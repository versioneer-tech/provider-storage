# Installation

Install the dependencies and configuration package for your storage backend.

## Namespaces

Choose a target namespace before deployment.

- Apply `Storage` resources to the target namespace.
- Apply namespaced `ProviderConfig` resources in each Storage namespace.
- Create controller Secrets in the namespace named by the ProviderConfig's
  Secret reference. MinIO uses a separate `minio` namespace by default.
- Provider Storage creates the consumer Secret in the same namespace as its
  `Storage` resource. The Secret name is the principal name.

`EnvironmentConfig` and `Composition` resources are cluster-scoped.

For the examples in these guides, create `workspace`:

```bash
kubectl create namespace workspace
```

## Prerequisites

You need:

- a Kubernetes cluster;
- `kubectl` access to the cluster;
- Crossplane v2 installed in the cluster.

For example:

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane \
  --create-namespace \
  --set provider.defaultActivations={}
```

Each backend's `ManagedResourceActivationPolicy` lists the managed resource
types it uses. Selective activation requires a provider with `safe-start`
support; older providers activate all their types.

## 1. Install backend dependencies

For a cloud backend, install `bootstrap-iam.sh` and run `configure`, `apply`,
and `verify` as described in [Cloud IAM bootstrap](cloud-iam-bootstrap.md).
Choose where to run bootstrap: a specific host, a CI/CD pipeline, or a local
machine.
Compositions use a `ProviderConfig` to authenticate cloud API calls. For
static credentials, its `credentials.secretRef` must point to a controller
Secret. IAM `apply` creates the cloud identity and saves credentials locally.
Run `verify` and check its result before you render and deploy the Secret.
Then configure the ProviderConfig reference:

```bash
export CROSSPLANE_OVH_NAMESPACE=workspace
bootstrap-iam.sh ovh render-secrets |
  kubectl --context storage-cluster apply --server-side -f -
