# Centralize names and shared tags so later networking, ECS, ALB, and Jenkins
# resources use the same naming model.
locals {
  frontend_repository_name = "${var.project_name}-frontend"
  backend_repository_name  = "${var.project_name}-backend"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = var.owner
  }
}