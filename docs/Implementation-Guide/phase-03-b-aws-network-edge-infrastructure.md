# Phase 3B: AWS Network and Edge Infrastructure

## Purpose

This phase creates the AWS network, routing, security boundaries, and public
application-entry infrastructure required by the ECS Fargate runtime introduced
in Phase 3C.

The phase is divided into four parts:

```text
Part 1 - Multi-AZ VPC Foundation
Part 2 - Internet and Private Egress Routing
Part 3 - Network Security Boundaries
Part 4 - Application Load Balancer and Layer-7 Routing
```

The completed foundation is:

```text
                              Internet
                                 |
                                 v
                        Application ALB
                       us-east-1a + 1b
                        /             \
                       /               \
                 Frontend TG        Backend TG
                    :3000              :8080
                       \               /
                        \             /
                    Private subnets A/B
                         |         |
                       NAT-A     NAT-B
                         \         /
                         Internet
```

At the end of this phase, the target groups exist but contain no application
targets. Phase 3C adds the ECS Fargate workloads.

---

## Part 1: Multi-AZ VPC Foundation

### 3B.1 Architecture goals

This network design addresses several architecture qualities.

### Failure-domain separation

The application network spans two Availability Zones.

An Availability Zone is treated as a failure domain: resources within one AZ
may become unavailable together.

Using two AZs creates the foundation for the surviving AZ to continue operating
after a zonal failure.

### Redundancy

Two NAT Gateways provide two private-egress components.

Redundancy alone does not create High Availability. The redundant components
must be connected so that one failure does not remove the function from the
other failure domain.

### Fault isolation

Each private subnet routes through a NAT Gateway in its own Availability Zone.

```text
Private us-east-1a
        |
        v
Private Route Table A
        |
        v
NAT us-east-1a
```

and:

```text
Private us-east-1b
        |
        v
Private Route Table B
        |
        v
NAT us-east-1b
```

A NAT or routing failure in one AZ therefore does not remove private egress
from the surviving AZ.

### Blast-radius reduction

Separate private route tables let routing changes remain local to an
Availability Zone.

A bad route applied to the us-east-1a private route table does not
automatically change us-east-1b private routing.

### AZ independence

The design avoids making the private tier in one Availability Zone depend on a
NAT Gateway in another Availability Zone.

### Cost tradeoff

Two NAT Gateways cost more than a single shared NAT Gateway.

The additional cost is accepted to remove a cross-AZ private-egress dependency
for this challenge deployment.

---

### 3B.2 Define the VPC CIDR

Append to:

```text
terraform/infrastructure/variables.tf
```

```hcl
# IPv4 address space reserved for the application VPC.
#
# The /16 network provides enough address space to divide the VPC into
# multiple /24 subnets without changing the VPC CIDR later in this challenge.
#
# The subnet ranges themselves are calculated in network.tf with cidrsubnet()
# rather than being declared independently, which keeps the address plan
# derived from one authoritative VPC CIDR.
variable "vpc_cidr" {
  description = "IPv4 CIDR block assigned to the application VPC."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}
```

The address plan is:

```text
VPC             10.20.0.0/16

us-east-1a
Public           10.20.0.0/24
Private          10.20.10.0/24

us-east-1b
Public           10.20.1.0/24
Private          10.20.11.0/24
```

The gap between the public and private ranges makes the network tier easier to
recognize during troubleshooting.

---

### 3B.3 Discover Availability Zones

Create:

```text
terraform/infrastructure/network.tf
```

Begin with:

```hcl
# Discover Availability Zones currently available to this AWS account in the
# configured Region.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Use two Availability Zones for the challenge architecture.
  selected_azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Allocate /24 public-tier subnets from the VPC CIDR.
  public_subnet_cidrs = {
    for index, az in local.selected_azs :
    az => cidrsubnet(var.vpc_cidr, 8, index)
  }

  # Start private subnet numbering at 10 to maintain visible separation from
  # the public subnet range.
  private_subnet_cidrs = {
    for index, az in local.selected_azs :
    az => cidrsubnet(var.vpc_cidr, 8, index + 10)
  }
}
```

With the default VPC CIDR, the calculated ranges are:

```text
cidrsubnet(10.20.0.0/16, 8, 0)  -> 10.20.0.0/24
cidrsubnet(10.20.0.0/16, 8, 1)  -> 10.20.1.0/24
cidrsubnet(10.20.0.0/16, 8, 10) -> 10.20.10.0/24
cidrsubnet(10.20.0.0/16, 8, 11) -> 10.20.11.0/24
```

---

### 3B.4 Create the VPC

Add:

```hcl
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}
```

DNS support is required for normal AWS service name resolution from workloads
inside the VPC.

