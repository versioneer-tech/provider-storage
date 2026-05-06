# Provider Storage – Usage & Concepts

This section explains how to use `provider-storage` after installation. Read it as an operator-facing contract: users request buckets and access through a `Storage` claim, while the platform controls the backend, policies, credentials, lifecycle rules, and credential rotation.

The concepts are the same for MinIO, AWS S3, and OTC OBS. Buckets, credentials, access requests, access grants, and lifecycle rules use one API. The backend implementation is different, but the user-facing model stays clean.

---

## Concepts

### Credentials

For every `Storage` claim, access credentials are created for `spec.principal` and stored in a Kubernetes Secret in the same namespace. The Secret is named after the principal and exposes normalized S3-style keys on every supported backend.

Applications and other platform building blocks can consume this Secret directly. For example, a Datalab can use it to mount object-storage access into a workspace.

Credentials can be rolled over on a schedule. A configurable number of older credentials can stay valid during rotation, which avoids disruptions for running workloads.

### Buckets
A `Storage` claim defines one or more buckets for a principal. Each bucket is created on the selected backend: MinIO, AWS S3, or OTC OBS.

Buckets can be marked **discoverable** so other principals can request access. Operators still control which backend is used and which provider credentials are allowed to create resources.

### Lifecycle Rules
Buckets can define lifecycle rules under `spec.buckets[].lifecycleRules`. The same lifecycle rule model applies to MinIO, AWS S3, and OTC OBS.
Rules target either the whole bucket (`*`) or a prefix such as `tmp/*`, then either delete matching objects or report them without changing data.

`Delete` removes matching objects when the time condition is met.
`Notify` logs matching objects when the time condition is met and does not change objects.

Supported `minAge` suffixes are `s` seconds, `m` minutes, `h` hours, `d` days, and `w` weeks.
Rules may alternatively use `at` with an RFC3339 timestamp for a fixed UTC cutoff.

### Access Requests
A user may **request access** to another user’s bucket.
This is expressed in the `bucketAccessRequests` section of their `Storage` claim.
Requests specify the target bucket, a timestamp, and an optional free-text reason.
The request itself has no permission field; the bucket owner decides the effective permission in the grant.

### Access Grants
The owner of a bucket can **grant access** to other users via the `bucketAccessGrants` section.
A grant specifies the bucket, the grantee, and the permission: `ReadOnly`, `ReadWrite`, `WriteOnly`, or `None` to deny access.
A request only becomes effective once the corresponding grant is present.

---

## Example: Joe and Jeff

### Joe’s Storage definition

```yaml
# Joe creates one discoverable bucket s-joe, requests access to Jeff's bucket,
# and grants Jeff ReadWrite access to s-joe.
# Credentials are static, i.e. not automatically rolled over.
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

### Jeff’s Storage definition

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

---

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

This shows that a `Storage` claim may consist solely of access requests without creating any new buckets.

---

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

---

## Verifying Provisioning

Once a `Storage` claim has been applied, you can verify that the provisioning worked.

### Check Composite Status

List all `storages` in your namespace (e.g., `workspace`):

```bash
kubectl get storages -n workspace
```

You should see `READY=True` once reconciliation is complete. Example:

```
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

### Find the Secret with Credentials

Each `Storage` claim produces a **Secret in the same namespace** named after `spec.principal`.
For example, the claim `s-joe` with principal `s-joe` creates a Secret `s-joe`.

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

Decode credentials locally, e.g. for AWS-style keys:

```bash
kubectl get secret s-joe -n workspace -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d; echo
kubectl get secret s-joe -n workspace -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d; echo
```

All providers expose `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in the normalized Secret.
When configured through the selected storage environment, the Secret also carries connection metadata such as `AWS_ENDPOINT_URL`, `AWS_REGION`, and `AWS_S3_FORCE_PATH_STYLE`.

You can now use these credentials with any S3-compatible tool, e.g.:

```bash
aws s3 ls s3://s-joe
```

---

## Summary

- A `Storage` claim defines buckets, access requests, and access grants.
- Lifecycle rules can delete or report objects by target prefix and age.
- Requests only take effect once the bucket owner provides a matching grant.
- Every claim produces a Secret in the same namespace named after `spec.principal`.
- Check `kubectl get storages` for readiness and inspect the Secret for connection info.
- Use the credentials directly with S3 tools or mount them into workloads.
- Other platform building blocks, such as Datalab, can consume the generated Secret.
