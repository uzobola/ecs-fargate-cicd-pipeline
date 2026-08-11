# Security Model

## Purpose

This document describes the security model of the AWS ECS Fargate CI/CD
environment.

The goal is not to claim that this environment represents a complete
production security architecture.

Instead, this document explains:

- what the system is protecting
- which components are trusted
- where trust boundaries exist
- which components are publicly reachable
- how network access is restricted
- how AWS identities and permissions are separated
- how CI/CD credentials are handled
- how container artifacts are protected
- what security controls are enforced during deployment
- which risks remain intentionally accepted for the challenge

This document complements:

```text
docs/architecture.md
docs/design-decisions.md
```

The architecture document explains how the system is constructed.

This document explains how access to that architecture is controlled.

---

# 1. Security Objectives

The security model is designed around several primary objectives.

```text
Protect application tasks from direct internet access

Expose only the required application entry point

Restrict service-to-service network paths

Avoid long-lived AWS credentials in application and CI/CD workloads

Apply least-privilege AWS permissions where practical

Separate frontend and backend execution identities

Prevent mutable container-image replacement

Scan container images before deployment

Protect Terraform state

Restrict administrative access to Jenkins

Limit CI/CD permissions to deployment operations

Maintain traceability between source code and deployed artifacts
```

These objectives define the security boundaries used throughout the
implementation.

---

# 2. Security Domains

The system can be divided into several security domains.

```text
External / Internet
        |
        v
Application Edge
        |
        v
Application Runtime
        |
        v
AWS Managed Services


Developer / Operator
        |
        v
CI/CD Control Plane
        |
        v
AWS Deployment APIs


Developer Workstation
        |
        v
Terraform Control Plane
```

Each domain has a different level of trust and a different set of permissions.

---

# 3. Assets Being Protected

The primary assets in this project are:

### Application workloads

```text
Frontend ECS Fargate tasks
Backend ECS Fargate tasks
```

### Container artifacts

```text
Frontend ECR images
Backend ECR images
```

### Infrastructure state

```text
Terraform remote state
```

### Deployment authority

```text
Jenkins deployment IAM role
GitHub Actions deployment IAM role
Terraform execution role
```

### Source code

```text
Private GitHub repository
```

### CI/CD credentials

```text
GitHub Jenkins credential
AWS temporary role credentials
GitHub Actions OIDC identity
```

### Operational information

```text
CloudWatch application logs
ECS task definitions
deployment configuration
```

Protecting deployment authority is especially important because a principal
that can change an ECS task definition or publish a trusted application image
may indirectly control the application runtime.

---

# 4. Trust Boundaries

A trust boundary is a point where data or control moves between components with
different security assumptions.

The major trust boundaries in this environment are:

```text
Internet
    |
    v
Application Load Balancer
```

```text
Application Load Balancer
    |
    v
Private ECS tasks
```

```text
Jenkins
    |
    v
AWS deployment APIs
```

```text
GitHub Actions
    |
    v
AWS STS / deployment role
```

```text
Developer workstation
    |
    v
Terraform execution role
```

```text
ECS infrastructure
    |
    v
ECR and CloudWatch
```

Every crossing of one of these boundaries should have an explicit reason and
an explicit access control.

---

# 5. Public Attack Surface

The intentionally public components are limited.

## Application Load Balancer

The Application Load Balancer is the public entry point for the application.

It accepts:

```text
TCP/80
Source: 0.0.0.0/0
```

The ALB then routes requests internally:

```text
default /*
    -> frontend target group
    -> TCP/3000

/api
/api/*
    -> backend target group
    -> TCP/8080
```

The application containers themselves are not directly exposed to the
internet.

---

## Jenkins

Jenkins is also publicly reachable:

```text
TCP/8080
Source: 0.0.0.0/0
```

This is an intentional challenge tradeoff required for external access and
GitHub webhook delivery.

Administrative SSH access is more restrictive:

```text
TCP/22
Source: approved administrator IPv4 /32
```

A production environment should normally reduce Jenkins' public exposure and
place it behind a stronger HTTPS and administrative-access boundary.

---

# 6. Network Security Model

The application uses separate security groups for:

