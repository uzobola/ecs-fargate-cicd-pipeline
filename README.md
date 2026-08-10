# AWS ECS Fargate CI/CD Tech Challenge

## Overview

This project deploys a two-service web application to AWS ECS Fargate and
implements an automated Jenkins CI/CD pipeline for container build, security
validation, image publication, ECS deployment, and live application validation.

The application consists of:

```text
React frontend
    |
    | /api
    v
Express backend
```

AWS exposes both services through one public Application Load Balancer.

```text
Internet
    |
    v
Application Load Balancer
    |
    +---- default /* ----> Frontend ECS service :3000
    |
    +---- /api* ---------> Backend ECS service :8080
```

The deployed frontend displays:

```text
SUCCESS: <GUID>
```

when frontend-to-backend communication is working.

---

# Implementation Status

- [x] Local application validation
- [x] Backend `/health` endpoint
- [x] Environment-aware application configuration
- [x] Backend containerization
- [x] Frontend multi-stage containerization
- [x] Non-root container runtimes
- [x] Local path-routing integration validation
- [x] Terraform remote-state bootstrap
- [x] Amazon ECR repositories
- [x] Two-AZ VPC architecture
- [x] Public/private subnet separation
- [x] One NAT Gateway per Availability Zone
- [x] Application Load Balancer
- [x] Path-based `/api` routing
- [x] ECS Fargate cluster
- [x] Frontend ECS service
- [x] Backend ECS service
- [x] ECS task-definition CPU/memory configuration
- [x] Application Auto Scaling configuration
- [x] 50% CPU target-tracking policy
- [x] Jenkins infrastructure through Terraform
- [x] Jenkins host configuration through Ansible
- [x] Jenkins pipeline from SCM
- [x] Checkov Terraform scanning
- [x] Trivy container security gate
- [x] Immutable ECR image tagging
- [x] Automated ECS deployment
- [x] ECS steady-state validation
- [x] Live post-deployment validation
- [x] GitHub webhook-triggered Jenkins builds
- [x] Auto Scaling load-test evidence
- [x] GitHub Actions GitOps bonus

---

# Architecture

## AWS application architecture

```text
                            Internet
                               |
                               v
                    Application Load Balancer
                      Public Subnets / 2 AZs
                         /             \
                        /               \
                  default /*           /api*
                      |                   |
                      v                   v
              Frontend Target      Backend Target
                  Group                Group
                HTTP/3000            HTTP/8080
                      |                   |
                      v                   v
             Frontend Fargate      Backend Fargate
                  Service               Service
                      |                   |
                 Private Subnets across 2 AZs
                      |                   |
              NAT Gateway A       NAT Gateway B
                      |                   |
                    Internet Gateway
```

The application tasks run in private subnets.

The public ALB is the only internet-facing application entry point.

Frontend and backend security groups permit application traffic only from the
ALB security group.

---

# Availability and Failure-Domain Design

The network spans two Availability Zones.

Each AZ contains:

```text
1 public subnet
1 private subnet
1 NAT Gateway
1 private route table
```

Each private subnet routes outbound traffic through the NAT Gateway in the same
Availability Zone.

This improves:

- Availability Zone independence
- failure-domain separation
- private-egress availability
- fault isolation
- blast-radius reduction

The ALB spans both public subnets.

The challenge requires:

```text
Minimum tasks: 1
Desired tasks: 1
Maximum tasks: 4
```

A desired count of one means the complete application should not be described as
fully fault tolerant. A single running task can still produce a temporary
interruption during failure or replacement.

---

# ECS Fargate Configuration

Both services run on AWS Fargate.

Each task is configured with:

```text
CPU:     512 units / 0.5 vCPU
Memory:  1024 MiB / 1 GiB
```

Application Auto Scaling is configured with:

```text
Minimum capacity: 1
Desired capacity: 1
Maximum capacity: 4

Target metric:
ECSServiceAverageCPUUtilization

Target:
50%
```

The frontend and backend have independent scaling policies.

---

# Application Load Balancer Routing

One public Application Load Balancer exposes both services.

Routing rules:

```text
/api
/api/*
    |
    v
Backend target group
HTTP/8080


everything else
    |
    v
Frontend target group
HTTP/3000
```

Health checks:

```text
Frontend:
/

Backend:
/health
```

The frontend uses the relative path:

```text
/api
```

rather than embedding an environment-specific backend hostname.

This allows the browser to use one public application origin.

---

# Container Images

## Frontend

The frontend uses a multi-stage Docker build:

```text
Node.js 16.20.2
       |
       | compile React application
       v
static build files
       |
       v
nginx-unprivileged
```

Node.js exists only in the build stage.

