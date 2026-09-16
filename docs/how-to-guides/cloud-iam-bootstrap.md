# Bootstrap Cloud IAM

!!! danger "Review before deployment"

    Provider Storage needs permission to manage buckets, IAM users, policies,
    and access credentials. A cloud administrator must review the backend's
    `iam.sh` and any policy files before running the bootstrap.

For AWS, OTC, and OVHcloud, run the bootstrap before deploying the backend's
Crossplane providers and `ProviderConfig`. CloudFerro installs providers first
because its bootstrap creates the slot ProviderConfigs in the cluster. The
bootstrap identity is for the controller. It is separate from the consumer
identities and credentials that Provider Storage creates.

!!! warning "Choose the bucket prefix during IAM bootstrap"

    Bucket names are user-facing. For AWS and OTC, the default prefixes are
    `aws-<account-id>` and `otc-<domain-id>`. Configure any override before
    bootstrap and reuse it for every `Storage` deployment. AWS enforces this
    prefix in IAM. The OTC bootstrap assigns OBS Administrator to all existing
    and future projects. The OTC prefix is a naming convention and does not
    limit that permission.

## AWS

The AWS bootstrap consists of
[`iam.sh`](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/iam.sh)
and its
[`policies/`](https://github.com/versioneer-tech/provider-storage/tree/main/aws/dependencies/policies).
It creates the runtime role used by `provider-aws`. Choose how the provider
gets the base identity that assumes this role:

| Mode | Base identity |
| --- | --- |
| `assume-role` | An existing workload identity, such as IRSA or EKS Pod Identity |
| `bootstrap-user` | A dedicated IAM user with a static access key |

Both modes require the runtime role ARN in
`ProviderConfig.spec.assumeRoleChain`. The bootstrap user cannot manage
storage resources directly. It can only assume the runtime role.

AWS groups resources with IAM paths. The default bootstrap user is
`/provider-storage/bootstrap/crossplane`. Managed users and policies use the
`/provider-storage/managed/` path. IAM policy names start with
`provider-storage`.

The runtime policy lists the IAM actions used to manage users, access keys,
and policies. It limits IAM changes to the managed paths and S3 access to
buckets and objects with the configured prefix. The S3 statement uses `s3:*`
on those resources. Some read and list actions use wider resource scopes.
The policy denies changes to the bootstrap user. The bootstrap user's policy
grants only `sts:AssumeRole` for the runtime role.

The default bucket prefix is `aws-<account-id>`. Choose the prefix when running
the IAM bootstrap. The runtime policy embeds it, so every managed bucket must
start with the same value. Set `CROSSPLANE_AWS_RESOURCE_PREFIX` during
bootstrap when one account contains multiple installations, and reuse it for
deployment.

Use `aws/dependencies/iam.sh --help` for optional names and paths.

### Use an existing workload identity

The trusted principal must already exist and must be available to
`provider-aws`:

```bash
export CROSSPLANE_AWS_ACCOUNT_ID=123456789012
export CROSSPLANE_AWS_AUTH_MODE=assume-role
export CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN=arn:aws:iam::123456789012:role/crossplane-base

aws/dependencies/iam.sh apply
```

Give the trusted principal permission to assume the runtime role.

### Use the bootstrap user

Use an absolute credentials-file path outside Git:

```bash
export CROSSPLANE_AWS_ACCOUNT_ID=123456789012
export CROSSPLANE_AWS_AUTH_MODE=bootstrap-user
export CROSSPLANE_AWS_CREDENTIALS_FILE=/secure/provider-storage.credentials

aws/dependencies/iam.sh apply
```

The script writes the credentials file and prints the runtime role ARN. Store
the file in a secret manager.

### Configure `provider-aws`

For both modes, put the printed runtime role ARN in
[`aws/dependencies/03-providerConfigs.yaml`](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/03-providerConfigs.yaml)
and apply the `ProviderConfig` in each namespace that contains an AWS
`Storage`.

For `assume-role`, configure the workload credential source in that manifest.
For `bootstrap-user`, create the Secret in each `Storage` namespace:

```bash
namespace=<storage-namespace>
kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic aws-provider-creds \
  --namespace "${namespace}" \
  --from-file=credentials="${CROSSPLANE_AWS_CREDENTIALS_FILE}" \
  --dry-run=client -o yaml \
| kubectl apply -f -
```

### Inspect

Use the same account, mode, prefix, names, paths, and credentials-file value
for all operations:

```bash
aws/dependencies/iam.sh status
```

For a complete Kind test sequence, including Secret creation, provider
deployment, and an S3 round trip, see the
[integration test guide](https://github.com/versioneer-tech/provider-storage/blob/main/tests/integration/README.md#aws).

## OTC

The OTC provider uses one programmatic IAM user with a permanent access key.
The bootstrap adds the user to one group and assigns two permissions to it:

- `Security Administrator` at domain scope, because the controller creates IAM
  users and permanent credentials for them.
- The system-defined `OBS Administrator` policy for all existing and future
  projects.

OTC exposes project and domain role assignment through user groups. This is
why the bootstrap needs a group although the equivalent AWS setup does not.
The default bootstrap user and group are both named
`provider-storage-bootstrap-crossplane`. Composition-created users start with
`provider-storage-managed-`.

The system-defined OTC permissions cannot be limited to a bucket prefix or an
individual bucket. `Security Administrator` can change IAM permissions in the
domain, and `OBS Administrator` covers OBS resources across existing and future
projects. Use a dedicated domain for Provider Storage. An agency cannot
replace this controller identity because OTC does not permit
`Security Administrator` on an agency.

The user that runs the bootstrap must already have `Security Administrator` at
domain scope. The script re-scopes the active OpenStack token to the target
domain because OTC IAM APIs require a domain-scoped token. Review
[`iam.sh`](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/iam.sh),
then run:

```bash
export CROSSPLANE_OTC_DOMAIN_ID=0123456789abcdef0123456789abcdef
export CROSSPLANE_OTC_PROJECT_ID=abcdef0123456789abcdef0123456789
export CROSSPLANE_OTC_REGION=eu-nl
export CROSSPLANE_OTC_CREDENTIALS_FILE=/secure/provider-otc.json

otc/dependencies/iam.sh apply
```

The regional project ID is the provider project, not the OBS policy assignment
scope. The script writes the provider JSON with mode `0600` and
does not print its access key or secret key. Store this file in a secret
manager.

Run `otc/dependencies/iam.sh status` to check group membership, Security
Administrator, and the inherited OBS Administrator assignment. The bootstrap
uses OTC's all-projects IAM endpoint. IAM changes can take 10 to 15 minutes to
take effect.

The default bucket prefix is `otc-<domain-id>`. Choose any override through
`CROSSPLANE_OTC_RESOURCE_PREFIX` when running the IAM bootstrap, then reuse it
for every deployment. The prefix does not restrict OBS Administrator access.

Create the Secret used by `otc/dependencies/03-providerConfigs.yaml`:

```bash
namespace=<storage-namespace>
kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic otc-provider-creds \
  --namespace "${namespace}" \
  --from-file=credentials="${CROSSPLANE_OTC_CREDENTIALS_FILE}" \
  --dry-run=client -o yaml \
| kubectl apply -f -
```

Use `otc/dependencies/iam.sh rotate-credential` to replace the controller
AK/SK without recreating its user or policies, then update the provider Secret.

For the complete Kind test sequence, see the
[OTC integration test guide](https://github.com/versioneer-tech/provider-storage/blob/main/tests/integration/README.md#otc).

## OVHcloud

The OVHcloud controller identity is an OAuth2 service account with an IAM
policy for the target `publicCloudProject`. The bootstrap script creates that
identity and policy. The standard integration run tests the composed
`Storage` and its buckets through Crossplane.

Review [`iam.sh`](https://github.com/versioneer-tech/provider-storage/blob/main/ovh/dependencies/iam.sh)
and its [README](https://github.com/versioneer-tech/provider-storage/blob/main/ovh/dependencies/README.md).
Install the official [`ovhcloud` CLI](https://docs.ovhcloud.com/en/guides/manage-and-operate/cli/getting-started)
and `jq`. Run `ovhcloud login` to start an administrator session and save
it in `~/.ovh.conf`, the CLI's default login file. You can also use the
CLI's supported `OVH_*` variables. Select the same OVH API region for the CLI
and script. This API region is separate from the Object Storage region.

Set the exact project ID. The private controller JSON defaults to
`~/.ovh-provider-storage-<project-id>.json`, separate from `~/.ovh.conf`.
Unset any old `CROSSPLANE_OVH_CREDENTIALS_FILE` value that points to the CLI
login. Run `status` before and after `apply`, then repeat `apply` to check
that it is idempotent:

```bash
export CROSSPLANE_OVH_PROJECT_ID=0123456789abcdef0123456789abcdef
export CROSSPLANE_OVH_API_REGION=EU
unset CROSSPLANE_OVH_CREDENTIALS_FILE

ovh/dependencies/iam.sh apply
```

`status` is read-only. `apply` writes `endpoint`, `client_id`, and
`client_secret` as JSON with mode `0600`. Both commands print the credential
file path, but not the secret.
`verify` reads that file and reports access results without printing the
credential. The script checks the exact target-project URN in the controller
IAM policy and verifies that the controller can read the selected project and
list its users. Send only redacted status and verification results to the team.

The provider credential Secret handoff and one-Storage, two-bucket test are
documented in the
[integration test guide](https://github.com/versioneer-tech/provider-storage/blob/main/tests/integration/README.md#ovhcloud).
Rotation, lifecycle, owner replacement, and cleanup behavior remain in the
OVHcloud validation plan.

## CloudFerro

CloudFerro's S3 authorization boundary is the OpenStack project. A user in a
project can reach that project's containers; bucket policies share with a
different project's `root` ARN and do not restrict individual users. See the
[CloudFerro bucket-sharing guide](https://docs.cloudferro.com/en/latest/s3/Bucket-sharing-using-s3-bucket-policy-on-CloudFerro-Cloud.html).

Install the provider dependencies and `storage-cloudferro` Configuration
before bootstrap. Then follow the
[CloudFerro bootstrap guide](https://github.com/versioneer-tech/provider-storage/blob/main/cloudferro/dependencies/README.md).
It gives the required login check, variables, and `status`, `apply`, and
`verify` commands.

The bootstrap selects enabled, existing projects with an anchored numbered
name pattern. It creates one controller user, assigns it to each selected
project, and publishes one project-scoped ProviderConfig per slot. Separate
keys in one shared Secret hold the project scopes. The script does not create
projects. Portal activation and wallet setup remain separate.

After all `Storage` resources using a selected slot are removed, `iam.sh delete`
cleans that slot's shared Secret key, controller role assignments, and managed
cluster resources. It uses the same project-name pattern and leaves the shared
controller user, local identity file, and pre-existing projects intact.

The first live Composition run must prove that the controller can create an
EC2 credential for itself in the selected project. A cross-project test must
also verify the AWS S3 `BucketPolicy` adapter with owner and grantee Storages
in different numbered slots.
