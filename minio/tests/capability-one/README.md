# MinIO Capability 1 Fixtures

These cases follow the shared T0–T10 story in the
[test strategy](../../../../docs/test-strategy.md). The live MinIO run
confirmed bucket provisioning, normalized Secrets, pending-request denial,
`ReadWrite` and `ReadOnly` grants, and cross-principal S3 access.

Each `tNN-principal_action/` directory has the YAML claim input at that step, the
required peer and environment resources at that step, the observed
resources from the preceding step when that principal already existed,
and the reviewed expected render. A step can have more than one case when
a peer change affects both owner and requester Compositions. T0 is the
empty live-test precondition and has no render case.

The corresponding applied YAML changes are in
`tests/integration/capability-one/steps/`. A name such as
`t04-s-jeff_grant-readwrite_s-joe` identifies the timeline change; the
additional `t04-s-joe_receive-readwrite_s-jeff-shared` fixture verifies its
effect on Joe's Composition.

The observed files came from a live Kind run, then were reduced to fields
the Composition needs. Credential values and generated names are stable
test substitutes. Do not copy a raw Secret or unreviewed capture here.

Run the cases with `tests/unit.bash minio` from the repository root.
