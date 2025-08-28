# Tutorials: storage-aws

These tutorials offer a series of steps to install, run and deploy your first `Claim` for the `storage-aws` configuration package. We are going to create buckets for Alice and Bob, two imaginary users. Then, Alice is going to request access to a bucket which is owned by Bob and in the last step Bob is going to grant access to Alice for this bucket.

## Prerequisites

This tutorial assumes that you have [go](https://go.dev/), [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl) and [helm](https://helm.sh/docs/intro/install/) installed on your machine. Furthermore, we are using a local [kind](https://kind.sigs.k8s.io/) cluster for this tutorial. You can find installation instructions [here](https://kind.sigs.k8s.io/#installation-and-usage).

### `kind` cluster and `crossplane` installation

After you have installed the necessary tools, we can create a new cluster with

```bash
kind create cluster --name storage-aws
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
--create-namespace crossplane-stable/crossplane \
--version 2.0.2 \
--set provider.defaultActivations={} \
--set args={"--enable-operations"}
```

In order to reduce the strain on the control plane nodes, we also apply a [ManagedResourceActivationPolicy](https://docs.crossplane.io/latest/managed-resources/managed-resource-activation-policies/) and only activate the resources we need.

```bash
# mrap.yaml

apiVersion: apiextensions.crossplane.io/v1alpha1
kind: ManagedResourceActivationPolicy
metadata:
  name: storage-aws
spec:
  activate:
  - buckets.s3.aws.upbound.io
  - accesskeys.iam.aws.upbound.io
  - policies.iam.aws.upbound.io
  - users.iam.aws.upbound.io
  - userpolicyattachments.iam.aws.upbound.io
  - objects.kubernetes.crossplane.io

```

```bash
kubectl apply -f mrap.yaml
```

## `storage-aws` configuration package installation

In order to install the `storage-aws` configuration package, we first need to create a `Configuration`.

```yaml
# configuration.yaml

apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-aws
spec:
  package: ghcr.io/versioneer-tech/provider-storage/aws:<!version!>
```

Then, we need to apply it to the cluster with

```bash
kubectl apply -f configuration.yaml
```

This automatically installs the necessary dependencies specified in the configuration package:

- [provider-aws-s3](https://github.com/crossplane-contrib/provider-upjet-aws) >= v2.0.0
- [provider-aws-iam](https://github.com/crossplane-contrib/provider-upjet-aws) >= v2.0.0
- [provider-kubernetes](https://github.com/crossplane-contrib/provider-kubernetes) >= v0.18.0
- [function-auto-ready](https://github.com/crossplane-contrib/function-auto-ready) >= 0.5.0
- [function-go-templating](https://github.com/crossplane-contrib/function-go-templating) >= v0.10.0
- [function-python](https://github.com/crossplane-contrib/function-python) >= v0.2.0

You can check this by running

```bash
kubectl get pods -A
```

and confirm that you see pods name `crossplane-contrib-function-auto-ready-...`, `crossplane-contrib-provider-kubernetes-...`, etc. Furthermore, you should now see one `CompositeResourceDefinition` or `XRD` and one `Composition` with

```bash
kubectl get xrds
kubectl get compositions
```

The `storage-aws` configuration package is now installed. However, it is not functional yet since it does not install the necessary `ProviderConfigs`, `ServiceAccounts`, `ClusterRoles`, `ClusterRoleBindings` and `Secrets` that are needed by the `provider-aws-s3`, `provider-aws-iam` and `provider-kubernetes`.

### `provider-aws-s3` and `provider-aws-iam` configuration

For `storage-aws` to work, we need to configure the providers with a `ProviderConfig`.

Let's start with `provider-aws-s3` and `provider-aws-iam`. In order for the provider to know where to actually create the resources specified in the Crossplane composition, we need to provide it with connection details through a `ProviderConfig`.

We need to create a `Secret` with the access keys for `provider-aws-s3` and `provider-aws-iam` to connect.

```yaml
# secret.yaml

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

```bash
kubectl apply -f secret.yaml
```

Finally, we can finish the setup for `provider-aws-s3` and `provider-aws-iam` by applying a `ProviderConfig` that references this secret.

```yaml
# aws-provider-config.yaml

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

```bash
kubectl apply -f aws-provider-config.yaml
```

That's it for `provider-aws-s3` and `provider-aws-iam`.

### `provider-kubernetes` configuration

The second provider needed for `storage-aws` is `provider-kubernetes`. Since we want to observe `Policies` created by `provider-aws-iam`, we need to create a `ServiceAccount` for `provider-kubernetes` that actually has permissions to observe these resources.

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

That's it for `provider-kubernetes` and the complete installation of `storage-aws`! Now we can finally create our first claim and see the configuration package in action!

## Creating `Buckets` for Alice and Bob

Everything is up and running and we can create our first claim - or rather, our first claims! Let's assume that, by default, we need two buckets for every user of the platform. Therefore, we create two two buckets named `alice` and `alice-shared` for the user "Alice" and `bob` and `bob-shared` for the user "Bob".

```yaml
# claims.yaml
---
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: alice
spec:
  owner: alice
  buckets:
    - bucketName: alice
    - bucketName: alice-shared
---
apiVersion: pkg.internal/v1beta1
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
apiVersion: pkg.internal/v1beta1
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
apiVersion: pkg.internal/v1beta1
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
kubectl get objects.kubernetes.crossplane.io

# Output
NAME                                         KIND     PROVIDERCONFIG       SYNCED   READY   AGE
policy-observer-alice.readwrite.bob-shared   Policy   storage-kubernetes   False            87s
```

## Granting access to `Buckets` to Alice

Bob is the `owner` of `bob-shared` so he needs to grant Alice the `ReadWrite` permission to the bucket.

```yaml
# claims.yaml
---
apiVersion: pkg.internal/v1beta1
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
apiVersion: pkg.internal/v1beta1
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
kubectl get objects.kubernetes.crossplane.io

# Output
NAME                                         KIND     PROVIDERCONFIG       SYNCED   READY   AGE
policy-observer-alice.readwrite.bob-shared   Policy   storage-kubernetes   False            87s
```

```bash
kubectl get userpolicyattachments.iam.aws.upbound.io

# Output
NAME                         SYNCED   READY   EXTERNAL-NAME                      AGE
alice.owner.alice            True     True    alice-20250815121642974900000002   13m
alice.owner.alice-shared     True     True    alice-20250815121642980400000004   13m
alice.readwrite.bob-shared   True     True    alice-20250815122824423600000005   2m4s
bob.owner.bob                True     True    bob-20250815121642978200000003     13m
bob.owner.bob-shared         True     True    bob-20250815121642972100000001     13m
```

## Conclusion

Congratulations! You have worked through the whole tutorial and have installed `storage-aws` and deployed your first claims. You should no be able to follow most of the **How-to guides** in the sidebar and look through the API definitions in the **Reference guides** and see what other options you can enable/disable in the claims.

We are always happy about feedback and suggestions on how to improve the documentation or `provider-storage` as a whole. Therefore, if you have trouble following the tutorial or find errors please open an issue on [GitHub](https://github.com/versioneer-tech/provider-storage/issues) and let us know about it!
