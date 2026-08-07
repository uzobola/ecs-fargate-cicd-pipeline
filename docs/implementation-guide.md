
# Implementation Guide

## Phase 2: Containerization and Local Integration Validation

### Purpose

This phase packages the supplied React frontend and Express backend as separate
container images, verifies each container independently, then tests both through
a temporary local router that reproduces the planned AWS Application Load
Balancer path rules.

The temporary router is used only for local validation. It is not part of the
deployed AWS architecture.

### Acceptance criteria

Phase 2 passes when all of the following are proven:

- The backend image builds from its committed dependency lock file.
- The backend starts successfully under a non-root user.
- `GET /health` returns HTTP 200 with `{"status":"ok"}`.
- `GET /api` returns HTTP 200 with a GUID.
- The configured CORS origin appears in the backend response.
- The frontend image builds successfully.
- The final frontend image runs Nginx rather than Node.js.
- Nginx runs under a non-root user.
- `/` returns the compiled React application.
- Unknown frontend routes return `index.html`.
- A browser request through the local router displays `SUCCESS: <guid>`.

---

## 2.1 Prerequisites

Note: Run all commands from the repository root:

Confirm Docker is available:

```bash
# Display both the Docker client and Docker engine versions.
docker version
```

Expected result:

```text
Client:
...

Server:
...
```

Confirm the Docker engine is responding:

```bash
# This must complete without a permission or connection error.
docker ps
```

For a Windows and WSL workstation, Docker Desktop must be running and WSL
integration must be enabled for the Linux distribution containing this
repository.

---

## 2.2 Build the backend image

The backend image uses:

- Node.js 24 on Alpine Linux
- Production-only npm dependencies
- The committed `package-lock.json`
- The built-in non-root `node` account
- Port `8080`

Build the image:

```bash
# --pull checks for the current version of the selected base-image tag.
# --no-cache proves the image can build without previously cached layers.
# -t assigns a local name and tag to the completed image.
# ./backend sets the Docker build context.
docker build \
  --pull \
  --no-cache \
  -t tc1-backend:phase2 \
  ./backend
```

Expected final output includes:

```text
RUN npm ci --omit=dev
COPY --chown=node:node index.js config.js ./
exporting to image
naming to docker.io/library/tc1-backend:phase2
```

Confirm that the image exists locally:

```bash
docker image ls tc1-backend:phase2
```

Expected result:

```text
REPOSITORY      TAG       IMAGE ID       CREATED
tc1-backend     phase2    <image-id>     <time>
```

This step creates a local image only. It does not push the image to Docker Hub
or Amazon ECR.

---

## 2.3 Create the local integration network

Create one user-defined Docker network for the frontend, backend, and temporary
router:

```bash
# Reuse the network when it already exists.
docker network inspect tc1-net >/dev/null 2>&1 \
  || docker network create tc1-net
```

Confirm the network exists:

```bash
docker network ls --filter name=tc1-net
```

A user-defined network permits container-name DNS resolution. The router can
reach the backend through `tc1-backend:8080` and the frontend through
`tc1-frontend:3000`.

---

## 2.4 Run the backend container

Remove any earlier test container:

```bash
# Ignore the error when no earlier container exists.
docker rm -f tc1-backend 2>/dev/null || true
```

Start the backend:

```bash
# -d runs the container in the background.
# --name assigns a stable container name.
# --network places the container on the shared test network.
# -p publishes host port 8080 to container port 8080.
# CORS_ORIGIN defines the browser origin permitted by the CORS response.
docker run -d \
  --name tc1-backend \
  --network tc1-net \
  -p 8080:8080 \
  -e CORS_ORIGIN=http://localhost:8088 \
  tc1-backend:phase2
```

Docker returns a container ID when creation succeeds.

Confirm that the container remains running:

```bash
docker ps --filter name=tc1-backend
```

Expected result includes:

```text
STATUS
Up ...

PORTS
0.0.0.0:8080->8080/tcp
```

Inspect startup logs:

```bash
docker logs tc1-backend
```

Expected output:

