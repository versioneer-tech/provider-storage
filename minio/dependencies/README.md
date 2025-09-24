# Dependencies

These manifests declare the dependencies required for the **`storage-minio`** Composition.  
They set up the Crossplane runtime (providers, configs, and permissions) that the Storage resources rely on.

## Runtime prerequisites

- A Kubernetes cluster with Crossplane **v2.0.2+** installed and healthy.
- **MinIO** installed in the cluster. This Composition targets that runtime and was tested with the MinIO **Operator** (chart: `operator`, version: **7.1.1**). Installation instructions are available at: https://github.com/minio/operator  
  A vendored installation profile for convenience will be published here *(coming soon)*.
- Cluster DNS/ingress/TLS as appropriate for your environment.

## Providers and Functions

This Composition expects the following Crossplane components to be installed (versions are examples — pin to the versions you have validated):

- **Providers**
  - `provider-minio` (e.g., `xpkg.upbound.io/crossplane-contrib/provider-minio:v0.4.4`)
  - `provider-kubernetes` (e.g., `xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v1.0.0`)

- **Functions**
  - `crossplane-contrib-function-python`  
  - `crossplane-contrib-function-auto-ready`

  > Pin exact versions (or digests) and upgrade intentionally.

## MinIO notes

S3 buckets are managed via **MinIO** using `provider-minio`. You must supply:
- A reachable MinIO endpoint and credentials (referenced by the **`ProviderConfig`**).

## Best practices

- **Order matters**. Create dependencies in sequence so that later objects can reference earlier ones and no unnecessary XRDs are activated.
- **Pin versions** of Providers/Functions by exact tag or digest and update them via PRs.
- **Manage secrets** securely (e.g., Sealed Secrets, External Secrets). Do not inline credentials in Git.
- **Health gates**: wait for `ProviderRevision` and `FunctionRevision` readiness before applying `ProviderConfig` / MRAP / XR.
