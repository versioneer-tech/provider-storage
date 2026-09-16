# Provider Storage – Backend Differences

The `Storage` API defines the same buckets, credentials, access requests,
grants, and lifecycle rules for every backend. Each Composition maps that API
to its provider's bucket and access resources. The table below compares the
available implementations.

## Where Access Rules Live

| Backend | Bucket | Identity and credential | Access rule |
| --- | --- | --- | --- |
| MinIO | `Bucket` | `User` with generated credentials | Named `Policy` resources; the `User` lists their names. |
| AWS | S3 `Bucket` | IAM `User` and `AccessKey` | IAM `Policy` resources linked to the user by `UserPolicyAttachment`. |
| OTC | OBS `Bucket` | IAM `UserV3` and `CredentialV3` | One OBS `BucketPolicy` per bucket, with user IDs in `Principal`. |
| OVHcloud | Regional S3 `ProjectStorage` | Project `User` and `S3Credentials` | One consolidated `S3Policy` document per user, linked by `userIdRef`. |
| CloudFerro | Project-scoped OpenStack `ContainerV1` | One shared Keystone controller user with one `EC2CredentialV3` per Storage generation | The project owns access. An AWS S3 `BucketPolicy` uses the CloudFerro endpoint to share with another project's `root` ARN. |

### MinIO

- **Bucket:** The Composition creates a MinIO `Bucket` for each claimed bucket.
- **Identity and credential:** It creates a `User` for each retained credential
  generation.
- **Access rule:** It creates named `Policy` resources for owned buckets and
  grants. Each `User` lists the policy names that apply to that generation.

### AWS

- **Bucket:** The Composition creates an S3 `Bucket` for each claimed bucket.
- **Identity and credential:** It creates an IAM `User` and `AccessKey` for
  each retained credential generation.
- **Access rule:** It creates IAM `Policy` resources for owned buckets and
  grants. A `UserPolicyAttachment` links each applicable policy to a user.
  The Composition does not create S3 bucket policies.

### OTC

- **Bucket:** The Composition creates an OBS `Bucket`. Consumers use its
  S3-compatible endpoint.
- **Identity and credential:** It creates an IAM `UserV3` and `CredentialV3`
  for each retained credential generation.
- **Access rule:** It creates one OBS `BucketPolicy` for each bucket named in
  the claim's buckets or grants.
  The policy contains the observed IDs of allowed users in `Principal`.
  The Composition must observe those IDs before it can build the policy.

### OVHcloud

- **Bucket:** The Composition creates a regional S3-compatible
  `ProjectStorage` bucket.
- **Owner:** It creates a separate, stable project `User` without
  `S3Credentials` or an `S3Policy`. This user owns the buckets and keeps their
  owner ID unchanged when consumer credentials rotate or a credential user is
  replaced.
- **Identity and credential:** It creates a project `User` and `S3Credentials`
  for each retained credential generation.
