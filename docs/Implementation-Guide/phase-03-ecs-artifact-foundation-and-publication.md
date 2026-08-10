# Supporting Guide: Terraform Application Foundation, ECR, and Image Publication

## Purpose

This supporting guide documents the application-infrastructure Terraform
workspace, Amazon ECR repository controls, application image publication, and
ECR vulnerability-scan validation that occur before the ECS runtime is created.

It is kept separate from Phase 3B so that Phase 3B can remain focused on the
AWS network and public application-entry architecture.

The guide covers:

```text
Terraform application state
        |
        v
Private ECR repositories
        |
        v
Immutable application image publication
        |
        v
ECR vulnerability-scan validation
```

The published images are consumed later by the ECS Fargate task definitions in
Phase 3C.

---

## ECR.1 Scope

This phase creates:

```text
aws_ecr_repository.frontend
aws_ecr_repository.backend
aws_ecr_registry_scanning_configuration.project
```

This phase does not create:

```text
VPC
subnets
route tables
NAT gateways
load balancers
ECS clusters
ECS services
Jenkins
```

Those components are introduced in later phases.

---

## ECR.2 State separation

The main infrastructure configuration uses the remote state bucket created in
Phase 3A.

Bootstrap state:

```text
bootstrap/terraform.tfstate
```

Main infrastructure state:

```text
infrastructure/terraform.tfstate
```

This separation prevents normal application infrastructure operations from
modifying the state record that manages the Terraform backend itself.

The main Terraform directory is:

```text
terraform/infrastructure/
```

---

## ECR.3 Create the infrastructure directory

From Git Bash:

```bash
cd /c/Users/uzobo/projects/1-percent-university/tech-challenge-1

mkdir -p terraform/infrastructure
```

Create:

```text
terraform/infrastructure/
├── backend.tf
├── versions.tf
├── providers.tf
├── variables.tf
├── locals.tf
├── ecr.tf
└── outputs.tf
```

Terraform and AWS commands in this phase run from Git Bash through the
`terraform` aws-vault profile.

Docker build and local runtime validation continue from WSL against the same
Windows checkout through:

```text
/mnt/c/Users/uzobo/projects/1-percent-university/tech-challenge-1
```

---

## ECR.4 Configure the main Terraform backend

Create:

```text
terraform/infrastructure/backend.tf
```

Use:

```hcl
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
```

The state bucket name is supplied during initialization.

No credentials are stored in this file.

---

## ECR.5 Configure Terraform and provider versions

Create:

```text
terraform/infrastructure/versions.tf
```

Use:

```hcl
# Keep Terraform and provider compatibility consistent with the validated
# bootstrap configuration.
terraform {
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

The infrastructure directory receives its own:

```text
.terraform.lock.hcl
```

The lock file is committed to Git.

The `.terraform/` directory is ignored.

---

## ECR.6 Define infrastructure variables

Create:

```text
terraform/infrastructure/variables.tf
```

Use:

```hcl
# Region for the application infrastructure.
variable "aws_region" {
  description = "AWS Region where application infrastructure is deployed."
  type        = string
  default     = "us-east-1"
}

# Stable project prefix used for names and tags.
variable "project_name" {
  description = "Project identifier used for AWS resource names and tags."
  type        = string
  default     = "ecs-fargate-cicd"
}

# Environment label used for resource inventory and filtering.
variable "environment" {
  description = "Deployment environment represented by this Terraform state."
  type        = string
  default     = "challenge"
}

