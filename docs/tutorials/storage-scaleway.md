# Tutorials: storage-scaleway

These tutorials offer a series of steps to install, run and deploy your first `Claim` for the `storage-scaleway` configuration package. We are going to create buckets for Alice and Bob, two imaginary users. Then, Alice is going to request access to a bucket which is owned by Bob and in the last step Bob is going to grant access to Alice for this bucket.

## Prerequisites

This tutorial assumes that you have [go](https://go.dev/), [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl) and [helm](https://helm.sh/docs/intro/install/) installed on your machine. Furthermore, we are using a local [kind](https://kind.sigs.k8s.io/) cluster for this tutorial. You can find installation instructions [here](https://kind.sigs.k8s.io/#installation-and-usage).

### `kind` cluster and `crossplane` installation

After you have installed the necessary tools, we can create a new cluster with

```bash
kind create cluster --name storage-scaleway
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
--version 2.0.2
```

## `storage-scaleway` configuration package installation

In order to install the `storage-scaleway` configuration package, we first need to create a `Configuration`.

```yaml
# configuration.yaml

apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-scaleway
spec:
  package: ghcr.io/versioneer-tech/provider-storage:<!version!>-scaleway
```

Then, we need to apply it to the cluster with

```bash
kubectl apply -f configuration.yaml
```

This automatically installs the necessary dependencies specified in the configuration package:

- [provider-scaleway](https://github.com/scaleway/crossplane-provider-scaleway) >= v0.4.0
- [function-auto-ready](https://github.com/crossplane-contrib/function-auto-ready) >= 0.5.0
- [function-go-templating](https://github.com/crossplane-contrib/function-go-templating) >= v0.10.0
- [function-python](https://github.com/crossplane-contrib/function-python) >= v0.2.0

You can check this by running

```bash
kubectl get pods -A
```

and confirm that you see pods name `crossplane-contrib-function-auto-ready-...`, `scaleway-provider-scaleway-...`, etc. Furthermore, you should now see one `CompositeResourceDefinition` or `XRD` and one `Composition` with

```bash
kubectl get xrds
kubectl get compositions
```

The `storage-scaleway` configuration package is now installed. However, it is not functional yet since it does not install the necessary `ProviderConfig` and `Secret` that are needed by `provider-scaleway`.

### `provider-scaleway` configuration

In order for the provider to know where to actually create the resources specified in the Crossplane composition, we need to provide it with connection details through a `ProviderConfig`.

We need to create a `Secret` with the access keys for `provider-scaleway`.

Copy the output of the above command into the secret and apply it to the cluster.

```yaml
# secret.yaml

apiVersion: v1
kind: Secret
metadata:
  name: storage-scaleway
  namespace: crossplane-system
type: Opaque
stringData:
  credentials: |
    {
      "access_key": "<scaleway-access-key-id>",
      "secret_key": "<scaleway-secret-access-key>",
      "organization_id": "<scaleway-organization-id>",
      "user_id": "<scaleway-user-id>",
      "region": "fr-par",
      "zone": "fr-par-1"
    }
```

```bash
kubectl apply -f secret.yaml
```

!!! warning
    In the README for `provider-scaleway`, the `user_id` is not present but it is essential for `storage-scaleway` to work! This is the user ID of the user/application associated with the `access_key`.

Finally, we can finish the setup for `provider-scaleway`by applying a `ProviderConfig` that references this secret.

```yaml
# scaleway-provider-config.yaml

apiVersion: scaleway.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: storage-scaleway
spec:
  credentials:
    source: Secret
    secretRef:
      name: storage-scaleway
      namespace: crossplane-system
      key: credentials
```

```bash
kubectl apply -f scaleway-provider-config.yaml
```

That's it for `provider-scaleway`.

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

The `application_id` of `alice` is now attached to the policy.

```bash
kubectl describe policies.object.scaleway.upbound.io bob-shared

# Output
spec:
  Deletion Policy:  Delete
  For Provider:
    Bucket:  storage-scaleway-bob-shared-p-s
    Policy:  {
  "Version": "2023-04-17",
  "Statement": [
  ...
    {
      "Effect": "Allow",
      "Principal": {
        "SCW": [
          "application_id:dcff9178-bc0b-4da6-87ea-6cccae757dec"
        ]
      },
      "Action": [
        "s3:ListBucket",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "storage-scaleway-bob-shared-p-s",
        "storage-scaleway-bob-shared-p-s/*"
      ]
    }
  ...
```

## Conclusion

Congratulations! You have worked through the whole tutorial and have installed `storage-scaleway` and deployed your first claims. You should no be able to follow most of the **How-to guides** in the sidebar and look through the API definitions in the **Reference guides** and see what other options you can enable/disable in the claims.

We are always happy about feedback and suggestions on how to improve the documentation or `provider-storage` as a whole. Therefore, if you have trouble following the tutorial or find errors please open an issue on [GitHub](https://github.com/versioneer-tech/provider-storage/issues) and let us know about it!