```text
Application Load Balancer
Frontend ECS tasks
Backend ECS tasks
Jenkins
```

Security-group references are used where possible instead of broad IP ranges.

---

## 6.1 ALB Security Boundary

The ALB accepts public HTTP:

```text
Internet
    |
    | TCP/80
    v
ALB
```

Its application egress is restricted to:

```text
Frontend security group
TCP/3000
```

and:

```text
Backend security group
TCP/8080
```

The ALB is therefore allowed to communicate only with the application target
ports required by the two services.

---

## 6.2 Frontend Security Boundary

Frontend Fargate tasks:

```text
run in private subnets
do not receive public IP addresses
```

Inbound application traffic is restricted to:

```text
Source:
ALB security group

Port:
TCP/3000
```

The internet cannot directly connect to frontend task port 3000.

---

## 6.3 Backend Security Boundary

Backend Fargate tasks also:

```text
run in private subnets
do not receive public IP addresses
```

Inbound application traffic is restricted to:

```text
Source:
ALB security group

Port:
TCP/8080
```

The internet cannot directly connect to backend task port 8080.

The frontend security group is deliberately **not** granted access to the
backend security group.

The browser sends API requests through the ALB instead:

```text
Browser
    |
    | /api
    v
ALB
    |
    v
Backend target group
    |
    v
Backend ECS task
```

This keeps the ALB as the single application-routing boundary.

---

# 7. Private Workload Model

The frontend and backend ECS services use private subnets across two
Availability Zones.

They are configured with:

```text
assign_public_ip = false
```

Each Fargate task receives its own network interface and private IP through
ECS `awsvpc` networking.

This means a Fargate task is treated as its own network endpoint rather than
sharing the network identity of an EC2 container host.

Outbound access required for AWS services is provided through the NAT Gateway
in the task's Availability Zone.

---

# 8. ECS Identity Model

The project distinguishes between:

```text
ECS execution role
```

and:

```text
application task role
```

These are not the same thing.

The execution role is used by the ECS/Fargate infrastructure for operations
such as:

```text
pulling an image from ECR
publishing container logs
```

The application itself does not need AWS API access.

Therefore:

```text
No application task IAM role is assigned.
```

This reduces the permissions available if application code is compromised.

---

# 9. Frontend Execution Identity

The frontend has its own ECS execution role.

Its permissions are limited to operations required to start and operate the
frontend task.

It can:

```text
obtain an ECR authorization token
pull images from the frontend ECR repository
create frontend CloudWatch log streams
publish frontend log events
```

It cannot use the backend execution role's resource permissions.

---

# 10. Backend Execution Identity

The backend has a separate execution role.

It can:

```text
obtain an ECR authorization token
pull images from the backend ECR repository
create backend CloudWatch log streams
publish backend log events
```

Separating the roles creates an IAM boundary between the two workloads.

For example:

```text
Frontend execution role
    X
    cannot pull backend repository through its scoped repository permission
```

and vice versa.

---

# 11. Jenkins AWS Identity

Jenkins does not store a long-lived AWS access key.

Instead:

```text
Jenkins
    |
    v
EC2 instance profile
    |
    v
temporary AWS credentials
    |
    v
Jenkins IAM role
```

AWS supplies temporary credentials through the EC2 metadata service.

IMDSv2 is required.

This avoids storing static AWS credentials in:

```text
Jenkins environment variables
Jenkins credential entries
configuration files
pipeline source
```

---

# 12. Jenkins Least-Privilege Model

The Jenkins IAM role is a **deployment role**, not an infrastructure
administrator role.

It is allowed to perform the operations required by the deployment pipeline.

These include:

```text
authenticate to ECR
push images to the project repositories
describe/register ECS task definitions
update the two application ECS services
describe those services
discover the Application Load Balancer
pass the two ECS execution roles
```

The role does not receive general permission to modify:

```text
VPC configuration
subnets
route tables
security groups
Application Load Balancer configuration
Terraform remote state
arbitrary IAM roles
unrelated ECS services
unrelated ECR repositories
```

This is an important separation of duties:

```text
Terraform execution role
    -> infrastructure authority

Jenkins role
    -> application deployment authority
```

