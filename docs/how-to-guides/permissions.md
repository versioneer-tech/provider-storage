# Provider Storage – Permission Model

The **permission model** in `provider-storage` provides a consistent, backend-agnostic abstraction over the underlying IAM or policy mechanisms of MinIO, AWS, OTC, and others.  
Instead of exposing raw cloud-specific permission actions, permissions are normalized into four levels:

- **ReadWrite** → Full read and write access to bucket contents.  
  Includes: `ListBucket`, `GetObject`, `PutObject`, `DeleteObject`  
- **ReadOnly** → View-only access.  
  Includes: `ListBucket`, `GetObject`  
- **WriteOnly** → Append/write access without read visibility.  
  Includes: `ListBucket`, `PutObject`, `DeleteObject`  
- **None** → Deny access (default when no permission is granted).

---

## Discoverable Buckets

A bucket must be marked as **discoverable** by its owner before others can request access.  
This is done by setting `discoverable: true` in the bucket definition of the owner’s `Storage` claim.

Example (owner Joe making his bucket discoverable):

```yaml
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: s-joe
spec:
  principal: s-joe
  buckets:
    - bucketName: s-joe
      discoverable: true
```

---

## Requesting Access

Other users can **request access** to a discoverable bucket by adding a `bucketAccessRequests` entry.  
Requests include the bucket name and optionally a reason or timestamp.

Example (Jeff requesting access to Joe’s bucket):

```yaml
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: s-jeff
spec:
  principal: s-jeff
  buckets:
    - bucketName: s-jeff
  bucketAccessRequests:
    - bucketName: s-joe
      reason: Need access for collaboration
      requestedAt: "2025-09-29T10:10:00Z"
```

Until Joe explicitly grants access, Jeff’s request remains pending.  

---

## Granting or Denying Access

The bucket owner decides whether to **grant** or **deny** a request.  
This is captured with a `bucketAccessGrants` entry, which specifies:

- The bucket name  
- The grantee(s)  
- The granted permission (`ReadWrite`, `ReadOnly`, `WriteOnly`, or `None`)  
- The timestamp when the grant or denial was recorded (`grantedAt`)  

Example (Joe granting Jeff ReadOnly access to `s-joe`):  

```yaml
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: s-joe
spec:
  principal: s-joe
  buckets:
    - bucketName: s-joe
      discoverable: true
  bucketAccessGrants:
    - bucketName: s-joe
      grantee: s-jeff
      permission: ReadOnly
      grantedAt: "2025-09-29T10:15:00Z"
```

If Joe wanted to explicitly **deny** the request, he would set `permission: None` in the grant.

---

## Lifecycle of a Permission

1. **Bucket owner marks bucket discoverable.**  
2. **Requester adds a `bucketAccessRequests` entry** with desired permission.  
3. **Owner responds with a `bucketAccessGrants` entry.**  
   - If permission is one of `ReadWrite`, `ReadOnly`, or `WriteOnly`, access is granted.  
   - If permission is `None`, access is explicitly denied.  
4. The system captures both the **requestedAt** and **grantedAt** timestamps for traceability.  

This ensures a transparent workflow where requests, reasons, grants, and denials are all recorded in the claims.

---

## Example: Joe and Jeff

Joe shares his bucket, Jeff requests access, and Joe grants it:

```yaml
# Joe's claim
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: s-joe
spec:
  principal: s-joe
  buckets:
    - bucketName: s-joe
      discoverable: true
  bucketAccessGrants:
    - bucketName: s-joe
      grantee: s-jeff
      permission: ReadOnly
      grantedAt: "2025-09-29T10:15:00Z"
---
# Jeff's claim
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: s-jeff
spec:
  principal: s-jeff
  buckets:
    - bucketName: s-jeff
  bucketAccessRequests:
    - bucketName: s-joe
      reason: Need read-only access for collaboration
      requestedAt: "2025-09-29T10:10:00Z"
```

Outcome:
- Jeff requested access to Joe’s `s-joe`.  
- Joe granted it at a later time.  
- Both the **request** and **grant** are recorded declaratively.  

---

## Summary

- The permission model is abstracted into **ReadWrite**, **ReadOnly**, **WriteOnly**, and **None**.  
- Owners must mark buckets **discoverable** for others to request access.  
- Access requests include the **desired permission** and an optional **reason**.  
- Owners grant or deny access explicitly, recorded with **grantedAt** and the resulting permission.  
- This workflow ensures transparency, auditability, and consistent handling across all storage backends.
