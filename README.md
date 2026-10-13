<h1><img src="docs/imgs/logo.png" height="48" alt="Versioneer logo" /> Provider Storage</h1>

[![Tests](https://github.com/versioneer-tech/provider-storage/actions/workflows/pr.yaml/badge.svg?branch=main&event=push)](https://github.com/versioneer-tech/provider-storage/actions/workflows/pr.yaml)
[![Latest release](https://img.shields.io/github/v/release/versioneer-tech/provider-storage)](https://github.com/versioneer-tech/provider-storage/releases/latest)
[![License](https://img.shields.io/github/license/versioneer-tech/provider-storage)](LICENSE)

Provider Storage defines one namespaced Crossplane `Storage` API for S3
buckets, consumer credentials, access grants, and lifecycle rules. Platform
operators configure the storage backends. Users do not need to manage
provider-specific identities or policies.

Supported backends are MinIO, AWS S3, Open Telekom Cloud (OTC), OVHcloud, and
CloudFerro. See the
[backend comparison](docs/how-to-guides/backend_differences.md) before you
select a backend.

## Start here

1. Follow the [installation guide](docs/how-to-guides/installation.md).
2. For a managed cloud, review and run the backend IAM bootstrap before you
   deploy its provider configuration. The bootstrap uses an administrator
   login to prepare a separate Crossplane controller identity. See the
   [cloud IAM guide](docs/how-to-guides/cloud-iam-bootstrap.md).
3. Create a `Storage` resource in the same namespace as its namespaced
   `ProviderConfig`.

If MinIO is the only compatible Composition in the cluster, this example
creates one bucket without an explicit selector:

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

Provider Storage creates a consumer Secret named after `spec.principal` in
the same namespace. See [Usage and concepts](docs/how-to-guides/usage_concepts.md)
for access requests, grants, credential rollover, lifecycle rules, and
verification commands. The [API reference](docs/reference-guides/api.md)
lists all fields.

Backend-specific examples are in [`examples/overlays`](examples/overlays).
If you install more than one backend Composition, see
[Select a backend](docs/how-to-guides/usage_concepts.md#select-a-backend).

## Backend setup

| Backend | Dependency guide |
| --- | --- |
| MinIO | [MinIO dependencies](minio/dependencies/README.md) |
| AWS | [AWS dependencies](aws/dependencies/README.md) |
| OTC | [OTC dependencies](otc/dependencies/README.md) |
| OVHcloud | [OVHcloud dependencies](ovh/dependencies/README.md) |
| CloudFerro | [CloudFerro dependencies](cloudferro/dependencies/README.md) |

## Tests

Run the local validation suite from the repository root:

```bash
tests/unit.bash
```

The suite checks IAM helper behavior, renders each Composition, compares
golden files, validates schemas, and checks integration manifests. See the
[local test guide](docs/how-to-guides/local_setup.md) before you run a live
Kind or cloud integration test.

## License

Apache License 2.0. See [LICENSE](LICENSE).
