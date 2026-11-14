# Local tests

Use the [test guide](https://github.com/versioneer-tech/provider-storage/blob/main/tests/README.md)
to select checks and install local test tools. The unit suite uses Docker
and needs no Kubernetes cluster.

From the repository root, run all backends:

```bash
docker ps
tests/unit.bash
```

## Integration tests

Tests use the dedicated `provider-storage-it`
cluster and the explicit `kind-provider-storage-it` context. Use a separate
`KUBECONFIG` file to keep this setup apart from other clusters.

Get the operator's approval before creating the test cluster:

```bash
tests/integration/create-cluster.bash
tests/integration/run.bash minio
```

The runner installs Crossplane, MinIO, and the providers. It creates two
Storages and checks consumer Secrets, object access, and lifecycle cleanup.
Other backends need [cloud IAM bootstrap](cloud-iam-bootstrap.md) and provider
Secrets first. The
[integration guide](https://github.com/versioneer-tech/provider-storage/blob/main/tests/integration/README.md)
lists backend settings and the access checks.

The cluster is for a validation cycle. Remove it when the operator directs
you to do so:

```bash
kind delete cluster --name provider-storage-it
```
