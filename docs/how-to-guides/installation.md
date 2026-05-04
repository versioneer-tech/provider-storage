# Provider Storage – Installation Guide

The `provider-storage` configuration packages let platform operators offer S3-compatible bucket self-service on **MinIO**, **AWS S3**, and **OTC OBS** using Crossplane.
Buckets, access policies, sharing, lifecycle rules, and credentials are declared through one namespaced `Storage` spec.

---

## Namespacing Model (Important)

Everything in this guide is **namespaced**:

- You **apply** `Storage` claims **to a namespace** (e.g., `workspace`).
- The **provisioned Secret lives in the same namespace** as the `Storage` claim (Secret name = **principal**).
- Any **namespaced ProviderConfigs** or supporting objects that the compositions depend on **must exist in that same target namespace** (e.g., `workspace`).

> In short: choose your target namespace (e.g., `workspace`), apply the provider configs there, and create your `Storage` claims in that namespace.

---

## Prerequisites

- A running Kubernetes cluster (e.g., `kind`, managed K8s).
- `kubectl` access.
- **Crossplane** installed in the cluster:

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane \
  --create-namespace \
  --version 2.0.2 \
  --set provider.defaultActivations={}
```

> To reduce control-plane load, we use a `ManagedResourceActivationPolicy` (MRAP) per backend so only the needed Managed Resources are active.

---

## Step 1 – Install Provider Dependencies (per backend)

All providers follow the same staged pattern you **must** install **before** the configuration package:

1. **ManagedResourceActivationPolicy** – activate only the resource kinds that are needed.
2. **Deployment Runtime Configs** – define how providers/functions run.
3. **Providers** – install the required Crossplane providers.
4. **ProviderConfigs** (namespaced) – point providers to endpoints/credentials in your target namespace.
5. **Functions** – install supporting Crossplane Functions.
6. **RBAC** – permissions for `provider-kubernetes` to observe and reconcile objects.

Repository root: <https://github.com/versioneer-tech/provider-storage/>

Install only the backend packages you want to offer as platform service classes. If you install multiple backends, label each `Storage` claim so Crossplane selects the intended composition.

### MinIO

> You operate the MinIO endpoint yourself. It can run in the same cluster, another cluster, or another data center. For a local `kind` setup, see [Local Setup](local_setup.md).

- [00-mrap.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/minio/dependencies/00-mrap.yaml) – Activate MinIO-specific Managed Resources.
- [01-deploymentRuntimeConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/minio/dependencies/01-deploymentRuntimeConfigs.yaml) – Runtime configs for providers/functions.
- [02-providers.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/minio/dependencies/02-providers.yaml) – Install `provider-minio` and `provider-kubernetes`.
- [03-providerConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/minio/dependencies/03-providerConfigs.yaml) – **Apply in your target namespace** (e.g., `workspace`); points to your MinIO endpoint/credentials.
- [04-environmentConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/minio/dependencies/04-environmentConfigs.yaml) – Backend settings consumed by the composition.
- [functions.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/minio/dependencies/functions.yaml) – Functions used by compositions.
- [rbac.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/minio/dependencies/rbac.yaml) – RBAC for `provider-kubernetes`.

### AWS

> You provide AWS endpoint configuration and credentials via a Secret referenced by a namespaced `ProviderConfig`.

- [00-mrap.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/00-mrap.yaml) – Activate AWS S3/IAM Managed Resources.
- [01-deploymentRuntimeConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/01-deploymentRuntimeConfigs.yaml) – Runtime configs for AWS + Kubernetes providers.
- [02-providers.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/02-providers.yaml) – Install `provider-upjet-aws` and `provider-kubernetes`.
- [03-providerConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/03-providerConfigs.yaml) – **Apply in your target namespace**; references AWS credentials Secret.
- [04-environmentConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/04-environmentConfigs.yaml) – Backend settings consumed by the composition.
- [functions.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/functions.yaml) – Functions used by compositions.
- [rbac.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/rbac.yaml) – RBAC for `provider-kubernetes`.

### OTC

> You do **not** deploy OBS. You provide OTC credentials via a Secret referenced by a namespaced `ProviderConfig`.

- [00-mrap.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/00-mrap.yaml) – Activate OTC Managed Resources.
- [01-deploymentRuntimeConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/01-deploymentRuntimeConfigs.yaml) – Runtime configs for OTC + Kubernetes providers.
- [02-providers.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/02-providers.yaml) – Install OTC provider(s) and `provider-kubernetes`.
- [03-providerConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/03-providerConfigs.yaml) – **Apply in your target namespace**; references OTC credentials Secret.
- [04-environmentConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/04-environmentConfigs.yaml) – Backend settings consumed by the composition.
- [functions.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/functions.yaml) – Functions used by compositions.
- [rbac.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/rbac.yaml) – RBAC for `provider-kubernetes`.

---

## Step 2 – Install the Configuration Package (after dependencies)

Once the provider dependencies are in place, install the configuration package for your chosen backend. This registers the `Storage` CRD and compositions and allows reconciliation because the providers and configs already exist.

**Example – MinIO**

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-minio
spec:
  package: ghcr.io/versioneer-tech/provider-storage/minio:<!version!>
```

**Example – AWS**

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-aws
spec:
  package: ghcr.io/versioneer-tech/provider-storage/aws:<!version!>
```

**Example – OTC**

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-otc
spec:
  package: ghcr.io/versioneer-tech/provider-storage/otc:<!version!>
```

Apply your chosen one with:

```bash
kubectl apply -f configuration.yaml
```

---

## Step 3 – (Optional) Quick Verification

After the package installs and providers are healthy, create a minimal `Storage` claim in your target namespace and verify readiness and credentials. See the **Usage & Concepts** guide for details (`kubectl get storages -n <ns>`, and inspect the Secret named after the principal).
