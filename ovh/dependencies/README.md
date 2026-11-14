# OVHcloud dependencies

These manifests configure the providers used by the `storage-ovh`
Composition.

See [Cloud IAM bootstrap](../../docs/how-to-guides/cloud-iam-bootstrap.md#ovhcloud)
to install the script and check service-account permissions and project scope.

## IAM bootstrap

Install the official `ovhcloud` CLI and `jq`, then run `ovhcloud login` outside
this repository. Set `CROSSPLANE_OVH_PROJECT_ID`, the API region, Object Storage region, and the
target namespace. Then run:

```bash
bootstrap-iam.sh ovh configure
bootstrap-iam.sh ovh show
bootstrap-iam.sh ovh apply
bootstrap-iam.sh ovh verify
```

Keep the local controller credential file private and outside Git. Do not use
`~/.ovh.conf` as its path.

## Deployment

In [`03-providerConfigs.yaml`](03-providerConfigs.yaml), set the namespace that
contains `ovh-provider-creds`. Set the exact project ID, Object Storage region,
and S3 endpoint in
[`04-environmentConfigs.yaml`](04-environmentConfigs.yaml).

Set `CROSSPLANE_OVH_NAMESPACE` to that namespace and create the controller
Secret:

```bash
bootstrap-iam.sh ovh render-secrets |
  kubectl --context storage-cluster apply --server-side -f -
```

Replace `storage-cluster` with the deployment context. The ProviderConfig's
Secret reference must use `ovh-provider-creds`, the selected namespace, and
the `credentials` key. IAM `apply` prepares cloud resources only.

Apply [`03-providerConfigs.yaml`](03-providerConfigs.yaml) in every namespace
that contains an OVHcloud `Storage` resource. Apply the remaining manifests in
the order given in the
[installation guide](../../docs/how-to-guides/installation.md#1-install-backend-dependencies).
