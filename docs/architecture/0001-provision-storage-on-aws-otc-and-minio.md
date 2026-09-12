# ADR-001: Provision Storage on AWS, OTC, and MinIO

## Status

Accepted

## Date

2025-10-03

## Context

Provider Storage offers one `Storage` API for AWS S3, OTC OBS, and MinIO.
Each backend uses different bucket, identity, credential, and policy resources.
A shared Composition would mix these provider-specific models.

## Decision

Keep the `Storage` API independent of the backend. Use one Composition for
each backend.

Each Composition must:

1. create the declared buckets;
2. create the consumer identity, credentials, and permissions;
3. grant access only after it verifies the bucket owner and the matching grant;
4. publish the consumer Secret defined in the
   [Consumer Credential Strategy](credential-strategy.md).

An access request is intent only. Access becomes active only when the verified
bucket owner grants the requested access level.

The backend resource mapping is:

| Backend | Bucket | Consumer identity | Authorization |
| --- | --- | --- | --- |
| MinIO | `Bucket` | `User` | named `Policy` resources |
| AWS | S3 `Bucket` | IAM `User` and `AccessKey` | IAM `Policy` and `UserPolicyAttachment` |
| OTC | wrapped OBS `Bucket` | wrapped IAM `UserV3` and `CredentialV3` | OBS `BucketPolicy` with user IDs |

Provider-kubernetes `Object` resources wrap resources that cannot be composed
or observed directly.

## Consequences

- A new backend needs a new Composition and backend-specific tests.
- S3 compatibility does not prove correct provisioning or authorization.
- Grant logic must verify bucket ownership and discoverability.

## Current limits

- Provider-kubernetes has broad access to provider resources and Secrets.
  Platform RBAC is part of the security boundary.
