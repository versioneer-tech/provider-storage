# Provider Storage – Local Setup

This guide shows how to set up `provider-storage` locally using a [kind](https://kind.sigs.k8s.io/) cluster and a MinIO installation inside the cluster.  
It is intended for development, testing, and demonstrations.

---

## Prerequisites

Make sure you have the following installed on your machine:

- [Go](https://go.dev/) (for some tooling)
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)
- [Helm](https://helm.sh/docs/intro/install/)
- [kind](https://kind.sigs.k8s.io/)

---

## Step 1: Create a kind cluster

```bash
kind create cluster --name storage-minio
kubectl get pods -A
```

Verify that the cluster is up and running before proceeding.

---

## Step 2: Install Crossplane

Install Crossplane into the cluster using Helm:

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm install crossplane   --namespace crossplane-system   --create-namespace crossplane-stable/crossplane   --version 2.0.2   --set provider.defaultActivations={}
```

Apply a `ManagedResourceActivationPolicy` (MRAP) to only activate the resources needed for MinIO:

```yaml
apiVersion: apiextensions.crossplane.io/v1alpha1
kind: ManagedResourceActivationPolicy
metadata:
  name: storage-minio
spec:
  activate:
  - buckets.minio.crossplane.io
  - policies.minio.crossplane.io
  - users.minio.crossplane.io
  - objects.kubernetes.crossplane.io
```

```bash
kubectl apply -f mrap.yaml
```

---

## Step 3: Install MinIO Operator and Tenant

Install the MinIO Operator:

```bash
helm repo add minio-operator https://operator.min.io
helm install   --namespace minio-operator   --create-namespace operator minio-operator/operator
```

Create a small MinIO Tenant for testing. Save as `values.yaml`:

```yaml
tenant:
  pools:
    - servers: 1
      name: pool-0
      volumesPerServer: 1
      size: 1Gi
  certificate:
    requestAutoCert: false
```

Install the tenant:

```bash
helm install   --values values.yaml   --namespace minio-tenant   --create-namespace minio-tenant minio-operator/tenant
```

---

## Step 4: Install Provider Dependencies

Apply the provider dependency files from the repo (in order):

- [01-deploymentRuntimeConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/minio/dependencies/01-deploymentRuntimeConfigs.yaml)  
- [02-providers.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/minio/dependencies/02-providers.yaml)  
- [03-providerConfigs.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/minio/dependencies/03-providerConfigs.yaml) *(apply in your target namespace, e.g. `workspace`)*  
- [functions.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/minio/dependencies/functions.yaml)  
- [rbac.yaml](https://github.com/versioneer-tech/provider-storage/blob/main/minio/dependencies/rbac.yaml)  

These configure the MinIO provider, Kubernetes provider, and required permissions.

---

## Step 5: Install the Configuration Package

Finally, install the configuration package for MinIO:

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-minio
spec:
  package: ghcr.io/versioneer-tech/provider-storage/minio:<version>
```

```bash
kubectl apply -f configuration.yaml
```

This installs the Crossplane `Storage` CRD and compositions.

---

## Step 6: Create a Storage Claim

With everything installed, create a `Storage` claim in your namespace (`workspace` is recommended):

```yaml
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: team-wonderland
  namespace: workspace
spec:
  principal: alice
  buckets:
    - bucketName: wonderland
```

---

## Step 7: Verify the Setup

### Check if the resource is ready

```bash
kubectl get storages -n workspace
```

Expected output:

```
NAME     SYNCED   READY   COMPOSITION        AGE
team-wonderland    True     True    storage-minio      2m
```

Inspect details:

```bash
kubectl describe storage team-wonderland -n workspace
```

### Check the generated Secret

Each `Storage` claim produces a Secret with the **principal’s name** in the same namespace.  
For example, the claim above creates a Secret `alice` in the `workspace` namespace.

```bash
kubectl get secret alice -n workspace -o yaml
```

Decode credentials if needed:

```bash
kubectl get secret alice -n workspace -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d; echo
kubectl get secret alice -n workspace -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d; echo
```

### Use the credentials

```bash
aws s3 ls s3://alice   --endpoint-url http://minio-tenant-hl.minio-tenant.svc.cluster.local:9000
```

---

## Summary

- A `kind` cluster with Crossplane is created.  
- MinIO Operator and Tenant provide the S3 backend.  
- Provider dependencies are installed first (providers, configs, RBAC).  
- The `storage-minio` configuration package registers the CRD and compositions.  
- A `Storage` claim provisions buckets and credentials.  
- A Secret (named after the principal) contains S3-compatible credentials usable with CLI tools.
