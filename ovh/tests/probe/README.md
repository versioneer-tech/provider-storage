# OVHcloud direct-resource schema probe

Run `ovh/tests/probe/test.bash` to render four namespaced managed resources
without an observed owner. A second render uses a synthetic owner ID and adds
`ProjectStorage`. Both outputs and the namespaced `ProviderConfig` fixture are
validated against the pinned provider package. This probe does not contact
OVHcloud or use credentials. It needs Docker, `crossplane`, and `yq` v4. The
validator downloads the pinned provider package when it is not cached.

The bucket uses numeric `ownerId`, `hideObjects: true`, and management policies
that omit `Delete`. The provider schema has no `deletionPolicy` field. The
control-plane region candidate is `DE`; the S3 client region is `de` with
endpoint `https://s3.de.io.cloud.ovh.net`. The schema accepts any string for
`regionName`, so a live create must confirm the case and endpoint pair.

The pinned provider publishes `accessKeyId` in `S3Credentials` status. A live
direct-resource probe found two non-empty connection Secret fields:
`access_key_id` and `attribute.secret_access_key`. The latter includes the
provider's `attribute.` prefix. The observed status field names do not
include a secret key. The backend Composition must map the prefixed field to
the normalized consumer Secret.

Live questions before a backend Composition can rely on these resources:

- If the controller creates a bucket with `ownerId` set to a project user ID,
  does OVHcloud keep that owner, and can it update the owner later?
- Does the bucket remain in OVHcloud when its managed resource is removed
  without the `Delete` management action?
- Does `hideObjects: true` keep object names out of observed status after
  actual uploads?
- Does the controller identity have every API action needed for create,
  observe, update, and secret retrieval?
- Does the generated connection Secret contain both expected keys after
  reconciliation, and does status omit the secret key?
- Do not infer access denial from an omitted policy action. Test allowed and
  denied S3 calls, including the documented bucket-owner `FULL_CONTROL` ACL
  fallback, with real credentials.