---

### 3B.5 Create public-tier subnets

Add:

```hcl
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
```

Automatic public IPv4 assignment is disabled.

A subnet becomes functionally public through routing, not merely from its name.

At this checkpoint, these are subnets designated for the public tier. They
become functionally public after the Internet Gateway route is added.

---

### 3B.6 Create private subnets

Add:

```hcl
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
```

ECS Fargate tasks will later run in these subnets without public IP addresses.

---

### 3B.7 Attach an Internet Gateway

Add:

```hcl
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}
```

Attaching an Internet Gateway to a VPC does not, by itself, make workloads
publicly reachable.

Public reachability requires the correct combination of:

```text
routing
addressing
security policy
```

---

### 3B.8 Validate the VPC foundation

Format:

```bash
terraform -chdir=terraform/infrastructure fmt -recursive
git diff --check
```

Validate:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure validate
```

Expected:

```text
Success! The configuration is valid.
```

Verify the execution identity:

```bash
aws-vault exec terraform -- \
  aws sts get-caller-identity
```

The ARN must contain:

```text
assumed-role/TerraformExecutionRole
```

Create the saved plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan \
  -out=network-foundation.tfplan
```

Expected:

```text
Plan: 6 to add, 0 to change, 0 to destroy.
```

The resources are:

```text
aws_vpc.main
aws_internet_gateway.main

aws_subnet.public["us-east-1a"]
aws_subnet.public["us-east-1b"]

aws_subnet.private["us-east-1a"]
aws_subnet.private["us-east-1b"]
```

---

### 3B.9 Review the network foundation plan

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure show \
  -no-color \
  network-foundation.tfplan \
| grep -E \
'(^  # |cidr_block|availability_zone[[:space:]]*=|enable_dns|map_public_ip_on_launch|Name[[:space:]]*=|Tier[[:space:]]*=|Plan:)'
```

Confirm:

```text
VPC:
10.20.0.0/16
enable_dns_support   = true
enable_dns_hostnames = true

Public-tier:
10.20.0.0/24
10.20.1.0/24
map_public_ip_on_launch = false

Private:
10.20.10.0/24
10.20.11.0/24
map_public_ip_on_launch = false

Plan: 6 to add, 0 to change, 0 to destroy.
```

---

### 3B.10 Apply the VPC foundation

Apply the reviewed plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure apply \
  network-foundation.tfplan
```

Expected:

```text
Apply complete! Resources: 6 added, 0 changed, 0 destroyed.
```

---

### 3B.11 Verify the VPC directly in AWS

Capture the VPC ID:

```bash
VPC_ID=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -raw vpc_id
)
```

Inspect it:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].{
    VpcId:VpcId,
    CidrBlock:CidrBlock,
    State:State,
    IsDefault:IsDefault
  }'
```

Required:

```text
CidrBlock = 10.20.0.0/16
State     = available
IsDefault = false
```

Verify DNS:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport
```

and:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames
```

Both values must be `true`.

---

### 3B.12 Verify the subnet layout

Run:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{
    Name:Tags[?Key==`Name`]|[0].Value,
    Tier:Tags[?Key==`Tier`]|[0].Value,
    AZ:AvailabilityZone,
    CIDR:CidrBlock,
    PublicIPv4OnLaunch:MapPublicIpOnLaunch,
    State:State
  }' \
  --output table
```

Required layout:

```text
public   us-east-1a   10.20.0.0/24    false
public   us-east-1b   10.20.1.0/24    false

private  us-east-1a   10.20.10.0/24   false
private  us-east-1b   10.20.11.0/24   false
```

---

## Part 2: Internet and Private Egress Routing

### 3B.13 Allocate NAT Elastic IP addresses

Add to `network.tf`:

```hcl
resource "aws_eip" "nat" {
  for_each = aws_subnet.public

  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip-${each.key}"
  }
}
```

One Elastic IP is allocated for each NAT Gateway.

---

### 3B.14 Create one NAT Gateway per Availability Zone

Add:

```hcl
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
```

The Availability Zone key preserves the relationship:

```text
public["us-east-1a"] -> nat["us-east-1a"]
public["us-east-1b"] -> nat["us-east-1b"]
```

---

### 3B.15 Create the shared public route table

Both public subnets require the same default route, so one shared route table is
used.

```hcl
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-public-rt"
    Tier = "public"
  }
}
```

Add the Internet Gateway route:

```hcl
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}
```

Associate both public subnets:

```hcl
resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}
```

At this point, the designated public-tier subnets are functionally public.

---

### 3B.16 Create AZ-specific private route tables

Add:

```hcl
resource "aws_route_table" "private" {
  for_each = aws_subnet.private

  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-private-rt-${each.key}"
    Tier = "private"
  }
}
```

Separate route tables are required since each private subnet must use a
different NAT Gateway.

---

### 3B.17 Route each private subnet through its local-AZ NAT Gateway

Add:

```hcl
resource "aws_route" "private_nat" {
  for_each = aws_subnet.private

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[each.key].id
}
```

Associate them:

```hcl
resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}
```

The resulting relationship is deterministic:

```text
private["us-east-1a"]
        |
        v
private route table["us-east-1a"]
        |
        v
nat["us-east-1a"]
```

and independently for `us-east-1b`.

---

### 3B.18 Add network outputs

Append to `outputs.tf`:

```hcl
output "vpc_id" {
  description = "ID of the application VPC."
  value       = aws_vpc.main.id
}

output "availability_zones" {
  description = "Availability Zones used by the application network."
  value       = local.selected_azs
}

output "public_subnet_ids_by_az" {
  description = "Public subnet IDs keyed by Availability Zone."

  value = {
    for az, subnet in aws_subnet.public :
    az => subnet.id
  }
}

output "private_subnet_ids_by_az" {
  description = "Private subnet IDs keyed by Availability Zone."

  value = {
    for az, subnet in aws_subnet.private :
    az => subnet.id
  }
}

output "internet_gateway_id" {
  description = "Internet Gateway attached to the application VPC."
  value       = aws_internet_gateway.main.id
}

output "nat_gateway_ids_by_az" {
  description = "Public NAT Gateway IDs keyed by Availability Zone."

  value = {
    for az, nat in aws_nat_gateway.main :
    az => nat.id
  }
}

output "nat_gateway_public_ips_by_az" {
  description = "NAT Gateway public IPv4 addresses keyed by Availability Zone."

  value = {
    for az, eip in aws_eip.nat :
    az => eip.public_ip
  }
}

output "public_route_table_id" {
  description = "Route table used by the public-tier subnets."
  value       = aws_route_table.public.id
}

output "private_route_table_ids_by_az" {
  description = "Private route table IDs keyed by Availability Zone."

  value = {
    for az, route_table in aws_route_table.private :
    az => route_table.id
  }
}
```

---

### 3B.19 Plan the routing layer

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan \
  -out=network-routing.tfplan
```

Expected:

```text
Plan: 14 to add, 0 to change, 0 to destroy.
```

The resources are:

```text
2 Elastic IPs
2 NAT Gateways

1 public route table
1 public default route
2 public subnet associations

2 private route tables
2 private default routes
2 private subnet associations
```

---

### 3B.20 Review the routing plan

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure show \
  -no-color \
  network-routing.tfplan \
| grep -E \
'(^  # |domain[[:space:]]*=|connectivity_type|allocation_id|subnet_id|destination_cidr_block|gateway_id|nat_gateway_id|route_table_id|Name[[:space:]]*=|Tier[[:space:]]*=|Plan:)'
```

Confirm:

```text
2 x EIP
domain = vpc

2 x NAT Gateway
connectivity_type = public

Public:
0.0.0.0/0 -> Internet Gateway

Private us-east-1a:
0.0.0.0/0 -> NAT us-east-1a

Private us-east-1b:
0.0.0.0/0 -> NAT us-east-1b

Plan: 14 to add, 0 to change, 0 to destroy.
```

---

### 3B.21 Apply the routing layer

Apply:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure apply \
  network-routing.tfplan
```

NAT Gateway creation may take several minutes.

Expected:

```text
Apply complete! Resources: 14 added, 0 changed, 0 destroyed.
```

---

### 3B.22 Verify NAT Gateways

Run:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=$VPC_ID" \
  --query 'NatGateways[].{
    NAT:NatGatewayId,
    State:State,
    Subnet:SubnetId,
    PublicIP:NatGatewayAddresses[0].PublicIp
  }' \
  --output table
```

Required:

```text
2 NAT Gateways
State = available
2 different public subnet IDs
2 public IPv4 addresses
```

Verify that each NAT subnet belongs to the same AZ as the private subnet whose
route table points to that NAT.

---

### 3B.23 Verify route tables

Run:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[].{
    Name:Tags[?Key==`Name`]|[0].Value,
    RouteTableId:RouteTableId,
    AssociatedSubnets:Associations[?SubnetId!=null].SubnetId,
    Routes:Routes[].{
      Destination:DestinationCidrBlock,
      Gateway:GatewayId,
      NAT:NatGatewayId
    }
  }'
