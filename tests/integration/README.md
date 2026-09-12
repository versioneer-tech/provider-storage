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

## CI scope

The pull-request workflow runs the unit suite and the MinIO integration path.
It does not use AWS or OTC credentials.