```text
Backend started on 8080. ctrl+c to exit
```

No exception or crash stack should appear.

---

## 2.5 Verify the backend

### Health endpoint

```bash
curl -i http://localhost:8080/health
```

Expected result:

```text
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8
```

Expected body:

```json
{"status":"ok"}
```

This endpoint will later serve as the Application Load Balancer target-group
health-check path.

### Application endpoint

```bash
curl -i http://localhost:8080/api
```

Expected result:

```text
HTTP/1.1 200 OK
```

Expected body shape:

```json
{"id":"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"}
```

The GUID value changes when the backend process is recreated.

### CORS configuration

```bash
curl -i \
  -H "Origin: http://localhost:8088" \
  http://localhost:8080/api
```

Expected response header:

```text
Access-Control-Allow-Origin: http://localhost:8088
```

This proves that the runtime environment variable reached the Express
application.

CORS does not prevent direct requests made through tools such as `curl`.
Browsers enforce whether JavaScript from another origin may read the response.

### Negative CORS verification

```bash
curl -i \
  -H "Origin: https://untrusted.example" \
  http://localhost:8080/api
```

The response must not contain:

```text
Access-Control-Allow-Origin: https://untrusted.example
```

The current application returns the configured origin:

```text
Access-Control-Allow-Origin: http://localhost:8088
```

A browser page running from the untrusted origin cannot read that response.

### Non-root runtime verification

Inspect the configured runtime user:

```bash
docker inspect \
  --format 'Configured user: {{.Config.User}}' \
  tc1-backend
```

Expected result:

```text
Configured user: node
```

Inspect the identity inside the running container:

```bash
docker exec tc1-backend id
```

Expected result:

```text
uid=1000(node) gid=1000(node) groups=1000(node)
```

Inspect the live process:

```bash
docker top tc1-backend -eo user,pid,comm,args
```

The Node process must not run under UID `0` or the `root` account.

---

## 2.6 Build the frontend image

The frontend uses a multi-stage build:

1. Node.js 16.20.2 compiles the supplied React application.
2. The compiled static files are copied into an unprivileged Nginx image.
3. Node.js is absent from the final frontend runtime image.

Build the image:

```bash
docker build \
  --pull \
  --no-cache \
  -t tc1-frontend:phase2 \
  ./frontend
```

Expected final output includes:

```text
FROM docker.io/library/node:16.20.2-alpine
RUN npm ci --legacy-peer-deps
RUN npm run build
COPY --from=build /app/build /usr/share/nginx/html
FROM nginxinc/nginx-unprivileged:alpine
exporting to image
```

Confirm that the image exists:

```bash
docker image ls tc1-frontend:phase2
```

Expected result:

```text
REPOSITORY       TAG       IMAGE ID       CREATED
tc1-frontend     phase2    <image-id>     <time>
```

---

## 2.7 Run the frontend container

Remove any earlier test container:

```bash
docker rm -f tc1-frontend 2>/dev/null || true
```

Start the frontend:

```bash
# Port 3000 is used by the unprivileged Nginx server in this image.
docker run -d \
  --name tc1-frontend \
  --network tc1-net \
  -p 3000:3000 \
  tc1-frontend:phase2
```

Confirm that the container remains running:

```bash
docker ps --filter name=tc1-frontend
```

Expected result includes:

```text
STATUS
Up ...

PORTS
0.0.0.0:3000->3000/tcp
```

Inspect the startup logs:

```bash
docker logs tc1-frontend
```

Expected output includes:

```text
Configuration complete; ready for start up
start worker processes
```

The entrypoint may report that it cannot modify the read-only
`default.conf`. This is expected when the supplied configuration is mounted or
copied as an immutable file. Nginx must still start and remain running.

---

## 2.8 Verify the frontend

### Root route

```bash
curl -i http://localhost:3000/
```

Expected result:

```text
HTTP/1.1 200 OK
Content-Type: text/html
```

The response body should contain the compiled React HTML.

### SPA fallback

```bash
curl -i http://localhost:3000/test-route
```

Expected result:

