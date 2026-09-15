# Run Integration Tests

Provider Storage uses an ephemeral Kind cluster for local integration tests.
The cluster name is `provider-storage-it`. Every script uses the explicit
`kind-provider-storage-it` context.

## Prerequisites

Install Docker, Kind, kubectl, Helm, Crossplane CLI, and dyff. Run the full
unit suite before integration:

```bash
tests/unit.bash
```

An agent must ask the operator before it creates the local test cluster.
After approval, run:

```bash
tests/integration/create-cluster.bash
```

The other scripts stop if this cluster is absent. They do not create it or use
another current Kubernetes context.

## Test MinIO

MinIO needs no cloud IAM bootstrap:

```bash
tests/integration/run.bash minio
```

The integration command deploys Crossplane, MinIO, the required providers,
and one MinIO `Storage`. It waits for the resource and its credential Secret,
then verifies an object round trip and lifecycle cleanup.

## Test a Cloud Backend

Cloud tests use the same cluster. Before provider deployment:

1. complete the backend procedure in the
   [cloud IAM bootstrap guide](cloud-iam-bootstrap.md);
2. create the provider credential Secret with the direct kubectl command in
   the integration README; and
3. run the provider and verification scripts for the selected backend.

CloudFerro uses a different order because its IAM bootstrap creates the slot
ProviderConfigs. Follow the complete command sequence in the
[integration test guide](https://github.com/versioneer-tech/provider-storage/blob/main/tests/integration/README.md#cloudferro).

The backend commands, credential formats, and multi-backend workflow are in
[`tests/integration/README.md`](https://github.com/versioneer-tech/provider-storage/blob/main/tests/integration/README.md).

Run `tests/integration/run.bash ovh` for OVHcloud. It
creates one `Storage` with two buckets and checks S3 access through the
generated consumer Secret. Rotation, lifecycle, and orphan cleanup remain in
the integration plan.

List retained test resources by backend:

```bash
kubectl --context kind-provider-storage-it \
  get storages.pkg.internal \
  --namespace provider-storage-it \
  -L storages.pkg.internal/backend
```

The cluster is for a validation cycle. Remove it when the operator directs
you to do so:

```bash
kind delete cluster --name provider-storage-it
```

## Pull-request checks

The pull-request workflow runs all Composition unit tests and the Kind/MinIO
integration path. It does not load cloud-provider credentials.