# Human or team owner recorded in AWS tags.
variable "owner" {
  description = "Owner recorded on project resources."
  type        = string
  default     = "uzobola"
}
```

Only values with a reasonable chance of varying between deployments are exposed
as variables.

---

## ECR.7 Define shared names and tags

Create:

```text
terraform/infrastructure/locals.tf
```

Use:

```hcl
# Centralize names and shared tags so later networking, ECS, ALB, and Jenkins
# resources use the same naming model.
locals {
  frontend_repository_name = "${var.project_name}-frontend"
  backend_repository_name  = "${var.project_name}-backend"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = var.owner
  }
}
```

Expected repository names:

```text
ecs-fargate-cicd-frontend
ecs-fargate-cicd-backend
```

---

## ECR.8 Configure the AWS provider

Create:

```text
terraform/infrastructure/providers.tf
```

Use:

```hcl
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
```

The account number is discovered from the authenticated Terraform execution
session rather than hardcoded into the provider.

---

## ECR.9 Inspect the existing ECR registry scanning configuration

ECR registry scanning configuration applies at the AWS account and Region
level.

Before Terraform manages it, inspect the existing configuration:

```bash
aws-vault exec terraform -- \
  aws ecr get-registry-scanning-configuration \
  --region us-east-1
```

For this environment, the initial configuration returned:

```json
{
  "registryId": "421438965568",
  "scanningConfiguration": {
    "scanType": "BASIC",
    "rules": []
  }
}
```

No existing registry scanning rule was present.

This made it acceptable for this Terraform state to manage a project-specific
rule.

An environment containing an existing organizational registry rule requires a
review before Terraform takes ownership of this account-level setting.

Do not overwrite an existing enterprise scanning policy without that review.

---

## ECR.10 Configure ECR repositories and vulnerability scanning

Create:

```text
terraform/infrastructure/ecr.tf
```

Use the final configuration:

```hcl
# Configure vulnerability scanning at the ECR registry level.
#
# Amazon ECR manages scan-on-push behavior through registry scanning rules.
# Repositories that do not match a SCAN_ON_PUSH rule use manual scanning when
# Basic scanning is selected.
#
# This rule is intentionally scoped to this project's repository prefix rather
# than "*" so unrelated ECR repositories in the account are not pulled into
# this project's scanning policy.
#
# This resource manages the registry scanning configuration for us-east-1.
# The registry was verified to have BASIC scanning with no existing rules
# before Terraform took ownership of this setting.
resource "aws_ecr_registry_scanning_configuration" "project" {
  scan_type = "BASIC"

  rule {
    scan_frequency = "SCAN_ON_PUSH"

    repository_filter {
      filter      = "${var.project_name}-*"
      filter_type = "WILDCARD"
    }
  }
}

