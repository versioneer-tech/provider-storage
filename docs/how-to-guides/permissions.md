# Provider Storage – Permission Model

The **permission model** in `provider-storage` gives operators one access model across backends. Users work with four normalized permission levels instead of raw backend-specific IAM or policy actions. The Composition translates that model into the backend implementation.

- **ReadWrite** → Full read and write access to bucket contents.  
  Includes: `ListBucket`, `GetObject`, `PutObject`, `DeleteObject`  
- **ReadOnly** → View-only access.  
  Includes: `ListBucket`, `GetObject`  
- **WriteOnly** → Append/write access without read visibility.  
  Includes: `ListBucket`, `PutObject`, `DeleteObject`  
- **None** → Record that access is not granted by this claim. Backends differ
  in whether they remove an allow or write an explicit deny.

The [backend comparison](backend_differences.md#from-request-to-access) shows
how each backend implements a pending, granted, or denied request and records
current verification limits.

---

## Discoverable Buckets

`spec.buckets[].discoverable` records whether a bucket should be shown to
potential requesters. The Compositions do not use that field to decide
access. Compositions that resolve requests from peer `Storage` claims require
this label on the owner claim:

```yaml
metadata:
  labels:
    storages.pkg.internal/discoverable: "true"
```

Once loaded, the Composition checks that the peer owns the named bucket and
has a matching `bucketAccessGrants` entry for the requester. OTC uses
observed grantee identities to build bucket policies; its current
Composition does not inspect peer `Storage` resources for requests.

Example (owner Joe making his bucket discoverable):

```yaml
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
```

---

## Requesting Access

Other users can **request access** to a discoverable bucket by adding a `bucketAccessRequests` entry.
Requests include the bucket name, a `requestedAt` timestamp, and optionally a free-text reason.
The `Storage` API does not store a requested permission on the request itself; the effective permission is decided by the bucket owner's grant.

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
- The grantee
- The granted permission (`ReadWrite`, `ReadOnly`, `WriteOnly`, or `None`)
- The timestamp when the grant or denial was recorded (`grantedAt`)

Example (Joe granting Jeff ReadOnly access to `s-joe`):

```yaml
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
  bucketAccessGrants:
    - bucketName: s-joe
      grantee: s-jeff
      permission: ReadOnly
      grantedAt: "2025-09-29T10:15:00Z"
```

If Joe wanted to record a denial, he would set `permission: None` in the
grant. Whether this produces an explicit cloud policy deny depends on the
backend.

---

## Lifecycle of a Permission

1. **Bucket owner marks bucket discoverable.**
2. **Requester adds a `bucketAccessRequests` entry** with the target bucket, timestamp, and optional reason.
3. **Owner responds with a `bucketAccessGrants` entry.**
   - If permission is one of `ReadWrite`, `ReadOnly`, or `WriteOnly`, access is granted.
   - If permission is `None`, the claim records a denial; the generated
     policy behavior differs by backend.
4. Callers supply **requestedAt** and **grantedAt** timestamps for traceability.

This keeps the workflow transparent: requests, reasons, grants, and denials are recorded in the claims and remain visible to operators.

---

## Example: Joe and Jeff

Joe shares his bucket, Jeff requests access, and Joe grants it:

```yaml
# Joe's claim
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
