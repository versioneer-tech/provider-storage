# Provider Storage – Usage & Concepts

This section explains how to **use** the `provider-storage` configuration packages once they are installed. It focuses on the **concepts** of Buckets, Access Requests, and Access Grants, and shows how to verify provisioning and access credentials.

---

## Concepts

### Buckets
A `Storage` claim defines one or more **buckets** for a user (the `principal`).  
Each bucket is created on the configured storage backend (MinIO, AWS S3, OTC OBS) and may optionally be marked **discoverable** so that others can see and request access for it.

### Access Requests
A user may **request access** to another user’s bucket.  
This is expressed in the `bucketAccessRequests` section of their `Storage` claim.  
Requests specify the target bucket and a free-text reason field.

### Access Grants
The owner of a bucket can **grant access** to other users via the `bucketAccessGrants` section.  
A grant specifies the bucket, the grantee (user) and the permission – `ReadOnly`, `ReadWrite`, `WriteOnly`, or `None` in case of deny.  
A request only becomes effective once the corresponding grant is present.

---

## Example: Joe and Jeff

### Joe’s Storage definition

```yaml
# Joe creates one discoverable bucket s-joe, requests access to Jeff's bucket,
# and grants Jeff ReadWrite access to s-joe.
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: s-joe
spec:
  principal: joe
  buckets:
    - bucketName: s-joe
      discoverable: true
  bucketAccessRequests:
    - bucketName: s-jeff-shared
      reason: Need access
      requestedAt: "2025-09-29T10:00:00Z"
  bucketAccessGrants:
    - bucketName: s-joe
      grantee: jeff
      permission: ReadWrite
      grantedAt: "2025-09-29T10:05:00Z"
```

### Jeff’s Storage definition

```yaml
# Jeff creates two buckets, requests access to Joe's, and grants Joe ReadOnly access.
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: s-jeff
spec:
  principal: jeff
  buckets:
    - bucketName: s-jeff
    - bucketName: s-jeff-shared
      discoverable: true
  bucketAccessRequests:
    - bucketName: s-joe
      reason: Need access
      requestedAt: "2025-09-29T10:10:00Z"
  bucketAccessGrants:
    - bucketName: s-jeff-shared
      grantee: joe
      permission: ReadOnly
      grantedAt: "2025-09-29T10:15:00Z"
```

In this example:

- Joe owns `s-joe` and Jeff owns `s-jeff` and `s-jeff-shared`.
- Joe requests access to `s-jeff-shared`, Jeff requests access to `s-joe`.
- Joe grants Jeff **ReadWrite** access to `s-joe`.
- Jeff grants Joe **ReadOnly** access to `s-jeff-shared`.

---

## Example: Jane requesting access from John

```yaml
# Jane has no buckets but requests WriteOnly access to John's bucket.
# Note: This request only becomes effective once John grants it.
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: s-jane
spec:
  principal: jane
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
# John owns s-john. He grants Jane WriteOnly access to his bucket after her request.
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: s-john
spec:
  principal: john
  buckets:
    - bucketName: s-john
      discoverable: true
  bucketAccessGrants:
    - bucketName: s-john
      grantee: jane
      permission: WriteOnly
      grantedAt: "2025-09-29T10:25:00Z"
```

In this scenario:

- Jane requests **WriteOnly** access to `s-john`.
- John grants it, so the request becomes effective.
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

Each `Storage` claim produces a **Secret in the same namespace** with the **principal’s name**.  
For example, the claim `s-joe` with principal `joe` creates a Secret `joe`.

List Secrets in the namespace:

```bash
kubectl get secrets -n workspace
```

Inspect the Secret:

```bash
kubectl describe secret joe -n workspace
```

View raw YAML (keys are base64-encoded):

```bash
kubectl get secret joe -n workspace -o yaml
```

Decode credentials locally, e.g. for AWS-style keys:

```bash
kubectl get secret joe -n workspace -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d; echo
kubectl get secret joe -n workspace -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d; echo
```

**Key names by provider:**
- **MinIO / AWS**: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`
- **OTC**: `attribute.access`, `attribute.secret`

You can now use these credentials with any S3-compatible tool, e.g.:

```bash
aws s3 ls s3://s-joe
```

---

## Summary

- A `Storage` claim defines buckets, access requests, and access grants.  
- Requests only take effect once the bucket owner provides a matching grant.  
- Every claim produces a Secret in the same namespace with the **principal’s name**.  
- Check `kubectl get storages` for readiness and inspect the Secret for connection info.  
- Use the credentials directly with S3 tools or mount them into workloads.
