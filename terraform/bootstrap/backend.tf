#  This bootstrap configuration's state is stored in the S3 bucket created by this
# configuration.
#
# The bucket name would depend  on the authenticated AWS
# account and is supplied during `terraform init` through `-backend-config`.
#
# Credentials are never written here. aws-vault provides temporary credentials
# for TerraformExecutionRole through environment variables.

terraform {
  backend "s3" {
    # Keep bootstrap state separate from the main infrastructure state.
    key = "bootstrap/terraform.tfstate"

    # The state bucket was created in us-east-1.
    region = "us-east-1"

    # Request server-side encryption for both the state and lock objects.
    encrypt = true

    # Use S3-native state locking. Terraform creates a temporary
    # bootstrap/terraform.tfstate.tflock object during protected operations.
    use_lockfile = true
  }
}
