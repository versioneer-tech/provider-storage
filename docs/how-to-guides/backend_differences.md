# Provider Storage – Backend Differences

The `Storage` API defines the same buckets, credentials, access requests,
grants, and lifecycle rules for every backend. Each Composition maps that API
to its provider's bucket and access resources. The backends are MinIO, AWS S3,
OTC OBS, and OVHcloud Object Storage.

## Where Access Rules Live

| Backend | Bucket | Identity and credential | Access rule |
| --- | --- | --- | --- |
| MinIO | `Bucket` | `User` with generated credentials | Named `Policy` resources; the `User` lists their names. |
| AWS | S3 `Bucket` | IAM `User` and `AccessKey` | IAM `Policy` resources linked to the user by `UserPolicyAttachment`. |
| OTC | OBS `Bucket` | IAM `UserV3` and `CredentialV3` | One OBS `BucketPolicy` per bucket, with user IDs in `Principal`. |
| OVHcloud | Regional S3 `ProjectStorage` | Project `User` and `S3Credentials` | One consolidated `S3Policy` document per user, linked by `userIdRef`. |

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
  `ProjectStorage` bucket. It uses a separate, stable project `User` as the
  bucket owner.
- **Identity and credential:** It creates a project `User` and `S3Credentials`
  for each retained credential generation.
- **Access rule:** It creates one `S3Policy` per generation user. The policy
  document contains statements for owned buckets and requested buckets,
  with allow or deny rules based on the owner's grant. `userIdRef` links the
  policy to the user. This is a separate
  Crossplane resource that sets the user's policy document; the document is
  not inline in the `User` resource. Regional OVHcloud Object Storage does
  not support bucket policies. See the [OVHcloud access guide](https://docs.ovhcloud.com/en/guides/storage-and-backup/object-storage/s3-identity-and-access-management).

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

MinIO, AWS, and OVHcloud load peer `Storage` resources in the same namespace
to resolve a request against the bucket owner's grant. To be found by this
lookup, an owner `Storage` must carry this label:

```yaml
metadata:
  labels:
    storages.pkg.internal/discoverable: "true"
```

The `spec.buckets[].discoverable` field is for visibility to clients; these
Compositions do not check it when resolving access. After selecting a peer by
label, they check the peer's bucket and matching grant.

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

The OVHcloud direct resources passed readiness checks in a disposable DE
project. A composed `Storage` reached Ready and its five-key consumer Secret
passed an S3 round trip. A composed peer was denied before a grant, could
read but not write under `ReadOnly`, and lost read access after `None`
reconciled automatically. The policy updated within about a minute, but a read
shortly after it synced still succeeded. Other grant levels, credential
rotation, lifecycle, and teardown still need live tests.

The OVHcloud Composition omits the managed `Delete` action from production
buckets to avoid deleting user data when a `Storage` claim is removed.
Disposable direct probes include `Delete` for cleanup.
