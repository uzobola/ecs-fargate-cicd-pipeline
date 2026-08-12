# Terraform Remote-State Security Checklist

## Purpose

This document records the security controls protecting Terraform remote state
for both Terraform configurations used by this project.

The objective is to demonstrate that remote state is:

```text
encrypted
protected from public access
locked against concurrent writes
governed by a defined access model
recoverable
kept separate from application deployment authority
```

This checklist covers:

```text
terraform/bootstrap/
terraform/infrastructure/
```

and complements:

```text
docs/security-model.md
docs/iam-permissions-matrix.md
docs/design-decisions.md
docs/cleanup.md
```

Terraform state is treated as sensitive because it contains infrastructure
identifiers, resource relationships, configuration metadata, and potentially
sensitive Terraform-managed values.

---

# 1. State Architecture

The project uses two separate Terraform configurations.

They share one dedicated Amazon S3 backend bucket but use different state keys.

| Configuration | Purpose | State Key |
|---|---|---|
| Bootstrap | Creates and secures the remote-state bucket | `bootstrap/terraform.tfstate` |
| Infrastructure | Manages the application, networking, ECS, Jenkins, ECR, IAM, and Auto Scaling infrastructure | `infrastructure/terraform.tfstate` |

Conceptually:

```text
Amazon S3 state bucket
│
├── bootstrap/
│   ├── terraform.tfstate
│   └── terraform.tfstate.tflock
│
└── infrastructure/
    ├── terraform.tfstate
    └── terraform.tfstate.tflock
```

The two state keys provide:

```text
separate Terraform state inventories
separate lock objects
independent Terraform operations
clear ownership boundaries
```

Separate keys do **not** automatically create separate IAM authorization
boundaries.

Stronger administrative isolation would require prefix-scoped IAM policies or
separate state buckets.

---

## 1.1 Shared Backend Settings

Both Terraform configurations use the S3 backend with:

```hcl
region       = "us-east-1"
encrypt      = true
use_lockfile = true
```

The bucket name is supplied during `terraform init` rather than hardcoded into
the reusable Terraform backend source.

Example:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure init \
  -backend-config="bucket=$BUCKET"
```

Authentication is supplied through:

```text
AWS Vault
    |
    v
Terraform execution role
    |
    v
temporary AWS credentials
```

No AWS access key or secret access key is stored in the Terraform backend
configuration.

---

# 2. Control Status Summary

| Control | Bootstrap | Infrastructure |
|---|---|---|
| Dedicated remote-state bucket | Implemented | Implemented |
| Separate state key | Implemented | Implemented |
| S3 default encryption | Implemented | Implemented |
| Terraform backend encryption request | Implemented | Implemented |
| TLS-only transport policy | Implemented | Implemented |
| S3 Block Public Access | Implemented | Implemented |
| Bucket-owner-enforced ownership | Implemented | Implemented |
| S3-native state locking | Implemented | Implemented |
| S3 Versioning | Implemented | Implemented |
| Accidental bucket deletion protection | Implemented | Implemented |
| Credentials stored in Terraform source | Not used | Not used |
| State committed to Git | Not allowed | Not allowed |
| Jenkins state-bucket permissions | Not granted by project | Not granted by project |
| GitHub Actions state-bucket permissions | Not granted by project | Not granted by project |
| ECS execution-role state permissions | Not granted by project | Not granted by project |
| Terraform execution-role policy review | External review required | External review required |
| Dedicated state-access security alerting | Not implemented | Not implemented |
| Recovery procedure | Documented | Documented |

The Terraform execution role is managed outside this repository.

The project can therefore demonstrate how Terraform authenticates and how
deployment identities are excluded from state access, but the complete
Terraform execution-role policy must be reviewed separately before claiming
full least-privilege enforcement for that role.

---

# 3. Encryption

## 3.1 Encryption at Rest

The bootstrap configuration enables default Amazon S3 server-side encryption
using:

```text
SSE-S3
AES256
```

This bucket-level configuration protects objects stored under both Terraform
state prefixes.

Terraform also requests encryption through:

```hcl
encrypt = true
```

in both backend configurations.

### Validate Bucket Encryption

Set the bucket variable:

```bash
BUCKET="$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/bootstrap output \
    -raw state_bucket_name
)"
```

Verify:

```bash
aws-vault exec terraform -- \
  aws s3api get-bucket-encryption \
  --bucket "$BUCKET"
