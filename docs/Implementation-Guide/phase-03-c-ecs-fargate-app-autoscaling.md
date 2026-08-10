# Phase 3E: ECS Fargate Services and Application Auto Scaling

## Purpose

This phase deploys the frontend and backend application workloads to Amazon ECS
using AWS Fargate.

It connects the container artifacts created in Phase 3B to the networking,
security groups, target groups, and Application Load Balancer created in Phases
3C and 3D.

The completed application path becomes:

```text
Internet
   |
   v
Application Load Balancer
   |
   +------ :3000 ------> Frontend target group
   |                         |
   |                         v
   |                  Frontend Fargate service
   |
   +------ :8080 ------> Backend target group
                             |
                             v
                      Backend Fargate service
```

Both services run in private subnets without public IPv4 addresses.

Application Auto Scaling manages runtime capacity between one and four tasks per
service using average ECS service CPU utilization.

---

## 3E.1 Scope

This phase creates the ECS application runtime:

```text
ECS cluster

Frontend:
CloudWatch log group
ECS task execution IAM role
Execution IAM policy
Task definition
ECS service
Application Auto Scaling target
CPU target-tracking policy

Backend:
CloudWatch log group
ECS task execution IAM role
Execution IAM policy
Task definition
ECS service
Application Auto Scaling target
CPU target-tracking policy
```

The Terraform implementation is stored in:

```text
terraform/infrastructure/ecs.tf
```

The required runtime configuration is:

```text
Launch type:       FARGATE
Network mode:      awsvpc
CPU:               512 units / 0.5 vCPU
Memory:            1024 MiB / 1 GiB
Desired capacity:  1
Minimum capacity:  1
Maximum capacity:  4
CPU target:        50%
```

---

## 3E.2 Create the ECS cluster

Terraform creates:

```hcl
resource "aws_ecs_cluster" "application" {
  name = "${var.project_name}-cluster"
}
```

The resulting cluster name is:

```text
ecs-fargate-cicd-cluster
```

Fargate supplies the workload compute capacity.

No EC2 container hosts are provisioned for the application.

---

## 3E.3 Create separate CloudWatch log groups

Frontend and backend logs use independent CloudWatch log groups:

```text
/ecs/ecs-fargate-cicd/frontend
/ecs/ecs-fargate-cicd/backend
```

Each log group retains logs for:

```text
7 days
```

Separating the log groups preserves independent operational and IAM boundaries
for the two services.

---

## 3E.4 Create ECS task execution identities

Frontend and backend use separate ECS task execution IAM roles.

The trust relationship permits:

```text
ecs-tasks.amazonaws.com
```

to call:

```text
sts:AssumeRole
```

The execution roles are infrastructure identities used by ECS/Fargate.

They allow the platform to:

```text
authenticate to ECR
pull the service's container image
create CloudWatch log streams
write container logs
```

The frontend execution role can pull only from the frontend ECR repository.

The backend execution role can pull only from the backend ECR repository.

Log permissions are similarly restricted to the corresponding service log
group.

`ecr:GetAuthorizationToken` requires:

```text
Resource = "*"
```

but image-pull permissions are repository-scoped.

---

## 3E.5 Do not create an application task role

No application task role is assigned.

The frontend and backend application code do not call AWS APIs.

The identity boundary is therefore:

```text
ECS/Fargate infrastructure
        |
        v
execution role
        |
        +--> pull image
        +--> publish logs

application container
        |
        v
no AWS task role
```

This avoids granting AWS API permissions that the application does not require.

---

## 3E.6 Create the frontend task definition

The frontend task definition uses:

```text
Family:          ecs-fargate-cicd-frontend
Compatibility:   FARGATE
Network mode:    awsvpc
CPU:             512
Memory:          1024
OS:              Linux
Architecture:    x86_64
Container port:  3000
```

The baseline image is:

```text
<frontend-ecr-repository>:<app_image_tag>
```

