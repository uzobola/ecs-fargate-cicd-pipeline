# ---------------------------------------------------------------------------
# Application Load Balancer security group
# ---------------------------------------------------------------------------

# The ALB is the only internet-facing application component.
#
# Application tasks remain in private subnets and accept inbound application
# traffic only from this security group.
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Controls traffic to and from the public Application Load Balancer."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-alb-sg"
    Tier = "edge"
  }
}


# Permit public HTTP traffic to the ALB.
#
# 0.0.0.0/0 is intentional here since the challenge application must be
# publicly reachable.
#
# The application containers themselves are not exposed to this CIDR.
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id

  description = "Allow public HTTP traffic to the application entry point."

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 80
  to_port     = 80
  ip_protocol = "tcp"
}


# ---------------------------------------------------------------------------
# Frontend security group
# ---------------------------------------------------------------------------

# The frontend task runs in private subnets.
#
# It receives HTTP traffic only from the ALB security group. Direct internet
# access to the frontend container port is not permitted.
resource "aws_security_group" "frontend" {
  name        = "${var.project_name}-frontend-sg"
  description = "Controls network access for frontend ECS tasks."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-frontend-sg"
    Tier = "frontend"
  }
}


# Allow the ALB to reach the frontend Nginx listener.
#
# Referencing the ALB security group rather than an IP range ties this rule to
# the application entry-point identity instead of to addresses that may change.
resource "aws_vpc_security_group_ingress_rule" "frontend_from_alb" {
  security_group_id = aws_security_group.frontend.id

  description = "Allow frontend application traffic from the ALB."

  referenced_security_group_id = aws_security_group.alb.id

  from_port   = 3000
  to_port     = 3000
  ip_protocol = "tcp"
}


# Permit outbound HTTPS from the frontend task ENI.
#
# Fargate tasks require outbound connectivity to AWS services used during task
# startup and operation, including container-image retrieval and logging.
#
# Traffic leaves the private subnet through the AZ-local NAT Gateway.
resource "aws_vpc_security_group_egress_rule" "frontend_https" {
  security_group_id = aws_security_group.frontend.id

  description = "Allow HTTPS egress for AWS service access through NAT."

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"
}


# ---------------------------------------------------------------------------
# Backend security group
# ---------------------------------------------------------------------------

# The backend task runs in private subnets and is never exposed directly to the
# internet.
#
# Browser requests to /api reach the ALB first. The ALB then forwards those
# requests to the backend target group.
resource "aws_security_group" "backend" {
  name        = "${var.project_name}-backend-sg"
  description = "Controls network access for backend ECS tasks."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-backend-sg"
    Tier = "backend"
  }
}


# Allow backend application traffic only from the ALB.
#
# The frontend security group is deliberately not granted access here. The
# static frontend container does not call the backend directly; the user's
# browser sends /api requests through the ALB.
resource "aws_vpc_security_group_ingress_rule" "backend_from_alb" {
  security_group_id = aws_security_group.backend.id

  description = "Allow backend application traffic from the ALB."

  referenced_security_group_id = aws_security_group.alb.id

  from_port   = 8080
  to_port     = 8080
  ip_protocol = "tcp"
}


# Permit outbound HTTPS from the backend task ENI for AWS service access.
resource "aws_vpc_security_group_egress_rule" "backend_https" {
  security_group_id = aws_security_group.backend.id

  description = "Allow HTTPS egress for AWS service access through NAT."

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"
}


# ---------------------------------------------------------------------------
# ALB-to-application egress
# ---------------------------------------------------------------------------

# Allow the ALB to send traffic to frontend targets on port 3000.
#
# Using a security-group reference limits this path to network interfaces
# carrying the frontend security group.
resource "aws_vpc_security_group_egress_rule" "alb_to_frontend" {
  security_group_id = aws_security_group.alb.id

  description = "Allow ALB traffic to frontend targets."

  referenced_security_group_id = aws_security_group.frontend.id

  from_port   = 3000
  to_port     = 3000
  ip_protocol = "tcp"
}


# Allow the ALB to send API and health-check traffic to backend targets on
# port 8080.
resource "aws_vpc_security_group_egress_rule" "alb_to_backend" {
  security_group_id = aws_security_group.alb.id

  description = "Allow ALB traffic to backend targets."

  referenced_security_group_id = aws_security_group.backend.id

  from_port   = 8080
  to_port     = 8080
  ip_protocol = "tcp"
}
