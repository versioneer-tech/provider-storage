<h1><img src="docs/imgs/logo.png" height="48" alt="Versioneer logo" /> Provider Storage</h1>

[![Tests](https://github.com/versioneer-tech/provider-storage/actions/workflows/pr.yaml/badge.svg?branch=main&event=push)](https://github.com/versioneer-tech/provider-storage/actions/workflows/pr.yaml)
[![Latest release](https://img.shields.io/github/v/release/versioneer-tech/provider-storage)](https://github.com/versioneer-tech/provider-storage/releases/latest)
[![License](https://img.shields.io/github/license/versioneer-tech/provider-storage)](LICENSE)

Provider Storage provisions S3 buckets and consumer credentials on MinIO,
AWS, Open Telekom Cloud (OTC), OVHcloud, and CloudFerro. Declare buckets,
access grants, and lifecycle rules in a namespaced `Storage`; Crossplane
creates the provider resources from the platform's backend settings.

This example creates one MinIO bucket:

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

The consumer Secret is named `alice` in `workspace`. Applications use this
Secret for S3 access. Platform operators configure the backend and its
controller credentials before users create Storage resources.

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

## Development

Build instructions are in [`composition/`](composition/README.md).
Use the [test guide](tests/README.md) to select and run checks, and the
[integration guide](tests/integration/README.md) for the dedicated Kind cluster.

## License

Apache License 2.0. See [LICENSE](LICENSE).