```

Expected result:

```text
SSEAlgorithm = AES256
```

---

## 3.2 Validate Each State Object

Verify the bootstrap state:

```bash
aws-vault exec terraform -- \
  aws s3api head-object \
  --bucket "$BUCKET" \
  --key bootstrap/terraform.tfstate
```

Verify the infrastructure state:

```bash
aws-vault exec terraform -- \
  aws s3api head-object \
  --bucket "$BUCKET" \
  --key infrastructure/terraform.tfstate
```

Pass criteria for both:

```text
object exists
ContentLength > 0
ServerSideEncryption = AES256
```

State-file size is not used as a security control or acceptance criterion.

---

## 3.3 Encryption in Transit

The state bucket policy denies requests when:

```text
aws:SecureTransport = false
```

The policy applies to both:

```text
the bucket
all objects in the bucket
```

Verify:

```bash
aws-vault exec terraform -- \
  aws s3api get-bucket-policy \
  --bucket "$BUCKET" \
  --query Policy \
  --output text
```

The policy should contain:

```text
DenyInsecureTransport
aws:SecureTransport
false
```

This ensures that callers cannot use unencrypted HTTP access to the Terraform
state bucket.

---

# 4. Public Access and Object Ownership

## 4.1 S3 Block Public Access

The bootstrap configuration enables all four S3 Block Public Access settings.

Verify:

```bash
aws-vault exec terraform -- \
  aws s3api get-public-access-block \
  --bucket "$BUCKET"
```

Expected:

```text
BlockPublicAcls       = true
IgnorePublicAcls      = true
BlockPublicPolicy     = true
RestrictPublicBuckets = true
```

---

## 4.2 Bucket Policy Public Status

Verify:

```bash
aws-vault exec terraform -- \
  aws s3api get-bucket-policy-status \
  --bucket "$BUCKET"
```

Expected:

```text
IsPublic = false
```

---

## 4.3 Bucket-Owner-Enforced Ownership

The bucket uses:

```text
BucketOwnerEnforced
```

This disables ACL-based ownership controls and makes IAM and bucket policies
the authoritative access-control mechanisms.

Verify:

```bash
aws-vault exec terraform -- \
  aws s3api get-bucket-ownership-controls \
  --bucket "$BUCKET"
```

Expected:

```text
ObjectOwnership = BucketOwnerEnforced
```

---

# 5. State Locking

Both Terraform configurations use S3-native state locking:

```hcl
use_lockfile = true
```

The resulting lock objects are:

```text
bootstrap/terraform.tfstate.tflock
infrastructure/terraform.tfstate.tflock
```

The lock is tied to the state key.

Therefore:

```text
bootstrap lock
    -> protects bootstrap state

infrastructure lock
    -> protects infrastructure state
```

A lock on one state does not lock the other state.

---

## 5.1 Locking Acceptance Criteria

For both configurations:

```text
use_lockfile = true is present
Terraform acquires the corresponding state lock during protected operations
concurrent operations against the same state are rejected
the lock is released after the operation completes
```

Do not bypass a legitimate lock with:

```text
-lock=false
```

without first understanding why the lock exists.

---

## 5.2 Optional Live Lock Demonstration

A live demonstration is optional because a fast Terraform operation may finish
before the lock object can be observed manually.

### Infrastructure Example

Terminal A:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan
```

While the operation is active, Terminal B can inspect the prefix:

```bash
aws-vault exec terraform -- \
  aws s3api list-object-versions \
  --bucket "$BUCKET" \
  --prefix infrastructure/terraform.tfstate \
  --output table
```

