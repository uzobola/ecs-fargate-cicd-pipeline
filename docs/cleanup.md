# Tech Challenge 1 Cleanup and Teardown Runbook

## Purpose

This runbook removes the AWS resources created after the
the live Jenkins or application URLs are no longer needed.

Use this dependency order:

```text
1. Confirm repo + identity
2. Back up Terraform state
3. Destroy GitOps IAM
4. Empty ECR repositories
5. Destroy main infrastructure
6. Clean up CI/CD-created task-definition revisions
7. Verify high-cost resources are gone
8. Optionally destroy the Terraform state bucket last
```

Do not start while evaluation still requires the live environment.

---

## 1. Preconditions

Run from the repository root in Git Bash.

```bash
git switch main
git status --short
git log -1 --oneline
git push origin main
```

`git status --short` should be empty before destructive work begins.

Confirm the AWS identity:

```bash
aws-vault exec terraform -- aws sts get-caller-identity
```

Set reusable variables:

```bash
ACCOUNT_ID=$(
  aws-vault exec terraform --     aws sts get-caller-identity       --query Account       --output text
)

AWS_REGION="us-east-1"
PROJECT_NAME="ecs-fargate-cicd"
STATE_BUCKET="${PROJECT_NAME}-tfstate-${ACCOUNT_ID}-${AWS_REGION}"
```

For this challenge account the expected bucket is:

```text
ecs-fargate-cicd-tfstate-421438965568-us-east-1
```

---

## 2. Back up all Terraform state

State may contain sensitive values. Keep backups outside the repository and
never commit them.

```bash
BACKUP_DIR="$HOME/tc1-teardown-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
```

### Main infrastructure

```bash
aws-vault exec terraform --   terraform -chdir=terraform/infrastructure init     -backend-config="bucket=$STATE_BUCKET"

aws-vault exec terraform --   terraform -chdir=terraform/infrastructure state pull   > "$BACKUP_DIR/infrastructure.tfstate.json"
```

### Bootstrap

```bash
aws-vault exec terraform --   terraform -chdir=terraform/bootstrap init     -backend-config="bucket=$STATE_BUCKET"

aws-vault exec terraform --   terraform -chdir=terraform/bootstrap state pull   > "$BACKUP_DIR/bootstrap.tfstate.json"
```

### GitOps IAM

```bash
git switch gitops

aws-vault exec terraform --   terraform -chdir=terraform/gitops-iam init

aws-vault exec terraform --   terraform -chdir=terraform/gitops-iam state pull   > "$BACKUP_DIR/gitops.tfstate.json"

git switch main
```

Verify:

```bash
ls -lh "$BACKUP_DIR"
```

---

## 3. Destroy GitOps IAM first

The GitOps configuration reads the application ECR repositories and ECS
execution roles as data sources, so destroy this state while the application
resources still exist.

```bash
git switch gitops

aws-vault exec terraform --   terraform -chdir=terraform/gitops-iam init

aws-vault exec terraform --   terraform -chdir=terraform/gitops-iam plan     -destroy     -out=gitops-destroy.tfplan

aws-vault exec terraform --   terraform -chdir=terraform/gitops-iam show     -no-color     gitops-destroy.tfplan
```

The plan should remove the project GitHub Actions deployment IAM role and its
inline policy. It must not remove the existing account-level GitHub OIDC
provider.

Apply:

```bash
aws-vault exec terraform --   terraform -chdir=terraform/gitops-iam apply     gitops-destroy.tfplan
```

Verify:

```bash
aws-vault exec terraform --   terraform -chdir=terraform/gitops-iam state list
```

Expected: no managed resources.

Return to main:

```bash
git switch main
```

---

## 4. Empty the two ECR repositories

The Terraform repositories use `force_delete = false`, so image artifacts must
be removed before `terraform destroy`.

Repositories:

```text
ecs-fargate-cicd-frontend
ecs-fargate-cicd-backend
```

