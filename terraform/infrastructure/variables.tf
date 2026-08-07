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