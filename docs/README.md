# Implementation Guide

This guide is divided into independent phases so the environment can be built,
validated, and troubleshot incrementally.

Each phase includes its purpose, implementation steps, verification commands,
expected results, and acceptance criteria.

| Phase | Purpose |
|---|---|
| [Phase 2](phase-02-containerization-local-validation.md) | Containerize and validate the supplied application locally |
| [Phase 3](phase-03-aws-infrastructure.md) | Provision ECR, networking, ALB, ECS Fargate, and Auto Scaling with Terraform |
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
