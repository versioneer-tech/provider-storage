# Provider Storage installation guide

Provider Storage lets platform operators offer S3-compatible storage through
Crossplane. Install the dependencies and configuration package for each
backend that you want to provide.

## Namespaces

Choose a target namespace before deployment.

- Apply `Storage` resources to the target namespace.
- Provider Secrets and namespaced `ProviderConfig` resources must use the
  target namespace.
- Provider Storage creates the consumer Secret in the same namespace as its
  `Storage` resource. The Secret name is the principal name.

`EnvironmentConfig` and `Composition` resources are cluster-scoped.

## Prerequisites

You need:

- a Kubernetes cluster;
- `kubectl` access to the cluster;
- Crossplane installed in the cluster.

For example:

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane \
  --create-namespace \
  --set provider.defaultActivations={}
```

Provider Storage supplies a `ManagedResourceActivationPolicy` for each
backend. It activates only the managed resource types that the backend uses.

## 1. Install backend dependencies

Choose a backend and follow its dependency guide. The guide contains the IAM
bootstrap, credential Secret, provider configuration, and deployment steps
for that backend.

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
| `03-providerConfigs.yaml` | Target namespace | Configures provider authentication. Apply it in every namespace that contains a `Storage` resource. |
| `04-environmentConfigs.yaml` | Cluster | Defines endpoint, region, and backend settings. |
| `functions.yaml` | Cluster | Installs the Composition functions. |
| `rbac.yaml` | Cluster | Grants the required provider-kubernetes access. |

Edit all placeholders before you apply a manifest. Apply the numbered files
in order, then apply `functions.yaml` and `rbac.yaml`.

Create the target namespace before you apply the namespaced ProviderConfigs.
For example:

```bash
kubectl create namespace <storage-namespace>
kubectl apply --namespace <storage-namespace> \
  -f <backend>/dependencies/03-providerConfigs.yaml
```

## 2. Install the configuration package

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

Replace `<configuration-name>` and `<package>` with values from the table.
Replace `<!version!>` with the package version that you want to install. Save
the manifest as `configuration.yaml`, then apply it:

```bash
kubectl apply -f configuration.yaml
```

Wait until the configuration, providers, and functions are ready.

If the cluster has more than one Provider Storage Composition, each `Storage`
resource must select its backend explicitly. A selector is not needed when
only one compatible Composition is installed. See
[Select a backend](usage_concepts.md#select-a-backend).

## 3. Verify the installation

Create a small `Storage` resource in the target namespace. Check that the
resource becomes ready and that Provider Storage creates its consumer Secret.
See [Usage and concepts](usage_concepts.md) for examples and verification
commands.
