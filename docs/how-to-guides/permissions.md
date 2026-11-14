# Permissions

The bucket owner sets access in `spec.bucketAccessGrants`. Each grant names
a bucket, a grantee principal, a permission, and a `grantedAt` timestamp.

| Permission | Allowed S3 operations |
| --- | --- |
| `ReadWrite` | List, read, write, and delete objects. |
| `ReadOnly` | List and read objects. |
| `WriteOnly` | List, write, and delete objects. |
| `None` | No access granted by this resource. |

`None` can remove an allow or create a deny, depending on the backend.
See [Backend differences](backend_differences.md#from-request-to-access).
Other cloud permissions can still provide access.

## Discoverable buckets

`spec.buckets[].discoverable` lets clients show a bucket to potential
requesters. It does not grant access or restrict grants. Peer lookup uses
this label on the Storage resource:

```yaml
metadata:
  labels:
    storages.pkg.internal/discoverable: "true"
```

AWS and MinIO look up the owner and check bucket ownership and its grant.
OTC and CloudFerro look up grantees to resolve their identities. Label both
Storages when sharing access. OTC builds policies from the owner's grants
and observed grantee IDs; a request does not change that policy.

## Request and grant access

This MinIO example gives `analyst` read-only access to `reports`. Both
Storages are in the same namespace. Set the timestamps when you record the
request and grant:

```yaml
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: reports-owner
  namespace: workspace
  labels:
    storages.pkg.internal/discoverable: "true"
spec:
  crossplane:
    compositionSelector:
      matchLabels:
        provider: minio
  principal: reporter
  buckets:
    - bucketName: reports
      discoverable: true
  bucketAccessGrants:
    - bucketName: reports
      grantee: analyst
      permission: ReadOnly
      grantedAt: "2026-01-01T12:05:00Z"
---
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: reports-reader
  namespace: workspace
  labels:
    storages.pkg.internal/discoverable: "true"
spec:
  crossplane:
    compositionSelector:
      matchLabels:
        provider: minio
  principal: analyst
  buckets: []
  bucketAccessRequests:
    - bucketName: reports
      reason: Read reports for analysis
      requestedAt: "2026-01-01T12:00:00Z"
```

Apply both resources after installation. The consumer Secrets are `reporter`
and `analyst` in `workspace`. To withdraw access, set the owner's grant to
`None` or remove it. Cloud policy changes take time to affect access.

A request has no permission field. Its reason can describe the desired
access, but the owner chooses the permission. Requests and grants remain on
the Storage resources for operators to inspect.

See the [examples](usage_concepts.md#examples) for complete
manifests. Verify both allowed and denied operations with consumer
credentials; a successful render does not prove cloud enforcement.
