# How-to guides: storage-scaleway

The `storage-scaleway` configuration package allows the creation of S3-compatible `Buckets` on Scaleway and automatically creates `Policies` for permission control. Furthermore, `storage-scaleway` includes a workflow to request/grant access to `Buckets` from other `owners`.

## How-to guides

- [How to install the `storage-scaleway` configuration package](#how-to-install-the-storage-scaleway-configuration-package)

### How to install the `storage-scaleway` configuration package

!!! warning
    In order for `storage-scaleway` to work you need [enable Operations](https://docs.crossplane.io/latest/operations/operation/#troubleshooting-operations) when installing Crossplane!

The `storage-scaleway` configuration package can be installed like any other configuration package with

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-scaleway
spec:
  package: ghcr.io/versioneer-tech/provider-storage/scaleway:<!version!>
```

This automatically installs the necessary dependencies:

- [provider-scaleway](https://github.com/scaleway/crossplane-provider-scaleway) >= v0.4.0
- [function-auto-ready](https://github.com/crossplane-contrib/function-auto-ready) >= 0.5.0
- [function-python](https://github.com/crossplane-contrib/function-python) >= v0.2.0

However, it does not install the necessary `ProviderConfig` and `Secret` that are actually needed for the `storage-scaleway` to work.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: storage-scaleway
  namespace: crossplane-system
type: Opaque
stringData:
  credentials: |
    {
      "access_key": "<scaleway-access-key-id>",
      "secret_key": "<scaleway-secret-access-key>",
      "organization_id": "<scaleway-organization-id>",
      "user_id": "<scaleway-user-id>",
      "region": "fr-par",
      "zone": "fr-par-1"
    }
```

!!! warning
    In the README for `provider-scaleway`, the `user_id` is not present but it is essential for `storage-scaleway` to work! This is the user ID of the user/application associated with the `access_key`.

Furthermore, the `ProviderConfig` needs to reference this secret.

!!! warning
    The name of the `ProviderConfig` needs to be `storage-scaleway`! The composition will not work with any other name and will not be able to create resources!

```yaml
apiVersion: scaleway.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: storage-scaleway
spec:
  credentials:
    source: Secret
    secretRef:
      name: storage-scaleway
      namespace: crossplane-system
      key: credentials
```

This is everything that is needed for the `storage-scaleway` configuration package to function properly.