The final container serves static files through unprivileged Nginx on port
`3000`.

The legacy Node version is retained solely to support the supplied
`react-scripts 4.0.3` build environment.

## Backend

The backend uses a multi-stage runtime image.

The dependency stage contains Node/npm for package installation.

The final runtime contains only the components required to execute the
application.

The backend runs as a non-root user on port `8080`.

This reduced runtime image was introduced after the Trivy pipeline gate detected
HIGH and CRITICAL vulnerabilities in unnecessary runtime tooling and older
application dependencies.

---

# Amazon ECR

Separate repositories are used:

```text
ecs-fargate-cicd-frontend
ecs-fargate-cicd-backend
```

Controls include:

```text
Immutable image tags
AES-256 repository encryption
ECR Basic vulnerability scanning
registry-level SCAN_ON_PUSH rule
```

Pipeline image tags use:

```text
<12-character-git-commit>-<jenkins-build-number>
```

Example:

```text
e0ac840b5856-3
```

This provides both source traceability and build uniqueness.

---

# Terraform

Infrastructure is managed under:

```text
terraform/
├── bootstrap/
└── infrastructure/
```

## Remote state bootstrap

The bootstrap configuration creates the Terraform S3 backend.

Controls include:

```text
S3 object versioning
SSE-S3 encryption
S3-native state locking
bucket-owner-enforced ownership
S3 Block Public Access
TLS-only bucket policy
```

State objects:

```text
bootstrap/terraform.tfstate
infrastructure/terraform.tfstate
```

## Main infrastructure

Terraform manages:

```text
VPC
public/private subnets
Internet Gateway
NAT Gateways
route tables
security groups
ECR repositories
Application Load Balancer
target groups
listener rules
ECS cluster
task definitions
ECS services
CloudWatch log groups
IAM execution roles
Application Auto Scaling
Jenkins EC2 infrastructure
Jenkins IAM role
Jenkins security group
Elastic IP
```

---

# Terraform Authentication

Terraform commands are executed through `aws-vault`:

```bash
aws-vault exec terraform -- <command>
```

The Terraform profile assumes a dedicated Terraform execution role.

No AWS credentials are stored in this repository.

---

# Terraform Deployment

## 1. Bootstrap remote state

Initialize:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap init
```

Plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap plan \
  -out=bootstrap.tfplan
```

Apply:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/bootstrap apply \
  bootstrap.tfplan
```

## 2. Initialize the main infrastructure

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure init
```

## 3. Validate

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure validate
```

## 4. Plan

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan \
  -out=infrastructure.tfplan
```

Review the plan before applying it.

## 5. Apply

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure apply \
  infrastructure.tfplan
```

## 6. Verify convergence

After deployment:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan
```

Expected:

```text
No changes. Your infrastructure matches the configuration.
```

---

# Jenkins Infrastructure

Jenkins runs natively on an Amazon Linux 2023 EC2 instance.

```text
Instance type: c7i-flex.large
CPU:           2 vCPU
Memory:        4 GiB
Root disk:     30 GiB encrypted gp3
```

Terraform provisions:

```text
EC2 instance
Elastic IP
security group
SSH public key registration
IAM role
instance profile
```

Ansible configures:

```text
Java 21
Jenkins LTS
Docker
Git
AWS CLI
jq
Trivy
Checkov
```

This gives a clear ownership boundary:

```text
Terraform
    -> infrastructure

Ansible
    -> host configuration

Jenkinsfile
    -> deployment workflow
```

---

# Jenkins Network Controls

Inbound:

```text
TCP/22
    administrator public IP /32

TCP/8080
    public
```

Outbound:

```text
TCP/443
    GitHub
    AWS APIs
    ECR
    package/tool repositories

TCP/80
    deployed ALB validation
```

TCP/8080 is public for challenge grading and GitHub webhook delivery.

A production environment should normally place Jenkins behind HTTPS and use a
stronger administrative access model.

---

# Jenkins AWS Authentication

Jenkins uses an EC2 instance profile.

```text
Jenkins
   |
   v
EC2 metadata / temporary STS credentials
   |
   v
ecs-fargate-cicd-challenge-jenkins-role
```

No long-lived AWS access key is stored in Jenkins.

The role is scoped to the deployment operations required by the pipeline:

```text
ECR authentication
ECR image publication
ECS task-definition operations
ECS service deployment
iam:PassRole for the application execution roles
read-only ALB discovery
```

---

# Jenkins Host Configuration with Ansible

The committed configuration is:

```text
ansible/jenkins.yml
```

Example execution:

```bash
ansible-playbook \
  -i "${JENKINS_IP}," \
  -u ec2-user \
  --private-key ~/.ssh/ecs-fargate-cicd-jenkins \
  ansible/jenkins.yml
```

