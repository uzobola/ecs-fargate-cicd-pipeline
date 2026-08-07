# All AWS resources in this state are created in the selected project Region.
#
# default_tags gives every supported AWS resource the same ownership and
# inventory metadata without repeating the tag block in every resource.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# Read the AWS identity used by Terraform.
#
# Later outputs and validation can use this value without hardcoding an account
# number into reusable infrastructure code.
data "aws_caller_identity" "current" {}

# Read the active AWS Region from the provider session.
data "aws_region" "current" {}