- **Access rule:** It creates one `S3Policy` per generation user. The policy
  document contains statements for owned buckets and requested buckets,
  with allow or deny rules based on the owner's grant. `userIdRef` links the
  policy to the user. This is a separate
  Crossplane resource that sets the user's policy document; the document is
  not inline in the `User` resource. Regional OVHcloud does
  not support bucket policies. See the [OVHcloud access guide](https://docs.ovhcloud.com/en/guides/storage-and-backup/object-storage/s3-identity-and-access-management).

### CloudFerro

- **Bucket:** A slot-specific OpenStack ProviderConfig scopes each
  `ContainerV1` to one project. The slot name is selected with
  `spec.crossplane.compositionSelector.matchLabels.provider`, such as
  `cloudferro-0001`.
- **Identity and credential:** One controller user receives the configured
  member role in every managed project. The Composition creates retained EC2
  credential generations for that user in the selected project.
- **Access rule:** Users in one project can access its containers. For an
  active grant, the Composition resolves the grantee Storage's project slot
  and creates an AWS S3 `BucketPolicy` against the CloudFerro endpoint. The
  policy grants the grantee project's `root` ARN. It cannot isolate users in
  the owner project. Usage resources keep the EC2 credential, AWS provider
  configuration, and AWS provider credential Secret until each bucket policy
  is deleted.
  See the
  [bucket-sharing guide](https://docs.cloudferro.com/en/latest/s3/Bucket-sharing-using-s3-bucket-policy-on-CloudFerro-Cloud.html).

MinIO and OVHcloud both place consumer access on the user. MinIO users list
multiple named policies. OVHcloud has one policy document per user, so the
Composition combines all bucket rules into that document. AWS also uses user
policies, but needs explicit attachment resources. OTC places the consumer
grant rules on each bucket.

## From Request to Access

The requester records a target bucket in `bucketAccessRequests`. The bucket
owner records its decision in `bucketAccessGrants`. These are fields on
`Storage` claims; no backend creates a separate cloud request resource. The
owner's grant selects `ReadOnly`, `WriteOnly`, `ReadWrite`, or `None`. The
[permission guide](permissions.md) shows the claim fields and an example.

| Backend | Request pending, with no owner grant | Owner grants access | Owner sets `None` or removes the grant |
| --- | --- | --- | --- |
| MinIO | The request adds no policy name to the requester's `User`. | The owner creates a named grant `Policy`; the requester lists that policy on each retained `User`. | The requester stops listing the policy. With `None`, the owner's named policy has no allow statements. |
| AWS | The request creates no `UserPolicyAttachment` for the target bucket. | The owner creates an IAM grant `Policy`; the requester attaches it to each retained IAM `User`. | The requester has no attachment. With `None`, the owner's grant policy has no allow statements. |
| OTC | The request field does not change the generated policy. | The owner's grant adds allow statements for the observed grantee ID to the bucket's `BucketPolicy`, even if the grantee did not record a request. | The bucket policy has no allow statements for that grantee. `None` does not add an explicit deny. |
| OVHcloud | Each retained requester's `S3Policy` gets an explicit deny for the requested bucket. | The policy replaces that deny with allow statements for the granted actions. | While the request remains, the policy contains an explicit deny for that bucket. |
| CloudFerro | The request has no cloud-side effect. | The owner adds allow statements for the grantee project's `root` ARN to the bucket policy. | `None` or grant removal adds no cross-project allow. If no active grants remain, the bucket policy is removed. This does not restrict a user who is already in the owner's project. |

For the owner-label requirement and the distinction between bucket visibility
and access, see [Discoverable Buckets](permissions.md#discoverable-buckets).

OTC builds policies from the bucket owner's grants and observed grantee user
IDs. Its current Composition does not use peer `Storage` resources to resolve
requests. Its grantee observer uses the unsuffixed logical name, while created
users have generation suffixes. This grant path still needs a live test.

Removing a request also differs by backend. MinIO removes the grant policy
name from the requester's users, and AWS removes the grant attachments. OTC
does not use the request field, so removing it has no policy effect. OVHcloud
removes the bucket-specific rule from the requester's user policy. OVHcloud
then falls back to ACLs when no policy rule matches; removing a request alone
does not prove that S3 access is denied. See the [OVHcloud policy evaluation
rules](https://docs.ovhcloud.com/en/guides/storage-and-backup/object-storage/s3-identity-and-access-management).

These descriptions are the resources the Compositions request. Cloud-side
enforcement and revocation are asynchronous and need positive and negative
S3 tests, especially for OTC retained users and OVHcloud ACL fallback.

## Verification Status

The OVHcloud integration run created one `Storage` with two buckets in DE.
The claim reached Ready, and both buckets passed S3 object round trips. A
composed peer was denied before a grant, could read but not write under
`ReadOnly`, and lost read access after `None`
reconciled automatically. The policy updated within about a minute, but a read
shortly after it synced still succeeded. Other grant levels, credential
rotation, lifecycle, and teardown still need live tests.

All bucket resources use the default Crossplane management policy. Removing a
bucket from `spec.buckets`, or removing its `Storage` claim, requests bucket
deletion. A backend can reject the request while the bucket contains data; the
Compositions do not force removal of its objects.