The initial image tag comes from the immutable application-source tag published
during Phase 3B.

Container logs use:

```text
awslogs
```

with the frontend CloudWatch log group.

---

## 3E.7 Create the backend task definition

The backend task definition uses:

```text
Family:          ecs-fargate-cicd-backend
Compatibility:   FARGATE
Network mode:    awsvpc
CPU:             512
Memory:          1024
OS:              Linux
Architecture:    x86_64
Container port:  8080
```

The backend receives:

```text
CORS_ORIGIN=http://<application-alb-dns>
```

from the Terraform-created ALB hostname.

Container logs use the backend CloudWatch log group.

---

## 3E.8 Create the frontend ECS service

The frontend service starts with:

```text
Desired count: 1
Launch type:   FARGATE
```

Deployment configuration:

```text
Minimum healthy percent: 100
Maximum percent:         200
Health grace period:     60 seconds
```

The service enables the ECS deployment circuit breaker with automatic rollback.

Networking uses both private subnets:

```text
private us-east-1a
private us-east-1b
```

with:

```text
assign_public_ip = false
```

The service receives only the frontend security group.

It registers frontend tasks with:

```text
ecs-fargate-cicd-frontend-tg
```

on:

```text
TCP/3000
```

---

## 3E.9 Create the backend ECS service

The backend follows the same Fargate deployment model.

It runs in both private subnets with:

```text
assign_public_ip = false
```

and receives only the backend security group.

It registers tasks with:

```text
ecs-fargate-cicd-backend-tg
```

on:

```text
TCP/8080
```

The backend service depends on the `/api` ALB routing rule so the application
routing contract exists before the workload is deployed.

---

## 3E.10 Define deployment ownership

Two runtime fields intentionally have owners other than Terraform:

```text
desired_count
task_definition
```

The ECS services therefore contain:

```hcl
lifecycle {
  ignore_changes = [
    desired_count,
    task_definition
  ]
}
```

The ownership model is:

```text
Terraform
    |
    +--> ECS cluster
    +--> service infrastructure
    +--> baseline task definitions
    +--> networking
    +--> IAM
    +--> Auto Scaling configuration

Application Auto Scaling
    |
    +--> runtime desired_count

Jenkins / CI/CD
    |
    +--> new image versions
    +--> new task-definition revisions
    +--> deployed task_definition
```

Without this lifecycle boundary, a later Terraform operation could incorrectly
attempt to revert a valid scaling event or CI/CD deployment.

---

## 3E.11 Configure Application Auto Scaling

Both ECS services receive scalable targets.

Frontend:

```text
Minimum capacity: 1
Maximum capacity: 4
```

Backend:

```text
Minimum capacity: 1
Maximum capacity: 4
```

The scalable dimension is:

```text
ecs:service:DesiredCount
```

The service namespace is:

```text
ecs
```

---

## 3E.12 Configure CPU target tracking

Both services use:

```text
Policy type:
TargetTrackingScaling

Metric:
ECSServiceAverageCPUUtilization

Target:
50%

Scale-out cooldown:
60 seconds

Scale-in cooldown:
60 seconds
```

Application Auto Scaling can therefore increase or decrease ECS desired
capacity within the configured 1-4 task range.

Phase 7 performs the controlled load test that proves this control loop changes
runtime desired capacity.

---

## 3E.13 Add ECS outputs

Terraform exposes:

```text
ecs_cluster_name
ecs_service_names
ecs_task_definition_families
cloudwatch_log_groups
```

These outputs provide stable identifiers for validation and later CI/CD
operations.

Jenkins does not need to rediscover the infrastructure model manually.

---

## 3E.14 Format and validate

Run:

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

---

## 3E.15 Create and review the ECS plan

Create a saved plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan \
  -out=ecs-fargate.tfplan
