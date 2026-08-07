variable "aws_region" {
  description = "AWS Region where the Terraform state bucket is created."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project identifier used in resource names and tags."
  type        = string
  default     = "ecs-fargate-cicd"
}

variable "environment" {
  description = "Environment classification for shared bootstrap resources."
  type        = string
  default     = "shared"
}

variable "owner" {
  description = "Owner recorded in AWS resource tags."
  type        = string
  default     = "uzobola"
}
