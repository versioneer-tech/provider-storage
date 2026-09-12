# ADR-004: Add an OVHcloud S3 Backend

## Status

Proposed

## Date

2026-09-12

## Context

Provider Storage has no released OVHcloud backend. Standard regional OVHcloud Object
Storage has an S3-compatible data plane. OVHcloud provides project users,
generated S3 credentials, and one S3 policy per user. The candidate direct
Crossplane provider is `edixos/provider-ovh:v2.19.1`. This release has
breaking schema changes, so the backend must use a pinned version and must
qualify its managed resources before use.

The public `Storage` API already defines buckets, grants, credential
generations, and lifecycle rules. OVHcloud Local Zone Object Storage does not
enforce the same user-policy boundary: every access key in a project can
access every Local Zone bucket.

## Decision

Add an `ovh/` Composition for standard regional Object Storage. Select it
with the existing Composition label. Keep provider-specific region and
endpoint settings in an `EnvironmentConfig`. Keep the public `Storage` XRD
and the normalized consumer Secret contract unchanged.

Qualify the namespaced `ProjectStorage`, `User`, `S3Credentials`, and
`S3Policy` resources in `edixos/provider-ovh:v2.19.1`. Use direct managed
resources if they pass the qualification tests. Use one project `User`, one
`S3Credentials`, and one consolidated `S3Policy` for each retained credential
generation. This lets the Composition remove an old user's access when its
generation expires. A single stable user with several keys would keep the
same policy for old and new keys. Set each generated user's role to
`objectstore_operator`. Use a separate, stable owner User for the bucket so
credential rollover does not change bucket ownership. Keep that owner when
the `Storage` is removed until orphan cleanup has been proved. Resolve the
owner and every retained grantee User by observed ID before creating
dependent resources. In the pinned CRDs, `User.status.atProvider.id` is a
string and `ProjectStorage.ownerId` is a number. A live direct probe confirmed
this conversion for a new bucket. Owner replacement remains unproved.

Set `ProjectStorage.hideObjects` to true and verify that observed status does
not retain object names after a real upload.

Combine the current `S3Credentials` access key ID from observed status with
the `attribute.secret_access_key` field in its connection Secret. Do not
publish the consumer Secret
until both values exist. Publish only `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL`, `AWS_REGION`, and
`AWS_S3_FORCE_PATH_STYLE`. Use the regional S3 endpoint and test its region
mapping and path-style setting with a real client. Reuse the existing rclone
lifecycle jobs after the endpoint and permissions pass live tests.

Use an OAuth2 service account for the provider controller. Bind its IAM
policy to the intended `publicCloudProject`. Give the controller only the
project actions required for users, S3 credentials, policies, and standard
regional buckets. Do not give it permission to create service accounts or IAM
policies. Keep `client_id` and `client_secret` in the provider credential
Secret, never in a consumer Secret. The service account is an account identity;
its IAM policy names only the target project resource. This is separate from
the Object Storage Users created inside that project. Review the exact action
names and project URN before bootstrap. A denied read on a second project is
an optional extra check when one is available. Set the target project ID on
every managed resource that requires `serviceName`.

The pinned `ProjectStorage` CRD has no `deletionPolicy`. Start with
`managementPolicies` that omit `Delete` and `Update`, then test whether this
leaves the bucket and its owner in the project when the managed resource is
removed. An owner ID change needs a reviewed migration. Do not enable
destructive bucket deletion until a disposable-project test proves what
happens to a non-empty, versioned, or locked bucket. Exclude Object Lock and
Local Zone storage from the first backend. Record and clean up retained test
buckets explicitly.

## Consequences

- This ADR describes a proposed backend. The IAM bootstrap passed target-project
  reads, exact policy repair, and repeated `apply`. Direct `User`,
  `S3Credentials`, `ProjectStorage`, and `S3Policy` resources reached Ready in
  `DE`. A direct writer could use its granted bucket and was denied on another
  existing bucket. One composed `Storage` reached Ready and its normalized
  five-key Secret passed an S3 round trip. A composed peer was denied before a
  grant, could read but not write with `ReadOnly`, and was denied again after
  `None` propagated. A follow-up cycle without a manual peer reconcile updated
  the peer policy automatically within about a minute. Rotation, owner
  replacement, lifecycle, quotas, and teardown remain open. A two-project
  controller denial check is optional and was not run.
- Revocation was not immediate: a read about 24 seconds after the provider
  reported the `None` policy still succeeded, while a fresh retry about a
  minute later was denied. A second automatic cycle showed the same delay.
  Do not promise immediate access cutoff from a
  policy update; use credential deletion when that guarantee is needed, after
  its behavior is qualified.
- OVHcloud does not provide bucket policies for this service. Per-user S3
  policy rules, ACL fallback, and bucket-owner `FULL_CONTROL` need positive
  and negative access tests. An omitted policy action is not proof of denial.
- Bucket-name privacy needs an explicit `s3:ListAllMyBuckets` denial and a
  live test if it becomes part of the contract.
- The direct provider avoids an OpenTofu state layer, but the community
  provider must pass resource, secret-output, and recovery tests before the
  backend is called supported.
- One user per retained generation consumes the project's user quota. The
  first live test must confirm quotas for the intended number of principals
  and retained generations.

The provider [release](https://github.com/edixos/provider-ovh/releases/tag/v2.19.1),
OVHcloud [S3 IAM guide](https://docs.ovhcloud.com/en/guides/storage-and-backup/object-storage/s3-identity-and-access-management),
[service-account guide](https://docs.ovhcloud.com/en/guides/manage-and-operate/api/manage-service-account),
and [Local Zone limits](https://docs.ovhcloud.com/en/guides/storage-and-backup/object-storage/s3-local-zones-limitations)
give the current external constraints.