Inspect:

```bash
for repo in   ecs-fargate-cicd-frontend   ecs-fargate-cicd-backend
do
  aws-vault exec terraform --     aws ecr list-images       --region "$AWS_REGION"       --repository-name "$repo"       --output table
done
```

Delete:

```bash
for repo in   ecs-fargate-cicd-frontend   ecs-fargate-cicd-backend
do
  IMAGE_IDS=$(
    aws-vault exec terraform --       aws ecr list-images         --region "$AWS_REGION"         --repository-name "$repo"         --query 'imageIds'         --output json
  )

  if [ "$IMAGE_IDS" != "[]" ]; then
    aws-vault exec terraform --       aws ecr batch-delete-image         --region "$AWS_REGION"         --repository-name "$repo"         --image-ids "$IMAGE_IDS"
  else
    echo "$repo is already empty"
  fi
done
```

Verify both return `[]`:

```bash
for repo in   ecs-fargate-cicd-frontend   ecs-fargate-cicd-backend
do
  aws-vault exec terraform --     aws ecr list-images       --region "$AWS_REGION"       --repository-name "$repo"       --query 'imageIds'       --output json
done
```

---

## 5. Destroy the main infrastructure

This is the major cost-removal step. The main state owns the VPC, NAT Gateways,
ALB, ECS runtime, ECR repositories, Auto Scaling, CloudWatch log groups,
Jenkins EC2, Jenkins Elastic IP, and project IAM resources.

Initialize and validate:

```bash
aws-vault exec terraform --   terraform -chdir=terraform/infrastructure init     -backend-config="bucket=$STATE_BUCKET"

aws-vault exec terraform --   terraform -chdir=terraform/infrastructure validate
```

Create a saved destroy plan:

```bash
aws-vault exec terraform --   terraform -chdir=terraform/infrastructure plan     -destroy     -out=infrastructure-destroy.tfplan
```

Review it:

```bash
aws-vault exec terraform --   terraform -chdir=terraform/infrastructure show     -no-color     infrastructure-destroy.tfplan
```

Apply only the reviewed plan:

```bash
aws-vault exec terraform --   terraform -chdir=terraform/infrastructure apply     infrastructure-destroy.tfplan
```

Verify state is empty:

```bash
aws-vault exec terraform --   terraform -chdir=terraform/infrastructure state list
```

Expected: no managed resources.

---

## 6. Clean up CI/CD-created task-definition revisions

Jenkins and GitHub Actions registered task-definition revisions that Terraform
does not own. They do not create running Fargate cost by themselves, but they
can be deregistered for account hygiene after the services are removed.

Inspect:

```bash
for family in   ecs-fargate-cicd-frontend   ecs-fargate-cicd-backend
do
  aws-vault exec terraform --     aws ecs list-task-definitions       --region "$AWS_REGION"       --family-prefix "$family"       --status ACTIVE       --output table
done
```

Deregister:

```bash
for family in   ecs-fargate-cicd-frontend   ecs-fargate-cicd-backend
do
  for arn in $(
    aws-vault exec terraform --       aws ecs list-task-definitions         --region "$AWS_REGION"         --family-prefix "$family"         --status ACTIVE         --query 'taskDefinitionArns[]'         --output text
  )
  do
    aws-vault exec terraform --       aws ecs deregister-task-definition         --region "$AWS_REGION"         --task-definition "$arn"         --query 'taskDefinition.{Family:family,Revision:revision,Status:status}'
  done
done
```

---

## 7. Verify the runtime and expensive resources are gone

### ALB

```bash
aws-vault exec terraform --   aws elbv2 describe-load-balancers     --region "$AWS_REGION"     --names "${PROJECT_NAME}-alb"
```

Expected: `LoadBalancerNotFound`.

### NAT Gateways

