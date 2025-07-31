# Tutorials: storage-minio

These tutorials offer a series of steps to install, run and deploy your first `Claim` for the `storage-minio` configuration package.

## Prerequisites

This tutorial assumes that you have [go](https://go.dev/), [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl) and [helm](https://helm.sh/docs/intro/install/) installed on your machine. Furthermore, we are using a local [kind](https://kind.sigs.k8s.io/) cluster for this tutorial. You can find installation instructions [here](https://kind.sigs.k8s.io/#installation-and-usage).

### `kind` cluster and `crossplane` installation

After you have installed the necessary tools, we can create a new cluster with

```bash
kind create cluster --name storage-minio
```

and check if everything is working with

```bash
kubectl get pods -A
```

If the cluster is up and running, we need to install Crossplane. You can find more information about the installation process [here](https://docs.crossplane.io/latest/software/install/).

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm install crossplane \
--namespace crossplane-system \
--create-namespace crossplane-stable/crossplane
```

### MinIO installation

In order to test the functionality of `storage-minio` we need a MinIO installation. For this tutorial we install MinIO into our cluster as well.

First, we need to install the `minio-operator`.

```bash
helm repo add minio-operator https://operator.min.io
helm install \
  --namespace minio-operator \
  --create-namespace \
  operator minio-operator/operator
```

Next, we need to install a `minio-tenant`. This is where our `Buckets`, `Policies` and `Users` actually live. Since this is only for testing, we will make the footprint of the tenant as small as possible by configuring the installation with a `values.yaml` file.

```yaml
# values.yaml

tenant:
  pools:
    - servers: 1
      name: pool-0
      volumesPerServer: 1
      size: 1Gi
  certificate:
    requestAutoCert: false
```

Now we can install the `minio-tenant` with

```bash
helm install \
  --values values.yaml \
  --namespace minio-tenant \
  --create-namespace \
  minio-tenant minio-operator/tenant
```

This concludes the prerequisites and we can finally isntall the `storage-minio` configuration package.

## `storage-minio` configuration package installation

In order to install the `storage-minio` configuration package, we first need to create a `Configuration`.

```yaml
# configuration.yaml

apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-minio
spec:
  package: ghcr.io/versioneer-tech/provider-storage:v0.1-minio
```

Then, we need to apply it to the cluster with

```bash
kubectl apply -f configuration.yaml
```

This automatically installs the necessary dependencies specified in the configuration package:

- [provider-minio](https://github.com/vshn/provider-minio) >= v0.4.4
- [provider-kubernetes](https://github.com/crossplane-contrib/provider-kubernetes) >= v0.18.0
- [function-auto-ready](https://github.com/crossplane-contrib/function-auto-ready) >= 0.5.0
- [function-go-templating](https://github.com/crossplane-contrib/function-go-templating) >= v0.10.0

You can check this by running

```bash
kubectl get pods -A
```

and confirm that you see pods name `crossplane-contrib-function-auto-ready-...`, `crossplane-contrib-provider-kubernetes-...`, etc. Furthermore, you should now see one `CompositeResourceDefinition` or `XRD` and one `Composition` with

```bash
kubectl get xrds
kubectl get compositions
```

The `storage-minio` configuration package is now installed. However, it is not functional yet since it does not install the necessary `ProviderConfigs`, `ServiceAccounts`, `ClusterRoles`, `ClusterRoleBindings` and `Secrets` that are needed by the `provider-minio` and `provider-kubernetes`.

### `provider-minio` configuration

For `storage-minio` to work, we need to configure the providers with a `ProviderConfig`.

Let's start with `provider-minio`. In order for the provider to know where to actually create the resources specified in the Crossplane composition, we need to provide it with connection details through a `ProviderConfig`.

Since we are using the MinIO instance installed in the cluster, we can forward the port for the web interface and create an API key.

```bash
kubectl port-forward pod/myminio-pool-0-0 -n minio-tenant 9090 9090
```

Navigate to `http://localhost:9090` and login with the username `minio` and `minio123`. Click on `Access Keys` and create a new access key.

Then we need to create a `Secret` with the new access keys for `provider-minio` to connect.

```yaml
# secret.yaml

apiVersion: v1
kind: Secret
metadata:
  name: storage-minio
  namespace: minio-tenant
stringData:
  AWS_ACCESS_KEY_ID: <Access Key>
  AWS_SECRET_ACCESS_KEY: <Secret Key>
```

```bash
kubectl apply -f secret.yaml
```

Finally, we can finish the setup for `provider-minio` by applying a `ProviderConfig` that references this secret.

```yaml
# minio-provider-config.yaml

apiVersion: minio.crossplane.io/v1
kind: ProviderConfig
metadata:
  name: storage-minio
  namespace: crossplane-system
spec:
  credentials:
    apiSecretRef:
      name: storage-minio
      namespace: minio-tenant
    source: InjectedIdentity
  minioURL: "http://myminio-hl.minio-tenant.svc.cluster.local:9000/"
```

```bash
kubectl apply -f minio-provider-config.yaml
```

That's it for `provider-minio`.

### `provider-kubernetes` configuration

The second provider needed for `storage-minio` is `provider-kubernetes`. Since we want to observe `Policies` created by `provider-minio`, we need to create a `ServiceAccount` for `provider-kubernetes` that actually has permissions to observe these resources.

The following file creates a `ServiceAccount`, `ClusterRole` and `ClusterRoleBinding` for those permissions.

```yaml
# rbac.yaml

---
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
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: storage-kubernetes
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: storage-kubernetes
subjects:
- kind: ServiceAccount
  name: storage-kubernetes
  namespace: crossplane-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: storage-kubernetes
  namespace: crossplane-system
```

```bash
kubectl apply -f rbac.yaml
```

Now we can update `provider-kubernetes` with a `DeploymentRuntimeConfig` to use this new `ServiceAccount`. Additionally, we provide the basic `ProviderConfig` needed by `provider-kubernetes`.

```yaml
# kubernetes-provider-config.yaml

---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: crossplane-contrib-provider-kubernetes
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.18.0
  runtimeConfigRef:
    apiVersion: pkg.crossplane.io/v1beta1
    kind: DeploymentRuntimeConfig
    name: storage-kubernetes
---
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata:
  name: storage-kubernetes
spec:
  serviceAccountTemplate:
    metadata:
      name: storage-kubernetes
---
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: storage-kubernetes
spec:
  credentials:
    source: InjectedIdentity
```

```bash
kubectl apply -f kubernetes-provider-config.yaml
```

That's it for `provider-kubernetes` and the complete installation of `storage-minio`! Now we can finally create our first claim and see the configuration package in action!

## Creating `Buckets` for Alice and Bob

Everything is up and running and we can create our first claim - or rather, our first claims! Let's assume that, by default, we need two buckets for every user of the platform. Therefore, we create two two buckets named `alice` and `alice-shared` for the user "Alice" and `bob` and `bob-shared` for the user "Bob".

```yaml
# claims.yaml

---
apiVersion: epca.eo/v1beta1
kind: Storage
metadata:
  name: alice
spec:
  owner: alice
  buckets:
    - bucketName: alice
    - bucketName: alice-shared
---
apiVersion: epca.eo/v1beta1
kind: Storage
metadata:
  name: bob
spec:
  owner: bob
  buckets:
    - bucketName: bob
    - bucketName: bob-shared
```

```bash
kubectl apply -f claims.yaml
```

## Requesting access to `Buckets` from Bob

Now that everyone has their buckets, Alice wants to have access to `bob-shared` since both are working on a project together and she needs access to his results. Since Alice also needs to upload her results to that bucket she needs `ReadWrite` access.

```yaml
# claims.yaml

---
apiVersion: epca.eo/v1beta1
kind: Storage
metadata:
  name: alice
spec:
  owner: alice
  buckets:
    - bucketName: alice
    - bucketName: alice-shared
  bucketAccessRequests:
    - bucketName: bob-shared
      permission: ReadWrite
---
apiVersion: epca.eo/v1beta1
kind: Storage
metadata:
  name: bob
spec:
  owner: bob
  buckets:
    - bucketName: bob
    - bucketName: bob-shared
```

```bash
kubectl apply -f claims.yaml
```

Note that the status of the `XStorage` object `alice-...` has changed to `READY: False` since the `alice.readwrite.bob-shared` policy does not exist yet and, therefore, cannot be attached to the user role.

```bash
kubectl get xstorages

# Output
NAME          SYNCED   READY   COMPOSITION        AGE
alice-d7kbk   True     False   provider-storage   13m
bob-2s79f     True     True    provider-storage   13m
```

```bash
kubectl describe users.minio.crossplane.io alice

# Output
Name:         alice
...
Status:
  At Provider:
    Policies:   alice.owner.alice,alice.owner.alice-shared
    Status:     enabled
    User Name:  alice
...
```

## Granting access to `Buckets` to Alice

Bob is the `owner` of `bob-shared` so he needs to grant Alice the `ReadWrite` permission to the bucket.

```yaml
# claims.yaml

---
apiVersion: epca.eo/v1beta1
kind: Storage
metadata:
  name: alice
spec:
  owner: alice
  buckets:
    - bucketName: alice
    - bucketName: alice-shared
  bucketAccessRequests:
    - bucketName: bob-shared
      permission: ReadWrite
---
apiVersion: epca.eo/v1beta1
kind: Storage
metadata:
  name: bob
spec:
  owner: bob
  buckets:
    - bucketName: bob
    - bucketName: bob-shared
  bucketAccessGrants:
    - bucketName: bob-shared
      permission: ReadWrite
      grantees:
        - alice
```

```bash
kubectl apply -f claims.yaml
```

Note that it can take up to two minutes until the new policy is observed and synced. The status of the `XStorage` object has changed back to `READY: True` since the `alice.readwrite.bob-shared` policy has been created (Bob granted access to Alice) and is now attached to the user role.

```bash
kubectl get xstorages

# Output
NAME          SYNCED   READY   COMPOSITION        AGE
alice-d7kbk   True     True    storage-minio      15m
bob-2s79f     True     True    storage-minio      15m
```

```bash
kubectl describe users.minio.crossplane.io alice

# Output
Name:         alice
...
Status:
  At Provider:
    Policies:   alice.owner.alice,alice.owner.alice-shared,alice.readwrite.bob-shared
    Status:     enabled
    User Name:  alice
...
```

## Conclusion

Congratulations! You have worked through the whole tutorial and have installed `storage-minio` and deployed your first claims. You should no be able to follow most of the **How-to guides** in the sidebar and look through the API definitions in the **Reference guides** and see what other options you can enable/disable in the claims.

We are always happy about feedback and suggestions on how to improve the documentation or `provider-storage` as a whole. Therefore, if you have trouble following the tutorial or find errors please open an issue on [GitHub](https://github.com/versioneer-tech/provider-storage/issues) and let us know about it!
