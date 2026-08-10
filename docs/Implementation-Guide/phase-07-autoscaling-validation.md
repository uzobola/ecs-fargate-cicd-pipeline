# Phase 7: Application Auto Scaling Validation

## 7.1 Purpose

Validate that the ECS target-tracking configuration can change service capacity
in response to sustained application demand.

The backend policy is configured with:

```text
Metric: ECSServiceAverageCPUUtilization
Target: 50%
Minimum: 1
Maximum: 4
Scale-out cooldown: 60 seconds
Scale-in cooldown: 60 seconds
```

AWS created a target-tracking high alarm with:

```text
Threshold: > 50%
Period: 60 seconds
Evaluation periods: 3
```

The test therefore required sustained CPU utilization above 50%, rather than a
brief CPU spike.

---

## 7.2 Establish the baseline

```bash
aws-vault exec terraform -- \
  aws ecs describe-services \
  --cluster ecs-fargate-cicd-cluster \
  --services ecs-fargate-cicd-backend \
  --query 'services[0].{
    Desired:desiredCount,
    Running:runningCount,
    Pending:pendingCount
  }' \
  --output table
```

Expected baseline:

```text
Desired: 1
Running: 1
Pending: 0
```

---

## 7.3 Load-test calibration

Initial workstation-generated load was insufficient to reach the 50% service
CPU target consistently.

A later unrestricted high-concurrency test generated substantial request volume
but saturated the backend enough for the ALB health check to time out.

ECS events showed:

```text
target unhealthy: Request timed out
ECS started replacement task
ECS stopped unhealthy task
```

This was not counted as autoscaling evidence.

It demonstrated a separate ECS resilience mechanism:

```text
failed health check
        |
        v
ECS desired-state reconciliation
        |
        v
unhealthy task replacement
```

The final test used a controlled request rate instead.

---

## 7.4 Generate controlled backend load

Run the test from the Jenkins EC2 host so the workstation and external network
are not part of the load-generation path.

Resolve the ALB hostname:

```bash
ALB_DNS=$(
  aws elbv2 describe-load-balancers \
    --names ecs-fargate-cicd-alb \
    --query 'LoadBalancers[0].DNSName' \
    --output text
)
```

Verify the backend:

```bash
curl -s "http://$ALB_DNS/api"
```

Run the controlled load:

```bash
echo "GET http://$ALB_DNS/api" \
| docker run --rm -i jauderho/vegeta:latest \
    attack \
    -rate=1800/s \
    -duration=5m \
| tee /tmp/backend-load.bin \
| docker run --rm -i jauderho/vegeta:latest \
    report
```

The 1,800 requests/second rate was selected after observing that unrestricted
load could overwhelm the backend health-check path rather than produce the
stable CPU pressure needed for a target-tracking test.

---

## 7.5 Observe ECS scale-out

During the test:

```bash
aws-vault exec terraform -- \
  aws ecs describe-services \
  --cluster ecs-fargate-cicd-cluster \
  --services ecs-fargate-cicd-backend \
  --query 'services[0].{
    Desired:desiredCount,
    Running:runningCount,
    Pending:pendingCount
  }' \
  --output table
```

Observed transition:

```text
Desired 1
Running 1
Pending 0
```

to:

```text
Desired 2
Running 1
Pending 1
```

and finally:

```text
Desired 2
Running 2
Pending 0
```

The change in `Desired` from `1` to `2` distinguishes Application Auto Scaling
from temporary ECS deployment or unhealthy-task replacement behavior.

---

## 7.6 Verify Application Auto Scaling activity

```bash
aws-vault exec terraform -- \
  aws application-autoscaling describe-scaling-activities \
  --service-namespace ecs \
  --resource-id \
    service/ecs-fargate-cicd-cluster/ecs-fargate-cicd-backend \
  --scalable-dimension ecs:service:DesiredCount \
  --max-results 10 \
  --query 'ScalingActivities[].{
    Time:StartTime,
    Status:StatusCode,
    Cause:Cause
  }' \
  --output table
```

Observed result:

```text
Status:
Successful

Cause:
Target-tracking AlarmHigh entered ALARM and triggered
ecs-fargate-cicd-backend-cpu-50
```

---

## 7.7 Verify CloudWatch alarm history

The target-tracking alarm history showed:

```text
INSUFFICIENT_DATA -> OK
OK                -> ALARM
ALARM             -> OK
```

This proves the complete scaling control loop:

```text
load
  |
  v
CPU metric
  |
  v
CloudWatch alarm
  |
  v
Application Auto Scaling
  |
  v
ECS desired capacity
```

---

## 7.8 Acceptance criteria

Phase 7 passes when:

- the backend begins with desired capacity `1`
- sustained load drives the target-tracking alarm into `ALARM`
- Application Auto Scaling records a successful scaling activity
- ECS desired capacity changes from `1` to at least `2`
- a second Fargate task reaches running state
- the scaling evidence is stored under `docs/evidence/screenshots/scaling/`