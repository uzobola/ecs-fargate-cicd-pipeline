# Phase 3B: Amazon ECR Foundation and Image Publication

## Purpose

This phase creates private Amazon ECR repositories for the frontend and backend
container images, configures image-security controls, publishes the validated
application images, and verifies the resulting artifacts directly in AWS.

The phase establishes the artifact boundary used later by ECS and Jenkins.

The final flow is:

```text
Application source
        |
        | Docker build
        v
Local container image
        |
        | source-derived Git SHA tag
        v
Amazon ECR
        |
        +-- frontend image
        |
        +-- backend image
        |
        v
ECS task definitions
```

The ECR repositories are managed by Terraform.

Docker image contents are not managed by Terraform.

---

## 3B.1 Scope

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

## 3B.2 State separation

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

## 3B.3 Create the infrastructure directory

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

## 3B.4 Configure the main Terraform backend

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

## 3B.5 Configure Terraform and provider versions

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

## 3B.6 Define infrastructure variables

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

## 3B.7 Define shared names and tags

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

## 3B.8 Configure the AWS provider

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

## 3B.9 Inspect the existing ECR registry scanning configuration

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

## 3B.10 Configure ECR repositories and vulnerability scanning

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

## 3B.11 Define Terraform outputs

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

## 3B.12 Format the configuration

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

## 3B.13 Verify the Terraform execution identity

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

## 3B.14 Initialize the main remote backend

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

## 3B.15 Validate the Terraform configuration

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

## 3B.16 Create a saved Terraform plan

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

## 3B.17 Review ECR controls before apply

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

## 3B.18 Apply the reviewed plan

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

## 3B.19 Capture repository outputs

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

## 3B.20 Verify the live ECR repository controls

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

## 3B.21 Confirm the repositories are empty before publication

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

## 3B.22 Verify main Terraform state

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

## 3B.23 Verify the main remote-state object

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

## 3B.24 Verify Terraform idempotency

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

# Phase 3B.2: Publish Application Images

## 3B.25 Artifact-tagging strategy

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

## 3B.26 Verify application source is clean

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

## 3B.27 Rebuild the publication images

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

## 3B.28 Verify image platform

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

## 3B.29 Smoke-test the rebuilt backend image

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

## 3B.30 Smoke-test the rebuilt frontend image

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

## 3B.31 Authenticate Docker to Amazon ECR

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

## 3B.32 Tag the images for ECR

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

## 3B.33 Push both images

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

## 3B.34 Verify the tagged artifacts exist

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

## 3B.35 Understand the OCI image-index structure

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

## 3B.36 Inspect the complete ECR artifact structure

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

## 3B.37 Query vulnerability scans by platform-image digest

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

## 3B.38 Query HIGH and CRITICAL findings explicitly

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

## 3B.39 Scanner scope

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

## 3B.40 Capture Phase 3B evidence

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

## 3B.41 Troubleshooting

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

## 3B.42 Verify final Terraform idempotency

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

## 3B.43 Git safety checks

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
docs/implementation-guide.md
```

---

## 3B.44 Phase acceptance criteria

Phase 3B passes when:

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

## Phase 3B result

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


# Phase 3C: Multi-AZ VPC Networking

## Purpose

This phase creates the network foundation used by the Application Load Balancer
and ECS Fargate services.

The design uses two Availability Zones with:

- one public-tier subnet per Availability Zone
- one private subnet per Availability Zone
- one Internet Gateway
- one public NAT Gateway per Availability Zone
- one shared public route table
- one private route table per Availability Zone

The completed topology is:

```text
                              Internet
                                 |
                                 v
                         Internet Gateway
                                 |
                 +---------------+---------------+
                 |                               |
                 v                               v
          Public Subnet A                 Public Subnet B
            us-east-1a                      us-east-1b
           10.20.0.0/24                    10.20.1.0/24
                 |                               |
             NAT-A                           NAT-B
                 |                               |
                 v                               v
         Private Subnet A                Private Subnet B
            us-east-1a                      us-east-1b
          10.20.10.0/24                  10.20.11.0/24
```

The private subnets will later host ECS Fargate tasks.

---

## 3C.1 Architecture goals

This network design addresses several architecture qualities.

### Failure-domain separation

The application network spans two Availability Zones.

An Availability Zone is treated as a failure domain: resources within one AZ
may become unavailable together.

Using two AZs creates the foundation for the surviving AZ to continue operating
after a zonal failure.

### Redundancy

Two NAT Gateways provide two private-egress components.

Redundancy alone does not create High Availability. The redundant components
must be connected so that one failure does not remove the function from the
other failure domain.

### Fault isolation

Each private subnet routes through a NAT Gateway in its own Availability Zone.

```text
Private us-east-1a
        |
        v
Private Route Table A
        |
        v
NAT us-east-1a
```

and:

```text
Private us-east-1b
        |
        v
Private Route Table B
        |
        v
