# Discover Availability Zones that are currently available to this AWS account
# in the provider Region.
#
# AZ names are discovered rather than hardcoded so the Terraform configuration
# does not depend on fixed values such as us-east-1a or us-east-1b.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # The application spans two Availability Zones.
  #
  # Later resources such as the ALB and ECS service will use these same AZs.
  selected_azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Allocate one /24 public subnet per selected Availability Zone.
  #
  # With the default 10.20.0.0/16 VPC:
  #   first AZ  -> 10.20.0.0/24
  #   second AZ -> 10.20.1.0/24
  public_subnet_cidrs = {
    for index, az in local.selected_azs :
    az => cidrsubnet(var.vpc_cidr, 8, index)
  }

  # Allocate one /24 private subnet per selected Availability Zone.
  #
  # Starting private subnet numbering at 10 creates a visible separation from
  # the public subnet range:
  #   first AZ  -> 10.20.10.0/24
  #   second AZ -> 10.20.11.0/24
  private_subnet_cidrs = {
    for index, az in local.selected_azs :
    az => cidrsubnet(var.vpc_cidr, 8, index + 10)
  }
}

# Create the application VPC.
#
# DNS support is required for normal AWS service name resolution inside the
# VPC. DNS hostnames are enabled so resources that need AWS DNS names later in
# the architecture can use them.
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# Create one future public subnet in each selected Availability Zone.
#
# A subnet is considered public when its route table later contains a default
# route to the Internet Gateway.
#
# Automatic public IPv4 assignment is disabled. Workloads do not receive public
# addresses merely because they are launched in one of these subnets.
resource "aws_subnet" "public" {
  for_each = local.public_subnet_cidrs

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = each.value

  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-public-${each.key}"
    Tier = "public"
  }
}

# Create one private application subnet in each selected Availability Zone.
#
# ECS Fargate tasks will be placed in these subnets later. They will not receive
# public IP addresses.
resource "aws_subnet" "private" {
  for_each = local.private_subnet_cidrs

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = each.value

  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-private-${each.key}"
    Tier = "private"
  }
}

# Attach an Internet Gateway to the VPC.
#
# Creating the gateway alone does not expose any workload to the internet.
# Internet connectivity exists only when a subnet route table later sends
# traffic to this gateway and the resource itself has an appropriate address
# and security policy.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}


# ---------------------------------------------------------------------------
# Public NAT Gateway Elastic IP addresses
# ---------------------------------------------------------------------------

# Allocate one Elastic IP address for each NAT Gateway.
#
# The resources use the same Availability Zone keys as the public subnets:
#
#   us-east-1a -> EIP for NAT Gateway A
#   us-east-1b -> EIP for NAT Gateway B
#
# Elastic IPs provide the stable public IPv4 addresses used by the public NAT
# Gateways for outbound internet traffic from private subnets.
resource "aws_eip" "nat" {
  for_each = aws_subnet.public

  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip-${each.key}"
  }
}


# ---------------------------------------------------------------------------
# Public NAT Gateways
# ---------------------------------------------------------------------------

# Create one public NAT Gateway in each public subnet.
#
# Each private subnet will later route through the NAT Gateway located in the
# same Availability Zone. This avoids making private workloads in one AZ
# dependent on a NAT Gateway located in another AZ.
#
# The NAT Gateway requires:
#
# - A subnet that can reach the Internet Gateway
# - An Elastic IP address
#
# The explicit dependency makes the required ordering visible to Terraform and
# to engineers reading the configuration.
resource "aws_nat_gateway" "main" {
  for_each = aws_subnet.public

  allocation_id     = aws_eip.nat[each.key].allocation_id
  subnet_id         = each.value.id
  connectivity_type = "public"

  tags = {
    Name = "${var.project_name}-nat-${each.key}"
  }

  depends_on = [
    aws_internet_gateway.main
  ]
}


# ---------------------------------------------------------------------------
# Public route table
# ---------------------------------------------------------------------------

# Both public subnets use one shared route table.
#
# Their routing requirement is identical:
#
#   VPC-local traffic -> local route
#   Internet traffic  -> Internet Gateway
#
# A separate public route table per Availability Zone would duplicate the same
# route without changing the network behavior.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-public-rt"
    Tier = "public"
  }
}

# Make the designated public-tier subnets functionally public by adding a
# default IPv4 route to the VPC Internet Gateway.
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

# Associate both public subnets with the shared public route table.
resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}


# ---------------------------------------------------------------------------
# Private route tables
# ---------------------------------------------------------------------------

# Create a separate private route table for each Availability Zone.
#
# Separate route tables are required here since each private subnet must use
# the NAT Gateway located in its own AZ.
resource "aws_route_table" "private" {
  for_each = aws_subnet.private

  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-private-rt-${each.key}"
    Tier = "private"
  }
}

# Send outbound IPv4 traffic from each private subnet through the NAT Gateway
# that uses the same Availability Zone key.
#
# Example:
#
#   private["us-east-1a"] -> nat["us-east-1a"]
#   private["us-east-1b"] -> nat["us-east-1b"]
#
# Keying both resource collections by Availability Zone makes the relationship
# explicit and prevents accidental cross-AZ routing.
resource "aws_route" "private_nat" {
  for_each = aws_subnet.private

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[each.key].id
}

# Associate each private subnet with its AZ-specific private route table.
resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}