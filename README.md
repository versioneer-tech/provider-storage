# Storage Provider

**Provider Storage is a PaaS-style building block for platform operators:** it turns one `Storage` claim into end-user object-storage buckets on MinIO, AWS S3, or OTC OBS. Users get smooth self-service bucket provisioning. Operators keep visibility and control over provider credentials, backend choice, access policy, sharing, lifecycle rules, and credential rotation.

This package provides the **Storage** Composite Resource Definition (XRD) and ready-to-use Crossplane v2 Compositions for object-storage bucket provisioning.

## The Goal

Give platform operators one simple API for bucket self-service. Teams should not need to know the details of MinIO, AWS IAM, OTC OBS policies, or provider-specific credentials just to get a bucket.

As the operator, you install the backend-specific configuration package, configure provider credentials, and decide which object-storage systems are available. A `Storage` claim can then create buckets, issue normalized S3 credentials, and describe access requests or grants.

The API stays the same across all supported backends. Buckets, credentials, access requests, access grants, and lifecycle rules are the same concepts for MinIO, AWS S3, and OTC OBS. Only the implementation behind the composition changes.

Provider Storage currently supports:

- MinIO
- AWS S3
- OTC OBS

Each `Storage` claim is the contract for one principal, usually a user, service account, team, or workspace. It records the buckets owned by that principal, which buckets are discoverable, which access was requested, which access was granted, and how credentials should rotate.

Other platform building blocks and workloads can consume the generated Kubernetes Secret directly. For example, a Datalab can use the Secret to mount object-storage access into an end-user workspace.

✨ For a full introduction, see the [documentation](https://versioneer-tech.github.io/provider-storage/).

For local setup and MinIO end-to-end testing, see the [local setup guide](https://versioneer-tech.github.io/provider-storage/latest/how-to-guides/local_setup/).

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

This creates a bucket named **`wonderland`**, plus the backend-specific resources needed for access, such as users, credentials, and bucket policies.

A Kubernetes Secret is created in the same namespace. It exposes normalized S3 credentials for workloads and other platform building blocks:

```bash
aws s3 ls s3://wonderland
```

### More examples

See the [`examples`](examples/base) for complete scenarios, including:
- Storage claims with multiple buckets
- Access requests to other buckets (`bucketAccessRequests`)
- Access grants for own buckets (`bucketAccessGrants`)
- Bucket lifecycle rules (`lifecycleRules`)

> Note: When multiple configuration packages are installed (for example, to provision both **MinIO** and **AWS**), the `Storage` claim must be labeled so it is matched with the correct provider.

For example:
```bash
kubectl get storage -A -o name \
| xargs -I{} kubectl patch {} --type='merge' \
  -p '{"spec":{"crossplane":{"compositionSelector":{"matchLabels":{"provider":"minio"}}}}}'
```

For approval workflows you also need to add this label to the `Storage` resources:

```yaml
metadata:
  labels:
    storages.pkg.internal/discoverable: "true"
```

## Storage Credentials

For each `Storage` resource, Provider Storage creates a Kubernetes Secret in the same namespace.
The Secret is named after `spec.principal` and contains S3-compatible access credentials.

Credentials can be rotated automatically when `spec.credentialsRollover` is configured. By default, automatic rollover is disabled.
The Secret shape is provider-agnostic and consistently exposes:

- `AWS_ACCESS_KEY_ID`  
- `AWS_SECRET_ACCESS_KEY`

Workloads and other compositions can mount or reference this Secret directly to authenticate against the provisioned bucket backend.

Bucket lifecycle rules are documented in the
[Usage & Concepts guide](https://versioneer-tech.github.io/provider-storage/latest/how-to-guides/usage_concepts/#lifecycle-rules).

## License

Apache 2.0 (Apache License Version 2.0, January 2004)  
<https://www.apache.org/licenses/LICENSE-2.0>
