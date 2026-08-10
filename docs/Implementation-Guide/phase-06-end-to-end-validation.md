# Phase 6: End-to-End Deployment Validation

## 6.1 Live application validation

The pipeline resolves the ALB hostname at runtime:

```bash
aws elbv2 describe-load-balancers
```

No generated ALB DNS name is hardcoded into the Jenkinsfile.

Jenkins then verifies:

```text
GET /
    -> HTTP 200

GET /api
    -> JSON response containing a GUID
```

The pipeline succeeds only after both checks pass.

This validates both the deployment control path and the public application data
path.

---

## 6.2 Manual validation

Retrieve the ALB endpoint:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure output \
  -raw alb_dns_name
```

Test frontend:

```bash
curl -i "http://<alb-dns>/"
```

Test backend routing:

```bash
curl -i "http://<alb-dns>/api"
```

Browser verification must display:

```text
SUCCESS: <GUID>
```

---

## 6.3 GitHub webhook

In Jenkins:

```text
Job
-> Configure
-> Build Triggers
-> GitHub hook trigger for GITScm polling
```

In the GitHub repository create a webhook:

```text
Payload URL:
http://<jenkins-eip>:8080/github-webhook/

Content type:
application/json

Event:
push
```

Verify automation by pushing a harmless committed change.

Do not click `Build Now`.

Expected flow:

```text
git push
    |
    v
GitHub webhook
    |
    v
Jenkins pipeline
    |
    v
ECR
    |
    v
ECS
    |
    v
live application validation
```

Do not claim webhook validation as complete until a Git push has successfully
started the Jenkins job.

---

## 6.4 Final Terraform idempotency check

After Jenkins configuration and deployment changes are complete:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan
```

Required result:

```text
No changes. Your infrastructure matches the configuration.
```

This confirms Terraform no longer detects unintended infrastructure drift.