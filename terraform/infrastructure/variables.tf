# Region for the application infrastructure.
variable "aws_region" {
  description = "AWS Region where application infrastructure is deployed."
  type        = string
  default     = "us-east-1"
}

# Stable project prefix used for names and tags.
variable "project_name" {
  description = "Project identifier used for AWS resource names and tags."
  type        = string
  default     = "ecs-fargate-cicd"
}

# Environment label used for resource inventory and filtering.
variable "environment" {
  description = "Deployment environment represented by this Terraform state."
  type        = string
  default     = "challenge"
}

# Human or team owner recorded in AWS tags.
variable "owner" {
  description = "Owner recorded on project resources."
  type        = string
  default     = "uzobola"
}

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

# Immutable ECR image tag used for the initial Terraform-managed ECS deployment.
#
# The tag identifies the most recent committed application/container source
# used to build the currently published frontend and backend images.
#
# Later Jenkins deployments will publish new immutable source-derived tags and
# register new ECS task-definition revisions.
variable "app_image_tag" {
  description = "Immutable ECR image tag used by the baseline ECS task definitions."
  type        = string
  default     = "fbfbbe4665da"
}

# ---------------------------------------------------------------------------
# Jenkins infrastructure inputs
# ---------------------------------------------------------------------------

# Restrict administrative SSH access to a single trusted public IPv4 address.
#
# This value is supplied through the local terraform.tfvars file and should
# normally use a /32 CIDR.
variable "jenkins_admin_cidr" {
  description = "Public IPv4 /32 CIDR permitted to SSH to the Jenkins host."
  type        = string

  validation {
    condition = (
      can(cidrnetmask(var.jenkins_admin_cidr)) &&
      endswith(var.jenkins_admin_cidr, "/32")
    )

    error_message = "jenkins_admin_cidr must be a valid IPv4 /32 CIDR."
  }
}

# Register an operator-supplied SSH public key with EC2.
#
# The private key remains outside Terraform and AWS.
variable "jenkins_public_key" {
  description = "OpenSSH public key registered for Jenkins host administration."
  type        = string

  validation {
    condition = (
      startswith(var.jenkins_public_key, "ssh-ed25519 ") ||
      startswith(var.jenkins_public_key, "ssh-rsa ")
    )

    error_message = "jenkins_public_key must be an OpenSSH ED25519 or RSA public key."
  }
}

# c7i-flex.large provides 2 vCPU and 4 GiB RAM and is currently shown as
# Free Tier eligible for my AWS account.
#
# Keeping this as a variable makes the host size easy to change without
# modifying the resource definition.
variable "jenkins_instance_type" {
  description = "EC2 instance type used by the Jenkins controller/build host."
  type        = string
  default     = "c7i-flex.large"
}