NAT us-east-1b
```

A NAT or routing failure in one AZ therefore does not remove private egress
from the surviving AZ.

### Blast-radius reduction

Separate private route tables let routing changes remain local to an
Availability Zone.

A bad route applied to the us-east-1a private route table does not
automatically change us-east-1b private routing.

### AZ independence

The design avoids making the private tier in one Availability Zone depend on a
NAT Gateway in another Availability Zone.

### Cost tradeoff

Two NAT Gateways cost more than a single shared NAT Gateway.

The additional cost is accepted to remove a cross-AZ private-egress dependency
for this challenge deployment.

---

## 3C.2 Define the VPC CIDR

Append to:

```text
terraform/infrastructure/variables.tf
```

```hcl
# IPv4 address space reserved for the application VPC.
#
# The /16 network provides enough address space to divide the VPC into
# multiple /24 subnets without changing the VPC CIDR later in this challenge.
#
# The subnet ranges themselves are calculated in network.tf with cidrsubnet()
# rather than being declared independently, which keeps the address plan
# derived from one authoritative VPC CIDR.
variable "vpc_cidr" {
  description = "IPv4 CIDR block assigned to the application VPC."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}
```

The address plan is:

```text
VPC             10.20.0.0/16

us-east-1a
Public           10.20.0.0/24
Private          10.20.10.0/24

us-east-1b
Public           10.20.1.0/24
Private          10.20.11.0/24
```

The gap between the public and private ranges makes the network tier easier to
recognize during troubleshooting.

---

## 3C.3 Discover Availability Zones

Create:

```text
terraform/infrastructure/network.tf
```

Begin with:

```hcl
# Discover Availability Zones currently available to this AWS account in the
# configured Region.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Use two Availability Zones for the challenge architecture.
  selected_azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Allocate /24 public-tier subnets from the VPC CIDR.
  public_subnet_cidrs = {
    for index, az in local.selected_azs :
    az => cidrsubnet(var.vpc_cidr, 8, index)
  }

  # Start private subnet numbering at 10 to maintain visible separation from
  # the public subnet range.
  private_subnet_cidrs = {
    for index, az in local.selected_azs :
    az => cidrsubnet(var.vpc_cidr, 8, index + 10)
  }
}
```

With the default VPC CIDR, the calculated ranges are:

```text
cidrsubnet(10.20.0.0/16, 8, 0)  -> 10.20.0.0/24
cidrsubnet(10.20.0.0/16, 8, 1)  -> 10.20.1.0/24
cidrsubnet(10.20.0.0/16, 8, 10) -> 10.20.10.0/24
cidrsubnet(10.20.0.0/16, 8, 11) -> 10.20.11.0/24
```

---

## 3C.4 Create the VPC

Add:

```hcl
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}
```

DNS support is required for normal AWS service name resolution from workloads
inside the VPC.

---

## 3C.5 Create public-tier subnets

Add:

```hcl
resource "aws_subnet" "public" {
  for_each = local.public_subnet_cidrs

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = each.value

  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-public-${each.key}"
    Tier = "public"
  }
}
```

Automatic public IPv4 assignment is disabled.

A subnet becomes functionally public through routing, not merely from its name.

At this checkpoint, these are subnets designated for the public tier. They
become functionally public after the Internet Gateway route is added.

---

## 3C.6 Create private subnets

Add:

```hcl
resource "aws_subnet" "private" {
  for_each = local.private_subnet_cidrs

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = each.value

  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-private-${each.key}"
    Tier = "private"
  }
}
```

ECS Fargate tasks will later run in these subnets without public IP addresses.

---

## 3C.7 Attach an Internet Gateway

Add:

```hcl
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}
```

Attaching an Internet Gateway to a VPC does not, by itself, make workloads
publicly reachable.

Public reachability requires the correct combination of:

```text
routing
addressing
security policy
```

---

## 3C.8 Validate the VPC foundation

Format:

```bash
terraform -chdir=terraform/infrastructure fmt -recursive
git diff --check
```

Validate:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure validate
```

Expected:

```text
Success! The configuration is valid.
```

Verify the execution identity:

```bash
aws-vault exec terraform -- \
  aws sts get-caller-identity
```

The ARN must contain:

```text
assumed-role/TerraformExecutionRole
```

Create the saved plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan \
  -out=network-foundation.tfplan
```

Expected:

```text
Plan: 6 to add, 0 to change, 0 to destroy.
```

The resources are:

```text
aws_vpc.main
aws_internet_gateway.main

aws_subnet.public["us-east-1a"]
aws_subnet.public["us-east-1b"]

aws_subnet.private["us-east-1a"]
aws_subnet.private["us-east-1b"]
```

---

## 3C.9 Review the network foundation plan

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure show \
  -no-color \
  network-foundation.tfplan \
| grep -E \
'(^  # |cidr_block|availability_zone[[:space:]]*=|enable_dns|map_public_ip_on_launch|Name[[:space:]]*=|Tier[[:space:]]*=|Plan:)'
```

Confirm:

```text
VPC:
10.20.0.0/16
enable_dns_support   = true
enable_dns_hostnames = true

Public-tier:
10.20.0.0/24
10.20.1.0/24
map_public_ip_on_launch = false

Private:
10.20.10.0/24
10.20.11.0/24
map_public_ip_on_launch = false

Plan: 6 to add, 0 to change, 0 to destroy.
```