When observable, the lock object appears as:

```text
infrastructure/terraform.tfstate.tflock
```

A second Terraform operation against the same state should receive a state-lock
error while the first operation still owns the lock.

Repeat with the bootstrap directory when demonstrating bootstrap locking.

Because bucket versioning is enabled, historical lock-file versions or delete
markers may remain visible after the active lock has been released.

---

# 6. Identity and Least Privilege

## 6.1 Terraform Execution Identity

Terraform commands are executed using:

```bash
aws-vault exec terraform -- <command>
```

Verify the active AWS identity:

```bash
aws-vault exec terraform -- \
  aws sts get-caller-identity
```

Expected ARN pattern:

```text
arn:aws:sts::<account-id>:assumed-role/<terraform-execution-role>/<session>
```

The account and assumed role must be verified before running:

```text
terraform plan
terraform apply
terraform destroy
state-management commands
```

---

## 6.2 State-Access Governance Model

The intended project access model is:

```text
Terraform execution identity
    -> Terraform state access

Jenkins deployment role
    -> no Terraform state permissions granted by this project

GitHub Actions deployment role
    -> no Terraform state permissions granted by this project

Frontend ECS execution role
    -> no Terraform state permissions granted by this project

Backend ECS execution role
    -> no Terraform state permissions granted by this project
```

This separates:

```text
infrastructure authority
```

from:

```text
application deployment authority
```

The Terraform execution role is managed outside the repository and must be
reviewed separately to confirm the exact S3 permissions it receives.

---

## 6.3 Jenkins State Boundary

Jenkins is provisioned by the infrastructure Terraform configuration, but its
IAM role is deployment-scoped.

The Jenkins role is intended to perform operations such as:

```text
ECR image publication
ECS task-definition registration
ECS service deployment
read-only ALB discovery
restricted iam:PassRole
```

It is not granted project permissions for:

```text
s3:GetObject on Terraform state
s3:PutObject on Terraform state
s3:DeleteObject on Terraform lock files
general Terraform-state administration
```

Code-review check:

```bash
grep -nE 's3:' \
  terraform/infrastructure/jenkins.tf \
  || echo "No S3 permissions found in Jenkins policy"
```

This is evidence about the policy defined by this repository.

It is not an account-wide proof that no other policy exists outside the project.

---

## 6.4 GitHub Actions State Boundary

The GitHub Actions deployment role is intended for application deployment.

It receives permissions for:

```text
ECR image publication
ECS task-definition operations
ECS service updates
restricted iam:PassRole
read-only ALB discovery
```

It is not intended to receive Terraform-state access.

This preserves the boundary between the GitOps deployment control plane and the
Terraform infrastructure control plane.

---

## 6.5 ECS Execution Roles

Frontend and backend execution roles are scoped to:

```text
their corresponding ECR image pull
their corresponding CloudWatch log publication
```

Application task roles are not assigned.

These workload identities do not require Terraform-state access.

---

# 7. Recovery

## 7.1 S3 Versioning

The state bucket has S3 Versioning enabled.

This preserves previous versions when Terraform replaces the state object.

Verify:

```bash
aws-vault exec terraform -- \
  aws s3api get-bucket-versioning \
  --bucket "$BUCKET"
```

Expected:

```text
Status = Enabled
```

---

## 7.2 Inspect Version History

Bootstrap:

```bash
aws-vault exec terraform -- \
  aws s3api list-object-versions \
  --bucket "$BUCKET" \
  --prefix bootstrap/terraform.tfstate \
  --query 'Versions[].{
    VersionId:VersionId,
    IsLatest:IsLatest,
    LastModified:LastModified
  }' \
  --output table
```

Infrastructure:

```bash
aws-vault exec terraform -- \
  aws s3api list-object-versions \
  --bucket "$BUCKET" \
  --prefix infrastructure/terraform.tfstate \
  --query 'Versions[].{
    VersionId:VersionId,
    IsLatest:IsLatest,
    LastModified:LastModified
  }' \
  --output table
```