```

Required public route:

```text
10.20.0.0/16 -> local
0.0.0.0/0    -> Internet Gateway
```

Required private route A:

```text
10.20.0.0/16 -> local
0.0.0.0/0    -> NAT-A
```

Required private route B:

```text
10.20.0.0/16 -> local
0.0.0.0/0    -> NAT-B
```

---

### 3B.24 Verify Terraform state and idempotency

Inspect the managed network resources:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure state list \
| grep -E \
'aws_vpc|aws_subnet|aws_internet_gateway|aws_eip|aws_nat_gateway|aws_route'
```

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan
```

Required:

```text
No changes. Your infrastructure matches the configuration.
```

---

### 3B.25 VPC and routing acceptance criteria

Parts 1 and 2 pass when:

- one non-default VPC exists with CIDR `10.20.0.0/16`
- DNS support and DNS hostnames are enabled
- two Availability Zones are used
- each AZ contains one public-tier and one private subnet
- no subnet automatically assigns public IPv4 addresses
- an Internet Gateway is attached
- both public subnets route to the Internet Gateway
- two NAT Gateways are `available`
- each NAT Gateway is located in a different public subnet/AZ
- each private subnet has its own route table
- each private route table points to the NAT Gateway in the same AZ
- a final Terraform plan reports no changes

---

## Part 3: Network Security Boundaries

This part establishes the network trust boundaries between the public
Application Load Balancer and the private frontend and backend application
tiers.

The intended traffic graph is:

```text
Internet -> ALB       TCP/80

ALB -> Frontend       TCP/3000
ALB -> Backend        TCP/8080
```

Frontend and backend workloads remain private and do not accept direct public
application ingress.

---

### 3B.26 Architecture goals

### Segmentation

The edge, frontend, and backend tiers use separate security groups.

```text
ALB security group
Frontend security group
Backend security group
```

### Least privilege

The frontend accepts TCP/3000 only from the ALB security group.

The backend accepts TCP/8080 only from the ALB security group.

### Attack-surface reduction

The public internet cannot connect directly to:

```text
frontend:3000
backend:8080
```

### Trust boundary

The ALB is the transition point between the public network and the private
application tiers.

### Defense in depth

ECS tasks will later receive several independent controls:

```text
private subnet
+
no public IPv4 address
+
application security group
+
ALB-only application ingress
+
non-root container runtime
```

### Blast-radius reduction

Frontend and backend policies are independent, so a rule change on one tier
does not automatically modify the other.

---

### 3B.27 Create the ALB security group

Create:

```text
terraform/infrastructure/security.tf
```

Add:

```hcl
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Controls traffic to and from the public Application Load Balancer."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-alb-sg"
    Tier = "edge"
  }
}
```

Allow public HTTP:

```hcl
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id

  description = "Allow public HTTP traffic to the application entry point."

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 80
  to_port     = 80
  ip_protocol = "tcp"
}
```

`0.0.0.0/0` is intentional here since the challenge application must be
publicly reachable.

The application containers themselves do not receive this rule.

---

### 3B.28 Create the frontend security group

Add:

```hcl
resource "aws_security_group" "frontend" {
  name        = "${var.project_name}-frontend-sg"
  description = "Controls network access for frontend ECS tasks."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-frontend-sg"
    Tier = "frontend"
  }
}
```

Allow the ALB to reach frontend TCP/3000:

```hcl
resource "aws_vpc_security_group_ingress_rule" "frontend_from_alb" {
  security_group_id = aws_security_group.frontend.id

  description = "Allow frontend application traffic from the ALB."

  referenced_security_group_id = aws_security_group.alb.id

  from_port   = 3000
  to_port     = 3000
  ip_protocol = "tcp"
}
```

Allow outbound HTTPS:

```hcl
resource "aws_vpc_security_group_egress_rule" "frontend_https" {
  security_group_id = aws_security_group.frontend.id

  description = "Allow HTTPS egress for AWS service access through NAT."

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"
}
```

---

### 3B.29 Create the backend security group

Add:

```hcl
resource "aws_security_group" "backend" {
  name        = "${var.project_name}-backend-sg"
  description = "Controls network access for backend ECS tasks."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-backend-sg"
    Tier = "backend"
  }
}
```

Allow backend application traffic only from the ALB:

```hcl
resource "aws_vpc_security_group_ingress_rule" "backend_from_alb" {
  security_group_id = aws_security_group.backend.id

  description = "Allow backend application traffic from the ALB."

  referenced_security_group_id = aws_security_group.alb.id

  from_port   = 8080
  to_port     = 8080
  ip_protocol = "tcp"
}
```

Allow outbound HTTPS:

```hcl
resource "aws_vpc_security_group_egress_rule" "backend_https" {
  security_group_id = aws_security_group.backend.id

  description = "Allow HTTPS egress for AWS service access through NAT."

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"
}
```

---

### 3B.30 Restrict ALB egress to application security groups

Allow ALB-to-frontend traffic:

```hcl
resource "aws_vpc_security_group_egress_rule" "alb_to_frontend" {
  security_group_id = aws_security_group.alb.id

  description = "Allow ALB traffic to frontend targets."

  referenced_security_group_id = aws_security_group.frontend.id

  from_port   = 3000
  to_port     = 3000
  ip_protocol = "tcp"
}
```

Allow ALB-to-backend traffic:

```hcl
resource "aws_vpc_security_group_egress_rule" "alb_to_backend" {
  security_group_id = aws_security_group.alb.id

  description = "Allow ALB traffic to backend targets."

  referenced_security_group_id = aws_security_group.backend.id

  from_port   = 8080
  to_port     = 8080
  ip_protocol = "tcp"
}
```

No frontend-to-backend rule exists.

The frontend container serves static files. Browser `/api` traffic reaches the
backend through the ALB rather than through the frontend container.

---

### 3B.31 Stateful security-group behavior

Security groups are stateful.

An allowed outbound connection such as:

```text
Backend task -> HTTPS destination:443
```

permits the response traffic for that established connection.

It does not grant an internet host permission to initiate a new inbound
connection to the backend.

The outbound rules therefore do not create public inbound reachability.

---

### 3B.32 Egress tradeoff

Frontend and backend egress is limited to TCP/443, but the destination CIDR is:

```text
0.0.0.0/0
```

This means a task may initiate HTTPS connections to any IPv4 destination.

The project accepts this for the challenge environment.

A stricter production design could use interface/gateway VPC endpoints and
more restrictive egress controls for AWS service access.

---

### 3B.33 Add the security-group output

Append to `outputs.tf`:

```hcl
output "security_group_ids" {
  description = "Security groups used by the ALB and ECS application tiers."

  value = {
    alb      = aws_security_group.alb.id
    frontend = aws_security_group.frontend.id
    backend  = aws_security_group.backend.id
  }
}
```

---

### 3B.34 Plan the security boundary

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan \
  -out=security-boundaries.tfplan
```

