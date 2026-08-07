# Store the main infrastructure state in the S3 backend created during
# Phase 3A.
#
# The bucket name is supplied during `terraform init` rather than stored here.
# This keeps account-specific backend configuration separate from the reusable
# Terraform source.
#
# aws-vault supplies temporary TerraformExecutionRole credentials through the
# process environment. No AWS credentials are written into Terraform files.

terraform {
  backend "s3" {
    # Main application infrastructure uses a different state object from the
    # bootstrap configuration that manages the state bucket itself.
    key = "infrastructure/terraform.tfstate"

    region = "us-east-1"

    # Request S3 server-side encryption for the state object.
    encrypt = true

    # Use S3-native locking so competing Terraform operations cannot safely
    # write this state at the same time.
    use_lockfile = true
  }
}