```

Replace `ovh`, its namespace variable, and `storage-cluster` for your backend
and deployment. The Secret name, namespace, and key must match the
ProviderConfig. See [Deploy controller Secrets](cloud-iam-bootstrap.md#deploy-controller-secrets)
for all four backends. AWS workload identity uses external trust instead of
a static controller Secret. CloudFerro needs a project ProviderConfig and
EnvironmentConfig before Storage reconciliation.

Follow the dependency guide for your backend to edit the manifests:

| Backend | Dependency guide |
| --- | --- |
| MinIO | [MinIO dependencies](https://github.com/versioneer-tech/provider-storage/blob/main/minio/dependencies/README.md) |
| AWS | [AWS dependencies](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/README.md) |
| OTC | [OTC dependencies](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/README.md) |
| OVHcloud | [OVHcloud dependencies](https://github.com/versioneer-tech/provider-storage/blob/main/ovh/dependencies/README.md) |
| CloudFerro | [CloudFerro dependencies](https://github.com/versioneer-tech/provider-storage/blob/main/cloudferro/dependencies/README.md) |

The dependency manifests use the same order for every backend:

| Manifest | Scope | Purpose |
| --- | --- | --- |
| `00-mrap.yaml` | Cluster | Activates the managed resource types used by the backend. |
| `01-deploymentRuntimeConfigs.yaml` | Cluster | Configures provider and function deployments. |
| `02-providers.yaml` | Cluster | Installs the providers. |
| `03-providerConfigs.yaml` | Cluster or namespace | Configures provider authentication. Apply namespaced configs in every Storage namespace. |
| `04-environmentConfigs.yaml` | Cluster | Defines endpoint, region, and backend settings. |
| `functions.yaml` | Cluster | Installs the Composition functions. |
| `rbac.yaml` | Cluster | Grants provider-kubernetes access and Crossplane access to native Secrets. |

Edit all placeholders before you apply a manifest. Apply the numbered files
in order, then apply `functions.yaml` and `rbac.yaml`.

Keep the ProviderConfig's cloud account or project consistent with the
EnvironmentConfig. The default environment name matches the backend package
name, such as `storage-aws` or `storage-minio`. An environment annotation is
needed only to override that name. CloudFerro's supplied project manifests
need this override to select a project. Manage shared functions and
provider-kubernetes once. See [Select a backend](usage_concepts.md#select-a-backend)
for environment and provider selection.

Consumer Secrets are native composed resources. A namespaced Storage can
compose these Secrets even when its cloud provider has only cluster-scoped
resources. Those cloud resources still need Object adapters. Crossplane
cannot compose a cluster-scoped resource directly from a namespaced Storage.
See [Crossplane resource scope](https://docs.crossplane.io/latest/whats-new/).

The provider-kubernetes runtime redacts Secret data from Object status.
Keep the MinIO runtime's [logging configuration](https://github.com/versioneer-tech/provider-storage/blob/main/minio/dependencies/README.md#deployment)
to prevent credentials from appearing in provider logs.

For cleanup scheduling and Job limits, see
[Lifecycle rules](usage_concepts.md#lifecycle-rules).

### Replace a Storage

A new Storage can adopt existing composed resources after the old Storage
releases them. Before replacing a Storage, prevent its source manifests from
creating it again. Delete the old Storage with Kubernetes orphan propagation
(`--cascade=orphan`) to keep its composed resources. Wait until the old
Storage is gone and its controller references are removed.

Create the replacement in the same namespace. Keep the backend, provider
configuration, project, region, principal, provider identity, and bucket names
the same. The Composition can then adopt resources with the same kind and
name. Preserve their external-name annotations and provider ownership markers.
Consumer Secrets and credentials can be recreated if needed.

Do not use a failed deletion of a non-empty bucket as a handover method. Its
managed resource can remain in deletion, which prevents reuse. The pinned
MinIO provider also rejects an existing bucket when a new Bucket resource
lacks its ownership marker. Keep the existing Bucket resource and its Object
adapter. Recreating managed resources from cloud resources requires
[provider-specific import](https://docs.crossplane.io/latest/guides/import-existing-resources/).

## 2. Install the configuration package

Install one Configuration package for each backend you need. Each package
contains its backend Composition and depends on
`ghcr.io/versioneer-tech/provider-storage/api` from the same release.
Crossplane installs that API package once. It owns the shared Storage XRD.
Only the selected backend Compositions are installed. Provider controllers,
functions, and credentials are installed separately in step 1. Use the same
release for all installed backend packages.

Keep dependency resolution enabled on the Configuration resources; this is
the default. Do not set `spec.skipDependencyResolution: true`.

For later upgrades of this package layout, update the existing API
Configuration to the target release, then update all backend Configurations.
Crossplane does not upgrade installed dependencies automatically by default.

Older backend packages own the XRD directly. Moving that ownership to the API
package needs a separate migration before upgrade. Do not delete the XRD or
its CRD: this can delete existing Storage resources. The ownership migration
is not provided here.

After the backend dependencies are ready, create a `Configuration` manifest.
Use the name and package for your backend:

| Backend | Name | Package |
| --- | --- | --- |
| MinIO | `storage-minio` | `ghcr.io/versioneer-tech/provider-storage/minio:<!version!>` |
| AWS | `storage-aws` | `ghcr.io/versioneer-tech/provider-storage/aws:<!version!>` |
| OTC | `storage-otc` | `ghcr.io/versioneer-tech/provider-storage/otc:<!version!>` |
| OVHcloud | `storage-ovh` | `ghcr.io/versioneer-tech/provider-storage/ovh:<!version!>` |
| CloudFerro | `storage-cloudferro` | `ghcr.io/versioneer-tech/provider-storage/cloudferro:<!version!>` |

Use the selected values in this manifest:

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: <configuration-name>
spec:
  package: <package>
```

Replace the placeholders with values from the table and your package
version. Save the manifest as `configuration.yaml`, then apply it:

```bash
kubectl apply -f configuration.yaml
```

Check that the configuration, providers, and functions are healthy:

```bash
kubectl get configurations,providers,functions
```

If the cluster has more than one Provider Storage Composition, each `Storage`
resource must select its backend explicitly. A selector is not needed when
only one compatible Composition is installed. See
[Select a backend](usage_concepts.md#select-a-backend).

## 3. Verify the installation

Use the [bucket example](https://github.com/versioneer-tech/provider-storage#readme)
in the target namespace. Set its selector to your installed backend.
Check that the Storage becomes ready and that its
consumer credentials permit the expected S3 operations. See
[Use Storage](usage_concepts.md) for backend selection, credential rollover,
lifecycle rules, and verification commands.

For cloud backends, keep the project, endpoint, and region in the
EnvironmentConfig consistent with the settings saved by `bootstrap-iam.sh`.
