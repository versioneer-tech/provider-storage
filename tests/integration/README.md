# Provider Integration Tests

These tests use an ephemeral Kind cluster named `provider-storage-it`.
Every command uses the explicit `kind-provider-storage-it` context. The
scripts do not use another Kubernetes context or create a missing cluster.

The workflow keeps one `Storage` with two buckets for each deployed backend in
the `provider-storage-it` namespace. Each resource has the
`storages.pkg.internal/backend` inventory label and an explicit Crossplane
composition selector.

## Prerequisites

Install Docker, Kind, kubectl, Helm, Crossplane CLI, dyff, and jq. Run the unit
suite before integration. Ask the operator before an agent creates the local
test cluster. After approval, run:

```bash
tests/integration/create-cluster.bash
```

Clear `KUBECONFIG` first if a cloud login script selected another cluster.
The integration scripts use only the `kind-provider-storage-it` context.

Other integration scripts stop and print this command if the cluster is
absent. Reuse the cluster during a validation cycle; do not assume it will
exist for the next cycle. Remove it when the operator directs you to do so.

## Unit tests

Render and compare every backend Composition after each repository change:

```bash
tests/unit.bash
```

Pass backend names to limit the run:

```bash
tests/unit.bash minio aws
```

## MinIO

MinIO needs no external cloud bootstrap. This command deploys Crossplane,
MinIO, its providers, one selected `Storage`, an object round trip, and
lifecycle cleanup:

```bash
tests/integration/run.bash minio
```

The integration buckets are `minio-default-it-a` and `minio-default-it-b`,
named after the default MinIO installation used by the test cluster. The
provider-native user is `provider-storage-managed-it`; the consumer Secret is
`provider-storage-it/provider-storage-minio-it`.

## AWS

For a Kind cluster, use the `bootstrap-user` mode. Its access key only allows
`sts:AssumeRole`. The scoped runtime role holds the permissions used by the
provider to manage buckets, policies, users, and access keys.

Use an AWS CLI session with administrator permissions. Review the script and
policy files, then bootstrap IAM:

```bash
export CROSSPLANE_AWS_ACCOUNT_ID=<account-id>
export CROSSPLANE_AWS_AUTH_MODE=bootstrap-user
export CROSSPLANE_AWS_CREDENTIALS_FILE=/secure/provider-storage.credentials

aws/dependencies/iam.sh apply
```

The script writes the bootstrap user's credentials. Create or update the
Secret in the dedicated cluster without printing its content:

```bash
kubectl --context kind-provider-storage-it \
  apply -f tests/integration/manifests/namespaces.yaml
kubectl --context kind-provider-storage-it \
  create secret generic aws-provider-creds \
  --namespace provider-storage-it \
  --from-file="credentials=${CROSSPLANE_AWS_CREDENTIALS_FILE}" \
  --dry-run=client -o yaml \
| kubectl --context kind-provider-storage-it apply -f -
```

Run the integration test from any shell with the account and region set:

```bash
unset CROSSPLANE_AWS_RUNTIME_ROLE_ARN
export CROSSPLANE_AWS_ACCOUNT_ID=<account-id>
export CROSSPLANE_AWS_REGION=eu-central-1

tests/integration/run.bash aws
```

The Secret identifies the bootstrap user, but it does not tell Crossplane which
role to assume. The integration script therefore writes a role ARN into the AWS
`ProviderConfig`. It derives the default
`arn:aws:iam::<account-id>:role/provider-storage/crossplane` from
`CROSSPLANE_AWS_ACCOUNT_ID`. Set `CROSSPLANE_AWS_RUNTIME_ROLE_ARN` to the ARN
printed by `iam.sh` only if you used a custom role name or path.

The account ID derives the `aws-<account-id>` bucket prefix. The bootstrap
embeds this prefix in the runtime IAM policy, so choose any
`CROSSPLANE_AWS_RESOURCE_PREFIX` override before bootstrap and reuse it for
Storage deployment and verification. The default test buckets end
in `-it-a` and `-it-b`. AWS creates user `it` under
`/provider-storage/managed/`. Its managed policies start with
`provider-storage`. The consumer Secret is
`provider-storage-it/provider-storage-aws-it`.

## OTC

Use an OpenStack CLI session with OTC `Security Administrator` permission in a
dedicated domain. Review the script, then bootstrap the
controller identity:

```bash
export CROSSPLANE_OTC_DOMAIN_ID=<domain-id>
export CROSSPLANE_OTC_PROJECT_ID=<project-id>
export CROSSPLANE_OTC_REGION=eu-nl
export CROSSPLANE_OTC_CREDENTIALS_FILE=/secure/provider-otc.json

otc/dependencies/iam.sh apply
```

`CROSSPLANE_OTC_PROJECT_ID` is the regional project used by the provider.
The bootstrap assigns the system-defined `OBS Administrator` policy to all
existing and future projects, and `Security Administrator` at domain scope to
the controller group. The script verifies the inherited assignment. These
system-defined permissions cannot be limited to the test bucket prefix.

Create or update the Secret in the dedicated cluster:

```bash
kubectl --context kind-provider-storage-it \
  apply -f tests/integration/manifests/namespaces.yaml
kubectl --context kind-provider-storage-it \
  create secret generic otc-provider-creds \
  --namespace provider-storage-it \
  --from-file="credentials=${CROSSPLANE_OTC_CREDENTIALS_FILE}" \
  --dry-run=client -o yaml \
| kubectl --context kind-provider-storage-it apply -f -
```

Deploy and verify OTC:

```bash
export CROSSPLANE_OTC_DOMAIN_ID=<domain-id>
export CROSSPLANE_OTC_ENDPOINT=https://obs.eu-nl.otc.t-systems.com
export CROSSPLANE_OTC_REGION=eu-nl

tests/integration/run.bash otc
```

The domain ID derives the `otc-<domain-id>` bucket prefix. Choose any
`CROSSPLANE_OTC_RESOURCE_PREFIX` override during IAM bootstrap and reuse it for
Storage deployment and verification. The default test buckets end in `-it-a`
and `-it-b`; the domain ID reduces collisions in OBS's global namespace. The
provider-native user is `provider-storage-managed-it`; the consumer Secret is
`provider-storage-it/provider-storage-otc-it`.

## OVHcloud

The OVHcloud IAM bootstrap has passed a live target-project read. The
provider is healthy in the dedicated Kind cluster. Direct `User`,
`S3Credentials`, and `ProjectStorage` probes reached Ready. The bucket
reported the requested numeric owner ID in `DE`. The first policy edit
duplicated old actions; the updated bootstrap repaired the exact list, and
`status` and repeated `apply` passed. Direct owner and writer keys passed S3
round trips, and the writer was denied on a second bucket. One composed
`Storage` reached Ready and its normalized Secret passed an S3 round trip. A
composed peer passed ungranted denial, `ReadOnly` read with denied write, and
eventual `None` revocation. Peer policies updated automatically in a follow-up
cycle, while S3 denial lagged. Rotation and orphan cleanup remain unverified.

Install the official `ovhcloud` CLI and `jq`, then run `ovhcloud login` for an
administrator session in the selected OVH API region. Save that login in the
CLI's default `~/.ovh.conf` file. Review
`ovh/dependencies/iam.sh` and its README. The generated controller JSON
defaults to `~/.ovh-provider-storage-<project-id>.json`, separate from the
CLI's `~/.ovh.conf` login:

```bash
export CROSSPLANE_OVH_PROJECT_ID=0123456789abcdef0123456789abcdef
export CROSSPLANE_OVH_API_REGION=EU
unset CROSSPLANE_OVH_CREDENTIALS_FILE

ovh/dependencies/iam.sh status
ovh/dependencies/iam.sh apply
ovh/dependencies/iam.sh status
ovh/dependencies/iam.sh apply
ovh/dependencies/iam.sh verify
```

The API region is `EU`, `CA`, or `US`; it is not the Object Storage region.
The second `apply` checks that the bootstrap is idempotent. No second project
is needed. If one is already available, set `CROSSPLANE_OVH_OTHER_PROJECT_ID`
and run `verify` again for an optional controller denied-read check. The
script reports access results but does not print credentials.

To prepare the pinned provider for direct-resource probes, create the Secret
in the dedicated Kind cluster. The command below uses the default controller
JSON path. If you set `CROSSPLANE_OVH_CREDENTIALS_FILE`, use that file instead.
The pipeline does not print the Secret contents:

```bash
kubectl --context kind-provider-storage-it \
  apply -f tests/integration/manifests/namespaces.yaml
kubectl --context kind-provider-storage-it \
  create secret generic ovh-provider-creds \
  --namespace provider-storage-it \
  --from-file="credentials=${HOME}/.ovh-provider-storage-${CROSSPLANE_OVH_PROJECT_ID}.json" \
  --dry-run=client -o yaml \
| kubectl --context kind-provider-storage-it apply -f -
```

