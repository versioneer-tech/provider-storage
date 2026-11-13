# Consumer credentials

Provider Storage publishes S3 access keys in a stable consumer Secret.
Provider credentials are separate: Crossplane uses them to manage cloud
resources. They must never appear in a consumer Secret. See
[Cloud IAM bootstrap](../how-to-guides/cloud-iam-bootstrap.md).

## Secret contract

The Secret uses `spec.principal` as its name and the Storage namespace.
Every backend publishes these keys:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

Connection settings can add `AWS_ENDPOINT_URL`, `AWS_REGION`, and
`AWS_S3_FORCE_PATH_STYLE`. A Composition must omit the consumer Secret when
either required key is absent. It copies only the documented keys.

`spec.providerIdentity` can set a shorter provider-native name. It does not
change the principal or consumer Secret name. Provider-native connection
Secrets, such as `<principal>-credentials` or `<principal>-<generation>`, are
internal. Consumers use the stable Secret.

Static S3 keys work with the supported backends and common S3 clients,
including AWS SDKs and rclone. They do not depend on the cloud that hosts
Kubernetes. Their holders can use them outside that cluster, so Secret read
access gives access to the associated cloud permissions.

## Rollover

[ADR-002](0002-rotate-static-credentials-by-generation.md) defines retained
credential generations. Provider Storage writes the current generation to
the stable Secret and removes generations outside `maxToKeep`.

Consumers must reload that Secret or restart before the overlap ends.
Provider Storage does not force a reload. Rotation occurs on reconciliation
after a period boundary; it does not provide an exact expiry time. Function
response caching can delay it.

Live tests must prove that retained keys have only the intended access and
that removed generations can no longer access the buckets.

## Storage and access

Limit each identity to the declared buckets and grants where the backend
allows it. Enable Kubernetes Secret encryption at rest and restrict Secret
read access. Keep credentials out of Git, logs, and status fields. Use an
external secret manager when the deployment requires it.
