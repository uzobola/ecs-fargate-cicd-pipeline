# Implementation Guide

This guide is divided into independent phases so the environment can be built,
validated, and troubleshot incrementally.

Each phase includes its purpose, implementation steps, verification commands,
expected results, and acceptance criteria.


| Phase | Purpose |
|---|---|
| [Phase 2](phase-02-containerization-local-validation.md) | Containerize and validate the supplied application locally |
| [Phase 3A](phase-03-a-bootstrap-env-infrastructure.md) | Establish Terraform authentication, secure remote state, state migration, and S3-native locking |
| [Phase 3B](phase-03-b-aws-network-edge-infrastructure.md) | Provision the multi-AZ VPC, routing, security boundaries, and Application Load Balancer |
| [Phase 3C](phase-03-c-ecs-fargate-app-autoscaling.md) | Deploy the ECS Fargate runtime and configure Application Auto Scaling |
| [Phase 3 - ECR & Artifact Publication](phase-03-ecr-artifact-foundation-and-publication.md) | Establish the application Terraform workspace, ECR repositories, immutable image publication, and vulnerability validation |
| [Phase 4](phase-04-jenkins-infrastructure.md) | Provision Jenkins with Terraform and configure the host with Ansible |
| [Phase 5](phase-05-jenkins-cicd.md) | Configure and validate the Jenkins deployment pipeline |
| [Phase 6](phase-06-end-to-end-validation.md) | Validate the complete deployed application and CI/CD path |
| [Phase 7](phase-07-autoscaling-validation.md) | Generate controlled load and prove ECS horizontal scaling |


## Recommended order

Follow the phases sequentially for a new deployment.

A reader troubleshooting an existing environment can open only the phase
relevant to that subsystem.

## Supporting documentation

Architecture and engineering tradeoffs:

```text
docs/design-decisions.md
```

Validation evidence:

```text
docs/evidence/
```