---

## 3C.10 Apply the VPC foundation

Apply the reviewed plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure apply \
  network-foundation.tfplan
```

Expected:

```text
Apply complete! Resources: 6 added, 0 changed, 0 destroyed.
```

---

## 3C.11 Verify the VPC directly in AWS

Capture the VPC ID:

```bash
VPC_ID=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -raw vpc_id
)
```

Inspect it:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].{
    VpcId:VpcId,
    CidrBlock:CidrBlock,
    State:State,
    IsDefault:IsDefault
  }'
```

Required:

```text
CidrBlock = 10.20.0.0/16
State     = available
IsDefault = false
```

Verify DNS:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport
```

and:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames
```

Both values must be `true`.

---

## 3C.12 Verify the subnet layout

Run:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{
    Name:Tags[?Key==`Name`]|[0].Value,
    Tier:Tags[?Key==`Tier`]|[0].Value,
    AZ:AvailabilityZone,
    CIDR:CidrBlock,
    PublicIPv4OnLaunch:MapPublicIpOnLaunch,
    State:State
  }' \
  --output table
```

Required layout:

```text
public   us-east-1a   10.20.0.0/24    false
public   us-east-1b   10.20.1.0/24    false

private  us-east-1a   10.20.10.0/24   false
private  us-east-1b   10.20.11.0/24   false
```

---

# Phase 3C.2: Internet and Private Egress Routing

## 3C.13 Allocate NAT Elastic IP addresses

Add to `network.tf`:

```hcl
resource "aws_eip" "nat" {
  for_each = aws_subnet.public

  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip-${each.key}"
  }
}
```

One Elastic IP is allocated for each NAT Gateway.

---

## 3C.14 Create one NAT Gateway per Availability Zone

Add:

```hcl
resource "aws_nat_gateway" "main" {
  for_each = aws_subnet.public

  allocation_id     = aws_eip.nat[each.key].allocation_id
  subnet_id         = each.value.id
  connectivity_type = "public"

  tags = {
    Name = "${var.project_name}-nat-${each.key}"
  }

  depends_on = [
    aws_internet_gateway.main
  ]
}
```

The Availability Zone key preserves the relationship:

```text
public["us-east-1a"] -> nat["us-east-1a"]
public["us-east-1b"] -> nat["us-east-1b"]
```

---

## 3C.15 Create the shared public route table

Both public subnets require the same default route, so one shared route table is
used.

```hcl
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-public-rt"
    Tier = "public"
  }
}
```

Add the Internet Gateway route:

```hcl
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}
```

Associate both public subnets:

```hcl
resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}
```

At this point, the designated public-tier subnets are functionally public.

---

## 3C.16 Create AZ-specific private route tables

Add:

```hcl
resource "aws_route_table" "private" {
  for_each = aws_subnet.private

  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-private-rt-${each.key}"
    Tier = "private"
  }
}
```

Separate route tables are required since each private subnet must use a
different NAT Gateway.

---

## 3C.17 Route each private subnet through its local-AZ NAT Gateway

Add:

```hcl
resource "aws_route" "private_nat" {
  for_each = aws_subnet.private

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[each.key].id
}
```

Associate them:

```hcl
resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}
```

The resulting relationship is deterministic:

```text
private["us-east-1a"]
        |
        v
private route table["us-east-1a"]
        |
        v
nat["us-east-1a"]
```

and independently for `us-east-1b`.

---

## 3C.18 Add network outputs

Append to `outputs.tf`:

```hcl
output "vpc_id" {
  description = "ID of the application VPC."
  value       = aws_vpc.main.id
}

output "availability_zones" {
  description = "Availability Zones used by the application network."
  value       = local.selected_azs
}

output "public_subnet_ids_by_az" {
  description = "Public subnet IDs keyed by Availability Zone."

  value = {
    for az, subnet in aws_subnet.public :
    az => subnet.id
  }
}

output "private_subnet_ids_by_az" {
  description = "Private subnet IDs keyed by Availability Zone."

  value = {
    for az, subnet in aws_subnet.private :
    az => subnet.id
  }
}

output "internet_gateway_id" {
  description = "Internet Gateway attached to the application VPC."
  value       = aws_internet_gateway.main.id
}

output "nat_gateway_ids_by_az" {
  description = "Public NAT Gateway IDs keyed by Availability Zone."

  value = {
    for az, nat in aws_nat_gateway.main :
    az => nat.id
  }
}

output "nat_gateway_public_ips_by_az" {
  description = "NAT Gateway public IPv4 addresses keyed by Availability Zone."

  value = {
    for az, eip in aws_eip.nat :
    az => eip.public_ip
  }
}

output "public_route_table_id" {
  description = "Route table used by the public-tier subnets."
  value       = aws_route_table.public.id
}

output "private_route_table_ids_by_az" {
  description = "Private route table IDs keyed by Availability Zone."

  value = {
    for az, route_table in aws_route_table.private :
    az => route_table.id
  }
}
```

---

## 3C.19 Plan the routing layer

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan \
  -out=network-routing.tfplan
```

Expected:

```text
Plan: 14 to add, 0 to change, 0 to destroy.
```

The resources are:

```text
2 Elastic IPs
2 NAT Gateways

1 public route table
1 public default route
2 public subnet associations

2 private route tables
2 private default routes
2 private subnet associations
```

---

## 3C.20 Review the routing plan

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure show \
  -no-color \
  network-routing.tfplan \
| grep -E \
'(^  # |domain[[:space:]]*=|connectivity_type|allocation_id|subnet_id|destination_cidr_block|gateway_id|nat_gateway_id|route_table_id|Name[[:space:]]*=|Tier[[:space:]]*=|Plan:)'
```

Confirm:

```text
2 x EIP
domain = vpc

2 x NAT Gateway
connectivity_type = public

Public:
0.0.0.0/0 -> Internet Gateway

Private us-east-1a:
0.0.0.0/0 -> NAT us-east-1a

Private us-east-1b:
0.0.0.0/0 -> NAT us-east-1b

Plan: 14 to add, 0 to change, 0 to destroy.
```

---

## 3C.21 Apply the routing layer

Apply:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure apply \
  network-routing.tfplan
```

NAT Gateway creation may take several minutes.

Expected:

```text
Apply complete! Resources: 14 added, 0 changed, 0 destroyed.
```

---

## 3C.22 Verify NAT Gateways

Run:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=$VPC_ID" \
  --query 'NatGateways[].{
    NAT:NatGatewayId,
    State:State,
    Subnet:SubnetId,
    PublicIP:NatGatewayAddresses[0].PublicIp
  }' \
  --output table
```

Required:

```text
2 NAT Gateways
State = available
2 different public subnet IDs
2 public IPv4 addresses
```

Verify that each NAT subnet belongs to the same AZ as the private subnet whose
route table points to that NAT.

---

## 3C.23 Verify route tables

Run:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[].{
    Name:Tags[?Key==`Name`]|[0].Value,
    RouteTableId:RouteTableId,
    AssociatedSubnets:Associations[?SubnetId!=null].SubnetId,
    Routes:Routes[].{
      Destination:DestinationCidrBlock,
      Gateway:GatewayId,
      NAT:NatGatewayId
    }
  }'
```

Required public route:

```text
10.20.0.0/16 -> local
0.0.0.0/0    -> Internet Gateway
```

Required private route A:

```text
10.20.0.0/16 -> local
0.0.0.0/0    -> NAT-A
```

Required private route B:

```text
10.20.0.0/16 -> local
0.0.0.0/0    -> NAT-B
```

---

## 3C.24 Verify Terraform state and idempotency

Inspect the managed network resources:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure state list \
| grep -E \
'aws_vpc|aws_subnet|aws_internet_gateway|aws_eip|aws_nat_gateway|aws_route'
```

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

## 3C.25 Phase acceptance criteria

Phase 3C passes when:

- one non-default VPC exists with CIDR `10.20.0.0/16`
- DNS support and DNS hostnames are enabled
- two Availability Zones are used
- each AZ contains one public-tier and one private subnet
- no subnet automatically assigns public IPv4 addresses
- an Internet Gateway is attached
- both public subnets route to the Internet Gateway
- two NAT Gateways are `available`
- each NAT Gateway is located in a different public subnet/AZ
- each private subnet has its own route table
- each private route table points to the NAT Gateway in the same AZ
- a final Terraform plan reports no changes

---

# Phase 3D: Network Security and Application Load Balancing

## Purpose

This phase establishes the application network trust boundaries and creates the
single public Application Load Balancer used by the frontend and backend.

The final traffic graph is:

```text
Internet
   |
   | TCP/80
   v
Application Load Balancer
   |
   +------ TCP/3000 ------> Frontend ECS targets
   |
   +------ TCP/8080 ------> Backend ECS targets
