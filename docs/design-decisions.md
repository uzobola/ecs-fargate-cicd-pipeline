

## ADR-001: Pin Node.js 16.20.2 for the supplied frontend

### Context

Running the supplied `react-scripts 4.0.3` frontend with Node.js 24 produced
`ERR_OSSL_EVP_UNSUPPORTED` during the Webpack build process.

### Decision

Pin local development and frontend build operations to Node.js 16.20.2 using
the repository `.nvmrc` file.

### Reason

This matches the application’s tested environment and avoids modifying the
supplied application toolchain during an infrastructure-focused challenge.

### Consequences

- Local and pipeline builds must use the pinned Node version.
- The existing frontend toolchain remains unchanged.
- A later modernization should update the frontend build system and revalidate
  the application under a current Node.js release.



## ADR-002: Use an encrypted and versioned S3 backend with native lock files

### Context

The main infrastructure requires shared Terraform state that can be accessed
from repeatable local and pipeline workflows. Local state would tie the
infrastructure record to one workstation and would not provide coordinated
locking for concurrent Terraform operations.

### Decision

Create a dedicated S3 state bucket through a separate bootstrap configuration.

The backend uses:

- S3 object versioning
- Explicit SSE-S3 encryption
- S3-native lock files
- Bucket-owner-enforced object ownership
- All four S3 Block Public Access controls
- A bucket policy denying requests made without TLS

The bootstrap state is stored under:

```text
bootstrap/terraform.tfstate
```

The main infrastructure state is stored separately under:

```text
infrastructure/terraform.tfstate
```

This separates management of the state backend itself from the application
infrastructure that uses that backend.

### Consequences

- Terraform state is stored remotely rather than being tied to one workstation.
- State versioning provides recovery points for earlier state versions.
- Native S3 lock files coordinate Terraform state operations.
- Public access to the state bucket is blocked.
- Insecure transport is denied.
- Bootstrap and application infrastructure use separate state objects.

## ADR-003: Use immutable source-derived image tags and registry-level ECR scanning

### Context

The frontend and backend images must be traceable to source and protected from
silent tag replacement.

Docker BuildKit publishes the images as OCI image indexes. Each index references
the platform-specific container image and a small provenance/attestation
manifest.

Amazon ECR Basic vulnerability findings are associated with the platform-image
digest rather than the parent OCI index.

### Decision

Application images use the most recent Git commit that changed the application
or container source as the image tag.

For this deployment:

```text
fbfbbe4665da
```

ECR repositories use immutable tags.

Basic vulnerability scanning is configured through an ECR registry-level
`SCAN_ON_PUSH` rule scoped to:

```text
ecs-fargate-cicd-*
```

Terraform manages the registry scanning rule.

### Consequences

- An existing source-derived tag cannot be silently overwritten.
- A Git source revision can be correlated with its published image artifact.
- The ECR digest provides the cryptographic identity of the published content.
- OCI-index tags and platform-image digests are treated as separate artifact
  identities.
- ECR Basic scan findings are queried against the platform-image digest.
- ECR Basic scanning covers the container-image vulnerability scope provided by
  that service; the CI/CD pipeline will use Trivy as a separate image-security
  control.

## ADR-004: Use one NAT Gateway per Availability Zone for private egress

### Context

The application network spans two Availability Zones and places ECS workloads
in private subnets.

A single NAT Gateway could provide outbound internet access for both private
subnets at lower cost, but it would create a cross-AZ dependency.

For example:

```text
Private us-east-1a ─┐
                    ├── NAT us-east-1a
Private us-east-1b ─┘
```

A failure affecting the NAT Gateway or its Availability Zone could remove
private egress from both application zones.

### Decision

Create one public NAT Gateway in each Availability Zone.

Each private subnet uses a dedicated private route table whose default route
points to the NAT Gateway in the same AZ.

```text
Private us-east-1a
        |
        v
Private RT us-east-1a
        |
        v
NAT us-east-1a
```

and:

```text
Private us-east-1b
        |
        v
Private RT us-east-1b
        |
        v
NAT us-east-1b
```

Both public subnets share one public route table since their routing policy is
identical:

```text
0.0.0.0/0 -> Internet Gateway
```

### Architecture qualities

This choice improves:

- failure-domain separation
- AZ independence
- private-egress availability
- fault isolation
- blast-radius reduction

The two private route tables are not redundant copies. They preserve
AZ-specific routing policy so each private subnet uses its local NAT Gateway.

### Alternatives rejected

#### One shared NAT Gateway

Rejected for this implementation since the surviving AZ would depend on a NAT
Gateway located in the failed AZ.

#### Separate public route table per AZ

Rejected since both public subnets require the same Internet Gateway route.
Duplicating the route table would not remove a meaningful failure dependency.

#### VPC endpoints for all AWS service traffic

Not implemented in this challenge.

VPC endpoints could reduce NAT dependence and tighten AWS-service egress, but
would add several endpoint resources, security policies, cost, and additional
validation work outside the immediate challenge requirement.

### Consequences

- two NAT Gateways incur greater hourly cost than one
- each private subnet retains AZ-local outbound routing
- a routing change in one private route table does not automatically alter the
  other private subnet
- the environment should be destroyed promptly after challenge validation to
  avoid unnecessary NAT Gateway charges


## ADR-005: Use one public ALB with path-based routing to isolated application services

### Context

The supplied application contains two services:

```text
React/Nginx frontend
Express backend
```

The frontend uses the relative API path:

```text
/api
```

Publishing the frontend and backend through unrelated public endpoints would
require the browser to know a separate backend address and would introduce a
separate browser origin.

The ECS services also require independent ports and health checks.

### Decision

Use one internet-facing Application Load Balancer spanning both public
subnets.

Create separate target groups:

```text
Frontend
HTTP/3000
health check /
target type ip

Backend
HTTP/8080
health check /health
target type ip
```

Use an HTTP listener on TCP/80.

Route:

```text
/api
/api/*
    ->
backend target group
```

Use the frontend target group as the listener default action.

This produces:

```text
http://<alb-dns>/
        ->
frontend

http://<alb-dns>/api
        ->
backend
```

The browser therefore uses one public origin.

The frontend container does not proxy backend traffic.

### Security boundary

Only the ALB security group accepts public application traffic.

The frontend security group permits TCP/3000 from the ALB security group.

The backend security group permits TCP/8080 from the ALB security group.

No frontend-to-backend application rule is required.

### Architecture qualities

The design supports:

- load distribution
- Layer-7 service routing
- service isolation
- health-based routing
- horizontal-scaling support
- decoupling from individual ECS task addresses
- multi-AZ availability at the load-balancing tier
- reduced direct application attack surface

### High Availability limitation

The ALB spans two Availability Zones and provides a multi-AZ public entry tier.

That does not prove the complete application is highly available.

Application availability later depends on the number, placement, and health of
ECS tasks.

The challenge requires a minimum and desired ECS task count of one, so a
single running task may still create a temporary interruption during task
failure or replacement.

### HTTP tradeoff

The challenge deployment uses HTTP because no managed DNS name or ACM
certificate is part of the current scope.

A production design would normally terminate TLS at the ALB and redirect HTTP
to HTTPS.

This limitation is accepted and documented rather than adding a non-production
certificate workaround.

### Consequences

- clients use one stable ALB endpoint
- ECS task IP changes do not require frontend configuration changes
- frontend and backend health are evaluated independently
- `/api` traffic does not depend on the frontend Nginx container
- ALB listener rules become part of the application routing contract
- TLS remains a documented production improvement