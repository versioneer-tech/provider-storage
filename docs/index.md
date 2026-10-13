# Provider Storage

Provider Storage defines one namespaced Crossplane `Storage` API for S3
buckets, consumer credentials, access grants, and lifecycle rules. Platform
operators configure the storage backends. Users do not need to manage
provider-specific identities or policies.

## Responsibility boundary

Platform operators:

- install the selected backend package and its dependencies;
- configure the controller identity and backend settings;
- control who can select a backend, environment, or CloudFerro project; and
- monitor the generated provider resources and credentials.

Users and higher-level platform services create `Storage` resources. Each
resource represents one principal and can define owned buckets, requests for
other buckets, grants to other principals, credential rollover, and lifecycle
rules.

Crossplane creates the backend-specific resources and publishes a normalized
consumer Secret in the same namespace as the `Storage` resource. Provider
controller credentials are separate and must never be copied to this consumer
Secret.

!!! warning "Prepare cloud IAM before use"

    Managed cloud backends require controller credentials. Prepare them as
    described in the
    [cloud IAM guide](how-to-guides/cloud-iam-bootstrap.md).

## Documentation path

1. Compare the supported implementations in
   [Backend differences](how-to-guides/backend_differences.md).
2. Install the selected backend with the
   [Installation guide](how-to-guides/installation.md).
3. Create and inspect resources with
   [Usage and concepts](how-to-guides/usage_concepts.md).
4. Configure sharing with the
   [Permission model](how-to-guides/permissions.md).
5. Use the [API reference](reference-guides/api.md) for field details.

For repository development and live validation, use the
[local test guide](how-to-guides/local_setup.md).