```

Frontend and backend tasks remain in private subnets.

---

# Phase 3D.1: Security Boundaries

## 3D.1 Architecture goals

### Segmentation

The edge, frontend, and backend tiers use separate security groups.

```text
ALB security group
Frontend security group
Backend security group
```

### Least privilege

The frontend accepts TCP/3000 only from the ALB security group.

The backend accepts TCP/8080 only from the ALB security group.

### Attack-surface reduction

The public internet cannot connect directly to:

```text
frontend:3000
backend:8080
```

### Trust boundary

The ALB is the transition point between the public network and the private
application tiers.

### Defense in depth

ECS tasks will later receive several independent controls:

```text
private subnet
+
no public IPv4 address
+
application security group
+
ALB-only application ingress
+
non-root container runtime
```

### Blast-radius reduction

Frontend and backend policies are independent, so a rule change on one tier
does not automatically modify the other.

---

## 3D.2 Create the ALB security group

Create:

```text
terraform/infrastructure/security.tf
```

Add:

```hcl
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Controls traffic to and from the public Application Load Balancer."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-alb-sg"
    Tier = "edge"
  }
}
```

Allow public HTTP:

```hcl
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id

  description = "Allow public HTTP traffic to the application entry point."

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 80
  to_port     = 80
  ip_protocol = "tcp"
}
```

`0.0.0.0/0` is intentional here since the challenge application must be
publicly reachable.

The application containers themselves do not receive this rule.

---

## 3D.3 Create the frontend security group

Add:

```hcl
resource "aws_security_group" "frontend" {
  name        = "${var.project_name}-frontend-sg"
  description = "Controls network access for frontend ECS tasks."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-frontend-sg"
    Tier = "frontend"
  }
}
```

Allow the ALB to reach frontend TCP/3000:

```hcl
resource "aws_vpc_security_group_ingress_rule" "frontend_from_alb" {
  security_group_id = aws_security_group.frontend.id

  description = "Allow frontend application traffic from the ALB."

  referenced_security_group_id = aws_security_group.alb.id

  from_port   = 3000
  to_port     = 3000
  ip_protocol = "tcp"
}
```

Allow outbound HTTPS:

```hcl
resource "aws_vpc_security_group_egress_rule" "frontend_https" {
  security_group_id = aws_security_group.frontend.id

  description = "Allow HTTPS egress for AWS service access through NAT."

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"
}
```

---

## 3D.4 Create the backend security group

Add:

```hcl
resource "aws_security_group" "backend" {
  name        = "${var.project_name}-backend-sg"
  description = "Controls network access for backend ECS tasks."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-backend-sg"
    Tier = "backend"
  }
}
```

Allow backend application traffic only from the ALB:

```hcl
resource "aws_vpc_security_group_ingress_rule" "backend_from_alb" {
  security_group_id = aws_security_group.backend.id

  description = "Allow backend application traffic from the ALB."

  referenced_security_group_id = aws_security_group.alb.id

  from_port   = 8080
  to_port     = 8080
  ip_protocol = "tcp"
}
```

Allow outbound HTTPS:

```hcl
resource "aws_vpc_security_group_egress_rule" "backend_https" {
  security_group_id = aws_security_group.backend.id

  description = "Allow HTTPS egress for AWS service access through NAT."

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"
}
```

---

## 3D.5 Restrict ALB egress to application security groups

Allow ALB-to-frontend traffic:

```hcl
resource "aws_vpc_security_group_egress_rule" "alb_to_frontend" {
  security_group_id = aws_security_group.alb.id

  description = "Allow ALB traffic to frontend targets."

  referenced_security_group_id = aws_security_group.frontend.id

  from_port   = 3000
  to_port     = 3000
  ip_protocol = "tcp"
}
```

Allow ALB-to-backend traffic:

```hcl
resource "aws_vpc_security_group_egress_rule" "alb_to_backend" {
  security_group_id = aws_security_group.alb.id

  description = "Allow ALB traffic to backend targets."

  referenced_security_group_id = aws_security_group.backend.id

  from_port   = 8080
  to_port     = 8080
  ip_protocol = "tcp"
}
```

No frontend-to-backend rule exists.

The frontend container serves static files. Browser `/api` traffic reaches the
backend through the ALB rather than through the frontend container.

---

## 3D.6 Stateful security-group behavior

Security groups are stateful.

An allowed outbound connection such as:

```text
Backend task -> HTTPS destination:443
```

permits the response traffic for that established connection.

It does not grant an internet host permission to initiate a new inbound
connection to the backend.

The outbound rules therefore do not create public inbound reachability.

---

## 3D.7 Egress tradeoff

Frontend and backend egress is limited to TCP/443, but the destination CIDR is:

```text
0.0.0.0/0
```

This means a task may initiate HTTPS connections to any IPv4 destination.

The project accepts this for the challenge environment.

A stricter production design could use interface/gateway VPC endpoints and
more restrictive egress controls for AWS service access.

---

## 3D.8 Add the security-group output

Append to `outputs.tf`:

```hcl
output "security_group_ids" {
  description = "Security groups used by the ALB and ECS application tiers."

  value = {
    alb      = aws_security_group.alb.id
    frontend = aws_security_group.frontend.id
    backend  = aws_security_group.backend.id
  }
}
```

---

## 3D.9 Plan the security boundary

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan \
  -out=security-boundaries.tfplan
```

Expected:

```text
Plan: 10 to add, 0 to change, 0 to destroy.
```

Review:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure show \
  -no-color \
  security-boundaries.tfplan \
| grep -E \
'(^  # |description[[:space:]]*=|cidr_ipv4|referenced_security_group_id|from_port|to_port|ip_protocol|Plan:)'
```

Required traffic graph:

```text
Internet -> ALB       TCP/80

ALB -> Frontend       TCP/3000
ALB -> Backend        TCP/8080

Frontend -> outbound  TCP/443
Backend -> outbound   TCP/443
```

There must be no:

```text
Internet -> Frontend:3000
Internet -> Backend:8080
Frontend -> Backend:8080
```

---

## 3D.10 Apply the security boundary

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure apply \
  security-boundaries.tfplan
```

Expected:

```text
Apply complete! Resources: 10 added, 0 changed, 0 destroyed.
```

---

## 3D.11 Verify live security-group rules

