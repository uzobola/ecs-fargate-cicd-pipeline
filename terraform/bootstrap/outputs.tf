output "state_bucket_name" {
  description = "Name of the S3 bucket used for Terraform remote state."
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  description = "ARN of the S3 bucket used for Terraform remote state."
  value       = aws_s3_bucket.terraform_state.arn
}

output "backend_configuration" {
  description = "Values required by the main Terraform S3 backend."
  value = {
    bucket       = aws_s3_bucket.terraform_state.id
    key          = "infrastructure/terraform.tfstate"
    region       = var.aws_region
    encrypt      = true
    use_lockfile = true
  }
}
