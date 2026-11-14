# CloudFerro dependencies

These manifests configure the providers used by the `storage-cloudferro`
Composition.

See [Cloud IAM bootstrap](../../docs/how-to-guides/cloud-iam-bootstrap.md#cloudferro)
for script installation, controller permissions, and project isolation.

## IAM bootstrap

CloudFerro projects are billing resources. Create and activate them first in
the [CREODIAS billing portal](https://creodias.docs.cloudferro.com/en/latest/accountmanagement/Accounts-and-Projects-Management.html),
and check their wallet and region settings. The bootstrap script does not
create projects.

Assign separate projects to teams that need isolated bucket access.

Use a project- or domain-scoped `v3token` login. The script derives and
verifies a domain-scoped token for project discovery, user operations, and
project role grants. Limit
`CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN` to the projects that the controller
must manage. Set the domain, authentication URL, region, controller name, and
target namespace. Then run:

```bash
bootstrap-iam.sh cloudferro configure
bootstrap-iam.sh cloudferro show
bootstrap-iam.sh cloudferro apply
bootstrap-iam.sh cloudferro verify
```

Keep the local controller credential file private and outside Git.

## Deployment

Set the CloudFerro endpoint, OpenStack region, and S3 signing region in the
default `storage` EnvironmentConfig in
[`04-environmentConfigs.yaml`](04-environmentConfigs.yaml).

Set `CROSSPLANE_CLOUDFERRO_NAMESPACE` to the target namespace. Create one
controller Secret for each selected project:

```bash
bootstrap-iam.sh cloudferro render-secrets |
  kubectl --context storage-cluster apply --server-side -f -
```

Replace `storage-cluster` with the deployment context. IAM `apply` prepares
cloud resources only. The Secret names use `cloudferro-project-<project-id>`
and the `config` key.

The Composition creates a project-scoped OpenStack `ProviderConfig` for each
`Storage`. Restrict who can set the project ID annotation and who can read the
controller Secrets.

Apply [`03-providerConfigs.yaml`](03-providerConfigs.yaml) in every namespace
that contains a CloudFerro `Storage` resource. Apply the remaining manifests
in the order given in the
[installation guide](../../docs/how-to-guides/installation.md#1-install-backend-dependencies).