```text
HTTP/1.1 200 OK
Content-Type: text/html
```

The response should return the same React `index.html` document. This proves the
Nginx rule below is working:

```nginx
try_files $uri /index.html;
```

### Non-root runtime verification

Inspect the configured user:

```bash
docker inspect \
  --format 'Configured user: {{.Config.User}}' \
  tc1-frontend
```

Expected result:

```text
Configured user: 101
```

Inspect the identity inside the container:

```bash
docker exec tc1-frontend id
```

Expected result:

```text
uid=101(nginx) gid=101(nginx)
```

Inspect the live Nginx processes:

```bash
docker top tc1-frontend -eo user,pid,comm,args
```

The Nginx master and worker processes must not run under UID `0`.

Some host systems display another username for UID `101`. The numeric UID is
the authoritative value. Inside this container, UID `101` is the Nginx account.

---

## 2.9 Confirm both containers are on the shared network

```bash
docker network inspect tc1-net \
  --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}'
```

Expected names:

```text
tc1-backend
tc1-frontend
```

If a container is missing, connect it:

```bash
docker network connect tc1-net tc1-backend
docker network connect tc1-net tc1-frontend
```

Docker may report that the endpoint already exists when the container is
already connected.

---

## 2.10 Create the temporary local router

The production frontend bundle calls the relative path:

```text
/api
```

A browser opened directly at `http://localhost:3000` sends that request back to
the frontend Nginx container. The planned AWS Application Load Balancer will
route `/api` to the backend service.

The temporary router below reproduces that behavior locally:

```text
/       -> frontend container
/api    -> backend container
```

Create the temporary Nginx server configuration:

```bash
cat > /tmp/tc1-router.conf <<'EOF'
server {
    listen 8088;
    server_name _;

    # Forward API requests to the Express backend.
    location /api {
        proxy_pass http://tc1-backend:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # Send every other request to the React frontend.
    location / {
        proxy_pass http://tc1-frontend:3000;
        proxy_set_header Host $host;
    }
}
EOF
```

This file is created under `/tmp` and is not committed to the repository.

---

## 2.11 Run the temporary router

Remove an earlier router container:

```bash
docker rm -f tc1-router 2>/dev/null || true
```

Start the router:

```bash
# The temporary file replaces only the default server block.
# The image's main nginx.conf remains unchanged.
# :ro mounts the server configuration as read-only.
docker run -d \
  --name tc1-router \
  --network tc1-net \
  -p 8088:8088 \
  -v /tmp/tc1-router.conf:/etc/nginx/conf.d/default.conf:ro \
  nginxinc/nginx-unprivileged:alpine
```

Confirm that the router remains running:

```bash
docker ps --filter name=tc1-router
```

Expected result includes:

```text
STATUS
Up ...

PORTS
0.0.0.0:8088->8088/tcp
```

Inspect the router logs:

```bash
docker logs tc1-router
```

Expected output includes:

```text
Configuration complete; ready for start up
start worker processes
```

---

## 2.12 Verify local path routing

### Backend route through the router

```bash
curl -i http://localhost:8088/api
```

Expected result:

```text
HTTP/1.1 200 OK
Content-Type: application/json
Access-Control-Allow-Origin: http://localhost:8088
```

Expected body:

```json
{"id":"<guid>"}
```

This proves that `/api` was sent to the backend container.

### Frontend route through the router

```bash
curl -sS -o /dev/null \
  -w '/ -> %{http_code} %{content_type}\n' \
  http://localhost:8088/
```

Expected result:

```text
/ -> 200 text/html
```

### SPA route through the router

```bash
curl -sS -o /dev/null \
  -w '/test-route -> %{http_code} %{content_type}\n' \
  http://localhost:8088/test-route
```

Expected result:

```text
/test-route -> 200 text/html
```

This proves that non-API traffic reaches the frontend and retains the React SPA
fallback.

---

## 2.13 Verify the complete browser flow

Open:

```text
http://localhost:8088
```

Expected page content:

```text
SUCCESS: <guid>
```