Compromising Jenkins should therefore not automatically provide the same
permissions as compromising the Terraform administration identity.

---

# 13. `iam:PassRole` Boundary

Task-definition registration requires Jenkins to pass ECS execution roles to
the ECS service.

Unrestricted `iam:PassRole` would be dangerous because it could allow a
deployment system to attach a more privileged IAM role to a workload.

The Jenkins role is therefore restricted to passing only:

```text
frontend ECS execution role
backend ECS execution role
```

and only to:

```text
ecs-tasks.amazonaws.com
```

This prevents Jenkins from passing arbitrary IAM roles to arbitrary AWS
services.

---

# 14. Jenkins Host Security

The Jenkins EC2 instance includes several host-level controls.

### SSH key handling

Terraform receives only the administrator's public SSH key.

The private key is not stored in Terraform state or committed to the
repository.

### Administrative network access

SSH is restricted to:

```text
administrator public IPv4 /32
```

### Instance credentials

AWS credentials are supplied through:

```text
EC2 instance profile
IMDSv2
```

### Metadata protection

IMDSv2 is required and the metadata hop limit is restricted.

### Storage

The Jenkins root EBS volume is:

```text
encrypted
gp3
deleted when the instance is terminated
```

---

# 15. GitHub Repository Security

The source repository is private.

Jenkins reads the repository using a fine-grained GitHub credential with
repository-scoped read access.

The credential is stored in Jenkins Credentials rather than committed to the
repository.

The credential is needed for source checkout, not for AWS authentication.

AWS and GitHub identities are therefore kept separate:

```text
GitHub credential
    -> source repository access

EC2 instance profile
    -> AWS deployment access
```

---

# 16. GitHub Actions GitOps Identity

The optional GitOps deployment path does not use static AWS access keys.

Authentication uses:

```text
GitHub Actions
    |
    v
GitHub OIDC token
    |
    v
AWS STS
    |
    v
GitHub Actions deployment IAM role
```

The role trust policy restricts role assumption to the intended GitHub
repository and `gitops` branch.

The role receives deployment permissions similar in scope to the Jenkins
deployment identity.

This provides short-lived AWS credentials without storing AWS access keys in
GitHub repository secrets.

---

# 17. Container Supply-Chain Security

Container artifacts are stored in separate ECR repositories:

```text
frontend
backend
```

Image tags are immutable.

This means an existing deployment tag cannot later be silently replaced with a
different image.

Pipeline tags incorporate source/build identity.

Conceptually:

```text
Git commit
    |
    v
container build
    |
    v
immutable image tag
    |
    v
ECR
    |
    v
ECS task definition
```

This creates traceability from deployed workload back to the source revision
that produced it.

---

# 18. Container Vulnerability Scanning

The Jenkins pipeline performs container vulnerability scanning with Trivy.

Images are checked for:

```text
HIGH
CRITICAL
```

vulnerabilities according to the configured pipeline policy.

A blocking Trivy result prevents the deployment stage from proceeding.

This creates a security gate between:

```text
container build
```

and:

```text
image publication / deployment
```

The project also configures ECR scanning for project repositories.

---

# 19. Infrastructure Security Scanning

Terraform configuration is scanned with Checkov during the Jenkins pipeline.

The current Checkov stage operates as:

```text
soft-fail
```

This means findings are reported but do not automatically stop deployment.

This is intentionally different from the Trivy container gate.

```text
Checkov
    -> reporting control

Trivy
    -> blocking deployment control
```

The distinction should be understood when evaluating the security posture.

---

# 20. Terraform Authentication Security

Terraform is executed from the engineer workstation through AWS Vault.

The model is:

```text
Engineer source identity
        |
        | MFA
        v
AWS Vault
        |
        | STS AssumeRole
        v
Terraform execution role
        |
        v
Temporary AWS credentials
```

Long-lived credentials are not embedded in Terraform source.

Before executing Terraform, the engineer verifies the active AWS identity with:

```bash
aws-vault exec terraform -- \
  aws sts get-caller-identity
```

This reduces the risk of accidentally executing infrastructure changes with an
unexpected AWS identity.

