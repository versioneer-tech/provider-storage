# CloudFerro dependencies

These manifests configure the providers used by the `storage-cloudferro`
Composition.

Dedicated provider controllers in the cluster reconcile resources created by
the Composition. Give each `ProviderConfig` only the permissions it needs. Do
not use unrestricted administrator credentials. Read the
[CloudFerro IAM bootstrap guide](../../docs/how-to-guides/cloud-iam-bootstrap.md#cloudferro)
for the permission model and safety details.

## IAM bootstrap

CloudFerro projects are billing resources. Create and activate them first in
the [CREODIAS billing portal](https://creodias.docs.cloudferro.com/en/latest/accountmanagement/Accounts-and-Projects-Management.html),
and check their wallet and region settings. The bootstrap script does not
create projects.

Each project is also the access boundary for its buckets. Create every project
that Provider Storage needs before bootstrap, and assign one project to each
team that needs isolated bucket access.

Use a project- or domain-scoped `v3token` login. The script derives and
verifies a domain-scoped token for project discovery, user operations, and
project role grants. Limit
`CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN` to the projects that the controller
must manage. Set the domain, authentication URL, region, controller name, and
target namespace. Then run:

```bash
cloudferro/dependencies/iam.sh status
cloudferro/dependencies/iam.sh apply
cloudferro/dependencies/iam.sh verify
```

Keep the local controller credential file private and outside Git.

## Deployment

Set the CloudFerro endpoint, OpenStack region, and S3 signing region in the
default `storage` EnvironmentConfig in
[`04-environmentConfigs.yaml`](04-environmentConfigs.yaml).

Set `CROSSPLANE_CLOUDFERRO_NAMESPACE` to the target namespace. Create one
controller Secret for each selected project:

```bash
cloudferro/dependencies/iam.sh render-secrets |
  kubectl apply -f -
```

The Secret names use `cloudferro-project-<project-id>`.

The Composition creates a project-scoped OpenStack `ProviderConfig` for each
`Storage`. Restrict who can set the project ID annotation and who can read the
controller Secrets.

Apply [`03-providerConfigs.yaml`](03-providerConfigs.yaml) in every namespace
that contains a CloudFerro `Storage` resource. The other dependency manifests
are cluster-scoped. Apply the numbered manifests in order, then apply
[`functions.yaml`](functions.yaml) and [`rbac.yaml`](rbac.yaml). Wait for all
provider and function revisions to become ready.