# Private repository for the compiled frontend container image.
#
# Image tags are immutable so a Git-source tag cannot later be overwritten with
# different image content.
#
# Vulnerability scan frequency is controlled by the registry-level scanning
# configuration above.
#
# force_delete = false prevents Terraform from automatically deleting a
# repository that still contains image artifacts.
resource "aws_ecr_repository" "frontend" {
  name                 = local.frontend_repository_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Private repository for the Express backend container image.
#
# The repository follows the same immutability, encryption, deletion, and
# registry-level vulnerability-scanning policy as the frontend repository.
resource "aws_ecr_repository" "backend" {
  name                 = local.backend_repository_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  encryption_configuration {
    encryption_type = "AES256"
  }
}
```

The final repository controls are:

```text
Private ECR repository
Immutable tags
AES256 encryption
force_delete = false
Registry-level BASIC SCAN_ON_PUSH rule
```

The scanning rule is scoped to:

```text
ecs-fargate-cicd-*
```

It does not intentionally select unrelated ECR repositories.

---

## ECR.11 Define Terraform outputs

Create:

```text
terraform/infrastructure/outputs.tf
```

Use:

```hcl
# Repository names are useful for AWS CLI and CI/CD commands.
output "frontend_ecr_repository_name" {
  description = "Name of the frontend ECR repository."
  value       = aws_ecr_repository.frontend.name
}

output "backend_ecr_repository_name" {
  description = "Name of the backend ECR repository."
  value       = aws_ecr_repository.backend.name
}

# Repository URLs are the registry destinations used when tagging Docker images
# before pushing them to ECR.
output "frontend_ecr_repository_url" {
  description = "ECR URI used to push and pull the frontend image."
  value       = aws_ecr_repository.frontend.repository_url
}

output "backend_ecr_repository_url" {
  description = "ECR URI used to push and pull the backend image."
  value       = aws_ecr_repository.backend.repository_url
}

# Record the account and Region discovered from the authenticated provider
# session. These outputs are useful deployment evidence and troubleshooting
# context.
output "deployment_context" {
  description = "AWS account and Region used by this Terraform state."

  value = {
    account_id = data.aws_caller_identity.current.account_id
    region     = data.aws_region.current.region
  }
}
```

---

## ECR.12 Format the configuration

From Git Bash:

```bash
terraform -chdir=terraform/infrastructure fmt -recursive
```

Check for formatting problems:

```bash
git diff --check
```

List the files:

```bash
find terraform/infrastructure \
  -maxdepth 1 \
  -type f \
  -print
```

Expected source files:

```text
terraform/infrastructure/backend.tf
terraform/infrastructure/ecr.tf
terraform/infrastructure/locals.tf
terraform/infrastructure/outputs.tf
terraform/infrastructure/providers.tf
terraform/infrastructure/variables.tf
terraform/infrastructure/versions.tf
```

---

## ECR.13 Verify the Terraform execution identity

Before initialization or provisioning:

```bash
aws-vault exec terraform -- \
  aws sts get-caller-identity
```

The ARN must contain:

```text
assumed-role/TerraformExecutionRole
```

It must not show the source IAM user ARN.

---

## ECR.14 Initialize the main remote backend

Set the state bucket:

```bash
BUCKET="ecs-fargate-cicd-tfstate-421438965568-us-east-1"
```

Initialize:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure init \
  -backend-config="bucket=$BUCKET"
```

No `-migrate-state` option is required.

This configuration begins directly with remote state and has no earlier local
state to transfer.

Expected ending:

```text
Successfully configured the backend "s3"!

Terraform has been successfully initialized!
```

Initialization creates:

```text
terraform/infrastructure/.terraform/
terraform/infrastructure/.terraform.lock.hcl
```

---

## ECR.15 Validate the Terraform configuration

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure validate
```

Expected:

```text
Success! The configuration is valid.
```

---

## ECR.16 Create a saved Terraform plan

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan \
  -out=ecr.tfplan
```

For a clean first deployment using the final configuration, the plan contains:

```text
aws_ecr_repository.frontend
aws_ecr_repository.backend
aws_ecr_registry_scanning_configuration.project
```

Review the plan rather than relying only on the resource count.

---

## ECR.17 Review ECR controls before apply

Render the saved plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure show \
  -no-color \
  ecr.tfplan
```

Focused review:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure show \
  -no-color \
  ecr.tfplan \
| grep -E \
'(^  # |name[[:space:]]*=|image_tag_mutability|force_delete|encryption_type|scan_type|scan_frequency|filter[[:space:]]*=|filter_type|Plan:)'
```

Confirm:

```text
ecs-fargate-cicd-frontend
ecs-fargate-cicd-backend

image_tag_mutability = "IMMUTABLE"
force_delete         = false
encryption_type      = "AES256"

scan_type      = "BASIC"
scan_frequency = "SCAN_ON_PUSH"
filter         = "ecs-fargate-cicd-*"
filter_type    = "WILDCARD"
```

No ECR repository should be marked for replacement.

No unexpected resource should be created.

---

## ECR.18 Apply the reviewed plan

Verify the identity again:

```bash
aws-vault exec terraform -- \
  aws sts get-caller-identity
```

Apply the saved plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure apply \
  ecr.tfplan
```

Confirm that no resources are destroyed.

---

## ECR.19 Capture repository outputs

Retrieve the repository names:

```bash
FRONTEND_REPO=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -raw frontend_ecr_repository_name
)

BACKEND_REPO=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -raw backend_ecr_repository_name
)

echo "Frontend: $FRONTEND_REPO"
echo "Backend:  $BACKEND_REPO"
```

Expected:

```text
Frontend: ecs-fargate-cicd-frontend
Backend:  ecs-fargate-cicd-backend
```

Retrieve repository URLs:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure output \
  frontend_ecr_repository_url

aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure output \
  backend_ecr_repository_url
```

Expected URI pattern:

```text
421438965568.dkr.ecr.us-east-1.amazonaws.com/<repository>
```

---