---

# 21. Terraform State Protection

Terraform state is stored in a dedicated S3 bucket.

Security controls include:

```text
S3 Block Public Access
S3 server-side encryption
S3 Versioning
S3-native state locking
bucket-owner-enforced object ownership
TLS-only access policy
```

Terraform state is treated as sensitive because it may contain infrastructure
identifiers and potentially sensitive resource values.

State files must never be committed to the source repository.

---

# 22. Data Protection

## Data in transit

The challenge application currently uses:

```text
HTTP/80
```

between the external client and Application Load Balancer.

This satisfies the challenge requirement but is an intentional security
tradeoff.

A production deployment should normally use:

```text
HTTPS/443
ACM certificate
HTTP -> HTTPS redirect
```

Internal ALB-to-container traffic is also HTTP in this implementation.

---

## Data at rest

Relevant storage protections include:

```text
encrypted Jenkins EBS volume
encrypted ECR repositories
encrypted Terraform state bucket
```

---

# 23. Logging and Security Visibility

Frontend and backend workloads use separate CloudWatch log groups.

```text
Frontend
    -> frontend log group

Backend
    -> backend log group
```

Separate log groups provide clearer operational and security boundaries.

The configured retention period is intentionally limited for the challenge
environment.

CI/CD systems also provide execution history through Jenkins and GitHub
Actions.

---

# 24. Deployment Safety

Both ECS services use the ECS deployment circuit breaker with rollback enabled.

During deployment:

```text
new task definition
        |
        v
ECS rolling deployment
        |
        v
health/stability evaluation
```

If ECS determines that the new deployment cannot reach a healthy stable state,
the circuit breaker can fail the deployment and roll back to the last completed
deployment.

The Jenkins pipeline also waits for the ECS services to become stable before
performing live application validation.

A failure in the final live validation step does **not** itself invoke an
explicit Jenkins rollback command.

That distinction is important when describing the deployment security and
recovery model.

---

# 25. Security Invariants

A useful way to understand the system is to define conditions that should
remain true.

## Network invariants

```text
Internet cannot directly reach frontend ECS tasks.

Internet cannot directly reach backend ECS tasks.

Frontend ECS tasks cannot directly connect to backend TCP/8080 through a
security-group-granted application path.

Application traffic enters through the ALB.

Only the ALB security group may reach application container ports.
```

## Identity invariants

```text
Application containers do not receive general AWS API credentials.

Frontend and backend use separate execution roles.

Jenkins does not store static AWS access keys.

Jenkins cannot pass arbitrary IAM roles.

GitHub Actions does not require static AWS access keys.

Terraform uses a dedicated execution role.
```

## Artifact invariants

```text
Frontend and backend images are stored separately.

Published image tags are immutable.

Security scanning occurs before Jenkins deployment.

A deployed task definition references a specific image revision.
```

These invariants provide a simple way to review future infrastructure changes.

If a change violates one of them, the security implications should be reviewed.

---

# 26. Compromise Scenarios

Thinking through compromise scenarios is useful for understanding why the
security boundaries exist.

## Scenario: Internet attacker targets the backend

An attacker cannot connect directly to the backend task's private IP from the
internet.

Expected path:

```text
Attacker
    |
    v
ALB
    |
    | /api routing
    v
Backend
```

The ALB remains the application ingress boundary.

---

## Scenario: Frontend container is compromised

The compromised task does not receive an application IAM task role.

Its network security group does not receive a direct backend application rule.

The execution role used by the ECS infrastructure is separately scoped.

This limits, but does not eliminate, the effect of a compromised application
container.

---

## Scenario: Jenkins is compromised

This is a serious security event because Jenkins has deployment authority.

An attacker may potentially:

```text
publish application images
register task-definition revisions
update the two application ECS services
```

However, the Jenkins role is intentionally not an unrestricted AWS
administrator.

It should not automatically grant authority to:

```text
modify the VPC
change Terraform state
administer arbitrary IAM roles
deploy to unrelated ECS services
push to unrelated ECR repositories
```

This demonstrates why least privilege on CI/CD identities matters.

---

## Scenario: GitHub deployment credential is exposed

