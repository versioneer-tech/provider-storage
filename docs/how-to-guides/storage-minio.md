# How-to guides: storage-minio

The `storage-minio` configuration package allows the creation of `buckets` on a [MinIO](https://min.io/) backend and automatically creates [Policies](https://min.io/docs/minio/linux/administration/identity-access-management/policy-based-access-control.html) for permission control. Furthermore, `storage-minio` includes a workflow to request/grant access to `buckets` from other `owners`.

## How-to guides

- [How to install the `storage-minio` configuration package](#how-to-install-the-storage-minio-configuration-package)
- [How to create `Buckets` with `storage-minio`](#how-to-create-buckets-with-storage-minio)
- [How to request access to `Buckets` from other `owners`](#how-to-request-access-to-buckets-from-other-owners)
- [How to grant access to `Buckets` to other `owners`](#how-to-grant-access-to-buckets-to-other-owners)

### How to install the `storage-minio` configuration package

The `storage-minio` configuration package can be installed like any other configuration package with

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-minio
spec:
  package: ghcr.io/versioneer-tech/provider-storage:v0.1-minio
```

This automatically installs the necessary dependencies:

- [provider-minio](https://github.com/vshn/provider-minio) >= v0.4.4
- [provider-kubernetes](https://github.com/crossplane-contrib/provider-kubernetes) >= v0.18.0
- [function-auto-ready](https://github.com/crossplane-contrib/function-auto-ready) >= 0.5.0
- [function-go-templating](https://github.com/crossplane-contrib/function-go-templating) >= v0.10.0

However, it does not install the necessary `ProviderConfigs`, `ServiceAccounts` and `Secrets` that are actually needed for the `storage-minio` to work.

The `provider-minio` needs to know how to access the MinIO instance and also needs credentials for it. Therefore, it needs a `Secret` which includes the access key and secret key.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <name>
  namespace: <namespace>
stringData:
  AWS_ACCESS_KEY_ID: <Access Key>
  AWS_SECRET_ACCESS_KEY: <Secret Key>
```

Furthermore, the `ProviderConfig` needs to reference this secret and also provide the URL for the MinIO instance.

!!! warning
    The name of the `ProviderConfig` needs to be `storage-minio`! The composition will not work with any other name and will not be able to create resources!

```yaml
apiVersion: minio.crossplane.io/v1
kind: ProviderConfig
metadata:
  name: storage-minio
  namespace: crossplane-system
spec:
  credentials:
    apiSecretRef:
      name: <secretName>
      namespace: <secretNamespace>
    source: InjectedIdentity
  minioURL: <url>
```

The `provider-kubernetes` needs a `ServiceAccount` that can observe resources from `policies.minio.crossplane.io`. Below is an example `ClusterRole` which expands the default `ClusterRole` created by `crossplane-rbac`.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: <name>
rules:
- apiGroups:
  - kubernetes.crossplane.io
  resources:
  - objects
  - objects/status
  - observedobjectcollections
  - observedobjectcollections/status
  - providerconfigs
  - providerconfigs/status
  - providerconfigusages
  - providerconfigusages/status
  verbs:
  - get
  - list
  - watch
  - update
  - patch
  - create
- apiGroups:
  - kubernetes.crossplane.io
  resources:
  - '*/finalizers'
  verbs:
  - update
- apiGroups:
  - coordination.k8s.io
  resources:
  - secrets
  - configmaps
  - events
  - leases
  verbs:
  - '*'
- apiGroups:
  - minio.crossplane.io
  resources:
  - policies
  verbs:
  - watch
  - get
```

When the `ClusterRole` is attached to the `ServiceAccount` via a `ClusterRoleBinding`, the actual `provider-kubernetes` can be updated with a `DeploymentRuntimeConfig` to use the newly created `ServiceAccount`. Furthermore, a standard `ProviderConfig` can be applied.

!!! warning
    Make sure that the `name` and version of the `Provider` matches the name of the Kubernetes provider that is already installed in your cluster! If it does not match, `crossplane` installs a new Kubernetes provider with the given name. The standard name is `crossplane-contrib-provider-kubernetes` if the provider was installed as part of the dependencies in the configuration package.

!!! warning
    The name of the `ProviderConfig` needs to be `storage-kubernetes`! The composition will not work with any other name and will not be able to observe resources!

```yaml

---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: <name>
spec:
  package: xpkg.crossplane.io/crossplane-contrib/provider-kubernetes:<version>
  runtimeConfigRef:
    apiVersion: pkg.crossplane.io/v1beta1
    kind: DeploymentRuntimeConfig
    name: <deploymenRuntimeConfigName>
---
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata:
  name: <name>
spec:
  serviceAccountTemplate:
    metadata:
      name: <serviceAccountName>
---
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: storage-kubernetes
spec:
  credentials:
    source: InjectedIdentity
```

This is everything that is needed for the `storage-minio` configuration package to function properly.

### How to create `Buckets` with `storage-minio`

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
