# Provider Integration Tests

These tests use an ephemeral Kind cluster named `provider-storage-it`.
Every command uses the explicit `kind-provider-storage-it` context. The
scripts do not use another Kubernetes context or create a missing cluster.

The workflow creates two `Storage` resources for each backend in the
`provider-storage-it` namespace. The first owns buckets ending in `-it-a` and
`-it-b`. The second owns a bucket ending in `-it2-a` and has ReadOnly access
to the first Storage's `-it-b` bucket. Each resource has the
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
MinIO, its providers, both test Storages, object round trips, the ReadOnly
grant check, and lifecycle cleanup:

```bash
tests/integration/run.bash minio
```

The integration buckets are `minio-default-it-a`, `minio-default-it-b`, and
`minio-default-it2-a`, named after the default MinIO installation used by the
test cluster. The second Storage has ReadOnly access to
`minio-default-it-b`.

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
Storage deployment and verification. The default test buckets end in
`-it-a`, `-it-b`, and `-it2-a`. AWS creates users `it` and `it2` under
`/provider-storage/managed/`. The `it2` user has ReadOnly access to the
`-it-b` bucket. Managed policy names start with `provider-storage`.

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
Storage deployment and verification. The default test buckets end in `-it-a`,
`-it-b`, and `-it2-a`; the domain ID reduces collisions in OBS's global
namespace. The provider-native users are `provider-storage-managed-it` and
`provider-storage-managed-it2`. The second user has ReadOnly access to the
`-it-b` bucket.

## OVHcloud

Use an `ovhcloud` CLI administrator session for the target Public Cloud project
in the selected API region. Review `ovh/dependencies/iam.sh`, then
bootstrap the project-scoped controller identity:

```bash
export CROSSPLANE_OVH_PROJECT_ID=<project-id>
export CROSSPLANE_OVH_API_REGION=EU
unset CROSSPLANE_OVH_CREDENTIALS_FILE

ovh/dependencies/iam.sh apply
ovh/dependencies/iam.sh verify
```

The API region is separate from the Object Storage region. The bootstrap writes
controller credentials to `~/.ovh-provider-storage-<project-id>.json` by
default. The administrator login remains in `~/.ovh.conf`. `verify` checks
that the controller can read the selected project and list its users.

Create or update the Secret in the dedicated cluster without printing its
content:

```bash
kubectl --context kind-provider-storage-it \
  apply -f tests/integration/manifests/namespaces.yaml
credential_file="${CROSSPLANE_OVH_CREDENTIALS_FILE:-${HOME}/.ovh-provider-storage-${CROSSPLANE_OVH_PROJECT_ID}.json}"
kubectl --context kind-provider-storage-it \
  create secret generic ovh-provider-creds \
  --namespace provider-storage-it \
  --from-file="credentials=${credential_file}" \
  --dry-run=client -o yaml \
| kubectl --context kind-provider-storage-it apply -f -
```

If you replaced a Secret that an OVHcloud provider already used, restart the
provider so it loads the new credentials:

```bash
kubectl --context kind-provider-storage-it \
  --namespace crossplane \
  rollout restart deployment -l runtime=provider-ovh
kubectl --context kind-provider-storage-it \
  --namespace crossplane \
  rollout status deployment -l runtime=provider-ovh --timeout=3m
```

Deploy and verify OVHcloud:

```bash
export CROSSPLANE_OVH_PROJECT_ID=<project-id>
export CROSSPLANE_OVH_STORAGE_REGION=de

tests/integration/run.bash ovh
```

The project ID supplies the first 12 characters in each bucket name. The test
buckets end in `-it-a`, `-it-b`, and `-it2-a`. The second Storage has
ReadOnly access to the first Storage's `-it-b` bucket. Set
`CROSSPLANE_OVH_STORAGE_REGION=gra` if the project needs that Object Storage
region; the region selects the endpoint and does not change the bucket names.
The Composition creates stable owner users and separate credential users for
`it` and `it2`.

## CloudFerro

Use an active project- or domain-scoped CREODIAS `v3token` shell login. The
commands below target only the dedicated `kind-provider-storage-it` context.

### 1. Check the login and install providers

Check the OpenStack login. Then install Crossplane, the XRD, and the shared
provider dependencies:

```bash
cloudferro/dependencies/iam.sh check-login
tests/integration/deploy-providers.bash cloudferro
```

### 2. Set the bootstrap scope

Replace the domain ID with the slot project domain reported by `check-login`.
Replace the credentials directory with a private, absolute path outside this
repository. Its parent directory must exist.

```bash
export CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN='^.+-([0-9]{4})$'
export CROSSPLANE_CLOUDFERRO_DOMAIN_ID=0123456789abcdef0123456789abcdef
export CROSSPLANE_CLOUDFERRO_ADMIN_CLOUD=current
export CROSSPLANE_CLOUDFERRO_AUTH_URL="$OS_AUTH_URL"
export CROSSPLANE_CLOUDFERRO_REGION="$OS_REGION_NAME"
export CROSSPLANE_CLOUDFERRO_S3_REGION=RegionOne
export CROSSPLANE_CLOUDFERRO_S3_ENDPOINT=https://s3.waw3-2.cloudferro.com
export CROSSPLANE_CLOUDFERRO_KUBE_CONTEXT=kind-provider-storage-it
export CROSSPLANE_CLOUDFERRO_NAMESPACE=provider-storage-it
export CROSSPLANE_CLOUDFERRO_CREDENTIALS_DIR=/secure/cloudferro-controller
```

### 3. Bootstrap the selected projects

Inspect the selected projects. Continue only if `status` shows the expected
names and IDs. Then create the shared controller user and publish the slots:

```bash
cloudferro/dependencies/iam.sh status
cloudferro/dependencies/iam.sh apply
cloudferro/dependencies/iam.sh verify
```

The login needs permission to create a user in the project domain and assign
the configured member role in each selected project. A project in the list is
not proof of these permissions. See the
[bootstrap guide](../../cloudferro/dependencies/README.md) for the role
override, named OpenStack profiles, cleanup, and non-test installations.

### 4. Run the integration test

Select two published slots from different projects and run the test:

```bash
export CROSSPLANE_CLOUDFERRO_SLOT=cloudferro-0001
export CROSSPLANE_CLOUDFERRO_IT2_SLOT=cloudferro-0002
tests/integration/run.bash cloudferro
```

The test creates one Storage with two buckets in the first project and one
Storage with one bucket in the second project. It verifies each Storage's own
bucket access, ReadOnly cross-project access to the first Storage's `-it-b`
bucket, and lifecycle cleanup. It also proves that the controller can create
EC2 credentials and that the AWS S3 provider can manage a CloudFerro bucket
policy. If a command fails, share only redacted resource conditions and
events. Do not share generated credentials or tokens.

## CI scope

The pull-request workflow runs the unit suite and the MinIO integration path.
It does not use cloud-provider credentials.