The Jenkins GitHub credential is scoped to repository source access.

It is not an AWS credential.

Exposure therefore represents a source-control security issue rather than
automatic AWS account administrator access.

The credential should still be revoked immediately.

---

## Scenario: A malicious container image is published

Immutable tags prevent an existing image tag from being silently overwritten.

The deployment workflow also performs Trivy scanning before publication and
deployment.

This does not guarantee that an image is trustworthy, but it adds controls
against both artifact mutation and known vulnerable package deployment.

---

## Scenario: Terraform state is exposed

Terraform state may reveal:

```text
AWS resource identifiers
network topology
resource configuration
potentially sensitive Terraform-managed values
```

For that reason, the state bucket:

```text
blocks public access
requires TLS
encrypts objects
maintains versions
uses state locking
```

Exposure of Terraform state should be treated as a security incident even when
the state does not contain obvious plaintext credentials.

---

# 27. Intentional Challenge Tradeoffs

Some controls are intentionally weaker than a production implementation.

## HTTP application listener

Current:

```text
HTTP/80
```

Production preference:

```text
HTTPS/443
ACM-managed certificate
HTTP redirect to HTTPS
```

---

## Public Jenkins

Current:

```text
Jenkins TCP/8080 publicly reachable
```

This supports challenge grading and webhook access.

A production design should normally use:

```text
HTTPS
restricted administrative access
reverse proxy or load balancer
strong authentication
isolated build agents
```

---

## Jenkins controller also performs builds

The Jenkins controller also operates as the build host.

Docker-group membership provides significant privilege on that EC2 instance.

A stronger production model would isolate builds onto dedicated or ephemeral
agents.

---

## NAT-based AWS service access

Private Fargate tasks access AWS APIs through NAT Gateways.

A more isolated production architecture could evaluate VPC endpoints for
services such as:

```text
ECR API
ECR Docker registry
CloudWatch Logs
S3
```

This could reduce the need for AWS-service traffic to traverse general internet
egress infrastructure.

---

## Desired task count of one

The service baseline satisfies the challenge requirement:

```text
minimum = 1
desired = 1
maximum = 4
```

However, a single baseline task does not provide full workload redundancy.

This is primarily an availability consideration, but availability is part of
the broader security model.

---

# 28. Security Responsibility Summary

```text
Internet-facing application access
    -> Application Load Balancer

Application network isolation
    -> VPC + private subnets + security groups

Task placement and isolation
    -> ECS Fargate

Container execution identity
    -> ECS execution roles

Application AWS API authority
    -> none required

Artifact storage
    -> Amazon ECR

Artifact immutability
    -> ECR immutable tags

Container vulnerability gate
    -> Trivy

Infrastructure security reporting
    -> Checkov

Jenkins AWS authentication
    -> EC2 instance profile

GitHub Actions AWS authentication
    -> OIDC + AWS STS

Infrastructure administration
    -> Terraform execution role

Terraform credential handling
    -> AWS Vault + temporary STS credentials

Terraform state protection
    -> private encrypted versioned S3 backend

Application logs
    -> CloudWatch Logs
```

---

# 29. Learning Summary

The most important security lesson from this architecture is that security is
not provided by one AWS service.

It comes from multiple boundaries working together.

```text
Private subnets
        +
Security groups
        +
IAM roles
        +
Temporary credentials
        +
Artifact immutability
        +
Security scanning
        +
CI/CD permission boundaries
        +
State protection
```

For example, placing a task in a private subnet does not by itself make the
application secure.

The workload is protected because several controls combine:

```text
no public IP
+
private subnet placement
+
security-group restrictions
+
ALB-only ingress
+
limited AWS identity
+
controlled deployment path
```

Likewise, using Jenkins does not inherently provide secure CI/CD.

The security comes from limiting what Jenkins can do:

```text
instance-profile authentication
+
temporary AWS credentials
+
project-scoped ECR permissions
+
service-scoped ECS permissions
+
restricted iam:PassRole
+
container vulnerability scanning
```

The architecture therefore follows a defense-in-depth approach:

```text
A failure of one control should not automatically provide unrestricted access
to the entire environment.
```