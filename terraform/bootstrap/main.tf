# Derive stable names and shared tags once, then reuse them across resources.
#
# The AWS account ID comes from the active authenticated session instead of
# being hardcoded. This reduces the risk of creating the state bucket in one
# account with a name that claims it belongs to another account.
locals {
  state_bucket_name = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  # These tags are applied through the provider's default_tags configuration.
  # They make the bucket's purpose and ownership visible in AWS inventory,
  # billing views, and security reviews.
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = var.owner
    Purpose     = "Terraform remote state"
  }
}

# Create the S3 bucket that will hold the main infrastructure's Terraform state.
#
# This bootstrap configuration uses local state since the remote state bucket
# cannot be used before it exists.
#
# force_destroy = false prevents Terraform from recursively deleting a bucket
# that still contains state files or historical versions. State removal must be
# a deliberate manual action.
resource "aws_s3_bucket" "terraform_state" {
  bucket        = local.state_bucket_name
  force_destroy = false
}

# Disable S3 ACL-based ownership and access control.
#
# BucketOwnerEnforced makes the bucket policy and IAM policies the authoritative
# access-control mechanisms. Objects written to the bucket belong to the bucket
# owner, and callers cannot use object ACLs to introduce another access path.
resource "aws_s3_bucket_ownership_controls" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Apply all four S3 Block Public Access controls.
#
# Together, these settings prevent new public ACLs and public bucket policies,
# ignore existing public ACLs, and prevent the bucket from operating as a
# publicly accessible resource.
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Keep historical versions of the Terraform state object.
#
# Terraform updates state by replacing the object stored at the backend key.
# Versioning provides a recovery path when state is overwritten, corrupted, or
# removed unintentionally.
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Declare default server-side encryption for objects stored in the bucket.
#
# AES256 selects S3-managed encryption keys (SSE-S3). This provides encryption
# at rest without adding a customer-managed KMS key, KMS policy, or KMS charges.
# A customer-managed key would be considered when a stated compliance,
# cross-account, or key-administration requirement justifies it.
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Build the bucket policy as structured Terraform data rather than embedding
# handwritten JSON.
#
# This statement denies every S3 action when the request is sent without TLS.
# The policy covers both:
# - The bucket itself
# - Every object stored under the bucket
#
# The wildcard principal is intentional in a Deny statement. It makes the TLS
# requirement apply to every caller, including principals that otherwise have
# permission through IAM.
data "aws_iam_policy_document" "terraform_state" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    actions = [
      "s3:*"
    ]

    resources = [
      aws_s3_bucket.terraform_state.arn,
      "${aws_s3_bucket.terraform_state.arn}/*"
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# Attach the TLS-enforcement policy to the state bucket.
#
# The dependency makes the intended creation sequence explicit: establish the
# public-access protections before attaching the bucket policy.
resource "aws_s3_bucket_policy" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  policy = data.aws_iam_policy_document.terraform_state.json

  depends_on = [
    aws_s3_bucket_public_access_block.terraform_state
  ]
}