# Project Documentation

This directory contains the detailed engineering, security, implementation,
operational, and validation documentation for the project.

## Implementation

Step-by-step instructions for reproducing, deploying, and validating the
environment:

[Implementation Guide](Implementation-Guide/)

## Architecture and Design

System architecture, runtime relationships, networking, scaling, identity, and
control-plane ownership:

[Architecture](architecture.md)

Engineering decisions, tradeoffs, and ownership boundaries:

[Design Decisions](design-decisions.md)

## Security

Trust boundaries, network controls, workload identity, CI/CD security,
supply-chain controls, compromise scenarios, and residual risks:

[Security Model](security-model.md)

Reviewable IAM principal, action, resource, condition, and permission
boundaries:

[IAM Permissions Matrix](iam-permissions-matrix.md)

Terraform remote-state encryption, locking, recovery, access governance, and
security validation:

[Terraform Remote-State Security Checklist](terraform-remote-state-security-checklist.md)

## Operations

Dependency-aware AWS teardown, Terraform state backup, resource cleanup, and
final verification:

[Cleanup and Teardown](cleanup.md)

## Evidence

Screenshots and validation artifacts covering infrastructure, CI/CD,
container-security gates, application deployment, and Auto Scaling:

[Validation Evidence](evidence/)