Expected:

```text
Plan: 10 to add, 0 to change, 0 to destroy.
```

Review:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure show \
  -no-color \
  security-boundaries.tfplan \
| grep -E \
'(^  # |description[[:space:]]*=|cidr_ipv4|referenced_security_group_id|from_port|to_port|ip_protocol|Plan:)'
```

Required traffic graph:

```text
Internet -> ALB       TCP/80

ALB -> Frontend       TCP/3000
ALB -> Backend        TCP/8080

Frontend -> outbound  TCP/443
Backend -> outbound   TCP/443
```

There must be no:

```text
Internet -> Frontend:3000
Internet -> Backend:8080
Frontend -> Backend:8080
```

---

### 3B.35 Apply the security boundary

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure apply \
  security-boundaries.tfplan
```

Expected:

```text
Apply complete! Resources: 10 added, 0 changed, 0 destroyed.
```

---

### 3B.36 Verify live security-group rules

Retrieve the Terraform outputs:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure output security_group_ids
```

Load the values into the current Git Bash session:

```bash
ALB_SG=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -json security_group_ids \
  | sed -n 's/.*"alb":"\([^"]*\)".*/\1/p'
)

FRONTEND_SG=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -json security_group_ids \
  | sed -n 's/.*"frontend":"\([^"]*\)".*/\1/p'
)

BACKEND_SG=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -json security_group_ids \
  | sed -n 's/.*"backend":"\([^"]*\)".*/\1/p'
)
```

Verify:

```bash
printf 'ALB:      %s\nFrontend: %s\nBackend:  %s\n' \
  "$ALB_SG" "$FRONTEND_SG" "$BACKEND_SG"
```

All three values must start with:

```text
sg-
```

---

### 3B.37 Verify ALB security rules

Run:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$ALB_SG" \
  --query 'SecurityGroupRules[].{
    Egress:IsEgress,
    Protocol:IpProtocol,
    From:FromPort,
    To:ToPort,
    CIDR:CidrIpv4,
    ReferencedSG:ReferencedGroupInfo.GroupId,
    Description:Description
  }' \
  --output table
```

Required:

```text
Ingress:
0.0.0.0/0 -> TCP/80

Egress:
Frontend SG -> TCP/3000
Backend SG  -> TCP/8080
```

---

### 3B.38 Verify frontend security rules

Run:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$FRONTEND_SG" \
  --query 'SecurityGroupRules[].{
    Egress:IsEgress,
    Protocol:IpProtocol,
    From:FromPort,
    To:ToPort,
    CIDR:CidrIpv4,
    ReferencedSG:ReferencedGroupInfo.GroupId,
    Description:Description
  }' \
  --output table