Pass criteria:

```text
the expected state key exists
at least one version exists
historical versions are retained when previous state writes have occurred
```

---

## 7.3 Offline State Backup

Create a backup directory outside the repository:

```bash
BACKUP_DIR="$HOME/tfstate-backups"
mkdir -p "$BACKUP_DIR"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
```

Bootstrap:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap state pull \
  > "$BACKUP_DIR/bootstrap-$TS.json"
```

Infrastructure:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure state pull \
  > "$BACKUP_DIR/infrastructure-$TS.json"
```

Verify:

```bash
wc -c \
  "$BACKUP_DIR/bootstrap-$TS.json" \
  "$BACKUP_DIR/infrastructure-$TS.json"
```

Optional integrity hashes:

```bash
sha256sum \
  "$BACKUP_DIR/bootstrap-$TS.json" \
  "$BACKUP_DIR/infrastructure-$TS.json"
```

The backup files must remain outside the Git repository.

---

## 7.4 Point-in-Time Recovery

A prior object version can be downloaded without immediately replacing the
current Terraform state.

Example:

```bash
VERSION_ID="<known-good-version-id>"

aws-vault exec terraform -- \
  aws s3api get-object \
  --bucket "$BUCKET" \
  --key infrastructure/terraform.tfstate \
  --version-id "$VERSION_ID" \
  "$HOME/infrastructure-state-recovery-candidate.json"
```

The recovered file should be inspected before any restoration action.

---

## 7.5 Recovery Procedure

If Terraform state is suspected to be corrupted, overwritten, or accidentally
deleted:

```text
1. Stop all Terraform operations.
2. Confirm whether an active state lock exists.
3. Back up the current state and relevant S3 object versions.
4. Identify the last known-good state version.
5. Recover or restore the selected version deliberately.
6. Reinitialize Terraform if required.
7. Run terraform plan.
8. Compare the plan with the real AWS infrastructure.
9. Do not run terraform apply until unexplained differences are resolved.
```

A restored state must never be followed immediately by an unreviewed
`terraform apply`.

---

# 8. Accidental Deletion Protection

The remote-state bucket is configured with:

```hcl
force_destroy = false
```

Terraform therefore cannot recursively delete a non-empty state bucket as part
of a normal destroy.

This protects:

```text
current state
historical state versions
lock-file history
```

from casual deletion.

Full teardown requires deliberate state migration and permanent removal of S3
object versions.

The complete procedure is documented in:

```text
docs/cleanup.md
```

---

# 9. State Governance

## 9.1 Separate State Ownership

Bootstrap owns the S3 backend infrastructure.

Infrastructure consumes that backend.

```text
terraform/bootstrap
    -> owns the state bucket

terraform/infrastructure
    -> stores application-infrastructure state in that bucket
```

This dependency affects:

```text
initial deployment
state migration
recovery
teardown ordering
```

---

## 9.2 No State in Git

Terraform state must not be committed.

Check tracked files:

```bash
git ls-files \
  | grep -E 'terraform\.tfstate($|\.)' \
  || echo "No Terraform state tracked"
```

Review ignore behavior:

```bash
git check-ignore -v \
  terraform/bootstrap/terraform.tfstate \
  terraform/infrastructure/terraform.tfstate \
  2>/dev/null || true
```

The repository may contain backend configuration, but not Terraform state
contents.

---

## 9.3 Terraform and CI/CD Ownership

Terraform manages the baseline ECS services.

At runtime:

```text
Application Auto Scaling
    -> may change desired_count

Jenkins / GitHub Actions
    -> may deploy new task_definition revisions
```

The ECS service resources therefore use lifecycle rules so Terraform does not
fight these runtime owners.

Conceptually:

```text
Terraform
    -> infrastructure configuration

Application Auto Scaling
    -> runtime desired count

CI/CD
    -> deployed application revision

ECS
    -> service health and deployment reconciliation
```

