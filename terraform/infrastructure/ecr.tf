# Private repository for the compiled frontend container image.
#
# Image tags are immutable so a tag such as a Git commit SHA cannot later be
# replaced with different image content.
#
# scan_on_push requests an ECR vulnerability scan whenever a new image is
# pushed.
#
# force_delete = false protects the repository from automatic deletion when
# images are still stored in it.

resource "aws_ecr_repository" "frontend" {
  name                 = local.frontend_repository_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Private repository for the Express backend container image.
#
# The controls intentionally match the frontend repository so both deployment
# artifacts follow the same image-management policy.
resource "aws_ecr_repository" "backend" {
  name                 = local.backend_repository_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}