The playbook can be rerun to confirm configuration convergence.

---

# Jenkins CI/CD Pipeline

The pipeline definition is committed as:

```text
Jenkinsfile
```

The Jenkins job uses:

```text
Pipeline script from SCM
```

Pipeline flow:

```text
Checkout
    |
    v
Verify AWS Identity
    |
    v
Checkov IaC Scan
    |
    v
Build Images
    |
    v
Trivy Image Security Gate
    |
    v
Authenticate to ECR
    |
    v
Push Immutable Images
    |
    v
Register Task Definitions
    |
    v
Deploy to ECS
    |
    v
Wait for Stable Services
    |
    v
Validate Live Application
```

The pipeline does not declare deployment success immediately after
`UpdateService`.

It waits for ECS to report both services stable.

It then queries the live ALB and confirms:

```text
GET /      -> HTTP 200
GET /api   -> GUID response
```

---

# Security Gates

## Checkov

Checkov scans the Terraform configuration during the Jenkins pipeline.

It currently runs as a reporting control with:

```text
--soft-fail
```

Findings are reviewed rather than blindly remediated during the challenge.

## Trivy

Trivy scans both built images for:

```text
HIGH
CRITICAL
```

fixable vulnerabilities.

The pipeline uses an exit code that blocks deployment when such findings are
detected.

This control was tested during implementation when an earlier backend image
failed the security gate.

The backend runtime and dependencies were corrected before deployment
continued.

---

# GitHub Integration

The source repository is private.

Jenkins reads it using a fine-grained GitHub personal access token restricted to:

```text
Repository:
ecs-fargate-cicd-pipeline

Permission:
Contents - Read-only
```

The token is stored in Jenkins Credentials and is not committed to Git.

A GitHub webhook triggers the Jenkins pipeline after pushes to the configured
branch.

Webhook endpoint shape:

```text
http://<jenkins-eip>:8080/github-webhook/
```

---

# Local Docker Validation

Docker validation is performed from the repository root.

Build backend:

```bash
docker build \
  -t tc1-backend:local \
  ./backend
```

Build frontend:

```bash
docker build \
  -t tc1-frontend:local \
  ./frontend
```

The detailed local container and path-routing validation procedure is documented
in:

```text
Detailed phase-by-phase replication instructions:
[`docs/Implementation-Guide/`](docs/Implementation-Guide/)
```

---

# Application Validation

Retrieve the ALB hostname:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure output \
  -raw alb_dns_name
```

Frontend:

```bash
curl -i "http://<alb-dns>/"
```

Backend:

```bash
curl -i "http://<alb-dns>/api"
```

Browser result:

```text
SUCCESS: <GUID>
```

---

# Auto Scaling

Both ECS services use target-tracking scaling based on:

```text
ECSServiceAverageCPUUtilization = 50%
```

Capacity limits:

```text
Minimum: 1
Maximum: 4
```

Measured load-test results and scaling evidence are documented in:

[Phase 7: Auto Scaling Validation](docs/Implementation-Guide/phase-07-autoscaling-validation.md)

---

# Repository Structure

```text
.
├── Jenkinsfile
├── README.md
│
├── ansible/
│   └── jenkins.yml
│
├── backend/
│   ├── Dockerfile
│   ├── config.js
│   ├── index.js
│   ├── package.json
│   └── package-lock.json
│
├── frontend/
│   ├── Dockerfile
│   ├── nginx.conf
│   ├── package.json
│   ├── .nvmrc
│   └── src/
│
├── terraform/
│   ├── bootstrap/
│   └── infrastructure/
│
└── docs/
    ├── Implementation-Guide/
    │   ├── README.md
    │   ├── phase-02-containerization-local-validation.md
    │   ├── phase-03-a-bootstrap-env-infrastructure.md
    │   ├── phase-03-b-aws-infrastructure.md
    |   ├── phase-03-c-ecs-fargate-app-autoscaling.md
    │   ├── phase-04-jenkins-infrastructure.md
    │   ├── phase-05-jenkins-cicd.md
    │   ├── phase-06-end-to-end-validation.md
    │   └── phase-07-autoscaling-validation.md
    ├── design-decisions.md
    └── evidence/
