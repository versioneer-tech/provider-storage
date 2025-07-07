# provider-storage

A Crossplane Configuration Package to provision S3 compatible buckets with fine grained permissions for MinIO.

Documentation: [https://versioneer-tech.github.io/provider-storage/](https://versioneer-tech.github.io/provider-storage/)

## Installation

The `provider-storage` configuration package depends on:

- `crossplane>=v1.20.0`
- `provider-minio>=v0.4.4`
- `function-go-templating>=v0.10.0`

These dependencies have to be running before the `provider-storage` can be installed with a Crossplane Configuration:

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: provider-storage
spec:
  package: ghcr.io/versioneer-tech/provider-storage:0.0.1-dev
```

After applying the above manifest, the `xstorages.epca.eo` XRD and the `storage` Composition are installed to the cluster and ready to use.

## Usage

A minimal example to create a new bucket with the owner set to `alice`:

```yaml
apiVersion: epca.eo/v1beta1
kind: Storage
metadata:
  name: test-bucket
spec:
  buckets:
    - name: testeroni
      owner: alice
```

This will automatically create a new bucket named `test-bucket` and a new user named `alice` on MinIO. Furthermore, it attaches a Policy to the user `alice` that allows every action.

