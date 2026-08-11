# Implementation Guide

This guide breaks the implementation into ordered phases so the environment can
be built, validated, and troubleshot incrementally.

Each phase documents its purpose, implementation steps, verification commands,
expected results, and acceptance criteria.

| Phase | Purpose |
| --- | --- |
| [Phase 1: Workstation Setup](phase-01-workstation-setup.md) | Install and configure the local tools and AWS authentication required to work with the project |
| [Phase 2: Containerization and Local Validation](phase-02-containerization-local-validation.md) | Containerize the supplied application and validate frontend-to-backend communication locally |
| [Phase 3A: Terraform Bootstrap and Remote State](phase-03-a-bootstrap-env-infrastructure.md) | Configure Terraform authentication, create the secure remote-state backend, and establish state locking |
| [Phase 3: ECR and Artifact Foundation](phase-03-ecr-artifact-foundation-and-publication.md) | Provision the ECR repositories and establish immutable container-image publication |
| [Phase 3B: AWS Network and Edge Infrastructure](phase-03-b-aws-network-edge-infrastructure.md) | Provision the multi-AZ VPC, public and private networking, security boundaries, and Application Load Balancer |
| [Phase 3C: ECS Fargate and Auto Scaling](phase-03-c-ecs-fargate-app-autoscaling.md) | Deploy the frontend and backend ECS Fargate services and configure Application Auto Scaling |
| [Phase 4: Jenkins Infrastructure](phase-04-jenkins-infrastructure.md) | Provision the Jenkins host with Terraform and configure it with Ansible |
| [Phase 5: Jenkins CI/CD](phase-05-jenkins-cicd.md) | Configure and validate the automated Jenkins build, security, deployment, and validation pipeline |
| [Phase 6: End-to-End Validation](phase-06-end-to-end-validation.md) | Validate the complete deployed application and automated CI/CD path |
| [Phase 7: Auto Scaling Validation](phase-07-autoscaling-validation.md) | Generate controlled load and verify ECS horizontal scaling behavior |

## Recommended Order

For a new deployment, follow the phases in the order shown above.

The phases are separated by subsystem so an engineer troubleshooting an existing
environment can go directly to the relevant section without repeating the entire
deployment.

## Supporting Documentation

System architecture and runtime relationships:

```text
docs/architecture.md

Architecture and engineering decisions:

```text
docs/design-decisions.md
```

Validation evidence:

```text
docs/evidence/
```

Environment teardown and cleanup:
```text
docs/cleanup.md
```