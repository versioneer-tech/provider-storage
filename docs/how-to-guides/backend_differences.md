# Backend differences

Each backend Composition maps the `Storage` API to its provider's bucket,
identity, and access resources.

## Where access rules live

| Backend | Bucket | Identity and credential | Access rule |
| --- | --- | --- | --- |
| MinIO | `Bucket` | `User` with generated credentials | Named `Policy` resources; the `User` lists their names. |
| AWS | S3 `Bucket` | IAM `User` and `AccessKey` | IAM `Policy` resources linked to the user by `UserPolicyAttachment`. |
| OTC | OBS `Bucket` | IAM `UserV3` and `CredentialV3` | One OBS `BucketPolicy` per bucket, with user IDs in `Principal`. |
| OVHcloud | Regional S3 `ProjectStorage` | Project `User` and `S3Credentials` | One consolidated `S3Policy` document per user, linked by its observed numeric user ID. |
| CloudFerro | Project-scoped OpenStack `ContainerV1` | One shared Keystone controller user with one `EC2CredentialV3` per Storage generation | The project owns access. An AWS S3 `BucketPolicy` uses the CloudFerro endpoint to share with another project's `root` ARN. |

## Backend limits

Storage namespaces separate Kubernetes objects. The API does not enforce
which backend, environment, principal, or CloudFerro project a tenant can
select. Deployments need admission and RBAC rules for these choices.

OVHcloud uses a separate, stable project user as the bucket owner. Consumer
credential users can rotate without a change to the bucket owner ID.
Each credential user has one combined S3 policy.

OTC must observe grantee user IDs before it can build bucket policies.
It resolves each grantee through a discoverable peer Storage and observes
each of that peer's retained credential users. Policies include the observed
retained owner and grantee identities and omit expired generations.

CloudFerro uses the project in the
`storages.pkg.internal/cloudferro-project-id` annotation. The Composition
creates a project-scoped OpenStack ProviderConfig from the matching project
Secret. Every user with S3 access in that project can access its containers.
Separate credentials do not isolate users in one project.

For cross-project access, CloudFerro resolves the grantee Storage's project
annotation and grants that project's `root` ARN. Supporting resources keep
the EC2 credential and AWS provider configuration until the bucket policy is
deleted. Admission rules must restrict who can select each project.

## From request to access

The requester records a target bucket in `bucketAccessRequests`. The bucket
owner records its decision in `bucketAccessGrants`. These are fields on
`Storage` resources; no backend creates a separate cloud request resource. The
owner's grant selects `ReadOnly`, `WriteOnly`, `ReadWrite`, or `None`. The
[permission guide](permissions.md) shows the resource fields and an example.

| Backend | Request pending, with no owner grant | Owner grants access | Owner sets `None` or removes the grant |
| --- | --- | --- | --- |
| MinIO | The request adds no policy name to the requester's `User`. | The owner creates a named grant `Policy`; the requester lists that policy on each retained `User`. | The requester stops listing the policy. With `None`, the owner's named policy has no allow statements. |
| AWS | The request creates no `UserPolicyAttachment` for the target bucket. | The owner creates an IAM grant `Policy`; the requester attaches it to each retained IAM `User`. | The requester has no attachment. With `None`, the owner omits the grant policy. |
| OTC | The request field does not change the generated policy. | The owner's grant adds allow statements for the observed grantee ID to the bucket's `BucketPolicy`, even if the grantee did not record a request. | The bucket policy has no allow statements for that grantee. `None` does not add an explicit deny. |
| OVHcloud | Each retained requester's `S3Policy` gets an explicit deny for the requested bucket. | The policy replaces that deny with allow statements for the granted actions. | While the request remains, the policy contains an explicit deny for that bucket. |
| CloudFerro | The request has no cloud-side effect. | The owner adds allow statements for the grantee project's `root` ARN to the bucket policy. | `None` or grant removal adds no cross-project allow. If no active grants remain, the bucket policy is removed. This does not restrict a user who is already in the owner's project. |

For the owner-label requirement and the distinction between bucket visibility
and access, see [Discoverable Buckets](permissions.md#discoverable-buckets).

Removing a request also differs by backend. MinIO removes the grant policy
name from the requester's users, and AWS removes the grant attachments. OTC
does not use the request field, so removing it has no policy effect. OVHcloud
removes the bucket-specific rule from the requester's user policy. OVHcloud
then falls back to ACLs when no policy rule matches; removing a request alone
does not prove that S3 access is denied. See the [OVHcloud policy evaluation
rules](https://docs.ovhcloud.com/en/guides/storage-and-backup/object-storage/s3-identity-and-access-management).

These descriptions are the resources the Compositions request. Cloud-side
enforcement and revocation are asynchronous and need positive and negative
S3 tests.

## Deletion behavior

All bucket resources use the default Crossplane management policy. Removing a
bucket from `spec.buckets`, or removing its `Storage` resource, requests bucket
deletion. Deletion behavior is provider-specific. A provider can reject the
request when it cannot empty the bucket or when its cloud identity lacks the
required delete permission.
