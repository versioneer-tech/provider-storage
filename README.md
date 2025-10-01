# Storage Provider

This package provides the **Storage** Composite Resource Definition (XRD) and ready-to-use Crossplane v2 Compositions to provision S3-compatible storage for users and teams.  
It abstracts bucket creation, access policies, and cross-user sharing into a single spec.

The following S3 compatible storage systems are supported:
- MinIO (since 0.1)
- AWS S3 (since 0.1)
- OTC OBS (since 0.1)
- Scaleway (coming soon)

✨ For a full introduction, see the [documentation](https://versioneer-tech.github.io/provider-storage/).

## API Reference

The published XRD with all fields is documented here:  
👉 [API Reference Guide](https://versioneer-tech.github.io/provider-storage/latest/reference-guides/api/)

## Install the Configuration Package

Install the configuration package into your cluster. Providers and functions should typically be managed by your GitOps process.

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage
spec:
  package: ghcr.io/versioneer-tech/provider-storage/<minio|aws|otc|...>:<x.x>
  skipDependencyResolution: true
```

## Storage Spec

### Minimal example

# Quickstart Example

Just apply the following to your Kubernetes cluster:

```yaml
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: team-wonderland
spec:
  principal: alice
  buckets:
    - bucketName: wonderland
```

This will provision a bucket named **`wonderland`**, along with the required cloud-specific entities such as IAM users, access credentials, and bucket policies.

A Kubernetes Secret is automatically created in the same namespace. From this Secret you can read the connection information and then use standard S3 tooling, for example:

```bash
aws s3 ls s3://wonderland
```

### More examples

See the [`examples`](examples/base) for complete scenarios, including:
- Storage claims with multiple buckets
- Access requests to other buckets (`bucketAccessRequests`)
- Access grants for own buckets (`bucketAccessGrants`)

> Note: When multiple configuration packages are installed (for example, to provision both **MinIO** and **AWS**), the `Storage` claim must be labeled so it is matched with the correct provider.

For example:
```bash
kubectl get storage -A -o name \
| xargs -I{} kubectl patch {} --type='merge' \
  -p '{"spec":{"crossplane":{"compositionSelector":{"matchLabels":{"provider":"minio"}}}}}'
```

## Storage Credentials

For each `Storage` resource, the provider automatically provisions a Kubernetes Secret in the same namespace.  
The Secret has the same name as the `Storage` resource (e.g. `ws-alice`) and contains S3-compatible access credentials.

The key names differ by provider:

MinIO, AWS:
- `AWS_ACCESS_KEY_ID`  
- `AWS_SECRET_ACCESS_KEY`

OTC:
- `attribute.access`  
- `attribute.secret`

> Note: While harmonization is being considered, we currently recommend using tooling like the [External Secret Operator](https://external-secrets.io) to transform if needed.

Workloads and other compositions can mount or reference this Secret directly to authenticate against the provisioned storage backend.

## License

Apache 2.0 (Apache License Version 2.0, January 2004)  
<https://www.apache.org/licenses/LICENSE-2.0>
