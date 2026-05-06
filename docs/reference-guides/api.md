# Provider Storage API Reference

The source of truth for the `Storage` API is the
[`xrd.yaml`](https://github.com/versioneer-tech/provider-storage/blob/main/xrd.yaml)
CompositeResourceDefinition.

The API is the platform-facing contract for bucket self-service. Users describe buckets, access requests, grants, lifecycle rules, and credential rollover once. Operators choose whether the implementation is MinIO, AWS S3, or OTC OBS.

## Storage

```yaml
apiVersion: pkg.internal/v1beta1
kind: Storage
```

### Required Fields

- `spec.principal`: unique user or service principal.
- `spec.buckets`: bucket definitions owned by the principal.

### Buckets

Each bucket entry is keyed by `bucketName`.

- `bucketName`: bucket name to create.
- `discoverable`: optional boolean that advertises the bucket for access requests.
- `lifecycleRules`: optional object cleanup or notification rules.

### Lifecycle Rules

Lifecycle rules are configured under `spec.buckets[].lifecycleRules[]`.

- `target`: `*` for the whole bucket, or a prefix such as `tmp/*`.
- `mode`: `Delete` or `Notify`.
- `minAge`: relative object age such as `30s`, `15m`, `2h`, `1d`, or `2w`.
- `at`: RFC3339 timestamp for a fixed UTC cutoff.

Each rule must set exactly one of `minAge` or `at`.

### Access Requests

`spec.bucketAccessRequests[]` declares outbound requests for buckets owned by
other principals.

- `bucketName`: requested bucket.
- `reason`: optional free-text justification.
- `requestedAt`: RFC3339 timestamp for the request.

Requests do not carry a permission field. The effective permission is recorded
only on the owner's matching `bucketAccessGrants[]` entry.

### Access Grants

`spec.bucketAccessGrants[]` declares permissions granted by this principal.

- `bucketName`: bucket being shared.
- `grantee`: principal receiving access.
- `permission`: `ReadWrite`, `ReadOnly`, `WriteOnly`, or `None`.
- `grantedAt`: RFC3339 timestamp for the grant.

### Credential Rollover

`spec.credentialsRollover` controls automatic credential rotation.

- `interval`: `daily`, `weekly`, `monthly`, `quarterly`, `yearly`, or `none` (default).
- `maxToKeep`: number of active credential generations to keep.
