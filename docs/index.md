# Provider Storage

Welcome to the **Provider Storage** documentation.  
This Crossplane provider delivers a unified way to manage S3-compatible storage systems across different backends such as MinIO, AWS S3, OTC OBS, and Scaleway.  

It provides a **Storage Composite Resource Definition (XRD)** and ready-to-use **Compositions** to provision and manage buckets, access policies, and cross-user sharing.

---

## Features

- **Multi-cloud support**  
  Provision S3-compatible storage across MinIO, AWS, OTC, and Scaleway.
- **Unified abstraction**  
  Manage buckets, access grants, and requests through a single spec.  
- **Cross-user sharing**  
  Easily grant and request access to buckets across teams.  
- **Kubernetes-native secrets**  
  Automatically provisions S3-compatible credentials as Kubernetes Secrets.  

---

## Installation

To install the configuration package into your Crossplane empowered Kubernetes environment, use e.g. for MinIO: 

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-minio
spec:
  package: ghcr.io/versioneer-tech/provider-storage/minio:0.1
  skipDependencyResolution: true
```

---

## Quickstart

### Minimal Example

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

This will provision a bucket named **`wonderland`**, along with the required cloud-specific entities such as IAM users, access credentials, and bucket policies granting bucket `ReadWrite` access to `alice`

!!! note

    All configuration packages built from `provider-storage` share the same `Storage` Composite Resource Definition!

---

For each `Storage` resource, a Secret is created in the same namespace, containing credentials for the selected backend.

- **MinIO, AWS**:  
  - `AWS_ACCESS_KEY_ID`  
  - `AWS_SECRET_ACCESS_KEY`

- **OTC**:  
  - `attribute.access`  
  - `attribute.secret`

Use these secrets in your workloads to connect directly to the provisioned storage with standard S3 tooling, for example:

```bash
aws s3 ls s3://wonderland
```

---

### More Examples
Check the [examples folder](https://github.com/versioneer-tech/provider-storage/tree/main/examples/base) in the GitHub repository for complete scenarios, including:

- Storage claims with multiple buckets
- Cross-team access requests and grants

---

## Links

- [API Reference](http://provider-storage.versioneer.at/latest/reference-guides/api/)  
- [Examples](https://github.com/versioneer-tech/provider-storage/tree/main/examples/base)
