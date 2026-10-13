# OTC dependencies

These manifests configure the providers used by the `storage-otc`
Composition.

Dedicated provider controllers in the cluster reconcile resources created by
the Composition. Give each `ProviderConfig` only the permissions it needs. Do
not use unrestricted administrator credentials. Read the
[OTC cloud IAM bootstrap guide](../../docs/how-to-guides/cloud-iam-bootstrap.md#otc)
for the permission model and safety details.

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
that contains an OTC `Storage` resource. The other dependency manifests are
cluster-scoped. Apply the numbered manifests in order, then apply
[`functions.yaml`](functions.yaml) and [`rbac.yaml`](rbac.yaml). Wait for all
provider and function revisions to become ready.
