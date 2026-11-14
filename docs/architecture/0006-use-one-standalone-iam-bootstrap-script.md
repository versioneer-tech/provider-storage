# ADR-006: Use One Standalone IAM Bootstrap Script

## Status

Accepted

## Date

2026-11-14

## Context

Cloud IAM setup needs privileges that Crossplane does not need during normal
operation. Operators have different requirements for credentials, network
access, and automation. They need to choose where and when to run bootstrap.

## Decision

Operators choose where and when to run IAM bootstrap: on a specific host, in a
CI/CD pipeline, or on a local machine.

Provide one standalone script, `scripts/bootstrap-iam.sh`, for AWS, OTC,
OVHcloud, and CloudFerro. Include its policies and helpers so operators can
run it without a repository checkout.

Keep IAM bootstrap separate from Storage reconciliation and Kubernetes
deployment. The script prepares cloud identities and permissions and can
render controller Secrets. Operators deploy those Secrets through their
chosen deployment process. The script does not need Kubernetes access.

Crossplane uses only the controller credentials or workload identity needed
for runtime operations. It does not use the privileged bootstrap login.

## Consequences

- The same script supports manual and automated operator workflows.
- Operators control access to the bootstrap login and generated credentials.
- Cloud IAM setup and Kubernetes deployment remain separate steps.