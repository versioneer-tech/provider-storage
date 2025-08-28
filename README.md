# provider-storage
This repository offers a collection of different Crossplane Configuration Packages under the name `provider-storage`. The Configuration Packages provide a simple abstraction that creates S3-compatible buckets, controls access through Bucket/IAM Policies and creates API/Access Keys. Currently, we support the following backends: [MinIO](https://www.min.io/), [AWS](https://aws.amazon.com/), [Scaleway](https://www.scaleway.com/)

## Documentation
The [documentation](https://versioneer-tech.github.io/provider-storage/) includes tutorials and how-to guides to install and work with all Configuration Packages in `provider-storage`. Furthermore, it includes discussions about some of the inner workings of the different configuration packages and the reasoning behind the implementation details.

## Usage Notes
The different Configuration Packages are built for Crossplane v2.0 and make use of alpha features such as [Operations](https://docs.crossplane.io/latest/operations/). Therefore, the packages will not work without them.

```bash
helm install crossplane \
--namespace crossplane-system \
--create-namespace crossplane-stable/crossplane \
--version 2.0.2 \
--set provider.defaultActivations={} \
--set args={"--enable-operations"}
```

### Example Claims
We create buckets named `alice` and `alice-shared` for a user named `alice`. In the future, the `discoverable` field can be used e.g. to list the bucket in a catalog. This way other users know which buckets they can request access to.

```yaml
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: alice
spec:
  owner: alice
  buckets:
  - bucketName: alice
  - bucketName: alice-shared
    discoverable: true
```

In order to request access to the bucket `bob-shared` which is owned by the user `bob`, we can add the bucket name to `bucketAccessRequests`. We can request either `ReadWrite` or `ReadOnly` permissions.

```yaml
---
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: alice
  namespace: alice
spec:
  owner: alice
  buckets:
  - bucketName: alice
  - bucketName: alice-shared
    discoverable: true
  bucketAccessRequests:
  - bucketName: bob-shared
    permission: ReadWrite
---
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: bob
  namespace: bob
spec:
  owner: bob
  buckets:
  - bucketName: bob
  - bucketName: bob-shared
    discoverable: true
```

The user `bob` can now decide to grant `alice` access to `bob-shared` by referencing her explicitly in `bucketAccessGrants`.

```yaml
---
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: alice
  namespace: alice
spec:
  owner: alice
  buckets:
  - bucketName: alice
  - bucketName: alice-shared
    discoverable: true
  bucketAccessRequests:
  - bucketName: bob-shared
    permission: ReadWrite
---
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: bob
  namespace: bob
spec:
  owner: bob
  buckets:
  - bucketName: bob
  - bucketName: bob-shared
    discoverable: true
  bucketAccessGrants:
  - bucketName: bob-shared
    permission: ReadWrite
    grantees:
    - alice
```

## Getting Help

The best way to get help and ask questions is by simply an issue on [GitHub](https://github.com/versioneer-tech/provider-storage/issues).

