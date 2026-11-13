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
requesters. It does not grant access. Compositions that find peer Storage
resources require this label on the owner:

```yaml
metadata:
  labels:
    storages.pkg.internal/discoverable: "true"
```

The Composition checks that the peer owns the bucket and has a grant for
the requester. OTC uses the owner's grants and observed grantee IDs to build
bucket policies; a request does not change that policy.

## Request and grant access

1. The requester adds `bucketName`, `requestedAt`, and an optional `reason`
   to `spec.bucketAccessRequests`.
2. The owner adds a matching grant with the chosen permission.
3. To withdraw the grant, the owner sets `None` or removes the grant. Cloud
   policy changes take time to affect access.

A request has no permission field. Its reason can describe the desired
access, but the owner chooses the permission. Requests and grants remain on
the Storage resources for operators to inspect.

See the [examples](usage_concepts.md#examples) for complete
manifests. Verify both allowed and denied operations with consumer
credentials; a successful render does not prove cloud enforcement.
