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

Set `CROSSPLANE_CLOUDFERRO_NAMESPACE` to the target namespace and create the
controller Secrets:

```bash
bootstrap-iam.sh cloudferro render-secrets |
  kubectl --context storage-cluster apply --server-side -f -
```

Replace `storage-cluster` with the deployment context. IAM `apply` prepares
cloud resources only. Each project Secret uses the name
`cloudferro-project-<project-id>` and the `config` key.

For each project, copy [`03-providerConfigs.yaml`](03-providerConfigs.yaml)
and [`04-environmentConfigs.yaml`](04-environmentConfigs.yaml). Replace
`__CLOUDFERRO_PROJECT_ID__` and `__STORAGE_NAMESPACE__`, then set the endpoint,
OpenStack region, and S3 signing region. Apply the copies before the Storage.
Follow the [installation order](../../docs/how-to-guides/installation.md#1-install-backend-dependencies)
for the remaining dependencies.

The EnvironmentConfig defines `storage.projectId` and
`storage.providerConfigName`. The project ID must match `tenant_id` in the
referenced Secret. The ProviderConfig and Secret must exist in each Storage
namespace. Storages in one namespace can share the ProviderConfig.
EnvironmentConfigs are cluster-scoped.

Set `storages.pkg.internal/environment: storage-cloudferro-<project-id>` on
each Storage and select `provider: cloudferro`. Cross-project grants resolve
the grantee Storage's EnvironmentConfig and use its `storage.projectId`.
Restrict who can select or change project environments, change ProviderConfigs,
or read controller Secrets. The Composition still creates its internal AWS
ProviderConfig from generated S3 credentials for bucket policies.

On upgrade, create the project configuration first and set each Storage's
project environment selector. Keep the old project annotation until the
updated Composition is applied, then remove it. Keep project, principal,
bucket names, endpoint, and regions unchanged.

## Optional automation example

The [Kyverno policy](../kyverno/project-configs.yaml) and
[RBAC manifest](../kyverno/rbac.yaml) show how a deployment can generate
project configuration from Secrets named `cloudferro-project-<project-id>`.
Manual setup and tests do not need Kyverno.

Copy the example to the cluster's deployment source. Set
`__STORAGE_NAMESPACE__` to one trusted source namespace and check the endpoint,
regions, and Kyverno ServiceAccount binding. Apply RBAC before the policy,
after the provider CRDs are ready. Configure `provider-kubernetes` separately.
Use one source namespace for each shared EnvironmentConfig; create additional
namespaced ProviderConfigs separately.

The example processes existing Secrets and retains generated configuration
after Secret or policy removal. Policy edits do not update existing generated
configuration. Update credentials in place and remove project configuration
only after its Storages are deleted. See
[Kyverno generation](https://kyverno.io/docs/policy-types/cluster-policy/generate/).
