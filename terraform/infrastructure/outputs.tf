# Repository names are useful for AWS CLI and CI/CD commands.
output "frontend_ecr_repository_name" {
  description = "Name of the frontend ECR repository."
  value       = aws_ecr_repository.frontend.name
}

output "backend_ecr_repository_name" {
  description = "Name of the backend ECR repository."
  value       = aws_ecr_repository.backend.name
}

# Repository URLs are the registry destinations used when tagging Docker images
# before pushing them to ECR.
output "frontend_ecr_repository_url" {
  description = "ECR URI used to push and pull the frontend image."
  value       = aws_ecr_repository.frontend.repository_url
}

output "backend_ecr_repository_url" {
  description = "ECR URI used to push and pull the backend image."
  value       = aws_ecr_repository.backend.repository_url
}

# Record the account and Region discovered from the authenticated provider
# session. These outputs are useful deployment evidence and troubleshooting
# context.
output "deployment_context" {
  description = "AWS account and Region used by this Terraform state."

  value = {
    account_id = data.aws_caller_identity.current.account_id
    region     = data.aws_region.current.region
  }
}