```bash
aws-vault exec terraform --   aws ec2 describe-nat-gateways     --region "$AWS_REGION"     --filter "Name=tag:Name,Values=${PROJECT_NAME}-nat-*"     --query 'NatGateways[].{Id:NatGatewayId,State:State}'     --output table
```

No project NAT Gateway should remain active or pending.

### Jenkins EC2

```bash
aws-vault exec terraform --   aws ec2 describe-instances     --region "$AWS_REGION"     --filters       "Name=tag:Name,Values=${PROJECT_NAME}-jenkins"       "Name=instance-state-name,Values=pending,running,stopping,stopped"     --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name}'     --output table
```

Expected: no instances.

### Elastic IPs

```bash
aws-vault exec terraform --   aws ec2 describe-addresses     --region "$AWS_REGION"     --filters "Name=tag:Name,Values=${PROJECT_NAME}-*"     --query 'Addresses[].{AllocationId:AllocationId,PublicIp:PublicIp}'     --output table
```

Expected: no project Elastic IPs.

### ECR

```bash
aws-vault exec terraform --   aws ecr describe-repositories     --region "$AWS_REGION"     --repository-names       ecs-fargate-cicd-frontend       ecs-fargate-cicd-backend
```

Expected: `RepositoryNotFoundException`.

### ECS log groups

```bash
aws-vault exec terraform --   aws logs describe-log-groups     --region "$AWS_REGION"     --log-group-name-prefix "/ecs/${PROJECT_NAME}"     --query 'logGroups[].logGroupName'     --output text
```

Expected: no output.

At this point the main recurring application/Jenkins costs should be gone.

---

## 8. Decide whether to retain or delete the Terraform state bucket

The state bucket is intentionally separate from the main infrastructure.

It stores:

```text
bootstrap/terraform.tfstate
infrastructure/terraform.tfstate
gitops/terraform.tfstate
```

and historical object versions.

### Option A: retain it

This is the safer choice if the project may need to be audited or reconstructed.
The remaining S3 storage is tiny compared with NAT Gateway, ALB, Fargate, and EC2
cost.

Stop here if retaining the state bucket.

### Option B: full teardown

For complete removal, migrate the bootstrap state to local storage first,
because the bootstrap state currently lives in the bucket that Terraform itself
manages.

---

## 9. Full teardown: migrate bootstrap state to local

Create a final backup:

```bash
aws-vault exec terraform --   terraform -chdir=terraform/bootstrap state pull   > "$BACKUP_DIR/bootstrap-before-local-migration.tfstate.json"
```

Temporarily move the backend configuration out of Terraform's `.tf` inputs:

```bash
mv   terraform/bootstrap/backend.tf   terraform/bootstrap/backend.tf.remote
```

Reinitialize:

```bash
aws-vault exec terraform --   terraform -chdir=terraform/bootstrap init     -migrate-state
```

When Terraform asks whether to migrate the S3 state to the default local
backend, answer `yes`.

Verify local state exists:

```bash
ls -lh terraform/bootstrap/terraform.tfstate

aws-vault exec terraform --   terraform -chdir=terraform/bootstrap state list
```

Do not continue unless the bootstrap resources are visible from local state.

---

## 10. Permanently empty the versioned state bucket

A normal delete is insufficient because S3 Versioning is enabled. All object
versions and delete markers must be permanently removed.

Inspect first:

```bash
aws-vault exec terraform --   aws s3api list-object-versions     --bucket "$STATE_BUCKET"     --output table
```

Delete versions:

```bash
VERSIONS=$(
  aws-vault exec terraform --     aws s3api list-object-versions       --bucket "$STATE_BUCKET"       --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}'       --output json
)

if [ "$VERSIONS" != '{"Objects": null}' ] &&    [ "$VERSIONS" != '{"Objects":[]}' ]; then
  aws-vault exec terraform --     aws s3api delete-objects       --bucket "$STATE_BUCKET"       --delete "$VERSIONS"
fi
```

Delete markers:

