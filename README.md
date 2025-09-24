# Storage Provider

This package provides the **Storage** Composite Resource Definition (XRD) and ready-to-use Crossplane v2 Compositions to provision S3-compatible storage for users and teams.  
It abstracts bucket creation, access policies, and cross-user sharing into a single spec.

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
  package: ghcr.io/versioneer-tech/provider-storage/minio:latest
  skipDependencyResolution: true
```
## Storage Spec

### Minimal example

```yaml
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: ws-alice
spec:
  owner: alice
  buckets:
  - bucketName: ws-alice
```

### More examples

See [`examples/buckets.yaml`](examples/buckets.yaml) for complete scenarios, including:
- Storage claims with multiple buckets (personal + shared)
- Access requests to other users’ buckets (`bucketAccessRequests`)
- Access grants for discoverable buckets (`bucketAccessGrants`)

## Storage Credentials

For each `Storage` resource, the provider automatically provisions a Kubernetes Secret in the same namespace.  
The Secret has the same name as the `Storage` resource (e.g. `ws-alice`) and contains S3-compatible access credentials.

These keys are always included:

- `AWS_ACCESS_KEY_ID`  
- `AWS_SECRET_ACCESS_KEY` 

Workloads and other compositions can mount or reference this Secret directly to authenticate against the provisioned storage backend.

## License

Apache 2.0 (Apache License Version 2.0, January 2004)  
<https://www.apache.org/licenses/LICENSE-2.0>
