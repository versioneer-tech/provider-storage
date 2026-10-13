# Provider Storage usage and concepts

This section explains how to use Provider Storage after installation. Users
request buckets and access through a `Storage` resource. The platform controls
the backend, policies, credentials, lifecycle rules, and credential rotation.

Buckets, credentials, access requests, access grants, and lifecycle rules use one API. The backend implementation differs, but the user-facing model stays the same.

See the [backend comparison](backend_differences.md) for provider-specific
identity, policy, and verification limits.

## Select a backend

If the cluster has only one compatible Provider Storage Composition,
Crossplane can select it without a Composition selector. If the cluster has
more than one backend Composition, set an explicit selector on each `Storage`
resource. Valid provider values are `aws`, `cloudferro`, `minio`, `otc`, and
`ovh`.

```yaml
spec:
  crossplane:
    compositionSelector:
      matchLabels:
        provider: minio
```

All backends use the `storage` EnvironmentConfig by default. Set the
`storages.pkg.internal/environment` annotation or label to select a different
EnvironmentConfig. The multi-backend examples select `storage-<backend>`.

CloudFerro also requires the `storages.pkg.internal/cloudferro-project-id`
annotation and an explicit `provider: cloudferro` Composition selector. See the
[CloudFerro dependency guide](https://github.com/versioneer-tech/provider-storage/blob/main/cloudferro/dependencies/README.md).

## Concepts

### Credentials

For every `Storage` resource, access credentials are created for
`spec.principal` and stored in a Kubernetes Secret in the same namespace. The
Secret is named after the principal and uses the same S3 keys on every
supported backend.

Set `spec.providerIdentity` only when the provider-native user needs a
different short name. This does not change the consumer Secret name.

Applications and other platform building blocks can consume this Secret directly. For example, a Datalab can use it to mount object-storage access into a workspace.

Credentials can be rolled over on a schedule. A configurable number of older credentials can stay valid during rotation, which avoids disruptions for running workloads.

### Buckets

A `Storage` resource defines one or more buckets for a principal. Each bucket
is created on the selected backend.

Buckets can be marked **discoverable** so clients can show them to potential
requesters. The field does not enforce access; the owner's grant and the
backend policy do. See [Discoverable Buckets](permissions.md#discoverable-buckets)
for the owner-label requirement in request workflows.

### Lifecycle rules

Buckets can define lifecycle rules under `spec.buckets[].lifecycleRules`. The `Storage` API defines one lifecycle rule model across backends.
Rules target either the whole bucket (`*`) or a prefix such as `tmp/*`, then either delete matching objects or report them without changing data.

`Delete` removes matching objects when the time condition is met.
`Notify` logs matching objects when the time condition is met and does not change objects.

Supported `minAge` suffixes are `s` seconds, `m` minutes, `h` hours, `d` days, and `w` weeks.
Rules may alternatively use `at` with an RFC3339 timestamp for a fixed UTC cutoff.

### Access requests and grants

A principal records a request for another bucket in
`spec.bucketAccessRequests`. The bucket owner records the decision in
`spec.bucketAccessGrants`. The request does not contain a permission. The
owner selects `ReadOnly`, `ReadWrite`, `WriteOnly`, or `None` in the grant.
See the [permission model](permissions.md) for discovery requirements and
backend differences.

## Example: Joe and Jeff

### Joe’s Storage resource

```yaml
# Joe creates one discoverable bucket s-joe, requests access to Jeff's bucket,
# and grants Jeff ReadWrite access to s-joe.
# Credentials are static and do not rotate automatically.
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: s-joe
  labels:
    storages.pkg.internal/discoverable: "true"
spec:
  principal: s-joe
  buckets:
    - bucketName: s-joe
      discoverable: true
  bucketAccessRequests:
    - bucketName: s-jeff-shared
      reason: Need access
      requestedAt: "2025-09-29T10:00:00Z"
  bucketAccessGrants:
    - bucketName: s-joe
      grantee: s-jeff
      permission: ReadWrite
      grantedAt: "2025-09-29T10:05:00Z"
```

### Jeff’s Storage resource

```yaml
# Jeff creates two buckets, requests access to Joe's bucket,
# grants Joe ReadOnly access to one of his own buckets, cleans
# tmp/ under the shared bucket after twelve hours, and notifies
# on week-old scratch/ data.
# Credentials are automatically rolled over every week,
# keeping the current plus the previous credential active.
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: s-jeff
  labels:
    storages.pkg.internal/discoverable: "true"
spec:
  principal: s-jeff
  credentialsRollover:
    interval: weekly
    maxToKeep: 2
  buckets:
    - bucketName: s-jeff
    - bucketName: s-jeff-shared
      discoverable: true
      lifecycleRules:
        - target: tmp/*
          mode: Delete
          minAge: 12h
        - target: scratch/*
          mode: Notify
          minAge: 1w
  bucketAccessRequests:
    - bucketName: s-joe
      reason: Need access
      requestedAt: "2025-09-29T10:10:00Z"
  bucketAccessGrants:
    - bucketName: s-jeff-shared
      grantee: s-joe
      permission: ReadOnly
      grantedAt: "2025-09-29T10:15:00Z"
```

In this example:

- Joe owns `s-joe` and Jeff owns `s-jeff` and `s-jeff-shared`.
- Joe requests access to `s-jeff-shared`, Jeff requests access to `s-joe`.
- Joe grants Jeff **ReadWrite** access to `s-joe`.
- Jeff grants Joe **ReadOnly** access to `s-jeff-shared`.
- Jeff cleans `tmp/` in `s-jeff-shared` and reports week-old `scratch/` objects.

## Example: Jane requesting access from John

```yaml
# Jane has no buckets but requests access to John's bucket and explains
# in the reason that she wants WriteOnly access.
# Note: This request only becomes effective once John grants it.
# Credentials are automatically rolled over every quarter,
# keeping the current plus 4 previous credentials active.
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: s-jane
spec:
  principal: s-jane
  credentialsRollover:
    interval: quarterly
    maxToKeep: 5
  buckets: []
  bucketAccessRequests:
    - bucketName: s-john
      reason: Need WriteOnly access
      requestedAt: "2025-09-29T10:20:00Z"
```

A `Storage` resource can contain only access requests and create no buckets.

## Example: John responding to Jane

```yaml
# John owns s-john. He grants Jane ReadWrite access to his bucket even though
# Jane's request reason asked for WriteOnly access.
# His request to s-jane cannot resolve until that bucket exists.
# Credentials are automatically rolled over every day.
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: s-john
  labels:
    storages.pkg.internal/discoverable: "true"
spec:
  principal: s-john
  credentialsRollover:
    interval: daily
  buckets:
    - bucketName: s-john
      discoverable: true
  bucketAccessRequests:
    - bucketName: s-joe
      reason: Need access
      requestedAt: "2025-09-29T10:25:00Z"
    - bucketName: s-jeff
      reason: Need access
      requestedAt: "2025-09-29T10:26:00Z"
    - bucketName: s-jane
      reason: Need access
      requestedAt: "2025-09-29T10:27:00Z"
  bucketAccessGrants:
    - bucketName: s-john
      grantee: s-jane
      permission: ReadWrite
      grantedAt: "2025-09-29T10:28:00Z"
```

In this scenario:

- Jane requests access to `s-john` and records **WriteOnly** intent in the request reason.
- John grants **ReadWrite** access, so Jane receives broader access than she requested.
- The system reconciles and attaches the effective permission.

## Verify provisioning

After you apply a `Storage` resource, check that provisioning completed.

### Check resource status

List all `storages` in your namespace, for example `workspace`:

```bash
kubectl get storages -n workspace
```

You should see `READY=True` once reconciliation is complete. Example:

```text
NAME          SYNCED   READY   COMPOSITION        AGE
s-jane        True     True    storage-minio      2m
s-joe         True     True    storage-minio      2m
s-jeff        True     True    storage-minio      2m
s-john        True     True    storage-minio      2m
```

To see more detail, describe the composite:

```bash
kubectl describe storage s-joe -n workspace
```

Look for conditions like `Ready=True` and check any event messages.

### Find the consumer Secret

Each `Storage` resource produces a Secret in the same namespace named after
`spec.principal`. For example, the resource `s-joe` with principal `s-joe`
creates a Secret named `s-joe`.
Do not use internal Secrets such as `s-joe-credentials` or
`s-joe-20260911`. Providers create them with provider-native key names.

List Secrets in the namespace:

```bash
kubectl get secrets -n workspace
```

Inspect the Secret:

```bash
kubectl describe secret s-joe -n workspace
```

View raw YAML (keys are base64-encoded):

```bash
kubectl get secret s-joe -n workspace -o yaml
```

Decode credentials locally. For example, use these commands for AWS-style keys:

```bash
kubectl get secret s-joe -n workspace -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d; echo
kubectl get secret s-joe -n workspace -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d; echo
```

All providers expose only `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and the
configured connection keys in the normalized Secret. The connection keys are
`AWS_ENDPOINT_URL`, `AWS_REGION`, and `AWS_S3_FORCE_PATH_STYLE`.

You can now use these credentials with any S3-compatible tool. For example:

```bash
aws s3 ls s3://s-joe
```
