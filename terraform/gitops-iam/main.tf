# ---------------------------------------------------------------------------
# Existing GitHub Actions OIDC provider
# ---------------------------------------------------------------------------

# My AWS account already contains the GitHub Actions OIDC provider.
# I am reusing it rather than creating a duplicate account-level identity provider.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}


# ---------------------------------------------------------------------------
# Existing deployment resources
# ---------------------------------------------------------------------------

data "aws_ecr_repository" "frontend" {
  name = "${var.project_name}-frontend"
}

data "aws_ecr_repository" "backend" {
  name = "${var.project_name}-backend"
}

data "aws_iam_role" "frontend_execution" {
  name = "${var.project_name}-frontend-execution-role"
}

data "aws_iam_role" "backend_execution" {
  name = "${var.project_name}-backend-execution-role"
}


# ---------------------------------------------------------------------------
# GitHub Actions trust policy
# ---------------------------------------------------------------------------

# GitHub Actions may assume this role only when:
#
# 1. the token was issued for AWS STS, and
# 2. the workflow originates from the gitops branch of this repository.
#
# main, feature branches, forks, and unrelated repositories cannot use this
# trust relationship.
data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    sid     = "AllowGitHubActionsGitOpsBranch"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type = "Federated"

      identifiers = [
        data.aws_iam_openid_connect_provider.github.arn
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"

      values = [
        "sts.amazonaws.com"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"

      values = [
        "repo:${var.github_repository}:ref:refs/heads/${var.github_branch}"
      ]
    }
  }
}


# ---------------------------------------------------------------------------
# GitHub Actions deployment role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "github_actions_deploy" {
  name = "${var.project_name}-github-actions-deploy-role"

  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
    Purpose   = "GitHub Actions GitOps bonus"
  }
}


# ---------------------------------------------------------------------------
# GitHub Actions deployment permissions
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "github_actions_deploy" {

  # ECR authentication requires Resource "*".
  statement {
    sid    = "ECRAuthorization"
    effect = "Allow"

    actions = [
      "ecr:GetAuthorizationToken"
    ]

    resources = ["*"]
  }

  # Image publication is restricted to the two project repositories.
  statement {
    sid    = "PushApplicationImages"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart"
    ]

    resources = [
      data.aws_ecr_repository.frontend.arn,
      data.aws_ecr_repository.backend.arn
    ]
  }

  # GitHub Actions reads the current task definitions and creates new
  # deployment revisions containing the newly built image URIs.
  statement {
    sid    = "TaskDefinitionDeployment"
    effect = "Allow"

    actions = [
      "ecs:DescribeTaskDefinition",
      "ecs:RegisterTaskDefinition"
    ]

    resources = ["*"]
  }

  # Permit deployment only to the two challenge ECS services.
  statement {
    sid    = "UpdateApplicationServices"
    effect = "Allow"

    actions = [
      "ecs:DescribeServices",
      "ecs:UpdateService"
    ]

    resources = [
      "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${var.project_name}-cluster/${var.project_name}-frontend",
      "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${var.project_name}-cluster/${var.project_name}-backend"
    ]
  }

  # RegisterTaskDefinition must be able to pass the execution roles used by
  # Fargate, but no unrelated IAM roles.
  statement {
    sid    = "PassApplicationExecutionRoles"
    effect = "Allow"

    actions = [
      "iam:PassRole"
    ]

    resources = [
      data.aws_iam_role.frontend_execution.arn,
      data.aws_iam_role.backend_execution.arn
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"

      values = [
        "ecs-tasks.amazonaws.com"
      ]
    }
  }

  # Used for the same live post-deployment validation performed by Jenkins.
  statement {
    sid    = "DiscoverApplicationLoadBalancer"
    effect = "Allow"

    actions = [
      "elasticloadbalancing:DescribeLoadBalancers"
    ]

    resources = ["*"]
  }
}


resource "aws_iam_role_policy" "github_actions_deploy" {
  name = "${var.project_name}-github-actions-deployment"

  role   = aws_iam_role.github_actions_deploy.id
  policy = data.aws_iam_policy_document.github_actions_deploy.json
}
