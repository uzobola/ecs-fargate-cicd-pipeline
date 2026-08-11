# Phase 3A: Terraform Remote-State Bootstrap

## Purpose

This phase creates and validates the S3 backend that stores Terraform state for
the project.

The state backend is created separately from the application infrastructure so
that the main Terraform configuration can use remote state from its first
deployment.

The final state layout is:

```text
S3 bucket:
ecs-fargate-cicd-tfstate-<aws-account-id>-us-east-1

State objects:
bootstrap/terraform.tfstate
infrastructure/terraform.tfstate
```

The bootstrap configuration manages the S3 bucket itself.

The main infrastructure configuration will use the same bucket under a separate
state key.

---

## 3A.1 Scope

This phase creates only the Terraform state storage layer.

Resources created:

```text
aws_s3_bucket.terraform_state
aws_s3_bucket_ownership_controls.terraform_state
aws_s3_bucket_public_access_block.terraform_state
aws_s3_bucket_versioning.terraform_state
aws_s3_bucket_server_side_encryption_configuration.terraform_state
aws_s3_bucket_policy.terraform_state
```

No VPC, ECR, ECS, ALB, Jenkins, or application resources are created in this
phase.

---

## 3A.2 Working environment

Terraform and AWS CLI operations are run from Git Bash against the Windows
repository checkout.

Docker-related work remains in WSL.

The tooling boundary is:

```text
Git Bash / Windows
├── Git
├── Terraform
├── AWS CLI v2
└── aws-vault

WSL
└── Docker and local container validation
```

WSL does not hold AWS credentials or run Terraform.

---

## 3A.3 Authentication boundary

AWS access uses an MFA-backed role-assumption flow.

The AWS CLI configuration contains a source profile:

```ini
[profile grc-engineer]
region = us-east-1
output = json
```

and a Terraform execution profile:

```ini
[profile terraform]
source_profile = grc-engineer
role_arn       = arn:aws:iam::<account-id>:role/TerraformExecutionRole
mfa_serial     = arn:aws:iam::<account-id>:mfa/test-engineer
region         = us-east-1
```

The authentication path is:

```text
test-engineer
        |
        | MFA
        v
TerraformExecutionRole
        |
        | temporary STS credentials
        v
Terraform / AWS CLI
```

Terraform commands use:

```bash
aws-vault exec terraform -- <command>
```

Do not run Terraform provisioning through:

```bash
aws-vault exec grc-engineer -- <command>
```

That profile represents the source IAM user rather than the assumed execution
role.

Before provisioning, verify the active identity:

```bash
aws-vault exec terraform -- \
  aws sts get-caller-identity
```

Required ARN pattern:

```text
arn:aws:sts::<account-id>:assumed-role/TerraformExecutionRole/<session>
```

The result must not show:

```text
arn:aws:iam::<account-id>:user/test-engineer
```

This proves infrastructure changes are executed with temporary role
credentials rather than directly through the IAM user.

---

## 3A.4 Bootstrap directory structure

Create the bootstrap configuration:

```bash
mkdir -p terraform/bootstrap
```

Initial structure:

```text
terraform/
└── bootstrap/
    ├── versions.tf
    ├── providers.tf
    ├── variables.tf
    ├── main.tf
    └── outputs.tf
```

`backend.tf` is intentionally not created yet.

The first deployment must use local Terraform state since the S3 backend does
not exist at the beginning of the process.

---

## 3A.5 Terraform version and provider configuration

`terraform/bootstrap/versions.tf` defines the Terraform and AWS provider
requirements.

The configuration uses:

