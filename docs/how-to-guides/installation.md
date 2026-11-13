# Installation

Install the dependencies and configuration package for each storage backend.

## Namespaces

Choose a target namespace before deployment.

- Apply `Storage` resources to the target namespace.
- Apply namespaced `ProviderConfig` resources in each Storage namespace.
- Create controller Secrets in the namespace named by the ProviderConfig's
  Secret reference. MinIO uses a separate `minio` namespace by default.
- Provider Storage creates the consumer Secret in the same namespace as its
  `Storage` resource. The Secret name is the principal name.

`EnvironmentConfig` and `Composition` resources are cluster-scoped.

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

Follow the dependency guide for your backend to prepare controller
credentials and edit the manifests:

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

Lifecycle Jobs have a one-hour deadline and two retries by default. Adjust
these limits in the backend EnvironmentConfig when needed. See
[Lifecycle rules](usage_concepts.md#lifecycle-rules).

## 2. Install the configuration package

Each backend package includes the shared Storage XRD. Use one backend package
per cluster; two active packages cannot own the same XRD.

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

Create a small `Storage` resource in the target namespace. Check that the
resource becomes ready and that Provider Storage creates its consumer Secret.
See [Use Storage](usage_concepts.md) for examples and verification
commands.
