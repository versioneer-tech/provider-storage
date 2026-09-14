# ADR-004: Add an OVHcloud S3 Backend

## Status

Accepted

## Date

2026-09-12

## Context

Provider Storage needs to create S3 buckets and consumer credentials in an
OVHcloud Public Cloud project. The project provides OpenStack users, S3
credentials, regional buckets, and per-user S3 policies. Crossplane needs a
controller identity with permission to manage these resources.

## Decision

Bootstrap a dedicated OVHcloud IAM service account for the controller. Scope
its policy to the target Public Cloud project and grant the actions needed to
manage project users, their S3 credentials and policies, and regional buckets.
The controller does not need permission to create IAM service accounts or IAM
policies. Store its credentials in the provider Secret.

Use the OVHcloud Composition to create the buckets and the OpenStack users
inside that project. It creates S3 credentials and a policy for each consumer
user. A separate project user owns the buckets, so a consumer credential
change does not change bucket ownership. The consumer receives the same
credential Secret contract as for the other backends.

Use standard regional Object Storage. Keep the project ID, storage region, and
S3 endpoint in the backend configuration. The
[OVHcloud bootstrap guide](../../ovh/dependencies/README.md) gives the setup
steps.

## Consequences

The controller service account is distinct from the OpenStack users it
creates. The service account's IAM policy controls what Crossplane can manage
in the project; each user's S3 policy controls access to buckets and objects.

Removing a `Storage` claim retains its buckets to avoid deleting user data.
Operators must clean up retained buckets explicitly. S3 policy changes can
take time to affect access, so revocation is not immediate.