```hcl
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

The provider constraint permits AWS provider 6.x releases and prevents an
unreviewed major-version upgrade.

`terraform init` generates:

```text
terraform/bootstrap/.terraform.lock.hcl
```

The lock file records the exact provider build selected during initialization
and is committed to Git.

The `.terraform/` directory is not committed.

---

## 3A.6 Provider and AWS account discovery

`providers.tf` configures AWS in `us-east-1` and applies shared resource tags.

It also retrieves the AWS account ID from the authenticated session:

```hcl
data "aws_caller_identity" "current" {}
```

The account ID is not hardcoded into the bucket-name logic.

The state bucket name is calculated from:

```text
project name
+ tfstate
+ authenticated AWS account ID
+ AWS region
```

Example:

```text
ecs-fargate-cicd-tfstate-421438965568-us-east-1
```

This reduces the chance of creating infrastructure in one account with a
resource name that claims to belong to another account.

---

## 3A.7 State-bucket security controls

The bootstrap configuration applies the following controls.

### Automatic recursive deletion disabled

```hcl
force_destroy = false
```

Terraform cannot automatically empty and delete a populated state bucket.

State removal must be deliberate.

### Object ownership enforcement

```text
BucketOwnerEnforced
```

ACL-based access is disabled.

IAM and bucket policies become the access-control mechanisms for the bucket.

### S3 Block Public Access

All four controls are enabled:

```text
BlockPublicAcls       = true
IgnorePublicAcls      = true
BlockPublicPolicy     = true
RestrictPublicBuckets = true
```

### State versioning

S3 versioning is enabled:

```text
Status = Enabled
```

Terraform replaces the state object as infrastructure changes.

Versioning preserves earlier copies that may be needed for recovery.

### Server-side encryption

The bucket explicitly uses:

```text
SSEAlgorithm = AES256
```

This selects S3-managed server-side encryption.

A customer-managed KMS key was not introduced for this challenge since no
cross-account, separate key-administration, or stated regulatory requirement
requires one.

### TLS-only access

The bucket policy contains a deny statement:

```text
DenyInsecureTransport
```

The policy denies:

```text
s3:*
```

when:

```text
aws:SecureTransport = false
```

The policy applies to both:

```text
arn:aws:s3:::<state-bucket>
arn:aws:s3:::<state-bucket>/*
```

This prevents S3 operations over insecure transport.

---

## 3A.8 Terraform outputs

The bootstrap configuration exposes:

```text
state_bucket_name
state_bucket_arn
backend_configuration
```

The backend configuration reports:

```text
bucket       = <state bucket>
key          = infrastructure/terraform.tfstate
region       = us-east-1
encrypt      = true
use_lockfile = true
```

These values are used later by the main infrastructure configuration.

---

## 3A.9 Format the bootstrap configuration

From the repository root:

```bash
terraform -chdir=terraform/bootstrap fmt -recursive
```

Check for whitespace problems:

```bash
git diff --check
```

List the bootstrap files:

```bash
find terraform/bootstrap \
  -maxdepth 1 \
  -type f \
  -print
```

Expected Terraform source files:

```text
terraform/bootstrap/main.tf
terraform/bootstrap/outputs.tf
terraform/bootstrap/providers.tf
terraform/bootstrap/variables.tf
terraform/bootstrap/versions.tf
```

---

## 3A.10 Initialize Terraform with local state

Run initialization through the Terraform execution role:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap init
```

Expected result:

```text
Terraform has been successfully initialized!
```

Initialization creates:

```text
terraform/bootstrap/.terraform/
terraform/bootstrap/.terraform.lock.hcl
```

At this stage Terraform still uses local state.

---

## 3A.11 Validate the configuration

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap validate
```

Expected result:

```text
Success! The configuration is valid.
```

Do not plan or apply when validation fails.

---

## 3A.12 Create a saved Terraform plan

Create a saved plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap plan \
  -out=bootstrap.tfplan
```

Expected summary:

```text
Plan: 6 to add, 0 to change, 0 to destroy.
```

The six resources are:

```text
aws_s3_bucket.terraform_state
aws_s3_bucket_ownership_controls.terraform_state
aws_s3_bucket_public_access_block.terraform_state
aws_s3_bucket_versioning.terraform_state
aws_s3_bucket_server_side_encryption_configuration.terraform_state
aws_s3_bucket_policy.terraform_state
```

---

## 3A.13 Review the saved plan before applying

Render the saved plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap show \
  -no-color \
  bootstrap.tfplan
```

A focused review can be performed with:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap show \
  -no-color \
  bootstrap.tfplan \
  | grep -E \
'(^  # |bucket[[:space:]]*=|force_destroy|object_ownership|block_public_acls|block_public_policy|ignore_public_acls|restrict_public_buckets|status[[:space:]]*=|sse_algorithm|DenyInsecureTransport|aws:SecureTransport|Plan:)'
```

Confirm:

```text
force_destroy = false

object_ownership = "BucketOwnerEnforced"

block_public_acls       = true
block_public_policy     = true
ignore_public_acls      = true
restrict_public_buckets = true

status        = "Enabled"
sse_algorithm = "AES256"

DenyInsecureTransport
aws:SecureTransport

Plan: 6 to add, 0 to change, 0 to destroy.
```

Do not apply a plan that has not been reviewed.

---

## 3A.14 Apply the reviewed plan

Confirm the execution identity again:

```bash
aws-vault exec terraform -- \
  aws sts get-caller-identity
```

The ARN must contain:

```text
assumed-role/TerraformExecutionRole
```

Apply the saved plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap apply \
  bootstrap.tfplan
```

Using the saved plan applies the exact infrastructure proposal that was
reviewed.

Expected result:

```text
Apply complete! Resources: 6 added, 0 changed, 0 destroyed.
```

---

## 3A.15 Capture the bucket name

Retrieve the generated bucket name:

```bash
BUCKET=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/bootstrap output \
    -raw state_bucket_name
)

echo "$BUCKET"
```

Example:

```text
ecs-fargate-cicd-tfstate-421438965568-us-east-1
```

---

## 3A.16 Verify live S3 controls

Terraform plan output is not sufficient proof that the cloud resource was
configured correctly.

The deployed resource is checked directly through AWS CLI.

### Versioning

```bash
aws-vault exec terraform -- \
  aws s3api get-bucket-versioning \
  --bucket "$BUCKET"
```

Expected:

```json
{
  "Status": "Enabled"
}
```

### Public-access controls

```bash
aws-vault exec terraform -- \
  aws s3api get-public-access-block \
  --bucket "$BUCKET"
```

Expected:

```json
{
  "PublicAccessBlockConfiguration": {
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
  }
}
```

### Public policy status

```bash
aws-vault exec terraform -- \
  aws s3api get-bucket-policy-status \
  --bucket "$BUCKET"
```

Expected:

```json
{
  "PolicyStatus": {
    "IsPublic": false
  }
}
```

### Ownership controls

```bash
aws-vault exec terraform -- \
  aws s3api get-bucket-ownership-controls \
  --bucket "$BUCKET"
```

Expected:

```json
{
  "OwnershipControls": {
    "Rules": [
      {
        "ObjectOwnership": "BucketOwnerEnforced"
      }
    ]
  }
}
```

### Encryption

```bash
aws-vault exec terraform -- \
  aws s3api get-bucket-encryption \
  --bucket "$BUCKET"
```

Expected content:

```text
SSEAlgorithm = AES256
```

### Bucket policy

```bash
aws-vault exec terraform -- \
  aws s3api get-bucket-policy \
  --bucket "$BUCKET" \
  --query Policy \
  --output text
```

Confirm:

```text
DenyInsecureTransport
s3:*
aws:SecureTransport
false
```

### Tags

```bash
aws-vault exec terraform -- \
  aws s3api get-bucket-tagging \
  --bucket "$BUCKET"
```

Expected tag keys:

```text
Project
Environment
ManagedBy
Owner
Purpose
```

---

## 3A.17 Verify Terraform state inventory

Before state migration, inspect the local Terraform state:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap state list
```

Expected entries:

```text
data.aws_caller_identity.current
data.aws_iam_policy_document.terraform_state
aws_s3_bucket.terraform_state
aws_s3_bucket_ownership_controls.terraform_state
aws_s3_bucket_policy.terraform_state
aws_s3_bucket_public_access_block.terraform_state
aws_s3_bucket_server_side_encryption_configuration.terraform_state
aws_s3_bucket_versioning.terraform_state
```

---

## 3A.18 Verify idempotency before migration

Run a fresh plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap plan
```

Required result:

```text
No changes. Your infrastructure matches the configuration.
```

This proves the applied AWS resources match the Terraform configuration.

---

## 3A.19 Back up the local Terraform state

Before changing backends, create a local backup outside the repository:

```bash
BACKUP="$HOME/bootstrap-state-pre-migration-$(date -u +%Y%m%dT%H%M%SZ).tfstate"

cp terraform/bootstrap/terraform.tfstate "$BACKUP"
```

Compare the original and backup hashes:

```bash
sha256sum \
  terraform/bootstrap/terraform.tfstate \
  "$BACKUP"
```

The hashes must match.

Do not continue with migration when the backup is missing or does not match.

---

## 3A.20 Add the S3 backend configuration

After the S3 bucket exists, create:

```text
terraform/bootstrap/backend.tf
```

The backend configuration is:

```hcl
# This bootstrap configuration's state is stored in the S3 bucket created by
# this configuration.
#
# The bucket name depends on the authenticated AWS account and is supplied
# during `terraform init` through `-backend-config`.
#
# Credentials are never written here. aws-vault provides temporary credentials
# for TerraformExecutionRole through environment variables.

terraform {
  backend "s3" {
    # Keep bootstrap state separate from the main infrastructure state.
    key = "bootstrap/terraform.tfstate"

    # The state bucket was created in us-east-1.
    region = "us-east-1"

    # Request server-side encryption for the state object.
    encrypt = true

    # Use S3-native state locking.
    # Terraform creates a temporary .tflock object during protected operations.
    use_lockfile = true
  }
}
```

The bucket name is intentionally omitted from the source file.

It is supplied during initialization.

No AWS credentials are stored in Terraform configuration.

---

## 3A.21 Migrate local state to S3

After `backend.tf` is added, Terraform requires backend reinitialization.

Set the known bucket name:

```bash
BUCKET="ecs-fargate-cicd-tfstate-421438965568-us-east-1"
```

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap init \
  -migrate-state \
  -backend-config="bucket=$BUCKET"
```

Terraform asks whether the existing local state should be copied to the S3
backend.

Answer:

```text
yes
```

Expected ending:

```text
Successfully configured the backend "s3"!

Terraform has been successfully initialized!
```

`-migrate-state` is required here since existing local state must be transferred
to the new backend.

---

## 3A.22 Verify the migrated state inventory

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap state list
```

The same state entries should remain visible after migration.

This proves Terraform is reading the migrated remote state rather than creating
a new empty state.

---

## 3A.23 Verify the remote state object

Inspect the S3 object:

```bash
aws-vault exec terraform -- \
  aws s3api head-object \
  --bucket "$BUCKET" \
  --key bootstrap/terraform.tfstate
```

Expected fields include:

```text
ContentLength: <non-zero value>
ServerSideEncryption: AES256
VersionId: <version-id>
```

A non-zero content length confirms that a Terraform state object exists.

`AES256` confirms the object was written using the bucket encryption policy.

`VersionId` confirms that S3 versioning is active for the object.

---

## 3A.24 Verify state versions and native lock-file behavior

List state-related object versions:

```bash
aws-vault exec terraform -- \
  aws s3api list-object-versions \
  --bucket "$BUCKET" \
  --prefix bootstrap/terraform.tfstate \
  --query 'Versions[].{
    Key:Key,
    VersionId:VersionId,
    IsLatest:IsLatest,
    LastModified:LastModified
  }' \
  --output table
```

Expected keys include:

```text
bootstrap/terraform.tfstate
bootstrap/terraform.tfstate.tflock
```

The `.tflock` object is created during protected Terraform operations and
removed when the lock is released.

Since the bucket has versioning enabled, earlier lock-object versions may remain
visible in S3 version history after the current lock has been released.

No DynamoDB locking table is required.

---

## 3A.25 Verify idempotency after migration

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap plan
```

Required result:

```text
No changes. Your infrastructure matches the configuration.
```

This proves that moving the state backend did not change Terraform's view of
the managed infrastructure.

---

## 3A.26 Capture validation evidence

Create:

```text
docs/evidence/phase-3a/
```

Store:

```text
bootstrap-validation.txt
state-migration-validation.txt
```

Evidence should include:

```text
Execution identity
Bucket name
Versioning status
Public-access controls
Policy public status
Ownership controls
Encryption configuration
Resource tags
Terraform state inventory
Remote state-object metadata
State version history
Post-apply idempotency result
Post-migration idempotency result
```

Review evidence before committing it.

Do not commit:

```text
AWS access keys
secret access keys
session tokens
passwords
MFA codes
```

The AWS account ID and assumed-role ARN may be retained as deployment evidence
for this project.

---

## 3A.27 Files committed to Git

Commit:

```text
terraform/bootstrap/backend.tf
terraform/bootstrap/main.tf
terraform/bootstrap/outputs.tf
terraform/bootstrap/providers.tf
terraform/bootstrap/variables.tf
terraform/bootstrap/versions.tf
terraform/bootstrap/.terraform.lock.hcl

docs/design-decisions.md
docs/evidence/phase-3a/
```

Do not commit:

```text
terraform.tfstate
terraform.tfstate.backup
*.tfplan
.terraform/
```

Verify ignored state files with:

```bash
git check-ignore -v \
  terraform/bootstrap/terraform.tfstate \
  terraform/bootstrap/bootstrap.tfplan
```

---

## 3A.28 Commit the completed phase

Review:

```bash
git status --short
git diff --check
git diff --stat
```

Stage the intended files:

```bash
git add \
  terraform/bootstrap/backend.tf \
  terraform/bootstrap/main.tf \
  terraform/bootstrap/outputs.tf \
  terraform/bootstrap/providers.tf \
  terraform/bootstrap/variables.tf \
  terraform/bootstrap/versions.tf \
  terraform/bootstrap/.terraform.lock.hcl \
  docs/design-decisions.md \
  docs/Implementation-Guide/phase-03-bootstrap-env-infrastructure.md \
  docs/evidence/phase-3a/
```

Check the staged changes:

```bash
git diff --cached --check
git diff --cached --stat
```

Commit:

```bash
git commit -m "Bootstrap and validate remote Terraform state"
```

Push:

```bash
git push origin main
```

---

## 3A.29 Troubleshooting

### AccessDenied when creating the S3 bucket

Symptom:

```text
AccessDenied:
User arn:aws:iam::<account-id>:user/test-engineer
is not authorized to perform s3:CreateBucket
```

Cause:

Terraform was executed through the source profile:

```bash
aws-vault exec grc-engineer --
```

rather than the assumed-role profile.

Verify:

```bash
aws-vault exec terraform -- \
  aws sts get-caller-identity
```

The ARN must contain:

```text
assumed-role/TerraformExecutionRole
```

Regenerate the saved plan under the correct role before applying it.

Do not grant `s3:CreateBucket` directly to the source IAM user just to bypass
this error.

---

### Backend initialization required

Symptom:

```text
Error: Backend initialization required

Reason: Initial configuration of the requested backend "s3"
```

Cause:

`backend.tf` was added after the state bucket was created.

Terraform will not perform state-dependent operations until the new backend has
been initialized.

Do not attempt to read Terraform outputs at this point to rediscover the bucket
name.

Use the already verified bucket name:

```bash
BUCKET="ecs-fargate-cicd-tfstate-421438965568-us-east-1"
```

Then run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap init \
  -migrate-state \
  -backend-config="bucket=$BUCKET"
```

---

### Do not replace `-migrate-state` with `-reconfigure`

The goal is to transfer existing local state into S3.

Use:

```text
-migrate-state
```

for this transition.

The migration should preserve the existing Terraform state inventory.

---

## 3A.30 Teardown warning

The bootstrap configuration manages the bucket that contains its own Terraform
state.

Do not destroy the state bucket while the bootstrap configuration is still
using that bucket as its backend.

Before destroying the bootstrap resources:

```text
S3 remote backend
        |
        | migrate state back
        v
local Terraform state
        |
        | verify local state
        v
destroy state bucket
```

The state must first be migrated back to a local backend.

The S3 bucket uses:

```hcl
force_destroy = false
```

so Terraform will not silently delete a bucket that still contains state
objects and historical versions.

---

## 3A.31 Acceptance criteria

Phase 3A passes when all of the following are proven:

- Terraform executes through `TerraformExecutionRole`.
- The state bucket exists in the intended AWS account.
- S3 versioning is enabled.
- All four S3 Block Public Access settings are enabled.
- AWS reports the bucket policy as non-public.
- Object ownership is `BucketOwnerEnforced`.
- Default encryption is `AES256`.
- The bucket policy denies insecure transport.
- Required tags are present.
- Terraform manages all six expected S3 resources.
- A post-apply plan reports no changes.
- Bootstrap state is migrated successfully to S3.
- `bootstrap/terraform.tfstate` exists and has non-zero content.
- The state object is encrypted.
- The state object has an S3 version ID.
- S3-native `.tflock` activity is visible in version history.
- A post-migration Terraform plan reports no changes.
- Terraform state and plan files are excluded from Git.

---

## Phase 3A result

Phase 3A established a remote Terraform state foundation with:

```text
MFA-backed temporary AWS credentials
        |
        v
TerraformExecutionRole
        |
        v
Terraform
        |
        v
Private versioned S3 bucket
        |
        ├── bootstrap/terraform.tfstate
        └── infrastructure/terraform.tfstate
```

The state bucket uses encryption at rest, TLS-only access, blocked public
access, ACL-disabled ownership, object versioning, and S3-native state locking.

The bootstrap configuration was first deployed with local state, verified
against the live AWS resource, then migrated to the S3 backend.

Both the pre-migration and post-migration Terraform plans returned no changes,
confirming that the configuration, deployed resources, and remote state were
consistent at the completion of this phase.
