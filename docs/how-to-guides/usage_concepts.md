# Use Storage

Create a namespaced `Storage` after [installation](installation.md).
`spec.principal` identifies its consumer and names the consumer Secret.
`spec.buckets` lists owned buckets. Use `buckets: []` for access requests
without owned buckets.

## Select a backend

Set a selector to choose the backend explicitly:

```yaml
spec:
  crossplane:
    compositionSelector:
      matchLabels:
        provider: minio
```

Provider values are `aws`, `cloudferro`, `minio`, `otc`, and `ovh`.
The selector is required when several compatible Compositions are installed.
Install packages for the backends you need. They share one Storage API package,
which owns the XRD.

Each backend uses `storage-<backend>` as its default EnvironmentConfig name,
such as `storage-aws` or `storage-minio`. These names match the backend package
names. Set the `storages.pkg.internal/environment` annotation or label to
select another environment. If you keep an existing environment named
`storage`, select it explicitly.

The EnvironmentConfig can set `storage.providerConfigName` to select an
existing backend ProviderConfig. When unset or blank, AWS, MinIO, OTC, and
OVHcloud use `provider-aws`, `provider-minio`, `provider-otc`, and `provider-ovh`.

CloudFerro requires an explicit `provider: cloudferro` selector. Its supplied
project manifests use separate environment names. Select one with
`storages.pkg.internal/environment: storage-cloudferro-<project-id>`.
The EnvironmentConfig defines the project ID and an existing OpenStack
ProviderConfig name. See the
[CloudFerro dependency guide](https://github.com/versioneer-tech/provider-storage/blob/main/cloudferro/dependencies/README.md).

## Credentials

The consumer Secret is in the Storage namespace. It contains
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, plus configured connection
settings: `AWS_ENDPOINT_URL`, `AWS_REGION`, and `AWS_S3_FORCE_PATH_STYLE`.
Use this stable Secret instead of provider-native generation Secrets.

Set `spec.providerIdentity` when the provider needs a shorter user name.
This does not change the consumer Secret name.

Credentials do not rotate by default. Set `credentialsRollover.interval`
and `maxToKeep` to retain overlapping generations. Consumers must reload
the stable Secret before the previous generation is removed. Rotation occurs
on reconciliation after a period boundary. See the
[API reference](../reference-guides/api.md#credential-rollover).

For Secret publication and consumer reload requirements, see
[Consumer credentials](../architecture/credential-strategy.md).

## Lifecycle rules

Set rules under `spec.buckets[].lifecycleRules`. A target can be `*` for the
whole bucket or a prefix such as `tmp/*`. `Delete` removes matching objects;
`Notify` lists them in the job logs.

Set exactly one time condition: `minAge`, such as `30s`, `15m`, `2h`, `1d`,
or `2w`, or `at`, an RFC3339 UTC timestamp. After `at`, each job processes
all objects under the target, regardless of age. The backend
EnvironmentConfig's `storage.lifecycle.schedule` controls when the CronJob runs.

Jobs stop after one hour and allow two retries by default. Set
`storage.lifecycle.activeDeadlineSeconds` (1 through 86400) and
`storage.lifecycle.backoffLimit` (0 through 10) in that EnvironmentConfig
when cleanup needs different limits. Check failed Jobs before the next run.

## Access requests and grants

The requester lists a bucket in `bucketAccessRequests`. The owner sets its
permission in `bucketAccessGrants`. A request has no permission field.
See [Permissions](permissions.md) for discovery and backend limits.

## Examples

The shared examples cover these cases:

| Manifest | Behavior |
| --- | --- |
| [Joe](https://github.com/versioneer-tech/provider-storage/blob/main/examples/base/001-buckets.yaml) | One bucket, static credentials, and a ReadWrite grant to Jeff. |
| [Jeff](https://github.com/versioneer-tech/provider-storage/blob/main/examples/base/002-buckets.yaml) | Two buckets, a ReadOnly grant to Joe, weekly rotation, and lifecycle rules. |
| [Jane](https://github.com/versioneer-tech/provider-storage/blob/main/examples/base/003-buckets.yaml) | Access requests without owned buckets; five retained quarterly credential generations. |
| [John](https://github.com/versioneer-tech/provider-storage/blob/main/examples/base/004-buckets.yaml) | Daily rotation and a grant that differs from the access described in Jane's request. |

Use the matching backend overlay in
[`examples/overlays/`](https://github.com/versioneer-tech/provider-storage/tree/main/examples/overlays).
Set a different namespace in each overlay when you deploy several backend
example suites; they use the same Storage and principal names.
The CloudFerro overlay needs your project EnvironmentConfig names and omits
cross-project grants.

## Verify provisioning

Check the Storage conditions and events in your namespace:

```bash
kubectl get storages -n workspace
kubectl describe storage s-joe -n workspace
```

`Synced=True` means reconciliation succeeded. `Ready=True` means the composed
resources report ready. Check that the consumer Secret has both required
credential keys:

```bash
kubectl describe secret s-joe -n workspace
```

Pass the consumer Secret to the S3 client through its credential settings.
Use the endpoint and region from the Secret. Verify allowed and denied S3
operations; resource readiness alone does not prove access.
