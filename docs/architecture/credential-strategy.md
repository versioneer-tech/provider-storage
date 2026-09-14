# Consumer Credential Strategy

Last reviewed: 2026-09-12

This document defines how bucket consumers receive and replace credentials.
It is a living architecture strategy. An ADR records one accepted or proposed
decision. This strategy connects those decisions and states the direction for
future consumer authentication profiles.

Crossplane providers use separate credentials to create and delete cloud
resources. Provider authentication differs by cloud and is outside the scope
of this document. See the
[cloud IAM bootstrap guide](../how-to-guides/cloud-iam-bootstrap.md). Provider
credentials must never be published in a consumer Secret.

## Goals

Provider Storage must:

- keep the public `Storage` API independent of the selected backend;
- give common S3 clients a consistent connection contract;
- support credential replacement without a new Secret reference;
- limit every identity to its required resources; and
- allow provider-native workload identity when the backend and consumer both
  support it.

## Current portable consumer contract

The Compositions create an S3 access-key pair for each credential generation.
They publish the current pair in a Kubernetes Secret named after
`spec.principal`, in the same namespace as the `Storage` resource.

`spec.providerIdentity` can set a shorter provider-native user name without
changing the logical principal or consumer Secret name. Each backend applies
its own naming convention to that identity.

Providers can also create generation-specific connection Secrets such as
`<principal>-20260911`. Without rollover, the internal connection Secret is
`<principal>-credentials`. These Secrets are provider-native. Consumers must
use the stable `<principal>` Secret.

The required keys are:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

The optional connection keys are:

- `AWS_ENDPOINT_URL`
- `AWS_REGION`
- `AWS_S3_FORCE_PATH_STYLE`

A Composition must fail closed when a required key is absent. It must copy
only the documented keys from a provider connection Secret. It must not copy
an arbitrary provider result map.

This static access-key pair is the portable baseline for the backends and
consumers that Provider Storage supports today. All current backend resource
models can issue an access-key pair. Common S3 clients, including AWS SDKs and
rclone, can use the same key names and endpoint settings. This contract does
not depend on the cloud that hosts the Kubernetes cluster.

This baseline is not the only possible cloud-neutral design, and it is not the
preferred credential type for every deployment. Static keys are long-lived
secrets. They must be stored, distributed, rotated, and revoked.
Provider-native workload identity avoids several of these risks when all
parts of the request path support it.

## Rollover contract

[ADR-002](0002-rotate-static-credentials-by-generation.md) defines static-key
rollover. Provider Storage creates generation-specific credentials and keeps
the configured number of generations active. It writes the current generation
to the stable consumer Secret.

The overlap lets a consumer reload the stable Secret before the previous key
is revoked. Rollover does not make a static key temporary. It also does not
guarantee an exact rotation time. Rotation occurs during a successful
Crossplane reconciliation after a period boundary.

The consumer must reload the Secret or restart before the overlap ends.
Provider Storage does not force an application to reload its credential.

Operators must test both sides of rollover:

1. The current and retained credentials can access only their allowed buckets.
2. A generation outside `maxToKeep` is revoked.

## Other possibilities

Consumer credentials are used in different locations. Some clients run in the
platform cluster. Others run in another cluster or outside the platform. The
current portable contract therefore does not bind credentials to a client
identity or execution location. It uses static access keys and scopes each
identity as narrowly as the provider permits, typically to the declared buckets
and grant modes. These credentials are still long-lived and transferable, so
they remain a security risk.

A workload can fetch the current key pair through a credential helper or a
protected HTTP endpoint instead of reading the consumer Secret directly.
Clients that support the AWS credential chain can use a helper configured with
[`credential_process`](https://docs.aws.amazon.com/sdkref/latest/guide/feature-process-credentials.html)
or an HTTP endpoint (set
[`AWS_CONTAINER_CREDENTIALS_FULL_URI`](https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html)
in the workload). A platform service could serve the current credentials from
the consumer Secret through either interface. This does not require cloud STS
or a custom STS service because the source remains the existing access-key
pair. The helper or endpoint must authenticate callers and handle key rollover;
the retrieved keys remain static cloud credentials. This is a possible workload
integration, not a feature Provider Storage provides today.

When all consumers can be limited to workloads inside a supported cluster, a
provider-specific profile can use workload identity federation. Where the
cloud supports this pattern, its token service issues short-lived credentials
for a Kubernetes service account. Examples are AWS IRSA or EKS Pod Identity
with AWS STS, Microsoft Entra Workload ID on AKS, and GKE Workload Identity
Federation. Each option depends on the cloud, cluster, and client credential
chain. It also needs explicit selection and live trust, refresh, revocation,
and teardown tests. These are possible future profiles, not current support
promises.

## Security requirements

- Treat read access to a consumer Secret as access to its cloud permissions.
- Enable Kubernetes Secret encryption at rest and use least-privilege RBAC.
- Do not put credentials in Git, logs, status fields, or command output.
- Use an external secret manager when the deployment requires stronger
  controls than a Kubernetes Secret provides.
- Scope consumer permissions to the declared buckets and grant modes.
- Prefer temporary consumer credentials when a tested native profile is
  available.
- Verify consumer revocation and access boundaries in the real cloud.

## Current state

| Area | Current state |
| --- | --- |
| Portable consumer credentials | Static S3 access-key pairs in the stable consumer Secret. |
| Consumer rollover | Generation-based overlap through `spec.credentialsRollover`. |
| Provider-native consumer identity | Not implemented. |
