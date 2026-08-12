# IAM Permissions Matrix

## Purpose

This document converts the project's IAM security claims into reviewable
evidence.

For each workload identity it records:

```text
Who may assume the identity
What actions it may perform
Which resources it may access
Which IAM conditions apply
Why the permission exists
```

## Key Security Boundaries

Terraform execution role
    -> infrastructure authority

Jenkins EC2 role
    -> application deployment authority

GitHub Actions deployment role
    -> application deployment authority

Frontend / backend execution roles
    -> image pull + log publication only

Application containers
    -> no AWS API identity


## Trust / Role-Assumption Matrix

| Role                           | Trusted Principal                    | STS Action                      | Conditions                                                                                           | Rationale                                                                     |
| ------------------------------ | ------------------------------------ | ------------------------------- | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Jenkins EC2 role               | `ec2.amazonaws.com`                  | `sts:AssumeRole`                | EC2 service trust                                                                                    | Allows the Jenkins EC2 instance profile to obtain temporary AWS credentials   |
| Frontend ECS execution role    | `ecs-tasks.amazonaws.com`            | `sts:AssumeRole`                | ECS task service trust                                                                               | Allows ECS/Fargate infrastructure to pull the frontend image and publish logs |
| Backend ECS execution role     | `ecs-tasks.amazonaws.com`            | `sts:AssumeRole`                | ECS task service trust                                                                               | Allows ECS/Fargate infrastructure to pull the backend image and publish logs  |
| GitHub Actions deployment role | GitHub OIDC provider                 | `sts:AssumeRoleWithWebIdentity` | `aud = sts.amazonaws.com`; `sub` restricted to the immutable repository identity and `gitops` branch | Provides short-lived GitOps deployment credentials without static AWS keys    |
| Terraform execution role       | Environment-specific source identity | `sts:AssumeRole`                | Account-managed; verify source identity/MFA policy                                                   | Grants infrastructure-administration authority from the engineer workstation  |


## Permission Matrix

| Principal                      | Action                                                                                                                                               | Resource                                   | Condition                                       | Rationale                                                                     |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ | ----------------------------------------------- | ----------------------------------------------------------------------------- |
| Jenkins EC2 role               | `ecr:GetAuthorizationToken`                                                                                                                          | `*`                                        | None                                            | ECR authentication token API does not use repository-level resource scoping   |
| Jenkins EC2 role               | `ecr:BatchCheckLayerAvailability`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, `ecr:PutImage`, `ecr:DescribeImages` | Frontend and backend ECR repositories only | None                                            | Publish application images without access to unrelated repositories           |
| Jenkins EC2 role               | `ecs:DescribeTaskDefinition`, `ecs:RegisterTaskDefinition`                                                                                           | `*`                                        | None                                            | Create immutable deployment revisions from the current task definitions       |
| Jenkins EC2 role               | `ecs:UpdateService`, `ecs:DescribeServices`                                                                                                          | Frontend and backend ECS services only     | None                                            | Deploy only the two challenge services                                        |
| Jenkins EC2 role               | `elasticloadbalancing:DescribeLoadBalancers`                                                                                                         | `*`                                        | Read-only                                       | Discover the ALB DNS name for live validation                                 |
| Jenkins EC2 role               | `iam:PassRole`                                                                                                                                       | Frontend and backend execution roles only  | `iam:PassedToService = ecs-tasks.amazonaws.com` | Prevent Jenkins from passing unrelated IAM roles                              |
| Frontend execution role        | `ecr:GetAuthorizationToken`                                                                                                                          | `*`                                        | None                                            | Authenticate ECS infrastructure to ECR                                        |
| Frontend execution role        | `ecr:BatchCheckLayerAvailability`, `ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage`                                                                 | Frontend ECR repository only               | None                                            | Pull only the frontend image                                                  |
| Frontend execution role        | `logs:CreateLogStream`, `logs:PutLogEvents`                                                                                                          | Frontend CloudWatch log group only         | None                                            | Publish frontend container logs                                               |
| Backend execution role         | `ecr:GetAuthorizationToken`                                                                                                                          | `*`                                        | None                                            | Authenticate ECS infrastructure to ECR                                        |
| Backend execution role         | `ecr:BatchCheckLayerAvailability`, `ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage`                                                                 | Backend ECR repository only                | None                                            | Pull only the backend image                                                   |
| Backend execution role         | `logs:CreateLogStream`, `logs:PutLogEvents`                                                                                                          | Backend CloudWatch log group only          | None                                            | Publish backend container logs                                                |
| GitHub Actions deployment role | `ecr:GetAuthorizationToken`                                                                                                                          | `*`                                        | None                                            | Authenticate the GitOps workflow to ECR                                       |
| GitHub Actions deployment role | ECR image-upload actions                                                                                                                             | Frontend and backend ECR repositories only | None                                            | Publish GitOps-built application images                                       |
| GitHub Actions deployment role | `ecs:DescribeTaskDefinition`, `ecs:RegisterTaskDefinition`                                                                                           | `*`                                        | None                                            | Create GitOps deployment revisions                                            |
| GitHub Actions deployment role | `ecs:DescribeServices`, `ecs:UpdateService`                                                                                                          | Frontend and backend ECS services only     | None                                            | Restrict GitOps deployment to the two application services                    |
| GitHub Actions deployment role | `iam:PassRole`                                                                                                                                       | Frontend and backend execution roles only  | `iam:PassedToService = ecs-tasks.amazonaws.com` | Prevent GitHub Actions from passing unrelated IAM identities                  |
| GitHub Actions deployment role | `elasticloadbalancing:DescribeLoadBalancers`                                                                                                         | `*`                                        | Read-only                                       | Resolve the ALB for post-deployment validation                                |
| Application containers         | None                                                                                                                                                 | None                                       | No task IAM role                                | Application code does not require AWS API access                              |
| Terraform execution role       | Account-managed infrastructure permissions                                                                                                           | Environment resources + Terraform state    | Review externally                               | Infrastructure administration; exact policy is not defined in this repository |
