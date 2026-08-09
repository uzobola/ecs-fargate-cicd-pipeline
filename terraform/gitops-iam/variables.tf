variable "aws_region" {
  description = "AWS Region containing the challenge infrastructure."
  type        = string
  default     = "us-east-1"
}

variable "github_repository" {
  description = "GitHub repository allowed to assume the GitOps deployment role."
  type        = string
  default     = "uzobola/ecs-fargate-cicd-pipeline"
}

variable "github_branch" {
  description = "Only this branch may assume the GitOps deployment role."
  type        = string
  default     = "gitops"
}

variable "project_name" {
  description = "Project resource-name prefix."
  type        = string
  default     = "ecs-fargate-cicd"
}