## ECR.20 Verify the live ECR repository controls

Query ECR directly:

```bash
aws-vault exec terraform -- \
  aws ecr describe-repositories \
  --repository-names \
    "$FRONTEND_REPO" \
    "$BACKEND_REPO" \
  --query 'repositories[].{
    Name:repositoryName,
    URI:repositoryUri,
    TagMutability:imageTagMutability,
    Encryption:encryptionConfiguration.encryptionType
  }' \
  --output table
```

Required values for both repositories:

```text
TagMutability = IMMUTABLE
Encryption    = AES256
```

Check the live registry scanning rule separately:

```bash
aws-vault exec terraform -- \
  aws ecr get-registry-scanning-configuration \
  --region us-east-1
```

Required configuration:

```text
scanType      = BASIC
scanFrequency = SCAN_ON_PUSH
filter        = ecs-fargate-cicd-*
filterType    = WILDCARD
```

---

## ECR.21 Confirm the repositories are empty before publication

Before image publication:

```bash
aws-vault exec terraform -- \
  aws ecr list-images \
  --repository-name "$FRONTEND_REPO"

aws-vault exec terraform -- \
  aws ecr list-images \
  --repository-name "$BACKEND_REPO"
```

A new repository should return an empty image list.

Terraform manages ECR infrastructure.

Docker and the future Jenkins pipeline manage image contents.

---

## ECR.22 Verify main Terraform state

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure state list
```

Expected resources include:

```text
data.aws_caller_identity.current
data.aws_region.current
aws_ecr_repository.backend
aws_ecr_repository.frontend
aws_ecr_registry_scanning_configuration.project
```

---

## ECR.23 Verify the main remote-state object

Set:

```bash
BUCKET="ecs-fargate-cicd-tfstate-421438965568-us-east-1"
```

Inspect:

```bash
aws-vault exec terraform -- \
  aws s3api head-object \
  --bucket "$BUCKET" \
  --key infrastructure/terraform.tfstate
```

Confirm:

```text
ContentLength        = non-zero
ServerSideEncryption = AES256
VersionId            = populated
```

This proves the main infrastructure is using:

```text
infrastructure/terraform.tfstate
```

rather than the bootstrap state key.

---

## ECR.24 Verify Terraform idempotency

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan
```

Required:

```text
No changes. Your infrastructure matches the configuration.
```

This closes the ECR infrastructure checkpoint.

---

## Part 2: Publish Application Images

## ECR.25 Artifact-tagging strategy

Do not use `latest` as the deployment identity.

The application image tag is derived from the most recent Git commit that
changed the frontend or backend application/container source.

From Git Bash:

```bash
APP_SHA=$(
  git log -1 \
    --format=%H \
    -- frontend backend \
  | cut -c1-12
)

echo "$APP_SHA"
```

For the validated deployment documented in this project:

```text
fbfbbe4665da
```

Later Terraform-only or documentation-only commits do not change this image tag.

This keeps the artifact tag tied to application source rather than unrelated
repository changes.

---

## ECR.26 Verify application source is clean

Before building:

```bash
git status --short -- frontend backend
```

Required:

```text
<no output>
```

Do not claim an image represents a Git SHA when the build context contains
uncommitted application changes.

---

## ECR.27 Rebuild the publication images

Switch to WSL and enter the shared Windows checkout:

```bash
cd /mnt/c/Users/uzobo/projects/1-percent-university/tech-challenge-1
```

Derive the same application SHA:

```bash
APP_SHA=$(
  git log -1 \
    --format=%H \
    -- frontend backend \
  | cut -c1-12
)

echo "$APP_SHA"
```

Build the backend:

```bash
docker build \
  --pull \
  --no-cache \
  -t tc1-backend:"$APP_SHA" \
  ./backend
```

Build the frontend:

```bash
docker build \
  --pull \
  --no-cache \
  -t tc1-frontend:"$APP_SHA" \
  ./frontend
```

The images are rebuilt before publication rather than relabeling an earlier
test image.

---

## ECR.28 Verify image platform

Run:

```bash
docker image inspect \
  tc1-backend:"$APP_SHA" \
  --format 'backend: {{.Os}}/{{.Architecture}}'

docker image inspect \
  tc1-frontend:"$APP_SHA" \
  --format 'frontend: {{.Os}}/{{.Architecture}}'
```

Expected:

```text
backend: linux/amd64
frontend: linux/amd64
```

This matches the planned ECS Fargate runtime architecture.

---

## ECR.29 Smoke-test the rebuilt backend image

Remove an earlier temporary container:

```bash
docker rm -f tc1-backend-publish 2>/dev/null || true
```

Run:

```bash
docker run -d \
  --name tc1-backend-publish \
  -p 8080:8080 \
  -e CORS_ORIGIN=http://localhost:3000 \
  tc1-backend:"$APP_SHA"
```

Verify health:

```bash
curl -fsS http://localhost:8080/health
echo
```

Expected:

```json
{"status":"ok"}
```

Verify API response:

```bash
curl -fsS http://localhost:8080/api
echo
```

Expected body shape:

```json
{"id":"<guid>"}
```

Verify runtime identity:

```bash
docker exec tc1-backend-publish id
```

Expected:

```text
uid=1000(node) ...
```

Remove the temporary container:

```bash
docker rm -f tc1-backend-publish
```

---

## ECR.30 Smoke-test the rebuilt frontend image

Remove an earlier temporary container:

```bash
docker rm -f tc1-frontend-publish 2>/dev/null || true
```

Run:

```bash
docker run -d \
  --name tc1-frontend-publish \
  -p 3000:3000 \
  tc1-frontend:"$APP_SHA"
```

Verify:

```bash
curl -fsS -o /dev/null \
  -w 'HTTP %{http_code} %{content_type}\n' \
  http://localhost:3000/
```

Expected:

```text
HTTP 200 text/html
```

Verify runtime identity:

```bash
docker exec tc1-frontend-publish id
```

Expected:

```text
uid=101(nginx) ...
```

Remove the temporary container:

```bash
docker rm -f tc1-frontend-publish
```

The complete router integration test does not need to be repeated here.

Phase 2 already established the frontend/backend routing behavior.

This checkpoint verifies the newly rebuilt publication images.

---

## ECR.31 Authenticate Docker to Amazon ECR

Return to Git Bash.

Set:

```bash
REGISTRY="421438965568.dkr.ecr.us-east-1.amazonaws.com"

APP_SHA=$(
  git log -1 \
    --format=%H \
    -- frontend backend \
  | cut -c1-12
)
```

Confirm Docker Desktop is reachable:

```bash
docker version
```

Both Client and Server sections must appear.

Verify AWS identity:

```bash
aws-vault exec terraform -- \
  aws sts get-caller-identity
```

The ARN must contain:

```text
assumed-role/TerraformExecutionRole
```

Authenticate Docker:

```bash
aws-vault exec terraform -- \
  aws ecr get-login-password \
  --region us-east-1 \
| docker login \
    --username AWS \
    --password-stdin "$REGISTRY"
```

Expected:

```text
Login Succeeded
```

AWS credentials remain in the Git Bash/aws-vault boundary.

WSL does not require AWS CLI or aws-vault.

---

## ECR.32 Tag the images for ECR

Frontend:

```bash
docker tag \
  tc1-frontend:"$APP_SHA" \
  "$REGISTRY/ecs-fargate-cicd-frontend:$APP_SHA"
```

Backend:

```bash
docker tag \
  tc1-backend:"$APP_SHA" \
  "$REGISTRY/ecs-fargate-cicd-backend:$APP_SHA"
```

Verify:

```bash
docker image inspect \
  "$REGISTRY/ecs-fargate-cicd-frontend:$APP_SHA" \
  --format '{{json .RepoTags}}'

docker image inspect \
  "$REGISTRY/ecs-fargate-cicd-backend:$APP_SHA" \
  --format '{{json .RepoTags}}'
```

---

## ECR.33 Push both images

Frontend:

```bash
docker push \
  "$REGISTRY/ecs-fargate-cicd-frontend:$APP_SHA"
```

Backend:

```bash
docker push \
  "$REGISTRY/ecs-fargate-cicd-backend:$APP_SHA"
```

The repositories use immutable tags.

Once `fbfbbe4665da` exists, a different image cannot silently replace that tag.

---

## ECR.34 Verify the tagged artifacts exist

Frontend:

```bash
aws-vault exec terraform -- \
  aws ecr describe-images \
  --repository-name ecs-fargate-cicd-frontend \
  --image-ids imageTag="$APP_SHA" \
  --query 'imageDetails[0].{
    Digest:imageDigest,
    Tags:imageTags,
    PushedAt:imagePushedAt,
    SizeBytes:imageSizeInBytes,
    ManifestType:imageManifestMediaType
  }'
```

Backend:

```bash
aws-vault exec terraform -- \
  aws ecr describe-images \
  --repository-name ecs-fargate-cicd-backend \
  --image-ids imageTag="$APP_SHA" \
  --query 'imageDetails[0].{
    Digest:imageDigest,
    Tags:imageTags,
    PushedAt:imagePushedAt,
    SizeBytes:imageSizeInBytes,
    ManifestType:imageManifestMediaType
  }'
```

Each artifact must have:

```text
Digest      = sha256:...
Tags        = <APP_SHA>
PushedAt    = populated
SizeBytes   = non-zero
ManifestType = populated
```

---

## ECR.35 Understand the OCI image-index structure

Docker BuildKit published the application tag as an OCI image index.

ECR displayed three related rows for each application artifact:

```text
Tagged OCI image index
        |
        +-- platform-specific container image
        |
        +-- small provenance/attestation manifest
```

For the frontend deployment:

```text
Tagged index:
sha256:6984132d99b446a66e9ff610a8339b1019f858cd8267c1310e14a5b73ee3e674

Platform image:
sha256:9c35064c946e148654af2783a47c05b2ea491a11c121ff24a303a8499eb3d4bb
```

For the backend deployment:

```text
Tagged index:
sha256:b785477b5c10ac772ee9ecd4bcd5195bb0ae14fab6ccac75e29e50cd7d76b726

Platform image:
sha256:d17aff133c979948b041ca72d9887710c0e5915168aa150c933d74a60d793236
```

The small untagged manifest is build/provenance metadata rather than another
copy of the running application.

One application tag can therefore produce several rows in the ECR console.

---

## ECR.36 Inspect the complete ECR artifact structure

Frontend:

```bash
aws-vault exec terraform -- \
  aws ecr describe-images \
  --repository-name ecs-fargate-cicd-frontend \
  --query 'imageDetails[].{
    Digest:imageDigest,
    Tags:imageTags,
    Size:imageSizeInBytes,
    ManifestType:imageManifestMediaType,
    ArtifactType:artifactMediaType
  }' \
  --output table
```

Backend:

```bash
aws-vault exec terraform -- \
  aws ecr describe-images \
  --repository-name ecs-fargate-cicd-backend \
  --query 'imageDetails[].{
    Digest:imageDigest,
    Tags:imageTags,
    Size:imageSizeInBytes,
    ManifestType:imageManifestMediaType,
    ArtifactType:artifactMediaType
  }' \
  --output table
```

The tagged artifact uses:

```text
application/vnd.oci.image.index.v1+json
```

The larger untagged manifest represents the actual platform image used for the
container runtime.

The very small manifest represents BuildKit metadata.

---

## ECR.37 Query vulnerability scans by platform-image digest

Do not query ECR Basic scan findings using the tagged OCI index.

The scan findings belong to the platform-specific image digest.

For the validated deployment:

```bash
FRONTEND_DIGEST="sha256:9c35064c946e148654af2783a47c05b2ea491a11c121ff24a303a8499eb3d4bb"

BACKEND_DIGEST="sha256:d17aff133c979948b041ca72d9887710c0e5915168aa150c933d74a60d793236"
```

Frontend:

```bash
aws-vault exec terraform -- \
  aws ecr describe-image-scan-findings \
  --repository-name ecs-fargate-cicd-frontend \
  --image-id imageDigest="$FRONTEND_DIGEST" \
  --query '{
    Status:imageScanStatus.status,
    CompletedAt:imageScanFindings.imageScanCompletedAt,
    SeverityCounts:imageScanFindings.findingSeverityCounts
  }'
```

