# Welcome to Provider Storage

**Provider Storage is a PaaS-style building block for platform operators:** it turns one `Storage` claim into end-user object-storage buckets on MinIO, AWS S3, or OTC OBS. Users get smooth self-service bucket provisioning. Operators keep visibility and control over provider credentials, backend choice, access policy, sharing, lifecycle rules, and credential rotation.

Provider Storage is built on [Crossplane v2](https://crossplane.io). It provides a tenant-facing `Storage` API and backend-specific compositions for MinIO, AWS S3, and OTC OBS.

The API stays the same across all supported backends. Buckets, credentials, access requests, access grants, and lifecycle rules are the same concepts for MinIO, AWS S3, and OTC OBS. Only the implementation behind the composition changes.

## Operator Contract

For an operator, a `Storage` claim is the contract for one principal and its object-storage access:

- You install the backend package you want to offer: MinIO, AWS S3, or OTC OBS.
- You configure provider credentials and backend settings in the target namespace.
- Users or higher-level platform services submit `Storage` claims for buckets, access requests, and access grants.
- Crossplane creates the backend-specific resources: buckets, users or IAM identities, policies, access keys, and a normalized Kubernetes Secret.
- The resulting resources stay visible to the operator, so access, sharing, lifecycle rules, and credential rotation remain under platform control.

This is the main design point: users get simple bucket self-service, while operators keep responsibility for the storage systems, provider credentials, access model, and lifecycle policy.

At its core, Provider Storage provides:

- A **Storage Composite Resource Definition (XRD)**
- **Compositions** to provision buckets, manage access, and reconcile credentials
- Support for **cross-user sharing** and collaboration
- **Bucket lifecycle rules** for object cleanup by prefix and age
- A normalized Secret shape with `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`

Other platform building blocks and workloads can consume the generated Secret directly. For example, a Datalab can use it to mount object-storage access into an end-user workspace.

---

## Features

- **Backend support**
  Provision S3-compatible buckets on MinIO, AWS S3, and OTC OBS.
- **Clean abstraction**
  Use the same bucket, access, credential, and lifecycle concepts across MinIO, AWS S3, and OTC OBS.
- **Cross-user sharing**
  Let owners grant or deny bucket access across users or teams.
- **Kubernetes-native secrets**
  Create S3-compatible credentials as Kubernetes Secrets.
- **Operator control**
  Keep provider credentials, policies, lifecycle rules, and credential rotation visible.

---

## Installation

To install the configuration package into your Crossplane-enabled Kubernetes environment, use a backend-specific package. For MinIO:

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

This creates a bucket named **`wonderland`**, plus the backend-specific resources needed for `alice` to access it.

!!! note

    All configuration packages derived from `provider-storage` expose the same `Storage` Composite Resource Definition (XRD). If multiple providers are installed, each `Storage` claim **must be labeled** to ensure it binds to the desired provider.

---

For each `Storage` resource, a Secret is created in the same namespace. The Secret is named after `spec.principal` and contains credentials for the selected backend.

- **MinIO, AWS S3, OTC OBS**:
  - `AWS_ACCESS_KEY_ID`  
  - `AWS_SECRET_ACCESS_KEY`

Use these secrets in your workloads to connect directly to the provisioned storage with standard S3 tooling, for example:

```bash
aws s3 ls s3://wonderland
```

---

### More Examples
Check the [examples folder](https://github.com/versioneer-tech/provider-storage/tree/main/examples/base) in the GitHub repository for complete scenarios, including:

- Storage claims with multiple buckets
- Cross-team access requests and grants

### Lifecycle Rules

Lifecycle rules are defined per bucket under `spec.buckets[].lifecycleRules`.

```yaml
spec:
  buckets:
    - bucketName: s-jeff-shared
      discoverable: true
      lifecycleRules:
        - target: tmp/*
          mode: Delete
          minAge: 12h
        - target: scratch/*
          mode: Notify
          minAge: 1w
```

`Delete` removes matching objects when the time condition is met. `Notify` logs
matching objects when the time condition is met and does not change objects.

Supported `minAge` suffixes:

- `s` seconds
- `m` minutes
- `h` hours
- `d` days
- `w` weeks
