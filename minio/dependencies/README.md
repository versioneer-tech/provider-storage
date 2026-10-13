# MinIO dependencies

These manifests configure the providers used by the `storage-minio`
Composition.

Dedicated provider controllers in the cluster reconcile resources created by
the Composition. Use a separate MinIO credential for the controller and give
it only the permissions it needs. Keep the credential outside Git.

## Controller credential

MinIO does not use a cloud IAM bootstrap script. Create a dedicated controller
credential in MinIO and give it only the permissions needed to manage buckets,
users, and policies. Store the access key and secret key in separate local
files. Each file must contain only its credential value.

## Deployment

Create the namespace and the controller Secret referenced by
[`03-providerConfigs.yaml`](03-providerConfigs.yaml):

```bash
kubectl create namespace minio
kubectl create secret generic default-env-configuration \
  --namespace minio \
  --from-file=accesskey=<access-key-file> \
  --from-file=secretkey=<secret-key-file>
```

If the namespace already exists, omit the first command.

Set the MinIO endpoint and lifecycle schedule in
[`04-environmentConfigs.yaml`](04-environmentConfigs.yaml). If the endpoint,
namespace, or Secret name is different, update
[`03-providerConfigs.yaml`](03-providerConfigs.yaml) to match it.

Apply [`03-providerConfigs.yaml`](03-providerConfigs.yaml) in every namespace
that contains a MinIO `Storage` resource. The MinIO controller Secret can stay
in the `minio` namespace because the ProviderConfig refers to it explicitly.
The other dependency manifests are cluster-scoped. Apply the numbered
manifests in order, then apply [`functions.yaml`](functions.yaml) and
[`rbac.yaml`](rbac.yaml). Wait for all provider and function revisions to
become ready.