This is a state-governance decision.

A later Terraform plan should not attempt to roll back legitimate CI/CD or
Auto Scaling changes that are intentionally delegated outside Terraform.

---

## 9.4 Idempotency

After a stable deployment, Terraform should converge cleanly.

Bootstrap:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap plan
```

Infrastructure:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan
```

Expected:

```text
No changes. Your infrastructure matches the configuration.
```

Unexpected changes must be explained before running `terraform apply`.

---

# 10. Teardown Dependency

The state bucket must not be destroyed before the infrastructure state is no
longer required.

Correct dependency order:

```text
1. Back up all Terraform states.
2. Destroy GitOps IAM resources if they depend on application resources.
3. Destroy terraform/infrastructure.
4. Confirm the main infrastructure state is empty.
5. Migrate bootstrap state away from S3 if performing a full teardown.
6. Permanently remove remaining S3 object versions and delete markers.
7. Destroy terraform/bootstrap last.
```

The detailed procedure is documented in:

```text
docs/cleanup.md
```

Never destroy the bootstrap state bucket while
`infrastructure/terraform.tfstate` is still required to manage live resources.

---

# 11. Evidence Checklist

The following evidence is sufficient to demonstrate the remote-state security
model.

## 11.1 Shared Bucket Controls

| Evidence | Validation |
|---|---|
| AWS execution identity | `aws sts get-caller-identity` |
| Encryption | `aws s3api get-bucket-encryption` |
| Versioning | `aws s3api get-bucket-versioning` |
| Public access block | `aws s3api get-public-access-block` |
| Bucket not public | `aws s3api get-bucket-policy-status` |
| Object ownership | `aws s3api get-bucket-ownership-controls` |
| TLS-only policy | `aws s3api get-bucket-policy` |
| Governance tags | `aws s3api get-bucket-tagging` |

---

## 11.2 Bootstrap State Evidence

Capture:

```text
head-object for bootstrap/terraform.tfstate
version history for bootstrap/terraform.tfstate
terraform/bootstrap state list
terraform/bootstrap plan showing no unintended changes
state pull backup
```

Optional:

```text
live .tflock demonstration
```

---

## 11.3 Infrastructure State Evidence

Capture:

```text
head-object for infrastructure/terraform.tfstate
version history for infrastructure/terraform.tfstate
terraform/infrastructure state list
terraform/infrastructure plan showing no unintended changes
state pull backup
```

Optional:

```text
live .tflock demonstration
```

---

## 11.4 Authorization Boundary Evidence

Review:

```text
Jenkins role contains no Terraform-state S3 permissions
GitHub Actions deployment role contains no Terraform-state S3 permissions
ECS execution roles contain no Terraform-state S3 permissions
Terraform execution role is used for Terraform operations
```

The Terraform execution-role policy itself requires a separate external IAM
review because it is not managed by this repository.

---

# 12. Residual Risks and Production Improvements

| Area | Current Design | Residual Risk / Production Improvement |
|---|---|---|
| Encryption key | SSE-S3 / AES256 | Evaluate customer-managed KMS keys when compliance, cross-account access, or key-administration requirements justify them |
| State bucket | One bucket, separate state keys | Use prefix-scoped IAM or separate buckets when stronger administrative isolation is required |
| State layout | Bootstrap state + one main infrastructure state | Larger production environments may split network, platform, and application infrastructure into separate state domains |
| State locking | S3-native `.tflock` | Retain unless organizational standards require another backend/locking model |
| Operator authentication | AWS Vault + role assumption + MFA | Enterprise environments may use centralized federation / IAM Identity Center |
| State-access monitoring | Normal AWS API/account logging only | Add dedicated CloudTrail S3 data events and alerting for sensitive state access |
| Recovery | S3 Versioning + manual state backups | Formalize tested recovery exercises and protected backup retention |
| Terraform execution role | Managed outside repository | Review exact policy, trust relationship, MFA/federation requirements, and S3 prefix scope separately |

