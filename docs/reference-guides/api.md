# API reference

[`xrd.yaml`](https://github.com/versioneer-tech/provider-storage/blob/main/xrd.yaml)
CompositeResourceDefinition defines the `Storage` API.

## Storage

```yaml
apiVersion: pkg.internal/v1beta1
kind: Storage
```

### Identity

- `spec.principal`: required logical user or service principal. Provider
  Storage also uses it as the consumer Secret name.
- `spec.providerIdentity`: optional short provider-native user name. It does
  not change the principal or consumer Secret name.

### Buckets

Each bucket entry is keyed by `bucketName`.

`spec.buckets` is required but can be an empty list for a resource that only
requests access.

- `bucketName`: bucket name to create.
- `discoverable`: optional boolean that advertises the bucket for access requests.
- `lifecycleRules`: optional object cleanup or notification rules.

### Lifecycle rules

Lifecycle rules are configured under `spec.buckets[].lifecycleRules[]`.

- `target`: `*` for the whole bucket, or a prefix such as `tmp/*`.
- `mode`: `Delete` or `Notify`.
- `minAge`: relative object age such as `30s`, `15m`, `2h`, `1d`, or `2w`.
- `at`: RFC3339 UTC timestamp after which each job processes all matching objects.

Each rule must set exactly one of `minAge` or `at`.

### Access requests

`spec.bucketAccessRequests[]` declares outbound requests for buckets owned by
other principals.

- `bucketName`: requested bucket.
- `reason`: optional free-text justification.
- `requestedAt`: required RFC3339 timestamp supplied by the requester.

Requests do not carry a permission field. The effective permission is recorded
only on the owner's matching `bucketAccessGrants[]` entry.

### Access grants

`spec.bucketAccessGrants[]` declares permissions granted by this principal.

- `bucketName`: bucket being shared.
- `grantee`: principal receiving access.
- `permission`: `ReadWrite`, `ReadOnly`, `WriteOnly`, or `None`.
- `grantedAt`: required RFC3339 timestamp supplied by the owner.

### Credential rollover

`spec.credentialsRollover` controls automatic credential rotation.

- `interval`: `daily`, `weekly`, `monthly`, `quarterly`, `yearly`, or `none` (default).
- `maxToKeep`: number of active credential generations to keep, from 1
  through 10. It must be 1 when `interval` is `none`.
