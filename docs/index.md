# Welcome to Provider Storage

The **Provider Storage** package brings cloud-native, declarative storage management into your Kubernetes cluster, built on [Crossplane v2](https://crossplane.io). It gives **end users** a simple way to request and share S3 buckets, and it gives **operators** a consistent control plane to enforce policies across multiple backends such as **MinIO**, **AWS S3**, **OTC OBS**, and others.

Instead of juggling credentials, APIs, and bucket lifecycles separately for each provider, everything is managed through a single Kubernetes Custom Resource: the `Storage` claim.  This claim captures a user’s storage needs — create a bucket, request access to someone else’s, or grant access to collaborators — while Crossplane and the compositions takes care of provisioning on the underlying backend.

For **end users**, this means:

- Create personal or shared buckets with one manifest.  
- Request access to other buckets without having to ask operators directly.  
- Receive credentials automatically in a Kubernetes Secret.  

For **operators**, this means:

- A unified model for managing storage across different S3-compatible systems.  
- Consistent enforcement of access policies and sharing rules.  
- Extensibility through Crossplane’s composition model — adapt the backend without changing the user-facing API.  

At its core, Provider Storage provides:

- A **Storage Composite Resource Definition (XRD)**  
- **Compositions** to provision buckets, manage access, and reconcile credentials  
- Support for **cross-user sharing** and collaboration  

With Provider Storage, storage becomes **declarative, multi-tenant, and self-service**, all while staying under operator control.
---

## Features

- **Multi-cloud support**  
  Provision S3-compatible storage across MinIO, AWS, OTC, and others.
- **Unified abstraction**  
  Manage buckets, access grants, and requests through a single spec.  
- **Cross-user sharing**  
  Easily grant and request access to buckets across teams.  
- **Kubernetes-native secrets**  
  Automatically provisions S3-compatible credentials as Kubernetes Secrets.
- **Extensible by design**  
  Built on Crossplane, ready to extend with new resources.  

---

## Installation

To install the configuration package into your Crossplane empowered Kubernetes environment, use e.g. for MinIO: 

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-minio
spec:
  package: ghcr.io/versioneer-tech/provider-storage/minio:<!version!>
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

    All configuration packages derived from `provider-storage` expose the same `Storage` Composite Resource Definition (XRD). If multiple providers are installed, each `Storage` claim **must be labeled** to ensure it binds to the desired provider.

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