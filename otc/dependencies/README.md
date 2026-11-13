# OTC dependencies

These manifests configure the providers used by the `storage-otc`
Composition.

See [Cloud IAM bootstrap](../../docs/how-to-guides/cloud-iam-bootstrap.md#otc)
for the required domain and project permissions.

## IAM bootstrap

Set `CROSSPLANE_OTC_DOMAIN_ID`, `CROSSPLANE_OTC_PROJECT_ID`, the region, the
target namespace, and any optional resource prefix or IAM names. Use the
bootstrap administrator login, then run:

```bash
otc/dependencies/iam.sh status
otc/dependencies/iam.sh apply
otc/dependencies/iam.sh verify
```

Keep the local credential file private and outside Git.

## Deployment

In [`03-providerConfigs.yaml`](03-providerConfigs.yaml), set the namespace that
contains `otc-provider-creds`. Set the OBS endpoint and region in
[`04-environmentConfigs.yaml`](04-environmentConfigs.yaml).

Set `CROSSPLANE_OTC_NAMESPACE` to that namespace and create the controller
Secret:

```bash
otc/dependencies/iam.sh render-secrets |
  kubectl apply -f -
```

After `rotate-credential`, run this command again to update the Secret.

Apply [`03-providerConfigs.yaml`](03-providerConfigs.yaml) in every namespace
that contains an OTC `Storage` resource. Apply the remaining manifests in the
order given in the
[installation guide](../../docs/how-to-guides/installation.md#1-install-backend-dependencies).