```

Required:

```text
Ingress:
ALB SG -> TCP/3000

Egress:
0.0.0.0/0 -> TCP/443
```

---

### 3B.39 Verify backend security rules

Run:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$BACKEND_SG" \
  --query 'SecurityGroupRules[].{
    Egress:IsEgress,
    Protocol:IpProtocol,
    From:FromPort,
    To:ToPort,
    CIDR:CidrIpv4,
    ReferencedSG:ReferencedGroupInfo.GroupId,
    Description:Description
  }' \
  --output table
```

Required:

```text
Ingress:
ALB SG -> TCP/8080

Egress:
0.0.0.0/0 -> TCP/443
```

---

### 3B.40 Prove negative security claims

Verify that application security groups do not accept direct public IPv4
ingress.

Frontend:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$FRONTEND_SG" \
  --query 'SecurityGroupRules[?IsEgress==`false` && CidrIpv4==`0.0.0.0/0`]'
```

Backend:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$BACKEND_SG" \
  --query 'SecurityGroupRules[?IsEgress==`false` && CidrIpv4==`0.0.0.0/0`]'
```

Required for both:

```json
[]
```

This supports the statement:

```text
Neither application security group accepts direct IPv4 internet ingress.
```

---

## Part 4: Application Load Balancer and Layer-7 Routing

### 3B.41 Load-balancing architecture

The ALB is the single public application entry point.

```text
                        Internet
                           |
                           v
                    Public ALB :80
                    /            \
                   /              \
             /api paths        other paths
                 |                 |
                 v                 v
           Backend TG         Frontend TG
             :8080               :3000
```

The ALB spans the two public subnets.

This creates failure-domain separation at the public entry tier.

---

### 3B.42 Architecture qualities

### Load distribution

The ALB can distribute requests across multiple healthy targets registered in a
target group.

### Decoupling

Clients use one ALB hostname instead of knowing ECS task IP addresses.

### Health-based routing

Unhealthy targets can be removed from active request routing.

### Horizontal-scaling support

More ECS tasks may be registered behind the same target group without changing
the public endpoint.

### Service isolation

Frontend and backend use separate target groups and independent health states.

### High Availability at the entry tier

The ALB spans two Availability Zones.

This statement applies to the load-balancing tier. Application-level High
Availability depends on the number and placement of healthy ECS tasks.

---

### 3B.43 Create the Application Load Balancer

Create:

```text
terraform/infrastructure/load_balancer.tf
```

Add:

```hcl
resource "aws_lb" "application" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"

  security_groups = [
    aws_security_group.alb.id
  ]

  subnets = [
    for az in local.selected_azs :
    aws_subnet.public[az].id
  ]

  drop_invalid_header_fields = true

  enable_deletion_protection = false

  tags = {
    Name = "${var.project_name}-alb"
    Tier = "edge"
  }
}
```

The challenge environment uses deletion protection `false` so the temporary
infrastructure can be removed after validation.

---

### 3B.44 Create the frontend target group

Add:

```hcl
resource "aws_lb_target_group" "frontend" {
  name = "${var.project_name}-frontend-tg"

  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled = true

    protocol = "HTTP"
    path     = "/"
    port     = "traffic-port"

    matcher = "200-399"

    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = {
    Name = "${var.project_name}-frontend-tg"
    Tier = "frontend"
  }
}
```

Fargate tasks using `awsvpc` networking register by IP address, so the target
type is `ip`.

The frontend health check verifies that Nginx is serving the compiled
application.

---

### 3B.45 Create the backend target group

Add:

```hcl
resource "aws_lb_target_group" "backend" {
  name = "${var.project_name}-backend-tg"

  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled = true

    protocol = "HTTP"
    path     = "/health"
    port     = "traffic-port"

    matcher = "200"

    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = {
    Name = "${var.project_name}-backend-tg"
    Tier = "backend"
  }
}
```

The backend uses its explicit `/health` endpoint as the target-health signal.

---

### 3B.46 Create the public HTTP listener

Add:

```hcl
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.application.arn

  port     = 80
  protocol = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}
```

The challenge uses HTTP since no managed DNS name or ACM certificate is part of
the current scope.

A production deployment would normally terminate TLS at the ALB and redirect
HTTP to HTTPS.

This is an accepted challenge-environment tradeoff rather than a claim that
HTTP is the preferred production design.

---

### 3B.47 Add backend path-based routing

Add:

```hcl
resource "aws_lb_listener_rule" "backend_api" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    path_pattern {
      values = [
        "/api",
        "/api/*"
      ]
    }
  }
}
```

