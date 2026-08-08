# ---------------------------------------------------------------------------
# Jenkins Amazon Linux 2023 AMI
# ---------------------------------------------------------------------------

# Select the most recent standard x86_64 Amazon Linux 2023 AMI published by
# Amazon in the configured Region.
#
# The owner restriction prevents an unrelated third party from satisfying the
# AMI-name filter.
data "aws_ami" "jenkins_amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name = "name"

    values = [
      "al2023-ami-2023.*-kernel-*-x86_64"
    ]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}


# ---------------------------------------------------------------------------
# Jenkins SSH key
# ---------------------------------------------------------------------------

# Register only the operator's public SSH key with EC2.
#
# Terraform never receives or stores the corresponding private key.
resource "aws_key_pair" "jenkins" {
  key_name   = "${var.project_name}-jenkins"
  public_key = var.jenkins_public_key

  tags = {
    Name = "${var.project_name}-jenkins"
  }
}


# ---------------------------------------------------------------------------
# Jenkins EC2 role trust policy
# ---------------------------------------------------------------------------

# Permit the EC2 service to assume the Jenkins workload role.
data "aws_iam_policy_document" "jenkins_assume_role" {
  statement {
    sid     = "AllowEC2ToAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}


# ---------------------------------------------------------------------------
# Jenkins EC2 workload identity
# ---------------------------------------------------------------------------

# Jenkins receives AWS permissions through an EC2 instance profile.
#
# No long-lived AWS access key is stored on the server or inside Jenkins.
resource "aws_iam_role" "jenkins" {
  name = "${var.project_name}-${var.environment}-jenkins-role"

  assume_role_policy = data.aws_iam_policy_document.jenkins_assume_role.json

  tags = {
    Name = "${var.project_name}-jenkins-role"
    Tier = "cicd"
  }
}


# ---------------------------------------------------------------------------
# Jenkins deployment permissions
# ---------------------------------------------------------------------------

# The Jenkins deployment role is intentionally scoped to:
#
# - push images into the two project ECR repositories
# - read/register ECS task definitions
# - update the two application ECS services
# - pass only the two Fargate execution roles
#
# It cannot modify the VPC, ALB, ECS cluster, Terraform state, or IAM roles.
data "aws_iam_policy_document" "jenkins_deployment" {

  # ECR authorization tokens cannot be resource-scoped.
  statement {
    sid    = "GetECRAuthorizationToken"
    effect = "Allow"

    actions = [
      "ecr:GetAuthorizationToken"
    ]

    resources = ["*"]
  }

  # Push application images only to this project's frontend/backend
  # repositories.
  statement {
    sid    = "PushApplicationImages"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages"
    ]

    resources = [
      aws_ecr_repository.frontend.arn,
      aws_ecr_repository.backend.arn
    ]
  }

  # Task-definition registration and retrieval are required when Jenkins
  # produces a new immutable image revision.
  statement {
    sid    = "ManageTaskDefinitionRevisions"
    effect = "Allow"

    actions = [
      "ecs:DescribeTaskDefinition",
      "ecs:RegisterTaskDefinition"
    ]

    resources = ["*"]
  }

  # Jenkins may deploy only the two application services.
  statement {
    sid    = "DeployApplicationServices"
    effect = "Allow"

    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices"
    ]

    resources = [
      "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${aws_ecs_cluster.application.name}/${aws_ecs_service.frontend.name}",
      "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${aws_ecs_cluster.application.name}/${aws_ecs_service.backend.name}"
    ]
  }

  # Resolve the Terraform-created ALB DNS name during post-deployment validation.
  #
  # DescribeLoadBalancers is read-only and lets the pipeline verify the deployed
  # application without hardcoding a generated ALB hostname.
  statement {
    sid    = "DiscoverApplicationLoadBalancer"
    effect = "Allow"

    actions = [
      "elasticloadbalancing:DescribeLoadBalancers"
    ]

    resources = ["*"]
  }

  # RegisterTaskDefinition must be able to pass the execution roles referenced
  # by the frontend and backend task definitions.
  #
  # Jenkins cannot pass arbitrary IAM roles.
  statement {
    sid    = "PassOnlyApplicationExecutionRoles"
    effect = "Allow"

    actions = [
      "iam:PassRole"
    ]

    resources = [
      aws_iam_role.frontend_execution.arn,
      aws_iam_role.backend_execution.arn
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"

      values = [
        "ecs-tasks.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role_policy" "jenkins_deployment" {
  name = "${var.project_name}-jenkins-deployment"

  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins_deployment.json
}


# ---------------------------------------------------------------------------
# Jenkins instance profile
# ---------------------------------------------------------------------------

# EC2 receives IAM roles through an instance profile.
resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project_name}-${var.environment}-jenkins-profile"
  role = aws_iam_role.jenkins.name
}


# ---------------------------------------------------------------------------
# Jenkins network security boundary
# ---------------------------------------------------------------------------

resource "aws_security_group" "jenkins" {
  name        = "${var.project_name}-jenkins-sg"
  description = "Controls network access to the Jenkins CI/CD host."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-jenkins-sg"
    Tier = "cicd"
  }
}


# SSH administration is restricted to the operator's current public IPv4
# address rather than the public internet.
resource "aws_vpc_security_group_ingress_rule" "jenkins_ssh" {
  security_group_id = aws_security_group.jenkins.id

  description = "Allow SSH administration from the approved operator address."

  cidr_ipv4   = var.jenkins_admin_cidr
  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"
}


# Jenkins must be publicly reachable for GitHub webhook delivery.
#
# Authentication is enforced by Jenkins at the application layer.
resource "aws_vpc_security_group_ingress_rule" "jenkins_ui" {
  security_group_id = aws_security_group.jenkins.id

  description = "Allow public Jenkins UI and webhook access."

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 8080
  to_port     = 8080
  ip_protocol = "tcp"
}


# Jenkins needs outbound HTTPS for:
#
# - Jenkins package/plugin repositories
# - GitHub
# - ECR and ECS APIs
# - Docker registries
# - Trivy
# - Python package installation
#
# AmazonProvidedDNS traffic cannot be filtered using security groups, so a
# separate port-53 rule is not required.
resource "aws_vpc_security_group_egress_rule" "jenkins_https" {
  security_group_id = aws_security_group.jenkins.id

  description = "Allow HTTPS egress required by CI/CD tooling."

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"
}


# ---------------------------------------------------------------------------
# Jenkins EC2 instance
# ---------------------------------------------------------------------------

# Jenkins is deliberately placed in a public subnet.
#
# Unlike the application tasks, Jenkins must be reachable publicly and
# also by GitHub webhook delivery.
#
# Host configuration is intentionally not performed through user_data.
# Ansible owns operating-system and Jenkins configuration after provisioning.
resource "aws_instance" "jenkins" {
  ami           = data.aws_ami.jenkins_amazon_linux.id
  instance_type = var.jenkins_instance_type

  subnet_id = aws_subnet.public[local.selected_azs[0]].id

  associate_public_ip_address = false

  vpc_security_group_ids = [
    aws_security_group.jenkins.id
  ]

  key_name = aws_key_pair.jenkins.key_name

  iam_instance_profile = aws_iam_instance_profile.jenkins.name

  monitoring = true

  # Require IMDSv2 for retrieval of temporary instance-profile credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30

    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-jenkins"
    Tier = "cicd"
  }

  # The AMI data source selects a current Amazon Linux 2023 image for a new
  # Jenkins deployment.
  #
  # AWS regularly publishes newer AL2023 AMIs. A newer image appearing in the
  # data-source result should not cause Terraform to replace an already
  # configured Jenkins controller during an unrelated infrastructure change.
  #
  # AMI upgrades are treated as an explicit maintenance operation.
  lifecycle {
    ignore_changes = [
      ami
    ]
  }
}

# ---------------------------------------------------------------------------
# Stable Jenkins public IPv4 address
# ---------------------------------------------------------------------------

# A stable public address prevents the Jenkins URL and GitHub webhook
# destination from changing if the EC2 instance is stopped and started.
resource "aws_eip" "jenkins" {
  domain   = "vpc"
  instance = aws_instance.jenkins.id

  tags = {
    Name = "${var.project_name}-jenkins-eip"
  }

  depends_on = [
    aws_internet_gateway.main
  ]
}