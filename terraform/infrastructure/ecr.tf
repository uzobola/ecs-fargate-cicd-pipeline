# Configure vulnerability scanning at the ECR registry level.
#
# Amazon ECR now manages scan-on-push behavior through registry scanning rules.
# Repositories that do not match a SCAN_ON_PUSH rule use manual scanning when
# Basic scanning is selected.
#
# This rule is intentionally scoped to this project's repository prefix rather
# than "*" so unrelated ECR repositories in the account are not pulled into
# this project's scanning policy.
#
# This resource manages the registry scanning configuration for us-east-1.
# The registry currently has BASIC scanning with no rules, so this configuration
# does not replace an existing organizational scanning policy.
resource "aws_ecr_registry_scanning_configuration" "project" {
  scan_type = "BASIC"

  rule {
    scan_frequency = "SCAN_ON_PUSH"

    repository_filter {
      filter      = "${var.project_name}-*"
      filter_type = "WILDCARD"
    }
  }
}

# Private repository for the compiled frontend container image.
#
# Image tags are immutable so a Git-source tag cannot later be overwritten with
# different image content.
#
# Vulnerability scan frequency is controlled by the registry-level scanning
# configuration above rather than the deprecated repository-level scan setting.
#
# force_delete = false prevents Terraform from automatically deleting a
# repository that still contains image artifacts.
resource "aws_ecr_repository" "frontend" {
  name                 = local.frontend_repository_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Private repository for the Express backend container image.
#
# The repository follows the same immutability, encryption, deletion, and
# registry-level vulnerability-scanning policy as the frontend repository.
resource "aws_ecr_repository" "backend" {
  name                 = local.backend_repository_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  encryption_configuration {
    encryption_type = "AES256"
  }
}