Retrieve the Terraform outputs:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure output security_group_ids
```

Load the values into the current Git Bash session:

```bash
ALB_SG=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -json security_group_ids \
  | sed -n 's/.*"alb":"\([^"]*\)".*/\1/p'
)

FRONTEND_SG=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -json security_group_ids \
  | sed -n 's/.*"frontend":"\([^"]*\)".*/\1/p'
)

BACKEND_SG=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -json security_group_ids \
  | sed -n 's/.*"backend":"\([^"]*\)".*/\1/p'
)
```

Verify:

```bash
printf 'ALB:      %s\nFrontend: %s\nBackend:  %s\n' \
  "$ALB_SG" "$FRONTEND_SG" "$BACKEND_SG"
```

All three values must start with:

```text
sg-
```

---

## 3D.12 Verify ALB security rules

Run:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$ALB_SG" \
  --query 'SecurityGroupRules[].{
    Egress:IsEgress,
    Protocol:IpProtocol,
    From:FromPort,
    To:ToPort,
    CIDR:CidrIpv4,
    ReferencedSG:ReferencedGroupInfo.GroupId,
    Description:Description
  }' \
  --output table
```

Required:

```text
Ingress:
0.0.0.0/0 -> TCP/80

Egress:
Frontend SG -> TCP/3000
Backend SG  -> TCP/8080
```

---

## 3D.13 Verify frontend security rules

Run:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$FRONTEND_SG" \
  --query 'SecurityGroupRules[].{
    Egress:IsEgress,
    Protocol:IpProtocol,
    From:FromPort,
    To:ToPort,
    CIDR:CidrIpv4,
    ReferencedSG:ReferencedGroupInfo.GroupId,
    Description:Description
  }' \
  --output table
```

Required:

```text
Ingress:
ALB SG -> TCP/3000

Egress:
0.0.0.0/0 -> TCP/443
```

---

## 3D.14 Verify backend security rules

Run:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$BACKEND_SG" \
  --query 'SecurityGroupRules[].{
    Egress:IsEgress,
    Protocol:IpProtocol,
    From:FromPort,
    To:ToPort,
    CIDR:CidrIpv4,
    ReferencedSG:ReferencedGroupInfo.GroupId,
    Description:Description
  }' \
  --output table
```

Required:

```text
Ingress:
ALB SG -> TCP/8080

Egress:
0.0.0.0/0 -> TCP/443
```

---

## 3D.15 Prove negative security claims

Verify that application security groups do not accept direct public IPv4
ingress.

Frontend:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$FRONTEND_SG" \
  --query 'SecurityGroupRules[?IsEgress==`false` && CidrIpv4==`0.0.0.0/0`]'
```

Backend:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$BACKEND_SG" \
  --query 'SecurityGroupRules[?IsEgress==`false` && CidrIpv4==`0.0.0.0/0`]'
```

Required for both:

```json
[]
```

This supports the statement:

```text
Neither application security group accepts direct IPv4 internet ingress.
```

---

# Phase 3D.2: Application Load Balancer and Layer-7 Routing

## 3D.16 Load-balancing architecture

The ALB is the single public application entry point.

```text
                        Internet
                           |
                           v
                    Public ALB :80
                    /            \
                   /              \
             /api paths        other paths
                 |                 |
                 v                 v
           Backend TG         Frontend TG
             :8080               :3000
```

The ALB spans the two public subnets.

This creates failure-domain separation at the public entry tier.

---

## 3D.17 Architecture qualities

### Load distribution

The ALB can distribute requests across multiple healthy targets registered in a
target group.

### Decoupling

Clients use one ALB hostname instead of knowing ECS task IP addresses.

### Health-based routing

Unhealthy targets can be removed from active request routing.

### Horizontal-scaling support

More ECS tasks may be registered behind the same target group without changing
the public endpoint.

### Service isolation

Frontend and backend use separate target groups and independent health states.

### High Availability at the entry tier

The ALB spans two Availability Zones.

This statement applies to the load-balancing tier. Application-level High
Availability depends on the number and placement of healthy ECS tasks.

---

## 3D.18 Create the Application Load Balancer

Create:

```text
terraform/infrastructure/load_balancer.tf
```

Add:

```hcl
resource "aws_lb" "application" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"

  security_groups = [
    aws_security_group.alb.id
  ]

  subnets = [
    for az in local.selected_azs :
    aws_subnet.public[az].id
  ]

  drop_invalid_header_fields = true

  enable_deletion_protection = false

  tags = {
    Name = "${var.project_name}-alb"
    Tier = "edge"
  }
}
```

The challenge environment uses deletion protection `false` so the temporary
infrastructure can be removed after validation.

---

## 3D.19 Create the frontend target group

Add:

```hcl
resource "aws_lb_target_group" "frontend" {
  name = "${var.project_name}-frontend-tg"

  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled = true

    protocol = "HTTP"
    path     = "/"
    port     = "traffic-port"

    matcher = "200-399"

    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = {
    Name = "${var.project_name}-frontend-tg"
    Tier = "frontend"
  }
}
```

Fargate tasks using `awsvpc` networking register by IP address, so the target
type is `ip`.

The frontend health check verifies that Nginx is serving the compiled
application.

---