Backend:

```bash
aws-vault exec terraform -- \
  aws ecr describe-image-scan-findings \
  --repository-name ecs-fargate-cicd-backend \
  --image-id imageDigest="$BACKEND_DIGEST" \
  --query '{
    Status:imageScanStatus.status,
    CompletedAt:imageScanFindings.imageScanCompletedAt,
    SeverityCounts:imageScanFindings.findingSeverityCounts
  }'
```

The validated deployment returned:

```text
Status = COMPLETE
```

for both images.

Severity counts were:

```json
{}
```

for both images.

This means ECR Basic reported no vulnerability findings at scan time.

---

## ECR.38 Query HIGH and CRITICAL findings explicitly

Frontend:

```bash
aws-vault exec terraform -- \
  aws ecr describe-image-scan-findings \
  --repository-name ecs-fargate-cicd-frontend \
  --image-id imageDigest="$FRONTEND_DIGEST" \
  --query 'imageScanFindings.findings[?severity==`CRITICAL` || severity==`HIGH`].{
    Severity:severity,
    Finding:name,
    Description:description,
    URI:uri
  }'
```

Backend:

```bash
aws-vault exec terraform -- \
  aws ecr describe-image-scan-findings \
  --repository-name ecs-fargate-cicd-backend \
  --image-id imageDigest="$BACKEND_DIGEST" \
  --query 'imageScanFindings.findings[?severity==`CRITICAL` || severity==`HIGH`].{
    Severity:severity,
    Finding:name,
    Description:description,
    URI:uri
  }'
```

The validated deployment returned:

```json
[]
```

for both images.

---

## ECR.39 Scanner scope

The correct project claim is:

```text
Both published platform images completed Amazon ECR Basic vulnerability scans
with no findings reported at scan time.
```

Do not claim:

```text
The application has no vulnerabilities.
```

ECR Basic scanning and the later Trivy CI control have different coverage.

The Jenkins phase will run Trivy as a separate image-security check.

---

## ECR.40 Capture ECR evidence

Create:

```text
docs/evidence/phase-3b/
```

Recommended evidence files:

```text
ecr-infrastructure-validation.txt
ecr-artifact-validation.txt
```

The infrastructure evidence should contain:

```text
Terraform execution identity
Live ECR repository controls
Registry scanning configuration
Terraform state inventory
Main remote-state metadata
Terraform idempotency result
```

The artifact evidence should contain:

```text
Application source tag
Frontend ECR artifact metadata
Backend ECR artifact metadata
OCI manifest structure
Frontend scan result
Backend scan result
HIGH/CRITICAL query results
```

Do not place credentials, session tokens, MFA codes, or ECR authorization
passwords in evidence files.

---

## ECR.41 Troubleshooting

### aws-vault not found during ECR login

Symptom:

```text
aws-vault: command not found
password is empty
```

Cause:

The ECR authentication command was executed from WSL.

This project uses:

```text
WSL
→ Docker build and local container validation

Git Bash
→ AWS CLI, aws-vault, Terraform, ECR authentication
```

Return to Git Bash before running:

```bash
aws-vault exec terraform -- \
  aws ecr get-login-password \
  --region us-east-1 \
| docker login \
    --username AWS \
    --password-stdin "$REGISTRY"
```

---

### ScanNotFoundException when querying by image tag

Symptom:

```text
ScanNotFoundException:
Image scan does not exist for imageTag <APP_SHA>
```

Cause:

The source-derived tag points to an OCI image index.

ECR Basic scan findings are associated with the referenced platform-image
digest.

Inspect the repository:

```bash
aws-vault exec terraform -- \
  aws ecr describe-images \
  --repository-name <repository> \
  --query 'imageDetails[].{
    Digest:imageDigest,
    Tags:imageTags,
    Size:imageSizeInBytes,
    ManifestType:imageManifestMediaType,
    ArtifactType:artifactMediaType
  }' \
  --output table
```

