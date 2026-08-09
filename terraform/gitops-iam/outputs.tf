output "github_actions_role_arn" {
  description = "IAM role assumed by GitHub Actions through OIDC."

  value = aws_iam_role.github_actions_deploy.arn
}

output "github_oidc_provider_arn" {
  description = "Existing GitHub Actions OIDC provider reused by this configuration."

  value = data.aws_iam_openid_connect_provider.github.arn
}