Routing behavior is:

```text
/api
/api/*
    |
    v
backend target group
```

All unmatched paths use the listener default action:

```text
/
static assets
frontend routes
other paths
    |
    v
frontend target group
```

---

### 3B.48 Why both `/api` and `/api/*` are used

The exact path:

```text
/api
```

must reach the backend.

Nested API paths such as:

```text
/api/users
/api/orders/123
/api/v1/status
```

must reach the backend too.

The combination:

```text
/api
/api/*
```

covers both cases.

---

### 3B.49 Layer-3 versus Layer-7 routing

The project now uses different kinds of routing.

### VPC route tables

These make network-layer decisions:

```text
Where should traffic for this destination IP network go?
```

Example:

```text
0.0.0.0/0 -> NAT Gateway
```

### ALB listener rules

These make HTTP application-layer decisions:

```text
Which application service should handle this request?
```

Example:

```text
/api/* -> backend target group
```

### Target groups

These decide which healthy workload instances may receive requests for that
service.

The conceptual chain is:

```text
Route table
    |
    v
network path

ALB listener rule
    |
    v
service selection

Target group
    |
    v
healthy workload selection
```

---

### 3B.50 Same-origin browser routing

The frontend uses a relative API path:

```text
/api
```

The browser therefore uses the same ALB origin for both application layers:

```text
http://<alb-dns>/
http://<alb-dns>/api
```

The browser does not need to know backend ECS task addresses.

This reduces browser-side configuration and avoids using a separate backend
origin for this challenge.

---

### 3B.51 Backend health endpoint is not publicly routed

The backend target group health checker calls:

```text
/health
```

directly against registered backend targets.

The listener does not include a public `/health -> backend` rule.

A public request to:

```text
http://<alb-dns>/health
```

does not match `/api` and therefore follows the frontend default route.

The backend health endpoint does not need a dedicated public routing rule.

---

### 3B.52 Add ALB outputs

Append to `outputs.tf`:

```hcl
output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer."
  value       = aws_lb.application.dns_name
}

output "alb_arn" {
  description = "ARN of the public Application Load Balancer."
  value       = aws_lb.application.arn
}

output "target_group_arns" {
  description = "Target groups used by the frontend and backend ECS services."

  value = {
    frontend = aws_lb_target_group.frontend.arn
    backend  = aws_lb_target_group.backend.arn
  }
}

output "http_listener_arn" {
  description = "ARN of the ALB HTTP listener."
  value       = aws_lb_listener.http.arn
}
```

---

### 3B.53 Plan the ALB foundation

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan \
  -out=alb-foundation.tfplan
```

Expected:

```text
Plan: 5 to add, 0 to change, 0 to destroy.
```

Resources:

```text
aws_lb.application
aws_lb_target_group.frontend
aws_lb_target_group.backend
aws_lb_listener.http
aws_lb_listener_rule.backend_api
```

---

### 3B.54 Review the ALB plan

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure show \
  -no-color \
  alb-foundation.tfplan \
| grep -E \
'(^  # |internal[[:space:]]*=|load_balancer_type|drop_invalid_header_fields|port[[:space:]]*=|protocol[[:space:]]*=|target_type|path[[:space:]]*=|matcher|priority|values[[:space:]]*=|deregistration_delay|Plan:)'
```

Confirm:

```text
ALB
internal = false
load_balancer_type = application
drop_invalid_header_fields = true

Listener
HTTP :80

Frontend target group
HTTP :3000
target_type = ip
health path = /
matcher = 200-399

Backend target group
HTTP :8080
target_type = ip
health path = /health
matcher = 200

Backend listener rule
priority = 100
/api
/api/*

Plan: 5 to add, 0 to change, 0 to destroy.
```

---

### 3B.55 Apply the ALB foundation

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure apply \
  alb-foundation.tfplan
```

Expected:

```text
Apply complete! Resources: 5 added, 0 changed, 0 destroyed.
```

---

### 3B.56 Verify the ALB directly in AWS

Capture:

```bash
ALB_DNS=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -raw alb_dns_name
)
```

Inspect the load balancer:

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-load-balancers \
  --names ecs-fargate-cicd-alb \
  --query 'LoadBalancers[0].{
    DNSName:DNSName,
    Scheme:Scheme,
    Type:Type,
    State:State.Code,
    VpcId:VpcId,
    AZs:AvailabilityZones[].{
      AZ:ZoneName,
      Subnet:SubnetId
    }
  }'
```

Required:

```text
Scheme = internet-facing
Type   = application
State  = active

Availability Zones:
us-east-1a
us-east-1b
```

---

### 3B.57 Verify target-group configuration

