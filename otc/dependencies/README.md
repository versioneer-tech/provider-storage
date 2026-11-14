# OTC dependencies

These manifests configure the providers used by the `storage-otc`
Composition.

See [Cloud IAM bootstrap](../../docs/how-to-guides/cloud-iam-bootstrap.md#otc)
to install the script and check the required domain and project permissions.

## IAM bootstrap

Set `CROSSPLANE_OTC_DOMAIN_ID`, `CROSSPLANE_OTC_PROJECT_ID`, the region, the
target namespace, and any optional resource prefix or IAM names. Use the
bootstrap administrator login, then run:

```bash
bootstrap-iam.sh otc configure
bootstrap-iam.sh otc show
bootstrap-iam.sh otc apply
bootstrap-iam.sh otc verify
```

Keep the local credential file private and outside Git.

## Deployment

In [`03-providerConfigs.yaml`](03-providerConfigs.yaml), set the namespace that
contains `otc-provider-creds`. Set the OBS endpoint and region in
[`04-environmentConfigs.yaml`](04-environmentConfigs.yaml).

Set `CROSSPLANE_OTC_NAMESPACE` to that namespace and create the controller
Secret:

```bash
bootstrap-iam.sh otc render-secrets |
  kubectl --context storage-cluster apply --server-side -f -
```

Replace `storage-cluster` with the deployment context. The ProviderConfig's
Secret reference must match the rendered Secret name, namespace, and key.
For rotation, prepare the replacement, publish it with the same pipe, then
run `bootstrap-iam.sh otc complete-rotation`. See
[controller rotation](../../docs/how-to-guides/cloud-iam-bootstrap.md#rotate-controller-credentials).

Apply [`03-providerConfigs.yaml`](03-providerConfigs.yaml) in every namespace
that contains an OTC `Storage` resource. Apply the remaining manifests in the
order given in the
[installation guide](../../docs/how-to-guides/installation.md#1-install-backend-dependencies).