```

---

# Documentation

Detailed phase-by-phase replication instructions:

[Implementation Guide](docs/Implementation-Guide/)

System architecture and control-plane boundaries:

[Architecture](docs/architecture.md)

Architecture and engineering decisions:

[Design Decisions](docs/design-decisions.md)

Validation evidence:

[Evidence](docs/evidence/)


---

# Current Production-Like Tradeoffs

The following decisions are intentional for this timed challenge and are
documented rather than presented as ideal production defaults:

### HTTP-only ALB

The application currently uses HTTP/80.

A production deployment should normally terminate TLS at the ALB with an ACM
certificate and redirect HTTP to HTTPS.

### Public Jenkins TCP/8080

Required for external grading and webhook delivery.

A production Jenkins deployment should normally use HTTPS and a more restricted
administrative entry point.

### Single Jenkins controller/build host

The Jenkins EC2 instance is both controller and build host.

It is a CI/CD single point of failure.

Its failure does not stop the already-running ECS application, but it removes
deployment capability until Jenkins is restored.

### Docker-group access

The Jenkins service account belongs to the Docker group so it can build
containers.

This grants significant privilege on the Jenkins host.

A production design should normally use isolated build agents.

### Desired ECS task count of one

The configured scaling range meets the challenge requirement, but the baseline
desired count of one does not provide full workload-level redundancy.

---

# Submission

The submission form should contain:

```text
Jenkins URL
Jenkins grader credentials
Frontend public URL
```

Credentials are intentionally not committed to this repository.

The private repository must be shared with the grader account specified in the
challenge instructions.

---

# Bonus: GitHub Actions GitOps Alternative

A complete GitHub Actions CI/CD alternative is implemented on the `gitops`
branch.

The required Jenkins implementation remains on `main`, while the `gitops`
branch demonstrates an alternative deployment path:

```text
GitHub push to gitops
        |
        v
GitHub Actions
        |
        | OIDC
        v
AWS STS
        |
        v
GitHub Actions deployment role
        |
        +--> Build frontend/backend images
        |
        +--> Push immutable images to ECR
        |
        +--> Register new ECS task-definition revisions
        |
        +--> Deploy frontend/backend services
        |
        +--> Wait for ECS stability
        |
        +--> Validate the live application
```

AWS authentication uses GitHub OIDC and temporary STS credentials rather than
long-lived AWS access keys.

The IAM trust relationship is restricted to the immutable identity of this
repository and the `gitops` branch.

The GitOps IAM configuration is managed separately under:

```text
terraform/gitops-iam/
```

The complete workflow, implementation details, and validation evidence are
available on the `gitops` branch.

---

# Auto Scaling Validation

Both ECS services use target-tracking Application Auto Scaling based on:

# Auto Scaling Validation

Both ECS services use target-tracking Application Auto Scaling based on:

```text
Metric:
ECSServiceAverageCPUUtilization

Target:
50%

Minimum capacity:
1 task

Maximum capacity:
4 tasks
```

## Load-test methodology

The backend scaling policy was validated using a controlled-rate load test
against:

```text
GET /api
```

Earlier unrestricted concurrency tests were intentionally not used as the final
scaling proof.

A high-concurrency test saturated the backend enough to cause Application Load
Balancer health-check timeouts. ECS correctly replaced the unhealthy task, but
that behavior represented ECS health reconciliation rather than horizontal
autoscaling.

The final validation therefore used a controlled request rate so CPU utilization
could remain above the target long enough for the target-tracking policy to
evaluate sustained demand.

Final controlled load:

```text
Target:   backend /api endpoint
Rate:     1,800 requests/second
Duration: 5 minutes
Source:   Jenkins EC2 host
```

Running the load generator inside AWS removed the operator workstation and home
network from the load-generation path.

## Observed scaling behavior

Before load:

```text
Desired: 1
Running: 1
Pending: 0
```

Under sustained CPU pressure, the CloudWatch target-tracking high alarm entered:

```text
ALARM
```

Application Auto Scaling then changed the backend service capacity:

```text
Desired: 2
Running: 1
Pending: 1
```

After the new Fargate task became healthy:

```text
Desired: 2
Running: 2
Pending: 0
```

Application Auto Scaling recorded the scale-out activity as:

```text
Status: Successful
Policy: ecs-fargate-cicd-backend-cpu-50
Cause: target-tracking high CPU alarm entered ALARM
```

CloudWatch alarm history recorded the control-loop transition:

```text
INSUFFICIENT_DATA -> OK
OK                -> ALARM
ALARM             -> OK
```

This proves that the configured scaling range is not merely declarative.
Application Auto Scaling changed ECS desired capacity in response to sustained
CPU utilization.

The validated control path was:

```text
controlled application load
        |
        v
ECS service CPU > 50%
        |
        v
CloudWatch target-tracking alarm
        |
        v
Application Auto Scaling policy
        |
        v
Desired count 1 -> 2
        |
        v
new Fargate task launched
        |
        v
Running count 1 -> 2
```

Evidence:

```text
docs/evidence/screenshots/scaling/
```