Query the scan using the platform-image digest rather than the OCI-index tag.

---

### Scan quota exceeded

Symptom:

```text
LimitExceededException:
The scan quota per image has been exceeded.
```

Cause:

The image already received a Basic scan within the allowed scan interval.

Do not repeatedly call:

```text
start-image-scan
```

Retrieve the existing findings instead:

```bash
aws-vault exec terraform -- \
  aws ecr describe-image-scan-findings \
  --repository-name <repository> \
  --image-id imageDigest="<platform-image-digest>"
```

---

### Invalid MFA code

Symptom:

```text
AccessDenied:
MultiFactorAuthentication failed with invalid MFA one time pass code
```

Retry the aws-vault command with a current MFA code.

A later command reaching ECR confirms that role assumption succeeded.

Do not alter IAM permissions to solve an expired or mistyped MFA code.

---

### Registry has BASIC scanning but no rules

Symptom:

```json
{
  "scanType": "BASIC",
  "rules": []
}
```

A repository-level `scan_on_push` field may still appear in repository metadata,
but the project uses the current registry-level scanning model.

Configure:

```hcl
resource "aws_ecr_registry_scanning_configuration" "project" {
  scan_type = "BASIC"

  rule {
    scan_frequency = "SCAN_ON_PUSH"

    repository_filter {
      filter      = "${var.project_name}-*"
      filter_type = "WILDCARD"
    }
  }
}
```

Inspect existing account-level rules before Terraform manages this resource.

---

## ECR.42 Verify final Terraform idempotency

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan
```

Required:

```text
No changes. Your infrastructure matches the configuration.
```

---

## ECR.43 Git safety checks

Terraform working files must remain excluded from Git.

Check:

```bash
git check-ignore -v \
  terraform/infrastructure/ecr.tfplan \
  terraform/infrastructure/ecr-scanning-fix.tfplan
```

Do not commit:

```text
*.tfplan
.terraform/
terraform.tfstate
terraform.tfstate.backup
```

Commit:

```text
terraform/infrastructure/backend.tf
terraform/infrastructure/ecr.tf
terraform/infrastructure/locals.tf
terraform/infrastructure/outputs.tf
terraform/infrastructure/providers.tf
terraform/infrastructure/variables.tf
terraform/infrastructure/versions.tf
terraform/infrastructure/.terraform.lock.hcl
docs/design-decisions.md
docs/evidence/phase-3b/
```

---

## ECR.44 Phase acceptance criteria

This guide passes when:

- Terraform runs through `TerraformExecutionRole`.
- Main infrastructure state uses `infrastructure/terraform.tfstate`.
- Frontend and backend ECR repositories exist.
- Both repositories use immutable image tags.
- Both repositories use AES256 encryption.
- `force_delete` is disabled.
- Registry Basic scanning contains a project-scoped `SCAN_ON_PUSH` rule.
- The main Terraform plan is idempotent.
- Application images are rebuilt from committed source before publication.
- The publication tag is derived from the application/container source commit.
- Both published artifacts exist in ECR.
- OCI index and platform-image identities are distinguished correctly.
- ECR Basic scans complete against both platform-image digests.
- No HIGH or CRITICAL findings are reported for the validated images.
- Terraform plan files and state files remain outside Git.

---

## ECR and Application Artifact Result

Phase 3B established the project's container artifact pipeline:

```text
Committed application source
        |
        | APP_SHA = fbfbbe4665da
        v
Rebuilt linux/amd64 images
        |
        | local smoke validation
        v
ECR authentication through
TerraformExecutionRole
        |
        v
Private ECR repositories
        |
        +-- immutable source-derived tag
        +-- AES256 encryption
        +-- protected repository deletion
        +-- BASIC SCAN_ON_PUSH rule
        |
        v
OCI image index
        |
        +-- platform container image
        +-- BuildKit provenance metadata
        |
        v
ECR Basic scan against
platform-image digest
```

Both platform images completed ECR Basic vulnerability scans with no findings
reported at scan time.

The published artifacts are now ready to be referenced by the later ECS task
definitions.
