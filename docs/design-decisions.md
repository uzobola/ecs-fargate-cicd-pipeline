

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