Run:

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-target-groups \
  --names \
    ecs-fargate-cicd-frontend-tg \
    ecs-fargate-cicd-backend-tg \
  --query 'TargetGroups[].{
    Name:TargetGroupName,
    Port:Port,
    Protocol:Protocol,
    TargetType:TargetType,
    HealthPath:HealthCheckPath,
    Matcher:Matcher.HttpCode
  }' \
  --output table
```

Required:

```text
Frontend
Port       3000
Protocol   HTTP
TargetType ip
HealthPath /
Matcher    200-399

Backend
Port       8080
Protocol   HTTP
TargetType ip
HealthPath /health
Matcher    200
```

---

### 3B.58 Verify target groups are empty before ECS

Capture target-group ARNs:

```bash
FRONTEND_TG=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -json target_group_arns \
  | sed -n 's/.*"frontend":"\([^"]*\)".*/\1/p'
)

BACKEND_TG=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -json target_group_arns \
  | sed -n 's/.*"backend":"\([^"]*\)".*/\1/p'
)
```

Check:

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-target-health \
  --target-group-arn "$FRONTEND_TG"
```

and:

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-target-health \
  --target-group-arn "$BACKEND_TG"
```

Before ECS exists, both should return:

```json
{
  "TargetHealthDescriptions": []
}
```

This proves the load-balancing infrastructure exists but no application
workloads have registered yet.

---

### 3B.59 Verify the listener and routing rule

Capture the listener:

```bash
LISTENER_ARN=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -raw http_listener_arn
)
```

Verify the default action:

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-listeners \
  --listener-arns "$LISTENER_ARN" \
  --query 'Listeners[].{
    Port:Port,
    Protocol:Protocol,
    DefaultTargetGroup:DefaultActions[0].TargetGroupArn
  }'
```

The listener must use:

```text
HTTP :80
```

with the frontend target group as its default action.

Inspect rules:

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-rules \
  --listener-arn "$LISTENER_ARN" \
  --query 'Rules[].{
    Priority:Priority,
    Conditions:Conditions,
    Actions:Actions
  }'
```

Confirm:

```text
/api
/api/*
    ->
backend target group
```

and a default frontend action.

---

### 3B.60 Verify pre-ECS public behavior

Before ECS tasks register, request:

```bash
curl -i "http://$ALB_DNS/"
```

and:

```bash
curl -i "http://$ALB_DNS/api"
```

An HTTP `503 Service Unavailable` is expected at this checkpoint.

The response demonstrates that:

```text
DNS resolves
        |
        v
ALB receives request
        |
        v
listener selects target group
        |
        v
no healthy targets exist
        |
        v
503
```

This is different from a DNS failure, timeout, or network-connectivity failure.

---

### 3B.61 Verify Terraform idempotency

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan
```

Required:

```text
No changes. Your infrastructure matches the configuration.
```

---

### 3B.62 Security and ALB acceptance criteria

Parts 3 and 4 pass when:

- three separate security groups exist for ALB, frontend, and backend
- public ingress exists only on ALB TCP/80
- frontend TCP/3000 accepts traffic only from the ALB security group
- backend TCP/8080 accepts traffic only from the ALB security group
- neither application security group accepts direct public IPv4 ingress
- frontend and backend egress is limited to TCP/443
- the ALB is internet-facing and active
- the ALB spans both selected Availability Zones
- frontend target group uses HTTP/3000 and target type `ip`
- backend target group uses HTTP/8080 and target type `ip`
- frontend health check uses `/`
- backend health check uses `/health`
- `/api` and `/api/*` route to the backend target group
- unmatched paths route to the frontend target group
- pre-ECS target groups contain no registered targets
- a final Terraform plan reports no changes

---

## Phase 3B result

The project now has a validated multi-AZ network and public application-entry
layer:

```text
                              Internet
                                 |
                                 v
                        Application ALB
                       us-east-1a + 1b
                        /             \
                       /               \
                   :3000               :8080
                     |                   |
                 Frontend TG         Backend TG
                  no targets          no targets
                     |                   |
                 Frontend SG         Backend SG
                     |                   |
            private subnet A/B   private subnet A/B
                     |                   |
                 AZ-local NAT        AZ-local NAT
                     \                   /
                      \                 /
                       Internet Gateway
```

The network layer provides multi-AZ placement, AZ-local private egress,
fault-domain separation, and routing isolation.

The security layer restricts the application tiers to ALB-originated
application traffic.

The load-balancing layer provides one public endpoint, service-specific target
groups, health-check configuration, and path-based Layer-7 routing.

Phase 3C introduces ECS Fargate and registers healthy frontend and backend
application targets behind the load balancer.