```

Review the ECS-specific configuration:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure show \
  -no-color \
  ecs-fargate.tfplan \
| grep -E \
'(^  # |FARGATE|awsvpc|cpu[[:space:]]*=|memory[[:space:]]*=|desired_count|assign_public_ip|containerPort|execution_role_arn|target_value|min_capacity|max_capacity|ECSServiceAverageCPUUtilization|Plan:)'
```

Confirm:

```text
FARGATE
awsvpc

CPU    = 512
Memory = 1024

Desired = 1

assign_public_ip = false

Frontend port = 3000
Backend port  = 8080

Minimum capacity = 1
Maximum capacity = 4
CPU target       = 50
```

Review the complete plan before applying.

---

## 3E.16 Apply the ECS runtime

Apply the reviewed saved plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure apply \
  ecs-fargate.tfplan
```

Fargate task startup and target-group health checks may take several minutes.

---

## 3E.17 Verify the ECS cluster

Run:

```bash
aws-vault exec terraform -- \
  aws ecs describe-clusters \
  --clusters ecs-fargate-cicd-cluster \
  --query 'clusters[0].{
    Cluster:clusterName,
    Status:status,
    RunningTasks:runningTasksCount,
    PendingTasks:pendingTasksCount,
    ActiveServices:activeServicesCount
  }'
```

Required:

```text
Cluster = ecs-fargate-cicd-cluster
Status  = ACTIVE
```

---

## 3E.18 Verify both ECS services

Run:

```bash
aws-vault exec terraform -- \
  aws ecs describe-services \
  --cluster ecs-fargate-cicd-cluster \
  --services \
    ecs-fargate-cicd-frontend \
    ecs-fargate-cicd-backend \
  --query 'services[].{
    Service:serviceName,
    Status:status,
    Desired:desiredCount,
    Running:runningCount,
    Pending:pendingCount,
    LaunchType:launchType,
    TaskDefinition:taskDefinition,
    Network:networkConfiguration
  }'
```

At baseline steady state, both services should report:

```text
Status     = ACTIVE
Desired    = 1
Running    = 1
Pending    = 0
LaunchType = FARGATE
```

The service network configuration must show:

```text
assignPublicIp = DISABLED
```

---

## 3E.19 Verify task-definition resources

Inspect the frontend:

```bash
aws-vault exec terraform -- \
  aws ecs describe-task-definition \
  --task-definition ecs-fargate-cicd-frontend \
  --query 'taskDefinition.{
    Family:family,
    Revision:revision,
    CPU:cpu,
    Memory:memory,
    NetworkMode:networkMode,
    Compatibility:requiresCompatibilities,
    ExecutionRole:executionRoleArn,
    TaskRole:taskRoleArn,
    Runtime:runtimePlatform,
    Container:containerDefinitions[0]
  }'
```

Inspect the backend:

```bash
aws-vault exec terraform -- \
  aws ecs describe-task-definition \
  --task-definition ecs-fargate-cicd-backend \
  --query 'taskDefinition.{
    Family:family,
    Revision:revision,
    CPU:cpu,
    Memory:memory,
    NetworkMode:networkMode,
    Compatibility:requiresCompatibilities,
    ExecutionRole:executionRoleArn,
    TaskRole:taskRoleArn,
    Runtime:runtimePlatform,
    Container:containerDefinitions[0]
  }'
```

Confirm for both:

```text
CPU         = 512
Memory      = 1024
NetworkMode = awsvpc
Compatibility contains FARGATE
Runtime OS  = LINUX
Architecture = X86_64
ExecutionRole = populated
TaskRole      = null
```

---

## 3E.20 Verify target health

Retrieve the target-group ARNs using the outputs established in Phase 3D.

Check the frontend:

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-target-health \
  --target-group-arn "$FRONTEND_TG"
```

Check the backend:

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-target-health \
  --target-group-arn "$BACKEND_TG"
