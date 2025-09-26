# Dependencies

These manifests declare the dependencies required for the **`storage-aws`** Composition.  
They set up the Crossplane runtime (providers, configs, and permissions) that the Storage resources rely on.

## Runtime prerequisites

- A Kubernetes cluster with Crossplane **v2.0.2+** installed and healthy.

## Providers and Functions

This Composition expects the following Crossplane components to be installed (versions are examples — pin to the versions you have validated):

- **Providers**
  - `provider-aws-s3` (e.g., `xpkg.upbound.io/upbound/provider-aws-s3:v2.1.0`)
  - `provider-aws-iam` (e.g., `xpkg.upbound.io/upbound/provider-aws-iam:v2.1.0`)
  - `provider-kubernetes` (e.g., `xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v1.0.0`)

- **Functions**
  - `crossplane-contrib-function-python`  
  - `crossplane-contrib-function-auto-ready`

  > Pin exact versions (or digests) and upgrade intentionally.

## AWS notes

S3 buckets are managed via **AWS** using `provider-aws`. You must supply:
- A reachable AWS endpoint and credentials (referenced by the **`ProviderConfig`**).

## Best practices

- **Order matters**. Create dependencies in sequence so that later objects can reference earlier ones and no unnecessary XRDs are activated.
- **Pin versions** of Providers/Functions by exact tag or digest and update them via PRs.
- **Manage secrets** securely (e.g., Sealed Secrets, External Secrets). Do not inline credentials in Git.
- **Health gates**: wait for `ProviderRevision` and `FunctionRevision` readiness before applying `ProviderConfig` / MRAP / XR.
