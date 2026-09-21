# Dependencies

These manifests declare the dependencies required for the **`storage-aws`** Composition.  
They set up the Crossplane runtime (providers, configs, and permissions) that the Storage resources rely on.

## Runtime prerequisites

- A Kubernetes cluster with Crossplane **v2.x** installed and healthy. The e2e tests use **v2.4.1**.

## Providers and Functions

This Composition expects the following Crossplane components to be installed (versions are examples — pin to the versions you have validated):

- **Providers**
  - `provider-aws-s3` (e.g., `xpkg.upbound.io/upbound/provider-aws-s3:v2.7.2`)
  - `provider-aws-iam` (e.g., `xpkg.upbound.io/upbound/provider-aws-iam:v2.7.2`)
  - `provider-family-aws` (e.g., `xpkg.upbound.io/upbound/provider-family-aws:v2.7.2`)
  - `provider-kubernetes` (e.g., `xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v1.3.1`)

- **Functions**
  - `crossplane-contrib-function-python`  
  - `crossplane-contrib-function-auto-ready`

  > Pin exact versions (or digests) and upgrade intentionally.

## AWS notes

Before deployment, an AWS administrator must review and run [`iam.sh`](iam.sh)
and its [policy templates](policies) as described in the
[cloud IAM bootstrap guide](../../docs/how-to-guides/cloud-iam-bootstrap.md#aws).

S3 buckets are managed via **AWS** using `provider-aws`. Both IAM modes require
the runtime role ARN in the **`ProviderConfig`**. `bootstrap-user` also requires
the generated credential file to be stored as a Kubernetes Secret;
`assume-role` uses the configured source for its existing trusted identity.
The runtime policy limits resource changes to the managed IAM paths and the
configured S3 bucket prefix. The bootstrap user can only assume that role.

You must also supply:

- A reachable AWS endpoint.
- Backend defaults such as region in the **`EnvironmentConfig`** named `storage`.

## Best practices

- **Order matters**. Create dependencies in sequence so that later objects can reference earlier ones and no unnecessary XRDs are activated.
- **Pin versions** of Providers/Functions by exact tag or digest and update them via PRs.
- **Manage secrets** securely (e.g., Sealed Secrets, External Secrets). Do not inline credentials in Git.
- **Health gates**: wait for `ProviderRevision` and `FunctionRevision` readiness before applying `ProviderConfig` / MRAP / XR.
