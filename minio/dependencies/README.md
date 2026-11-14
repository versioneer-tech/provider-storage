# MinIO dependencies

These manifests configure the providers used by the `storage-minio`
Composition.

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
Apply the remaining manifests in the order given in the
[installation guide](../../docs/how-to-guides/installation.md#1-install-backend-dependencies).

Keep the `provider-minio` runtime configuration attached to the Provider.
The pinned provider logs credentials at Info level. The runtime uses
`--log-level=-1` to keep warnings and errors while it suppresses Info output.
Keep this setting until a provider without that defect is verified. Rotate
any credentials that appear in logs and review log retention.