## 3D.20 Create the backend target group

Add:

```hcl
resource "aws_lb_target_group" "backend" {
  name = "${var.project_name}-backend-tg"

  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled = true

    protocol = "HTTP"
    path     = "/health"
    port     = "traffic-port"

    matcher = "200"

    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = {
    Name = "${var.project_name}-backend-tg"
    Tier = "backend"
  }
}
```

The backend uses its explicit `/health` endpoint as the target-health signal.

---

## 3D.21 Create the public HTTP listener

Add:

```hcl
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.application.arn

  port     = 80
  protocol = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}
```

The challenge uses HTTP since no managed DNS name or ACM certificate is part of
the current scope.

A production deployment would normally terminate TLS at the ALB and redirect
HTTP to HTTPS.

This is an accepted challenge-environment tradeoff rather than a claim that
HTTP is the preferred production design.

---

## 3D.22 Add backend path-based routing

Add:

```hcl
resource "aws_lb_listener_rule" "backend_api" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    path_pattern {
      values = [
        "/api",
        "/api/*"
      ]
    }
  }
}
```

Routing behavior is:

```text
/api
/api/*
    |
    v
backend target group
```

All unmatched paths use the listener default action:

```text
/
static assets
frontend routes
other paths
    |
    v
frontend target group
```

---

## 3D.23 Why both `/api` and `/api/*` are used

The exact path:

```text
/api
```

must reach the backend.

Nested API paths such as:

```text
/api/users
/api/orders/123
/api/v1/status
```

must reach the backend too.

The combination:

```text
/api
/api/*
```

covers both cases.

---

## 3D.24 Layer-3 versus Layer-7 routing

The project now uses different kinds of routing.

### VPC route tables

These make network-layer decisions:

```text
Where should traffic for this destination IP network go?
```

Example:

```text
0.0.0.0/0 -> NAT Gateway
```

### ALB listener rules

These make HTTP application-layer decisions:

```text
Which application service should handle this request?
```

Example:

```text
/api/* -> backend target group
```

### Target groups

These decide which healthy workload instances may receive requests for that
service.

The conceptual chain is:

```text
Route table
    |
    v
network path

ALB listener rule
    |
    v
service selection

Target group
    |
    v
healthy workload selection
```

---

## 3D.25 Same-origin browser routing

The frontend uses a relative API path:

```text
/api
```

The browser therefore uses the same ALB origin for both application layers:

```text
http://<alb-dns>/
http://<alb-dns>/api
```

The browser does not need to know backend ECS task addresses.

This reduces browser-side configuration and avoids using a separate backend
origin for this challenge.

---

## 3D.26 Backend health endpoint is not publicly routed

The backend target group health checker calls:

```text
/health
```

directly against registered backend targets.

The listener does not include a public `/health -> backend` rule.

A public request to:

```text
http://<alb-dns>/health
```

does not match `/api` and therefore follows the frontend default route.

The backend health endpoint does not need a dedicated public routing rule.

---

## 3D.27 Add ALB outputs

Append to `outputs.tf`:

```hcl
output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer."
  value       = aws_lb.application.dns_name
}

output "alb_arn" {
  description = "ARN of the public Application Load Balancer."
  value       = aws_lb.application.arn
}

output "target_group_arns" {
  description = "Target groups used by the frontend and backend ECS services."

  value = {
    frontend = aws_lb_target_group.frontend.arn
    backend  = aws_lb_target_group.backend.arn
  }
}

output "http_listener_arn" {
  description = "ARN of the ALB HTTP listener."
  value       = aws_lb_listener.http.arn
}
```

---

## 3D.28 Plan the ALB foundation

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan \
  -out=alb-foundation.tfplan
```

Expected:

```text
Plan: 5 to add, 0 to change, 0 to destroy.
```

Resources:

```text
aws_lb.application
aws_lb_target_group.frontend
aws_lb_target_group.backend
aws_lb_listener.http
aws_lb_listener_rule.backend_api
```

---

## 3D.29 Review the ALB plan

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure show \
  -no-color \
  alb-foundation.tfplan \
| grep -E \
'(^  # |internal[[:space:]]*=|load_balancer_type|drop_invalid_header_fields|port[[:space:]]*=|protocol[[:space:]]*=|target_type|path[[:space:]]*=|matcher|priority|values[[:space:]]*=|deregistration_delay|Plan:)'
```

Confirm:

```text
ALB
internal = false
load_balancer_type = application
drop_invalid_header_fields = true

Listener
HTTP :80

Frontend target group
HTTP :3000
target_type = ip
health path = /
matcher = 200-399

Backend target group
HTTP :8080
target_type = ip
health path = /health
matcher = 200

Backend listener rule
priority = 100
/api
/api/*

Plan: 5 to add, 0 to change, 0 to destroy.
```

---

## 3D.30 Apply the ALB foundation

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure apply \
  alb-foundation.tfplan