The current controls are appropriate to the scope of the challenge, but they
should not be interpreted as a complete production Terraform governance model.

---

# 13. Reviewer Summary

The remote-state security model can be explained in six points:

```text
1. Bootstrap and infrastructure use separate state keys in one dedicated S3
   bucket.

2. State is encrypted at rest with SSE-S3 and protected in transit by a
   TLS-only bucket policy.

3. Public access is blocked and ACL-based ownership is disabled with
   BucketOwnerEnforced.

4. Both Terraform configurations use S3-native lock files to protect against
   concurrent state writes.

5. Versioning and state-pull backups provide recovery paths, while
   force_destroy = false protects the bucket from casual recursive deletion.

6. Application deployment identities do not receive Terraform-state access from
   this project; Terraform administration remains a separate control-plane
   responsibility.
```

---

# Appendix A: Optional Validation Script

The following script validates the principal remote-state controls for both
Terraform configurations.

Run it from the repository root.

```bash
#!/usr/bin/env bash
set -euo pipefail

BUCKET="${BUCKET:-$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/bootstrap output \
    -raw state_bucket_name \
    2>/dev/null || true
)}"

if [[ -z "$BUCKET" ]]; then
  echo "BUCKET is not set and could not be read from Terraform output."
  echo "Set it manually before continuing:"
  echo 'export BUCKET="ecs-fargate-cicd-tfstate-<account-id>-us-east-1"'
  exit 1
fi

run() {
  aws-vault exec terraform -- "$@"
}

echo "=== AWS identity ==="
run aws sts get-caller-identity

echo
echo "=== Bucket encryption ==="
run aws s3api get-bucket-encryption \
  --bucket "$BUCKET"

echo
echo "=== Bucket versioning ==="
run aws s3api get-bucket-versioning \
  --bucket "$BUCKET"

echo
echo "=== Public access block ==="
run aws s3api get-public-access-block \
  --bucket "$BUCKET"

echo
echo "=== Bucket policy status ==="
run aws s3api get-bucket-policy-status \
  --bucket "$BUCKET"

echo
echo "=== Ownership controls ==="
run aws s3api get-bucket-ownership-controls \
  --bucket "$BUCKET"

echo
echo "=== Terraform state objects ==="

for KEY in \
  bootstrap/terraform.tfstate \
  infrastructure/terraform.tfstate
do
  echo
  echo "--- $KEY ---"

  run aws s3api head-object \
    --bucket "$BUCKET" \
    --key "$KEY"

  run aws s3api list-object-versions \
    --bucket "$BUCKET" \
    --prefix "$KEY" \
    --query 'Versions[].{
      VersionId:VersionId,
      IsLatest:IsLatest,
      LastModified:LastModified
    }' \
    --output table
done

echo
echo "=== Bootstrap state inventory ==="
run terraform \
  -chdir=terraform/bootstrap \
  state list

echo
echo "=== Infrastructure state inventory ==="
run terraform \
  -chdir=terraform/infrastructure \
  state list

echo
echo "=== Terraform plans ==="

run terraform \
  -chdir=terraform/bootstrap \
  plan

run terraform \
  -chdir=terraform/infrastructure \
  plan

echo
echo "=== Offline state backups ==="

OUTDIR="${OUTDIR:-$HOME/tfstate-backups}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$OUTDIR"

run terraform \
  -chdir=terraform/bootstrap \
  state pull \
  > "$OUTDIR/bootstrap-$TS.json"

run terraform \
  -chdir=terraform/infrastructure \
  state pull \
  > "$OUTDIR/infrastructure-$TS.json"

wc -c \
  "$OUTDIR/bootstrap-$TS.json" \
  "$OUTDIR/infrastructure-$TS.json"

echo
echo "Remote-state validation complete."
```

The script intentionally does not:

```text
force-unlock state
delete lock objects
modify state
restore old state versions
perform destructive negative IAM tests
```

Those actions should remain deliberate operator procedures rather than routine
validation behavior.
