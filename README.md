<h1><img src="docs/imgs/logo.png" height="48" alt="Versioneer logo" /> Provider Storage</h1>

[![Tests](https://github.com/versioneer-tech/provider-storage/actions/workflows/pr.yaml/badge.svg?branch=main&event=push)](https://github.com/versioneer-tech/provider-storage/actions/workflows/pr.yaml)
[![Latest release](https://img.shields.io/github/v/release/versioneer-tech/provider-storage)](https://github.com/versioneer-tech/provider-storage/releases/latest)
[![License](https://img.shields.io/github/license/versioneer-tech/provider-storage)](LICENSE)

Provider Storage provisions S3 buckets and consumer credentials on MinIO,
AWS, Open Telekom Cloud (OTC), OVHcloud, and CloudFerro. Install the backends
you need in the same cluster. Declare buckets, access grants, and lifecycle
rules in a namespaced `Storage`.
Crossplane creates the provider resources from the platform's backend settings.

Use Crossplane 2.4.3 or later in the v2 series. The
[installation guide](docs/how-to-guides/installation.md#dependency-baseline)
lists the provider and function versions and the shared runtime settings.

After [installation](docs/how-to-guides/installation.md), save this example
as `storage.yaml`. It creates one MinIO bucket in the `workspace` namespace:

```yaml
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: team-wonderland
  namespace: workspace
spec:
  crossplane:
    compositionSelector:
      matchLabels:
        provider: minio
  principal: alice
  buckets:
    - bucketName: wonderland
```

Apply it and check the result:

```bash
kubectl apply -f storage.yaml
kubectl get storage team-wonderland -n workspace
kubectl describe secret alice -n workspace
```

The consumer Secret is named `alice` in `workspace`. Applications use its S3
credentials and must reload them during credential rollover. Platform
operators configure the backend and controller credentials before users
create Storage resources. They choose where and when to run cloud IAM
bootstrap: on a specific host, in a CI/CD pipeline, or on a local machine.

## Get started

[Read the documentation online](https://versioneer-tech.github.io/provider-storage/),
or use the guides in this checkout:

| Task | Guide |
| --- | --- |
| Compare access rules and limits | [Backend differences](docs/how-to-guides/backend_differences.md) |
| Install packages and backend dependencies | [Installation](docs/how-to-guides/installation.md) |
| Prepare cloud controller credentials | [Cloud IAM bootstrap](docs/how-to-guides/cloud-iam-bootstrap.md) |
| Create buckets, rotate credentials, and check provisioning | [Use Storage](docs/how-to-guides/usage_concepts.md) |
| Request and grant bucket access | [Permissions](docs/how-to-guides/permissions.md) |
| Look up resource fields | [API reference](docs/reference-guides/api.md) |

Backend examples are in [`examples/overlays`](examples/overlays).

Compositions use a `ProviderConfig` for cloud authentication. For static
credentials, it references a controller Secret. IAM `apply` prepares the cloud
identity and saves credentials locally. Run `verify` and check its result
before you deploy the Secret with
[`render-secrets | kubectl apply`](docs/how-to-guides/cloud-iam-bootstrap.md#deploy-controller-secrets).

## Development

Build instructions are in [`composition/`](composition/README.md).
Use the [test guide](tests/README.md) to select and run checks, and the
[integration guide](tests/integration/README.md) for the dedicated Kind cluster.

## License

Apache License 2.0. See [LICENSE](LICENSE).
