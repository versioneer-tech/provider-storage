# How-to guides: storage-minio

The `storage-minio` configuration package allows the creation of `buckets` on a [MinIO](https://min.io/) backend and automatically creates [Policies](https://min.io/docs/minio/linux/administration/identity-access-management/policy-based-access-control.html) for permission control. Furthermore, `storage-minio` includes a workflow to request/grant access t o `buckets` from other `owners`.

## How-to guides

- [How to install the `storage-minio` configuration package](### How to install the `storage-minio` configuration package)

### How to install the `storage-minio` configuration package

The `storage-minio` configuration package can be installed like any other with

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-minio
spec:
  package: ghcr.io/versioneer-tech/provider-storage:v0.1-minio
```

This automatically installs the necessary dependencies:

- [provider-minio](https://github.com/vshn/provider-minio) >= v0.4.4
- [provider-kubernetes](https://github.com/crossplane-contrib/provider-kubernetes) >= v0.18.0
- [function-auto-ready](https://github.com/crossplane-contrib/function-auto-ready) >= 0.5.0
- [function-go-templating](https://github.com/crossplane-contrib/function-go-templating) >= v0.10.0

However, it does not install the necessary `ProviderConfigs` and `Secrets` that are actually needed for the `storage-minio` to work.
