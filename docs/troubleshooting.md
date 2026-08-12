Jenkins webhook does not fire
    -> check GitHub delivery
    -> Jenkins public URL
    -> job SCM branch
    -> Jenkins logs

AWS identity check fails
    -> inspect EC2 instance profile
    -> IMDSv2
    -> IAM role trust/policy

Trivy fails
    -> inspect actual fixable HIGH/CRITICAL findings
    -> remediate image/dependencies
    -> rebuild; do not bypass

ECR push fails
    -> AWS identity
    -> authorization token
    -> repository IAM scope
    -> immutable-tag collision

Task cannot start
    -> ECS stopped reason
    -> ECR pull
    -> execution role
    -> private-subnet/NAT connectivity
    -> CloudWatch log configuration

ALB target unhealthy
    -> target health reason
    -> SG path
    -> container port
    -> health-check path

ECS deployment never stabilizes
    -> deployment events
    -> running/pending/stopped task counts
    -> target health
    -> circuit-breaker state

Frontend works but /api fails
    -> ALB listener rule
    -> backend target health
    -> backend logs
    -> backend task definition

Terraform state lock exists
    -> confirm no Terraform process is active
    -> investigate lock holder
    -> never casually delete a valid active lock

Terraform plan shows unexpected replacement
    -> stop
    -> verify state/backend/account
    -> inspect drift
    -> do not apply until explained