Then inspect recent backend logs:

```bash
docker logs tc1-backend --since 2m
```

Expected output includes a recent request:

```text
GET /api
```

Together, these results prove the complete request path:

```text
Browser
-> temporary router
-> React frontend
-> relative /api request
-> temporary router path rule
-> Express backend
-> GUID response
-> React SUCCESS message
```

Capture:

1. A browser screenshot showing `SUCCESS: <guid>`.
2. Backend logs showing the corresponding `GET /api`.
3. The non-root identity output from both containers.
4. The route-validation output from port `8088`.


---

## 2.14 Troubleshooting

### Docker command unavailable in WSL

Symptom:

```text
The command 'docker' could not be found in this WSL 2 distro
```

Correction:

1. Start Docker Desktop.
2. Enable the WSL 2 engine.
3. Enable integration for the active WSL distribution.
4. Run `wsl --shutdown` from Windows PowerShell.
5. Reopen WSL.
6. Confirm that `docker version` displays both Client and Server sections.

### Docker socket permission denied

Symptom:

```text
permission denied while trying to connect to the Docker API
```

Temporary method:

```bash
sudo docker ps
```

Local development method:

```bash
sudo usermod -aG docker "$USER"
```

Close the WSL session, run `wsl --shutdown` from Windows PowerShell, then reopen
WSL.

Confirm membership:

```bash
groups
docker ps
```

The Docker group grants control equivalent to root through the Docker daemon.
Use it only as a conscious workstation decision.

### Router exits with `/run/nginx.pid` permission denied

Symptom:

```text
open() "/run/nginx.pid" failed (13: Permission denied)
```

Cause:

The temporary configuration replaced the image's full
`/etc/nginx/nginx.conf`. That removed settings supplied by the unprivileged
Nginx image.

Incorrect mount:

```bash
-v /tmp/tc1-router.conf:/etc/nginx/nginx.conf:ro
```

Correct mount:

```bash
-v /tmp/tc1-router.conf:/etc/nginx/conf.d/default.conf:ro
```

Only the server block should be replaced. The image's main Nginx configuration
must remain intact.

### Frontend works but displays a fetch or JSON error on port 3000

Opening the frontend directly at:

```text
http://localhost:3000
```

causes the relative `/api` request to return to the frontend container.

Use:

```text
http://localhost:8088
```

for the integrated local test. Port `8088` supplies the same path-routing role
planned for the AWS Application Load Balancer.

### Container exists but is not running after a WSL restart

Check all containers:

```bash
docker ps -a
```

Start the existing container:

```bash
docker start tc1-backend
docker start tc1-frontend
docker start tc2-router
```

Confirm the state:

```bash
docker ps
```

Local containers were created without a restart policy. ECS will manage task
replacement in AWS.

---

## 2.15 Cleanup

Remove the temporary router:

```bash
docker rm -f tc1-router
rm -f /tmp/tc1-router.conf
```

Remove the frontend and backend containers:

```bash
docker rm -f tc1-frontend tc1-backend
```

Remove the local network:

```bash
docker network rm tc1-net
```

Optional local image cleanup:

```bash
docker image rm tc1-frontend:phase2
docker image rm tc1-backend:phase2
```

Do not remove the images when they are still needed for later local testing.

---

## Phase 2 result

Phase 2 demonstrated that:

- The supplied backend runs successfully in Node.js 24.
- The backend process runs as a non-root user.
- The legacy frontend builds under its pinned Node.js version.
- Node.js 16 is absent from the final frontend runtime image.
- The frontend runs under unprivileged Nginx.
- The frontend and backend work through one browser origin.
- Relative `/api` routing is compatible with the planned ALB architecture.




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
mfa_serial     = arn:aws:iam::<account-id>:mfa/grc-engineer01
region         = us-east-1
```

The authentication path is:

```text
grc-engineer01
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
arn:aws:iam::<account-id>:user/grc-engineer01
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
docs/implementation-guide.md
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
  docs/implementation-guide.md \
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
User arn:aws:iam::<account-id>:user/grc-engineer01
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