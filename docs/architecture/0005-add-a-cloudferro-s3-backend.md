# ADR-005: Add a CloudFerro S3 Backend with Project Boundaries

## Status

Accepted

## Date

2026-09-14; revised 2026-11-16

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

Before Storage reconciliation, an administrator creates a controller user
without a default project, assigns the configured member role in each
selected project, and verifies project-scoped Object Storage access. The
administrator must have permission to create the controller user in the
domain and assign the project role. The controller user needs only the
configured project role.

Operators provide one namespaced controller Secret for each project. Its name is
`cloudferro-project-<project-id>` and its key is `config`. The JSON value
contains the controller credentials and the project ID as `tenant_id`.
Operators create a namespaced OpenStack ProviderConfig that refers to this
Secret. A project EnvironmentConfig holds `storage.projectId`,
`storage.providerConfigName`, endpoint, and region settings. The project ID
must match the Secret's authentication scope.

A Storage selects the generic Composition and its project EnvironmentConfig:

```yaml
spec:
  environmentName: storage-cloudferro-0123456789abcdef0123456789abcdef
  crossplane:
    compositionSelector:
      matchLabels:
        provider: cloudferro
```

All OpenStack managed resources for a Storage refer to the ProviderConfig
named by its EnvironmentConfig. Storages in one namespace can share the
project ProviderConfig. The Composition does not create or own it.
`ContainerV1` uses the project from the Secret. `EC2CredentialV3` uses the current auth
scope; the Composition does not pass `projectId` or `userId`.

The Composition creates buckets with `ContainerV1` and one EC2 credential for
each retained Storage credential generation. It publishes the standard
consumer Secret. It does not create OpenStack users or role assignments.

For an active cross-project grant, the Composition resolves one discoverable
Storage with the matching principal. It resolves that Storage's
EnvironmentConfig and creates an AWS S3 BucketPolicy with the grantee
project's `root` ARN. It does not use a peer ProviderConfig lookup. The
Composition still creates an AWS ProviderConfig from its generated EC2
credentials for S3 bucket policies. Pending requests and `None` grants do
not add access.

The environment selector is an authorization selector. Admission controls
must limit which users and namespaces can select each project environment.
Only trusted operators can change project EnvironmentConfigs or ProviderConfigs.
Secret read access must be limited to provider workloads and trusted operators.

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
- The IAM bootstrap owns OpenStack identities and role assignments.
  Operators apply project Secrets, OpenStack ProviderConfigs, and project
  EnvironmentConfigs. A platform can generate the two configuration resources
  from project Secret names with Kyverno. The Composition owns only its
  internal AWS ProviderConfig.
- EnvironmentConfigs are cluster-scoped. Each Storage namespace needs its
  own OpenStack ProviderConfig and project Secret. A shared project
  EnvironmentConfig needs one source of configuration.
- Operators must review dependent Storage resources before removing controller
  users, role assignments, or project Secrets.
- Removing a bucket requests deletion under Crossplane's default management
  policy. The Composition does not force deletion of a non-empty bucket.
