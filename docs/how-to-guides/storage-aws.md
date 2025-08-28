# How-to guides: storage-aws

The `storage-aws` configuration package allows the creation of S3-compatible `Buckets` on AWS and automatically creates `Policies` for permission control. Furthermore, `storage-aws` includes a workflow to request/grant access to `Buckets` from other `owners`.

## How-to guides

- [How to install the `storage-aws` configuration package](#how-to-install-the-storage-aws-configuration-package)

### How to install the `storage-aws` configuration package

The `storage-aws` configuration package can be installed like any other configuration package with

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-aws
spec:
  package: ghcr.io/versioneer-tech/provider-storage:<!version!>-aws
```

This automatically installs the necessary dependencies:

- [provider-aws-s3](https://github.com/crossplane-contrib/provider-upjet-aws) >= v2.0.0
- [provider-aws-iam](https://github.com/crossplane-contrib/provider-upjet-aws) >= v2.0.0
- [provider-kubernetes](https://github.com/crossplane-contrib/provider-kubernetes) >= v0.18.0
- [function-auto-ready](https://github.com/crossplane-contrib/function-auto-ready) >= 0.5.0
- [function-go-templating](https://github.com/crossplane-contrib/function-go-templating) >= v0.10.0
- [function-python](https://github.com/crossplane-contrib/function-python) >= v0.2.0

However, it does not install the necessary `ProviderConfigs`, `ServiceAccounts` and `Secrets` that are actually needed for the `storage-aws` to work.

The `provider-aws` needs credentials for AWS. Therefore, it needs a `Secret` which includes the access key and secret key.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: storage-aws
  namespace: crossplane-system
stringData:
  credentials: |
    [default]
    aws_access_key_id = <aws-access-key-id>
    aws_secret_access_key = <aws-secret-access-key>
```

Furthermore, the `ProviderConfig` needs to reference this secret.

!!! warning
    The name of the `ProviderConfig` needs to be `storage-aws`! The composition will not work with any other name and will not be able to create resources!

```yaml
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: storage-aws
spec:
  credentials:
    source: Secret
    secretRef:
      name: storage-aws
      namespace: crossplane-system
      key: credentials
```

The `provider-kubernetes` needs a `ServiceAccount` that can observe resources from `policies.iam.aws.upbound.io`. Below is an example `ClusterRole` which expands the default `ClusterRole` created by `crossplane-rbac`.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: storage-kubernetes
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
      - "*/finalizers"
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
      - "*"
  - apiGroups:
      - iam.aws.upbound.io
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
  package: xpkg.upbound.io/crossplane-contrib/provider-kubernetes:<version>
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

This is everything that is needed for the `storage-aws` configuration package to function properly.
