# OVHcloud dependencies

These manifests configure the providers used by the `storage-ovh`
Composition.

Dedicated provider controllers in the cluster reconcile resources created by
the Composition. Give each `ProviderConfig` only the permissions it needs. Do
not use unrestricted administrator credentials. Read the
[OVHcloud IAM bootstrap guide](../../docs/how-to-guides/cloud-iam-bootstrap.md#ovhcloud)
for the permission model and safety details.

## IAM bootstrap

Install the official `ovhcloud` CLI and `jq`, then run `ovhcloud login` outside
this repository. Set `CROSSPLANE_OVH_PROJECT_ID`, the API region, and the
target namespace. Then run:

```bash
ovh/dependencies/iam.sh status
ovh/dependencies/iam.sh apply
ovh/dependencies/iam.sh verify
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
ovh/dependencies/iam.sh render-secrets |
  kubectl apply -f -
```

Apply [`03-providerConfigs.yaml`](03-providerConfigs.yaml) in every namespace
that contains an OVHcloud `Storage` resource. The other dependency manifests
are cluster-scoped. Apply the numbered manifests in order, then apply
[`functions.yaml`](functions.yaml) and [`rbac.yaml`](rbac.yaml). Wait for all
provider and function revisions to become ready.