After the Secret is present, run `tests/integration/deploy-ovh-probe.bash` with
`CROSSPLANE_OVH_PROJECT_ID` set. It uses `de` by default; set
`CROSSPLANE_OVH_STORAGE_REGION=gra` if the project cannot use `de`. It installs
the provider and applies namespaced ProviderConfigs in the dedicated Kind
cluster. It does not create a cloud user, credential, policy, or bucket. Live
direct-resource probes must pass before the `Storage` Composition can rely
on these resources.

Run the first live probe after the provider is healthy:

```bash
tests/integration/probe-ovh-user.bash
```

It creates one disposable `xyz-ovh-owner-<project-prefix>` project user with
the `objectstore_operator` role and waits for a numeric observed user ID. The
user allows an explicit `Delete` management action for later cleanup. The
probe creates no bucket or S3 credential. Keep this user until the bucket
ownership probe is complete. The first run created the user but did not reach
Ready because the previous controller policy omitted
`publicCloudProject:apiovh:user/openrc/get`. The administrator added that
action, and the rerun reached Ready. The CLI also duplicated the old actions.
The updated bootstrap script repaired the action list through the CLI editor.
Its `status` reports the policy present, and a repeated `apply` succeeds.

After the User probe passes, run the S3 credential probe:

```bash
tests/integration/probe-ovh-s3-credentials.bash
```

It creates one credential for the disposable User. It checks the observed
access key ID and the two non-empty connection Secret fields,
`access_key_id` and `attribute.secret_access_key`, without printing either
value. The first live resource reached Ready; its Secret used the provider's
`attribute.` prefix, which the first field-name check did not expect. Keep
the credential until S3 access and cleanup probes are complete. User and
credential readiness do not yet prove bucket ownership or S3 access.

Run the bucket ownership and region probe after the owner User is Ready:

```bash
tests/integration/probe-ovh-bucket.bash
```

It uses `DE` for the provider's region name and `de` for the S3 endpoint by
default. Set `CROSSPLANE_OVH_STORAGE_REGION=gra` to test `GRA` instead. The
bucket name starts with `xyz-ovh-` and includes the project prefix. This
direct probe includes the `Delete` management action so an empty test bucket
can be removed through its managed resource after validation. It checks the
observed owner and region; it does not upload an object or test S3 access.

After both the bucket and S3 credential are Ready, test an object upload,
download, and delete with the owner credential:

```bash
tests/integration/probe-ovh-s3-roundtrip.bash
```

The Job mounts the connection Secret by key name and runs Rclone against the
regional S3 endpoint. The first live run passed. It prints only the
round-trip result. The test object has the fixed `xyz-ovh-probe/` prefix and
is removed by the Job, including on failure when the delete request succeeds.

To test a non-owner grant, create another User in the same project, its S3
credential, and one bucket-scoped S3 policy:

```bash
tests/integration/probe-ovh-writer-policy.bash
CROSSPLANE_OVH_S3_PRINCIPAL=writer \
  tests/integration/probe-ovh-s3-roundtrip.bash
```

The writer policy allows operations on the probe bucket and denies bucket
listing across the project. The round trip uses the writer's own connection
Secret. A live write to the composed bucket returned access denied.

After the direct-resource probes, test the production Composition and its
normalized consumer Secret:

```bash
tests/integration/probe-ovh-composition.bash
```

This creates `storage-ovh-it` with one project-prefixed bucket, waits for
`Ready`, checks the five non-empty Secret keys and the bucket's orphaning
management policy, then runs a disposable S3 object round trip. The first live
run passed. A second `Storage` with an access request was also tested live:
its peer key was denied before a grant; `ReadOnly` allowed download and denied
write; `None` denied the same read after an explicit peer reconcile and policy
propagation. A read about 24 seconds after the provider reported the deny
policy still succeeded, and a fresh retry about a minute later was denied. A
follow-up cycle without a manual peer reconcile updated the `ReadOnly` and
`None` policies in about 40 and 50 seconds; S3 denial lagged again. The peer
test needs an automated script before it joins the repeatable integration path.
The test object was removed.

## CI scope

The pull-request workflow runs the unit suite and the MinIO integration path.
It does not use AWS, OTC, or OVHcloud credentials.
