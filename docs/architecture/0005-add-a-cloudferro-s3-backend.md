# ADR-005: Add a CloudFerro S3 Backend with Project Boundaries

## Status

Accepted

## Date

2026-09-14

## Context

CloudFerro uses OpenStack projects for identity and Ceph for S3-compatible
object storage. A Keystone EC2 credential belongs to one user and one project.
CloudFerro bucket policies identify another project as
`arn:aws:iam::<PROJECT_ID>:root`.

Users with S3 access in the same project can access that project's containers.
Separate credentials can be revoked separately, but they do not isolate
buckets between users in one project.

Provider-openstack reads the project scope from its JSON authentication
configuration. A ProviderConfig has no separate field that overrides the
project in that configuration.

## Decision

Use the OpenStack project as the CloudFerro team and S3 authorization
boundary. Assign separate projects to teams that need isolation.

Before Storage reconciliation, `cloudferro/dependencies/iam.sh apply` selects
existing projects by an anchored project-name pattern. It creates one
controller user without a default project, assigns the configured member role
in each selected project, and verifies project-scoped Object Storage access.
The bootstrap administrator login must be able to list these projects, create
the controller user in the domain, and assign the project role. The controller
user needs only the configured project role.
Project creation, portal activation, wallet configuration, and billing remain
outside the script.

`apply` writes one private local credential file that contains the shared
controller identity and an array of selected project IDs. It updates the
project array after all project checks pass. The `render-secrets` action reads
only that file and prints one
namespaced Secret manifest for each project. Its name is
`cloudferro-project-<project-id>` and its key is `config`. The JSON value
contains the controller credentials and the project ID as `tenant_id`. A
static `storage` EnvironmentConfig contains only endpoint and region
settings. This is the same default EnvironmentConfig name as the other
backends.

A Storage selects the generic Composition and declares its project ID:

```yaml
metadata:
  labels:
    storages.pkg.internal/backend: cloudferro
  annotations:
    storages.pkg.internal/cloudferro-project-id: 0123456789abcdef0123456789abcdef
spec:
  crossplane:
    compositionSelector:
      matchLabels:
        provider: cloudferro
```

The Composition creates one namespaced OpenStack ProviderConfig per Storage.
It refers to the deterministic project Secret. All OpenStack managed resources
for that Storage refer to the composed ProviderConfig. `ContainerV1` therefore
uses the project from the Secret. `EC2CredentialV3` also uses the current auth
scope; the Composition does not pass `projectId` or `userId`.

The Composition creates buckets with `ContainerV1` and one EC2 credential for
each retained Storage credential generation. It publishes the standard
consumer Secret. It does not create OpenStack users or role assignments.

For an active cross-project grant, the Composition resolves one discoverable
Storage with the matching principal. It reads that Storage's
`storages.pkg.internal/cloudferro-project-id` annotation and creates an AWS S3
BucketPolicy with the grantee project's `root` ARN. It does not use a peer
ProviderConfig lookup. Pending requests and `None` grants do not add access.

The project annotation is an authorization selector. Admission controls must
limit which users and namespaces can set each project ID. Secret read access
must be limited to provider workloads and trusted operators.

## Consequences

- Every S3 user in one project can access that project's buckets. EC2 key
  rotation and revocation do not provide user-level bucket isolation.
- The runtime controller receives a project member role. It does not receive
  user-administration or role-administration permission.
- One shared controller user can serve many projects. Separate controller
  users also work because every project Secret contains a complete identity.
- Compromise of a shared controller password affects all projects assigned to
  that user. Separate per-project Secrets reduce Kubernetes access scope but
  do not change the OpenStack identity scope.
- The Composition owns per-Storage ProviderConfigs. The IAM bootstrap owns
  only OpenStack identities and role assignments. Operators apply the rendered
  project Secrets and the static EnvironmentConfig.
- The bootstrap script does not remove users, role assignments, or Secrets.
  Operators must review dependent Storage resources before manual cleanup.
- Removing a bucket requests deletion under Crossplane's default management
  policy. The Composition does not force deletion of a non-empty bucket.

## Implementation checks

Test bootstrap idempotency, project binding, ownership checks, and credential
recovery. Verify that the runtime user can create an EC2 credential for itself
in the Secret's project but cannot administer users or roles. Test bucket
creation, credential authentication, cross-project grants, `None` grants, and
same-project access. Keep credentials out of Git, logs, and resource specs.
