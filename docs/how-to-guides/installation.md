# Provider Storage – Installation Guide

The `provider-storage` configuration packages let platform operators offer S3-compatible bucket self-service through Crossplane.
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

## Step 0 – Bootstrap the Cloud Identity

!!! danger "Required before cloud provider deployment"

    Before deployment, a cloud administrator must review the backend's
    `<cloud>/dependencies/iam.sh` script and any policy templates. A managed
    cloud backend needs a controller identity scoped to its cloud account,
    domain, or project. Complete that bootstrap before installing the
    backend's provider dependencies.
    The OVHcloud bootstrap needs the official `ovhcloud` CLI, `jq`, and an
    administrator session. Follow its [bootstrap README](https://github.com/versioneer-tech/provider-storage/blob/main/ovh/dependencies/README.md)
    and the
    [cloud IAM bootstrap guide](cloud-iam-bootstrap.md).

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

> Both AWS IAM modes require the runtime role ARN in the namespaced
> `ProviderConfig`. `bootstrap-user` also requires a Secret with the generated
> base credentials. `assume-role` uses the configured source for the existing
> trusted identity.

- [00-mrap.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/00-mrap.yaml) – Activate AWS S3/IAM Managed Resources.
- [01-deploymentRuntimeConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/01-deploymentRuntimeConfigs.yaml) – Runtime configs for AWS + Kubernetes providers.
- [02-providers.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/02-providers.yaml) – Install `provider-upjet-aws` and `provider-kubernetes`.
- [03-providerConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/03-providerConfigs.yaml) – **Configure for the selected IAM mode and apply in each `Storage` namespace**; both modes require the runtime role ARN, while `bootstrap-user` also requires the credentials Secret in that namespace.
- [04-environmentConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/04-environmentConfigs.yaml) – Backend settings consumed by the composition.
- [functions.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/functions.yaml) – Functions used by compositions.
- [rbac.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/rbac.yaml) – RBAC for `provider-kubernetes`.

### OTC

> You do **not** deploy OBS. Use the controller credentials created in Step 0
> for the Secret referenced by `ProviderConfig`.

- [00-mrap.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/00-mrap.yaml) – Activate OTC Managed Resources.
- [01-deploymentRuntimeConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/01-deploymentRuntimeConfigs.yaml) – Runtime configs for OTC + Kubernetes providers.
- [02-providers.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/02-providers.yaml) – Install OTC provider(s) and `provider-kubernetes`.
- [03-providerConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/03-providerConfigs.yaml) – **Apply in your target namespace**; references OTC credentials Secret.
- [04-environmentConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/04-environmentConfigs.yaml) – Backend settings consumed by the composition.
- [functions.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/functions.yaml) – Functions used by compositions.
- [rbac.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/rbac.yaml) – RBAC for `provider-kubernetes`.

### OVHcloud

Complete the
[OVHcloud controller bootstrap](https://github.com/versioneer-tech/provider-storage/blob/main/ovh/dependencies/README.md)
for the target Public Cloud project first. Its private JSON contains
`endpoint`, `client_id`, and `client_secret`.
Create `ovh-provider-creds` with a `credentials` key in every target
`Storage` namespace. The namespaced ProviderConfig references that Secret;
the administrator CLI login is separate and must not be used for it.
If you replace the Secret in a running cluster, restart the OVHcloud provider
Deployment so it uses the new controller credential.

- [00-mrap.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/ovh/dependencies/00-mrap.yaml) – Activate only the OVHcloud managed resource kinds used by the Composition.
- [01-deploymentRuntimeConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/ovh/dependencies/01-deploymentRuntimeConfigs.yaml) – Provider and function runtime settings.
- [02-providers.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/ovh/dependencies/02-providers.yaml) – Install the OVHcloud provider and `provider-kubernetes`.
- [03-providerConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/ovh/dependencies/03-providerConfigs.yaml) – Set the credential Secret namespace, then apply in each `Storage` namespace.
- [04-environmentConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/ovh/dependencies/04-environmentConfigs.yaml) – Set `data.storage.serviceName` to the exact project ID. The initial configuration uses Object Storage region `de` and endpoint `https://s3.de.io.cloud.ovh.net`; this is separate from the EU control-plane API region.
- [functions.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/ovh/dependencies/functions.yaml) – Composition functions.
- [rbac.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/ovh/dependencies/rbac.yaml) – `provider-kubernetes` permissions.

The [integration test guide](https://github.com/versioneer-tech/provider-storage/blob/main/tests/integration/README.md#ovhcloud)
shows the explicit-context Secret handoff and two-bucket integration run. Do
not apply the placeholder project ID in the EnvironmentConfig.

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

**Example – OVHcloud**

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-ovh
spec:
  package: ghcr.io/versioneer-tech/provider-storage/ovh:<!version!>
```

Apply your chosen one with:

```bash
kubectl apply -f configuration.yaml
```

### Selecting the Storage Environment

Each composition loads a Crossplane `EnvironmentConfig` named `storage` by default. To select a different environment, add the annotation or label `storages.pkg.internal/environment` to the `Storage` resource:

```yaml
metadata:
  annotations:
    storages.pkg.internal/environment: storage
```

This is the same hook used by higher-level workspace APIs to point new `Storage` resources at a specific provider-storage environment.

---

## Step 3 – (Optional) Quick Verification

After the package installs and providers are healthy, create a minimal `Storage` claim in your target namespace and verify readiness and credentials. For AWS, `Ready` stays `False` until the current credentials are observed and the consumer Secret is ready. See the **Usage & Concepts** guide for details (`kubectl get storages -n <ns>`, and inspect the Secret named after the principal).
