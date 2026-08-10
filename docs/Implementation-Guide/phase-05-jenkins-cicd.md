# Phase 5: Jenkins CI/CD Pipeline

## 5.1 GitHub source credential

The project repository is private.

Create a fine-grained GitHub personal access token restricted to:

```text
Repository:
ecs-fargate-cicd-pipeline

Permission:
Contents - Read-only
```

Store it in Jenkins as:

```text
Kind:        Username with password
Username:    <github-username>
Password:    <fine-grained-PAT>
Credential:  github-repo-read
```

The PAT is placed in the Jenkins password field for HTTPS Git authentication.

No GitHub token is stored in the repository.

---

## 5.2 Create the Jenkins job

Create:

```text
Job name:
ecs-fargate-cicd-deploy

Type:
Pipeline
```

Configure:

```text
Definition:
Pipeline script from SCM

SCM:
Git

Repository URL:
https://github.com/<owner>/ecs-fargate-cicd-pipeline.git

Credentials:
github-repo-read

Branch:
*/main

Script Path:
Jenkinsfile
```

This makes the committed `Jenkinsfile` the pipeline definition rather than
storing pipeline logic inside the Jenkins UI.

---

## 5.3 Pipeline ownership

Terraform owns:

```text
ECS cluster
ECS service infrastructure
networking
load balancer
baseline task definitions
auto-scaling configuration
```

Jenkins owns:

```text
new application image versions
new ECS task-definition revisions
application deployments
post-deployment validation
```

The ECS services ignore later Terraform changes to:

```text
desired_count
task_definition
```

so Application Auto Scaling and Jenkins can modify those runtime fields without
Terraform attempting to revert valid changes.

---

## 5.4 Pipeline stages

The committed Jenkins pipeline runs:

```text
Checkout
    |
Verify AWS Identity
    |
Checkov IaC Scan
    |
Build Images
    |
Trivy Image Security Gate
    |
Authenticate to ECR
    |
Push Immutable Images
    |
Register Task Definitions
    |
Deploy to ECS
    |
Wait for Stable Services
    |
Validate Live Application
    |
Post Actions
```

---

## 5.5 Immutable CI image tags

Each pipeline build creates an image tag from:

```text
<12-character-git-commit>-<jenkins-build-number>
```

Example:

```text
e0ac840b5856-3
```

This provides:

```text
Git commit
    -> source traceability

Jenkins build number
    -> build uniqueness
```

The repositories use immutable ECR tags, so an earlier artifact cannot be
silently overwritten by a later pipeline execution.

---

## 5.6 Security checks

### Checkov

Checkov scans:

```text
terraform/infrastructure
```

The current pipeline runs Checkov with `--soft-fail`.

Its findings remain visible in the build output and are reviewed as either:

```text
fix-now
accepted-with-rationale
```

rather than blindly modifying infrastructure during the timed challenge.

### Trivy

Trivy scans both built container images for:

```text
HIGH
CRITICAL
```

findings.

The pipeline uses:

```text
--ignore-unfixed
--exit-code 1
```

A fixable HIGH or CRITICAL vulnerability therefore blocks image publication and
ECS deployment.

During implementation, this gate successfully rejected a vulnerable backend
image. The backend dependencies and runtime image were corrected, then the
pipeline was rerun successfully.

This proves the scan is an enforcement control rather than a reporting-only
step.

---

## 5.7 ECR authentication

Jenkins obtains its AWS identity from the EC2 instance profile.

The pipeline requests a temporary ECR login password:

```text
EC2 instance role
      |
      v
AWS STS credentials
      |
      v
ECR login token
      |
      v
docker login
```

No static AWS credentials are stored in Jenkins.

---

## 5.8 ECS deployment

For each service, Jenkins:

```text
reads the currently deployed task definition
        |
changes only the application image URI
        |
removes response-only AWS fields
        |
registers a new task-definition revision
        |
updates the ECS service
```

This preserves the Terraform-created task settings instead of duplicating the
entire task-definition model inside the Jenkinsfile.

---

## 5.9 Wait for ECS steady state

After calling `UpdateService`, Jenkins does not immediately declare success.

It waits for:

```bash
aws ecs wait services-stable
```

for both services.

Successful deployment requires the services to reach:

```text
Desired = Running
Pending = 0
```

This distinguishes an accepted AWS deployment request from a completed workload
deployment.

---
## Phase 4-6 Acceptance Criteria

Jenkins CI/CD is complete when:

- Jenkins is publicly reachable on TCP/8080.
- SSH is restricted to the approved administrator `/32`.
- Jenkins infrastructure can be recreated through Terraform.
- Jenkins host configuration can be recreated through Ansible.
- Jenkins authenticates to AWS through an EC2 instance profile.
- No static AWS credential is stored in Jenkins.
- Jenkins can execute Docker builds.
- The private GitHub repository can be read through the scoped Jenkins credential.
- The pipeline definition is stored in the root `Jenkinsfile`.
- Checkov runs before deployment.
- Trivy blocks fixable HIGH/CRITICAL image vulnerabilities.
- Frontend and backend images use immutable build-specific tags.
- Both images are pushed to ECR.
- New ECS task-definition revisions are registered.
- Both ECS services are updated.
- Jenkins waits for ECS services to become stable.
- The live frontend returns HTTP 200.
- `/api` returns a GUID.
- A final Terraform plan reports no infrastructure changes.
- A GitHub push triggers Jenkins automatically when webhook automation is enabled.




---

## Phase 4-6 Evidence

Store concise evidence under:

```text
docs/evidence/screenshots/jenkins/
```

Recommended evidence:

```text
01-ansible-convergence.png
02-jenkins-aws-role-identity.png
03-jenkins-login-or-dashboard.png
04-full-pipeline-success.png
05-live-validation-success.png
06-github-webhook-delivery.png
```

The strongest Jenkins evidence is a fresh pipeline execution in which all stages
are green in one run.

A restarted-from-stage build is useful troubleshooting evidence but should not
replace the final full-pipeline screenshot.

---

