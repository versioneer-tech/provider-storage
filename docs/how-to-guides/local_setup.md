# Provider Storage: Local Setup And End-To-End Testing

This guide shows how to run `provider-storage` locally with a kind cluster, Crossplane, an in-cluster MinIO service, the MinIO `Storage` composition, and the example resources.

The recommended path is the MinIO e2e script. It is the same entry point used by the PR GitHub Action, so local runs and CI exercise the same setup.

## Prerequisites

Install:

- [Docker](https://docs.docker.com/engine/install/)
- [kind](https://kind.sigs.k8s.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)
- [Helm](https://helm.sh/docs/intro/install/)

## Run The Full MinIO E2E Test

From the repository root:

```bash
bash minio/tests/e2e.bash
```

By default, the script:

- creates or reuses a kind cluster named `storage-minio`
- installs Crossplane `2.0.2`
- installs a small MinIO deployment and service in the `minio` namespace
- applies the MinIO dependencies:
  - `minio/dependencies/00-mrap.yaml`
  - `minio/dependencies/01-deploymentRuntimeConfigs.yaml`
  - `minio/dependencies/02-providers.yaml`
  - `minio/dependencies/functions.yaml`
  - `minio/dependencies/rbac.yaml`
  - `minio/dependencies/03-providerConfigs.yaml`
  - `minio/dependencies/04-environmentConfigs.yaml`
- installs the local `xrd.yaml` and `minio/composition.yaml`
- applies `examples/overlays/minio`
- waits for the example `Storage` resources to become Ready
- verifies buckets, users, and policies directly in MinIO with `mc`
- verifies generated principal Secrets contain `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
- uses the generated `s-joe` Secret to upload an object to MinIO, list it, download it, compare the downloaded content, and remove it again
- verifies lifecycle cleanup by creating a lifecycle test bucket, seeding objects with `rclone`, triggering the generated CronJob, and checking that only the matching `tmp/*` object is deleted

The successful run ends with:

```text
==> MinIO e2e completed
```

## Useful Local Options

Reuse the current Kubernetes context instead of creating or selecting a kind cluster:

```bash
CREATE_KIND_CLUSTER=false bash minio/tests/e2e.bash
```

Delete the kind cluster after the run, if the script created it:

```bash
DELETE_KIND_CLUSTER=true bash minio/tests/e2e.bash
```

Skip the lifecycle test:

```bash
VERIFY_LIFECYCLE=false bash minio/tests/e2e.bash
```

Skip the generated-credential upload/download roundtrip:

```bash
VERIFY_OBJECT_ROUNDTRIP=false bash minio/tests/e2e.bash
```

Run only the setup and examples, without direct MinIO verification:

```bash
VERIFY_MINIO=false VERIFY_OBJECT_ROUNDTRIP=false VERIFY_LIFECYCLE=false bash minio/tests/e2e.bash
```

Run setup and tests as separate phases:

```bash
RUN_EXAMPLE_TESTS=false RUN_LIFECYCLE_TEST=false bash minio/tests/e2e.bash
RUN_SETUP=false RUN_EXAMPLE_TESTS=true RUN_LIFECYCLE_TEST=false bash minio/tests/e2e.bash
RUN_SETUP=false RUN_EXAMPLE_TESTS=false RUN_LIFECYCLE_TEST=true bash minio/tests/e2e.bash
```

Install a published Configuration package instead of the local `xrd.yaml` and `minio/composition.yaml`:

```bash
INSTALL_CONFIGURATION_PACKAGE=true \
PACKAGE=ghcr.io/versioneer-tech/provider-storage/minio:<tag> \
bash minio/tests/e2e.bash
```

This package mode is optional. The default local run and the PR workflow both install `xrd.yaml` and `minio/composition.yaml` directly from the checked-out repository. That is intentional: it validates the exact composition changes in the branch without requiring an intermediate push to GHCR.

Adjust the lifecycle wait, for example while debugging:

```bash
LIFECYCLE_WAIT_SECONDS=90 bash minio/tests/e2e.bash
```

## Manual Setup Reference

If you want to do the setup by hand instead of running the script, these are the same high-level steps.

Create a kind cluster:

```bash
kind create cluster --name storage-minio
kind export kubeconfig --name storage-minio
```

Install Crossplane:

```bash
kubectl create namespace crossplane --dry-run=client -o yaml | kubectl apply -f -
helm repo add crossplane-stable https://charts.crossplane.io/stable --force-update
helm repo update
helm upgrade --install crossplane crossplane-stable/crossplane \
  --namespace crossplane \
  --version 2.0.2 \
  --set 'provider.defaultActivations={}' \
  --wait \
  --timeout 10m
```

Apply the MinIO dependencies:

```bash
kubectl apply -f minio/dependencies/00-mrap.yaml
kubectl apply -f minio/dependencies/01-deploymentRuntimeConfigs.yaml
kubectl apply -f minio/dependencies/02-providers.yaml
kubectl apply -f minio/dependencies/functions.yaml
kubectl apply -f minio/dependencies/rbac.yaml
kubectl wait provider.pkg.crossplane.io/provider-minio --for=condition=Healthy --timeout=10m
kubectl wait provider.pkg.crossplane.io/provider-kubernetes --for=condition=Healthy --timeout=10m
kubectl wait function.pkg.crossplane.io/crossplane-contrib-function-python --for=condition=Healthy --timeout=10m
kubectl wait function.pkg.crossplane.io/crossplane-contrib-function-auto-ready --for=condition=Healthy --timeout=10m
kubectl apply -f minio/dependencies/03-providerConfigs.yaml
kubectl apply -f minio/dependencies/04-environmentConfigs.yaml
```

Install the local API and composition:

```bash
kubectl apply -f xrd.yaml
kubectl wait crd/storages.pkg.internal --for=condition=Established --timeout=2m
kubectl apply -f minio/composition.yaml
```

Apply the MinIO examples:

```bash
kubectl create namespace workspace --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f - <<'EOF'
apiVersion: kubernetes.m.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: provider-kubernetes
  namespace: workspace
spec:
  credentials:
    source: InjectedIdentity
EOF
kubectl apply -k examples/overlays/minio
```

Check readiness:

```bash
kubectl get storages.pkg.internal -n workspace
```

Expected shape:

```text
NAME     SYNCED   READY   COMPOSITION     AGE
s-jane   True     True    storage-minio   2m
s-jeff   True     True    storage-minio   2m
s-joe    True     True    storage-minio   2m
s-john   True     True    storage-minio   2m
```

## GitHub Actions

The PR workflow also runs the same script. It is triggered by:

- pull requests to `main` on `opened`, `reopened`, and `synchronize`
- manual runs through GitHub Actions via `workflow_dispatch`

Manual trigger:

1. Open the repository in GitHub.
2. Go to **Actions**.
3. Select the **PR** workflow.
4. Click **Run workflow**.

The workflow sets `INSTALL_CONFIGURATION_PACKAGE=false`, so it does not build or push a Configuration package. It creates a kind cluster and installs the checked-out `xrd.yaml` and `minio/composition.yaml` directly, matching the default local e2e behavior.

The workflow is split into three readable phases:

- setup the local MinIO stack
- run the four example `Storage` resources and generated-credential upload/download checks
- run the lifecycle cleanup check