```

Expected:

```text
Apply complete! Resources: 5 added, 0 changed, 0 destroyed.
```

---

## 3D.31 Verify the ALB directly in AWS

Capture:

```bash
ALB_DNS=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -raw alb_dns_name
)
```

Inspect the load balancer:

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-load-balancers \
  --names ecs-fargate-cicd-alb \
  --query 'LoadBalancers[0].{
    DNSName:DNSName,
    Scheme:Scheme,
    Type:Type,
    State:State.Code,
    VpcId:VpcId,
    AZs:AvailabilityZones[].{
      AZ:ZoneName,
      Subnet:SubnetId
    }
  }'
```

Required:

```text
Scheme = internet-facing
Type   = application
State  = active

Availability Zones:
us-east-1a
us-east-1b
```

---

## 3D.32 Verify target-group configuration

Run:

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-target-groups \
  --names \
    ecs-fargate-cicd-frontend-tg \
    ecs-fargate-cicd-backend-tg \
  --query 'TargetGroups[].{
    Name:TargetGroupName,
    Port:Port,
    Protocol:Protocol,
    TargetType:TargetType,
    HealthPath:HealthCheckPath,
    Matcher:Matcher.HttpCode
  }' \
  --output table
```

Required:

```text
Frontend
Port       3000
Protocol   HTTP
TargetType ip
HealthPath /
Matcher    200-399

Backend
Port       8080
Protocol   HTTP
TargetType ip
HealthPath /health
Matcher    200
```

---

## 3D.33 Verify target groups are empty before ECS

Capture target-group ARNs:

```bash
FRONTEND_TG=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -json target_group_arns \
  | sed -n 's/.*"frontend":"\([^"]*\)".*/\1/p'
)

BACKEND_TG=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -json target_group_arns \
  | sed -n 's/.*"backend":"\([^"]*\)".*/\1/p'
)
```

Check:

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-target-health \
  --target-group-arn "$FRONTEND_TG"
```

and:

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-target-health \
  --target-group-arn "$BACKEND_TG"
```

Before ECS exists, both should return:

```json
{
  "TargetHealthDescriptions": []
}
```

This proves the load-balancing infrastructure exists but no application
workloads have registered yet.

---

## 3D.34 Verify the listener and routing rule

Capture the listener:

```bash
LISTENER_ARN=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -raw http_listener_arn
)
```

Verify the default action:

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-listeners \
  --listener-arns "$LISTENER_ARN" \
  --query 'Listeners[].{
    Port:Port,
    Protocol:Protocol,
    DefaultTargetGroup:DefaultActions[0].TargetGroupArn
  }'
```

The listener must use:

```text
HTTP :80
```

with the frontend target group as its default action.

Inspect rules:

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-rules \
  --listener-arn "$LISTENER_ARN" \
  --query 'Rules[].{
    Priority:Priority,
    Conditions:Conditions,
    Actions:Actions
  }'
```

Confirm:

```text
/api
/api/*
    ->
backend target group
```

and a default frontend action.

---

## 3D.35 Verify pre-ECS public behavior

Before ECS tasks register, request:

```bash
curl -i "http://$ALB_DNS/"
```

and:

```bash
curl -i "http://$ALB_DNS/api"
```

An HTTP `503 Service Unavailable` is expected at this checkpoint.

The response demonstrates that:

```text
DNS resolves
        |
        v
ALB receives request
        |
        v
listener selects target group
        |
        v
no healthy targets exist
        |
        v
503
```

This is different from a DNS failure, timeout, or network-connectivity failure.

---

## 3D.36 Verify Terraform idempotency

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

## 3D.37 Phase acceptance criteria

Phase 3D passes when:

- three separate security groups exist for ALB, frontend, and backend
- public ingress exists only on ALB TCP/80
- frontend TCP/3000 accepts traffic only from the ALB security group
- backend TCP/8080 accepts traffic only from the ALB security group
- neither application security group accepts direct public IPv4 ingress
- frontend and backend egress is limited to TCP/443
- the ALB is internet-facing and active
- the ALB spans both selected Availability Zones
- frontend target group uses HTTP/3000 and target type `ip`
- backend target group uses HTTP/8080 and target type `ip`
- frontend health check uses `/`
- backend health check uses `/health`
- `/api` and `/api/*` route to the backend target group
- unmatched paths route to the frontend target group
- pre-ECS target groups contain no registered targets
- a final Terraform plan reports no changes

---

## Phase 3C and 3D result

The project now has a validated multi-AZ network and public application-entry
layer:

```text
                              Internet
                                 |
                                 v
                        Application ALB
                       us-east-1a + 1b
                        /             \
                       /               \
                   :3000               :8080
                     |                   |
                 Frontend TG         Backend TG
                  no targets          no targets
                     |                   |
                 Frontend SG         Backend SG
                     |                   |
            private subnet A/B   private subnet A/B
                     |                   |
                 AZ-local NAT        AZ-local NAT
                     \                   /
                      \                 /
                       Internet Gateway
```

The network layer provides multi-AZ placement, AZ-local private egress,
fault-domain separation, and routing isolation.

The security layer restricts the application tiers to ALB-originated
application traffic.

The load-balancing layer provides one public endpoint, service-specific target
groups, health-check configuration, and path-based Layer-7 routing.

ECS Fargate is the next dependency required to register healthy application
targets behind the load balancer.
