# How-to guides: general

All configuration packages in `provider-storage` allow the creation of S3-compatible `Buckets` and automatically create `Policies` for permission control. Furthermore, they include a workflow to request/grant access to `Buckets` from other `owners`.

## How-to guides

- [How to create `Buckets`](#how-to-create-buckets)
- [How to request access to `Buckets` from other `owners`](#how-to-request-access-to-buckets-from-other-owners)
- [How to grant access to `Buckets` to other `owners`](#how-to-grant-access-to-buckets-to-other-owners)

### How to create `Buckets`

In order to create buckets you need to specify the `owner` and the `bucketName`. Additionally, you can set the flag `discoverable` to true which adds an annotation `xstorages.pkg.internal/discoverable` to the bucket resource.

```yaml
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: <name>
  namespace: <namespace>
spec:
  owner: <owner>
  buckets:
    - bucketName: <bucketName>
    - bucketName: <bucketName>
      discoverable: true
```

### How to request access to `Buckets` from other `owners`

If an `owner` wants to request access to a bucket from another `owner` it can just be added to a claim by specifying the `bucketAccessRequests`. The permission can either be `ReadWrite` or `ReadOnly`.

```yaml
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: <name>
  namespace: <namespace>
spec:
  ...
  owner: <owner>
  bucketAccessRequests:
    - bucketName: <bucketName>
      permissions: <permission>
  ...
```

This creates a Kubernetes object with `provider-kubernetes` that observes if the `<owner>.<permission>.<bucketName>` exists. If the other `owner` has not granted access to the requested bucket yet (this means that the policy does not exist yet), the `XStorage` object will switch to `READY: False` and trigger the `crossplane` reconciliation loop which continuously checks if the policy exists.

If access is granted to the bucket, the policy is created and attached to the `User` object of the `owner`. This switches the status of the `XStorage` object back to `READY: True`.

### How to grant access to `Buckets` to other `owners`

It is possible to grant `owners` access to a bucket without them first requesting access. However, it is only attached to the user role if the user has requested access to it as well. Similarly to the requests, the claim can include `bucketAccessGrants` that grant permissions (`ReadWrite` or `ReadOnly`) to a bucket to a list of `grantees`.

```yaml
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: <name>
  namespace: <namespace>
spec:
  ...
  owner: <owner>
  bucketAccessGrants:
    - bucketName: <bucketName>
      permissions: <permission>
      grantees:
        - <grantee>
  ...
```

This creates the `<grantee>.<permission>.<bucketName>` policy so if the `grantee` request access to this bucket, they are automatically granted access.
