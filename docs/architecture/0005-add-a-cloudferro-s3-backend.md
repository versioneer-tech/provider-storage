# ADR-005: Add a CloudFerro S3 Backend with Project Slots

## Status

Accepted

## Date

2026-09-14

## Context

Provider Storage needs separate S3 credentials and bucket access for teams on
CloudFerro. CloudFerro uses OpenStack for project and credential management and
Ceph for S3-compatible object storage. A Keystone EC2 credential belongs to a
user and a project. Separate credentials can be revoked separately, but they
do not give users separate bucket permissions within one project.

CloudFerro's S3 bucket policies identify a project as
`arn:aws:iam::<PROJECT_ID>:root`. They grant selected access to a bucket to
**other projects**. They cannot restrict one user in the bucket owner's project
to one bucket while another user in that project uses a different bucket.
CloudFerro states that users in the same project can access all containers in
that project. This differs from OVHcloud, where a user S3 policy can restrict
that user's bucket access.

## Decision

Use the **OpenStack project as the CloudFerro team and S3 authorization
boundary**. Do not treat a consumer user, EC2 credential, or bucket policy as
an isolation boundary between users in the same project.

Before Storage reconciliation, `cloudferro/dependencies/iam.sh apply` will
discover the bootstrap user's existing projects and reconcile only the names
that match a mandatory, configurable numbered pattern. It will create one
controller user without a default project, assign that user project roles in
every matching project, and prepare one project-scoped OpenStack
`ProviderConfig` per slot in the target cluster and namespace. The bootstrap
identity must be able to create the controller user and assign roles in the
selected projects. For example, five matching projects produce one controller
user and five ProviderConfigs. The ProviderConfigs reuse one provider-openstack
controller installation.

Provider-openstack reads the project scope from the JSON authentication
configuration. It does not have a separate project field in `ProviderConfig`.
The bootstrap therefore publishes one shared Secret with one key per slot.
Each key contains the same controller user ID and password with a different
`tenant_id`. Each ProviderConfig selects its slot key and stores the project
name, project ID, and controller user ID as annotations. The slot name stays
the selector, and bootstrap checks these annotations and Secret keys before
it reconciles or deletes an existing slot.

The bootstrap takes an anchored project-name pattern, a bootstrap OpenStack
CLI profile or active `v3token` shell login, and a project role name or ID.
The role defaults to `member` and can be overridden for deployments that use
another name, such as `_member_`. It assigns this role to the shared controller
user in each slot project. The controller does not receive `admin`: it creates
EC2 credentials only for itself and manages containers in its selected
project. The bootstrap verifies password authentication, the project token,
and Object Storage access before publishing the slot. It also
creates a matching cluster-scoped `EnvironmentConfig` and selectable
Composition. CloudFerro's portal activation and billing remain separate.

Each slot has a stable name such as `cloudferro-0001`, its own project ID, and
a matching selectable Composition. A `Storage` selects the slot with the
existing Composition selector:

```yaml
metadata:
  labels:
    storages.pkg.internal/backend: cloudferro-0001
spec:
  crossplane:
    compositionSelector:
      matchLabels:
        provider: cloudferro-0001
```

The Composition must use that slot's ProviderConfig for project-scoped bucket
operations. `ContainerV1` has no project ID field, so its ProviderConfig sets
the project scope. The four-digit suffix provides at most 10,000 distinct slot
names.
The OpenStack region and S3 signing region are separate settings. CREODIAS
WAW3-2 uses `WAW3-2` for OpenStack and `RegionOne` for S3 clients.
The Storage backend label and Composition selector must agree; reconciliation
fails if they name different slots.
The selected slot must belong to the Storage's team; platform controls must
prevent a team from selecting another team's slot.

The CloudFerro Composition will create buckets in the selected project through
the OpenStack Object Storage `ContainerV1` resource. For each Storage and
retained generation, it creates a project-scoped EC2 credential for the shared
controller user and publishes the existing consumer Secret contract. Each EC2
credential is a separate S3 keypair, not a separate Keystone principal. It can
be rotated and revoked independently, but it inherits the project's access.
The Composition does not create a consumer OpenStack user or role assignment.

It uses S3 bucket policies only when a bucket owner grants access to a
**different** project. Such a grant names the grantee project's `root` ARN and
limits the actions and bucket or object resources. A pending request or `None`
grant must not add a cross-project allow. A same-project grant cannot promise
user-level `ReadOnly`, `WriteOnly`, or `None` access. The Composition uses the
AWS S3 provider with a CloudFerro endpoint to manage `BucketPolicy` resources
because `ContainerV1` does not expose bucket policies. It resolves the
grantee's project ID from the grantee Storage's numbered slot.

## Consequences

- Every user with S3 access in one slot project can access that project's
  buckets. Separate EC2 keys support rotation and revocation, not bucket
  isolation. Separate teams need separate slots.
- A slot can hold several `Storage` resources for one team, but their users
  share the same project-level access. Slot assignment must be controlled
  outside the consumer's editable bucket fields.
- Compromise of the shared controller password affects every assigned slot.
  Per-project ProviderConfigs scope normal reconciliation, but they do not
  make the shared identity least-privilege across projects. Access to the
  shared Secret and local identity file must be tightly restricted.
- Project quotas, region activation, and billing configuration apply to each
  slot. `iam.sh apply` must verify that a project is usable before it publishes
  the slot. Project creation and activation take place outside this script.
- Bootstrap deletion selects the same numbered projects, checks for active
  `Storage` resources, and removes only the selected Secret keys, controller
  role assignments, and managed cluster resources. It does not delete the
  shared controller user, projects, buckets, or consumer resources.
- Removing a bucket from `spec.buckets`, or removing its `Storage`, requests
  bucket deletion under the default Crossplane management policy. The
  Composition does not force deletion of objects in a non-empty bucket. A slot
  must not be reassigned to another team until buckets, credentials, role
  assignments, and cross-project grants are removed and their absence is
  verified.

## Implementation checks

Before this backend is offered, prove that `iam.sh apply` is idempotent, does
not adopt an unrelated project, and can establish the required controller
permissions. Verify that CloudFerro permits the managed user, role assignment,
and self-service EC2 credential flow. The runtime identity must not mint EC2
credentials for another user or an unassigned project. Confirm that the
OpenStack container resource creates a bucket visible through CloudFerro S3,
that EC2 credentials authenticate in their intended project, and that
cross-project `ReadOnly`, `WriteOnly`, `ReadWrite`, and `None` grants allow and
deny the expected S3 operations. Test same-project access explicitly to
preserve the documented limitation. Keep credentials out of Git, logs, and
resource specs.