```

The registered application targets must report:

```text
healthy
```

The target groups that were intentionally empty at the end of Phase 3D now
contain the ECS workloads.

---

## 3E.21 Verify Application Auto Scaling

Inspect the scalable targets:

```bash
aws-vault exec terraform -- \
  aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs \
  --query 'ScalableTargets[].{
    Resource:ResourceId,
    Minimum:MinCapacity,
    Maximum:MaxCapacity,
    Dimension:ScalableDimension
  }'
```

For both project services, confirm:

```text
Minimum = 1
Maximum = 4
Dimension = ecs:service:DesiredCount
```

Inspect target-tracking policies:

```bash
aws-vault exec terraform -- \
  aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs \
  --query 'ScalingPolicies[].{
    Name:PolicyName,
    Type:PolicyType,
    Resource:ResourceId,
    Target:TargetTrackingScalingPolicyConfiguration.TargetValue,
    Metric:TargetTrackingScalingPolicyConfiguration.PredefinedMetricSpecification.PredefinedMetricType
  }'
```

Required project policies:

```text
ecs-fargate-cicd-frontend-cpu-50
ecs-fargate-cicd-backend-cpu-50
```

with:

```text
Type   = TargetTrackingScaling
Target = 50
Metric = ECSServiceAverageCPUUtilization
```

---

## 3E.22 Validate the deployed application

Retrieve the ALB hostname:

```bash
ALB_DNS=$(
  aws-vault exec terraform -- \
    terraform -chdir=terraform/infrastructure output \
    -raw alb_dns_name
)
```

Frontend:

```bash
curl -i "http://$ALB_DNS/"
```

Required:

```text
HTTP 200
```

Backend routing:

```bash
curl -i "http://$ALB_DNS/api"
```

Required response shape:

```json
{"id":"<guid>"}
```

Opening the ALB endpoint in a browser must display:

```text
SUCCESS: <GUID>
```

This closes the application-runtime path:

```text
browser
   |
   v
ALB
   |
   +--> frontend Fargate task
   |
   +--> backend Fargate task
```

---

## 3E.23 Verify Terraform ownership and idempotency

Run:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan
```

Required:

```text
No changes. Your infrastructure matches the configuration.
```

Later Auto Scaling changes to `desired_count` and CI/CD changes to
`task_definition` must not create Terraform drift because those attributes are
intentionally owned by other control planes.

---

## 3E.24 Phase acceptance criteria

Phase 3E passes when:

- the ECS cluster is active
- frontend and backend task definitions use Fargate
- both task definitions use `awsvpc`
- each task uses 512 CPU units and 1024 MiB memory
- runtime architecture is Linux/x86_64
- frontend and backend use separate execution IAM roles
- execution-role image access is repository-scoped
- application containers receive no task IAM role
- frontend listens on TCP/3000
- backend listens on TCP/8080
- the backend receives the ALB CORS origin
- frontend and backend logs use separate CloudWatch log groups
- both services run in private subnets
- neither service assigns public IP addresses
- frontend tasks register with the frontend target group
- backend tasks register with the backend target group
- the deployment circuit breaker and rollback are enabled
- baseline desired capacity is one
- Application Auto Scaling allows one to four tasks
- both services use a 50% average CPU target
- target groups report healthy application targets
- `/` returns HTTP 200
- `/api` returns a GUID
- Terraform ignores runtime `desired_count` and deployed `task_definition`
- a final Terraform plan reports no infrastructure changes

---

## Phase 3E result

Phase 3E completes the AWS application runtime:

```text
Immutable ECR images
        |
        v
Fargate task definitions
        |
        +--> separate execution identities
        +--> CloudWatch logging
        +--> no application AWS permissions
        |
        v
Frontend + Backend ECS services
        |
        +--> private subnets
        +--> no public IPs
        +--> ALB target groups
        +--> health-based routing
        +--> deployment rollback
        |
        v
Application Auto Scaling
        |
        +--> minimum 1
        +--> maximum 4
        +--> 50% CPU target tracking
```

The infrastructure runtime is now ready for the Jenkins deployment control plane
introduced in Phase 4.