```bash
DELETE_MARKERS=$(
  aws-vault exec terraform --     aws s3api list-object-versions       --bucket "$STATE_BUCKET"       --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}'       --output json
)

if [ "$DELETE_MARKERS" != '{"Objects": null}' ] &&    [ "$DELETE_MARKERS" != '{"Objects":[]}' ]; then
  aws-vault exec terraform --     aws s3api delete-objects       --bucket "$STATE_BUCKET"       --delete "$DELETE_MARKERS"
fi
```

Verify:

```bash
aws-vault exec terraform --   aws s3api list-object-versions     --bucket "$STATE_BUCKET"
```

No versions or delete markers should remain. Repeat the deletion pass if any
remain.

---

## 11. Destroy the bootstrap state infrastructure

Now the bootstrap state is local and the state bucket is empty.

```bash
aws-vault exec terraform --   terraform -chdir=terraform/bootstrap plan     -destroy     -out=bootstrap-destroy.tfplan

aws-vault exec terraform --   terraform -chdir=terraform/bootstrap show     -no-color     bootstrap-destroy.tfplan

aws-vault exec terraform --   terraform -chdir=terraform/bootstrap apply     bootstrap-destroy.tfplan
```

Verify:

```bash
aws-vault exec terraform --   terraform -chdir=terraform/bootstrap state list
```

Expected: no managed resources.

Verify bucket deletion:

```bash
aws-vault exec terraform --   aws s3api head-bucket     --bucket "$STATE_BUCKET"
```

Expected: 404 / Not Found.

---

## 12. Restore the repository configuration

Restore the tracked backend file:

```bash
mv   terraform/bootstrap/backend.tf.remote   terraform/bootstrap/backend.tf
```

Remove generated destroy plans:

```bash
rm -f   terraform/infrastructure/infrastructure-destroy.tfplan   terraform/bootstrap/bootstrap-destroy.tfplan
```

Remove local bootstrap state only after confirming the AWS teardown succeeded:

```bash
rm -f   terraform/bootstrap/terraform.tfstate   terraform/bootstrap/terraform.tfstate.backup
```

Do not commit `.terraform/`, local state files, or `.tfplan` files.

Confirm:

```bash
git status --short
```

---

## 13. Final identity cleanup verification

GitHub Actions deployment role:

```bash
aws-vault exec terraform --   aws iam get-role     --role-name "${PROJECT_NAME}-github-actions-deploy-role"
```

Expected: `NoSuchEntity`.

Do **not** delete the account's GitHub Actions OIDC provider. This challenge
reused an existing provider rather than creating it.

Jenkins role:

```bash
aws-vault exec terraform --   aws iam get-role     --role-name "${PROJECT_NAME}-challenge-jenkins-role"
```

Expected: `NoSuchEntity`.

---

## Teardown acceptance criteria

```text
[ ] Latest documentation committed and pushed
[ ] Terraform states backed up outside repository
[ ] GitOps IAM state destroyed
[ ] ECR images removed
[ ] Main infrastructure state empty
[ ] ECS services and cluster removed
[ ] ALB removed
[ ] NAT Gateways removed
[ ] Jenkins EC2 removed
[ ] Project Elastic IPs removed
[ ] ECR repositories removed
[ ] ECS application log groups removed
[ ] CI/CD-created task-definition revisions deregistered
[ ] State bucket intentionally retained OR fully destroyed
[ ] Existing shared GitHub OIDC provider retained
[ ] No local state or destroy-plan files committed
```

## Ownership summary

```text
GitOps Terraform
    -> GitHub Actions deployment role

Main infrastructure Terraform
    -> application, networking, ECS, Jenkins

Manual ECR cleanup
    -> required because force_delete = false

Manual task-definition cleanup
    -> CI/CD-created revisions outside Terraform ownership

Bootstrap Terraform
    -> state bucket, destroyed last if full teardown is selected
```
