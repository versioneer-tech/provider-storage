# Dependencies

These manifests declare the dependencies required for the **`storage-otc`** Composition.
They set up the Crossplane runtime (providers, configs, and permissions) that the Storage resources rely on.

## Runtime prerequisites

- A Kubernetes cluster with Crossplane **v2.0.2+** installed and healthy.

## Providers and Functions

This Composition expects the following Crossplane components to be installed (versions are examples — pin to the versions you have validated):

- **Providers**
  - `provider-opentelekomcloud` (e.g., `xpkg.upbound.io/opentelekomcloud/provider-opentelekomcloud:v1.0.0`)
  - `provider-kubernetes` (e.g., `xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v1.3.1`)

- **Functions**
  - `crossplane-contrib-function-python`
  - `crossplane-contrib-function-auto-ready`

  > Pin exact versions (or digests) and upgrade intentionally.

## OTC notes

Before deployment, an OTC administrator must review and run [`iam.sh`](iam.sh).
See the
[cloud IAM bootstrap guide](../../docs/how-to-guides/cloud-iam-bootstrap.md#otc).

S3-compatible buckets are managed via **OTC OBS** using `provider-otc`. You must supply:
- OTC credentials referenced by the **`ProviderConfig`**.
- Backend defaults such as OBS endpoint and region in the **`EnvironmentConfig`** named `storage`.

The controller group has `Security Administrator` in the dedicated domain and
`OBS Administrator` for all existing and future projects. OTC's system-defined
permissions cannot be limited to a bucket prefix.

## Best practices

- **Order matters**. Create dependencies in sequence so that later objects can reference earlier ones and no unnecessary XRDs are activated.
- **Pin versions** of Providers/Functions by exact tag or digest and update them via PRs.
- **Manage secrets** securely (e.g., Sealed Secrets, External Secrets). Do not inline credentials in Git.
- **Health gates**: wait for `ProviderRevision` and `FunctionRevision` readiness before applying `ProviderConfig` / MRAP / XR.
