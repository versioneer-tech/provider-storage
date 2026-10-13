# Provider integration tests

All storage backends use the same test model and access checks. Only the
provider bootstrap, bucket prefix, and provider-native identity differ.

The bootstrap administrator runs `iam.sh` with an existing privileged login.
Crossplane uses the separate controller identity. Each test `Storage` receives
consumer credentials for bucket access.

## Common testing strategy for all clouds

### Resources and names

Each backend test creates two `Storage` resources in the
`provider-storage-it` namespace:

| Role | Storage resource | Principal | Owned buckets |
| --- | --- | --- | --- |
| Primary | `storage-<backend>-it` | `<principal>-it` | `<bucket>-it-a` through `<bucket>-it-d` |
| Secondary | `storage-<backend>-it2` | `<principal>-it2` | `<bucket2>-it2-a` |

The placeholders have these meanings:

| Placeholder | Meaning |
| --- | --- |
| `<backend>` | `minio`, `aws`, `otc`, `ovh`, or `cloudferro` |
| `<principal>` | `provider-storage-<backend>` |
| `<bucket>` | Provider-specific base name for buckets owned by the primary principal |
| `<bucket2>` | Provider-specific base name for the secondary principal's bucket |

The default values are:

| Backend | `<principal>` | `<bucket>` | `<bucket2>` |
| --- | --- | --- | --- |
| MinIO | `provider-storage-minio` | `minio-default` | `minio-default` |
| AWS | `provider-storage-aws` | `aws-<account-id>` | Same as `<bucket>` |
| OTC | `provider-storage-otc` | `otc-<domain-id>` | Same as `<bucket>` |
| OVHcloud | `provider-storage-ovh` | `ovh-<project-prefix>` | Same as `<bucket>` |
| CloudFerro | `provider-storage-cloudferro` | `cloudferro-<project-one-prefix>` | `cloudferro-<project-two-prefix>` |

The AWS and OTC resource-prefix variables can override the default bucket
bases. The OVHcloud and CloudFerro project prefixes are the first 12
characters of the applicable project IDs.

For example, the MinIO test uses principal `provider-storage-minio-it` with
bucket `minio-default-it-a`, and principal `provider-storage-minio-it2` with
bucket `minio-default-it2-a`.

### Access matrix

`<principal>-it` owns buckets `a` through `d`. `<principal>-it2` requests
access to buckets `b`, `c`, and `d`:

| Target bucket | Owner access | Request and decision for `<principal>-it2` | Verified `<principal>-it2` access |
| --- | --- | --- | --- |
| `<bucket>-it-a` | `<principal>-it`: full | No request; no grant | None |
| `<bucket>-it-b` | `<principal>-it`: full | `ReadOnly` requested; `ReadOnly` granted | Read only |
| `<bucket>-it-c` | `<principal>-it`: full | `ReadWrite` requested; denied with `None` | None |
| `<bucket>-it-d` | `<principal>-it`: full | `ReadOnly` requested; decision pending | None |
| `<bucket2>-it2-a` | `<principal>-it2`: full | Owned by `<principal>-it2` | Full |

For these checks, `None` means that list, read, write, and delete operations
must fail. `Read only` means that read must succeed while write and delete
must fail. `Full` means that the object write, read, and delete round trip
must succeed.

`bucketAccessRequests` does not have a permission field. The test stores the
requested permission in the request `reason`. The matching
`bucketAccessGrants` entry on the owner records the effective decision.

### What `verify.bash` checks

For every backend, the script:

1. Waits for both `Storage` resources and their consumer Secrets.
2. Checks that each Secret contains the portable S3 credential keys.
3. Runs an object write, read, and delete round trip in every owned bucket.
4. Seeds the target buckets as `<principal>-it` and verifies the access matrix
   with the `<principal>-it2` credentials.

MinIO and CloudFerro also test lifecycle cleanup on `<bucket>-it-a`.

## Test environment

The integration tests use an ephemeral Kind cluster named
`provider-storage-it`. Every command uses the explicit
`kind-provider-storage-it` context. The scripts do not use another Kubernetes
context and do not create a missing cluster.

Each `Storage` resource has the `storages.pkg.internal/backend` inventory
label and an explicit Crossplane composition selector.

## Run the tests

Install Docker, Kind, kubectl, Helm, Crossplane CLI, dyff, and jq.

### 1. Run the unit tests

Render and compare every backend Composition after each repository change:

```bash
tests/unit.bash
```

Pass backend names to limit the Composition tests:

```bash
tests/unit.bash minio aws
```

### 2. Create the integration cluster

Ask the operator before an agent creates the local test cluster. After
approval, run:

```bash
tests/integration/create-cluster.bash
```

The command creates or reuses the cluster and applies the
`provider-storage-it` namespace. You can then publish a controller Secret
before provider deployment.

Clear `KUBECONFIG` first if a cloud login script selected another cluster.
Other integration scripts stop and print the cluster creation command if the
cluster is absent.

Reuse the cluster during one validation cycle. Do not assume that it will
exist for the next cycle. Remove it when the operator directs you to do so.

### 3. Configure and run one backend

Use the matching section below. `run.bash` deploys the backend resources and
then calls `verify.bash`.

## Backend setup

### MinIO

MinIO needs no external cloud bootstrap. This command deploys Crossplane,
MinIO, its providers, both test Storages, the common access checks, and
lifecycle cleanup:

```bash
tests/integration/run.bash minio
```

The integration buckets are `minio-default-it-a` through
`minio-default-it-d` and `minio-default-it2-a`. They are named after the
default MinIO installation used by the test cluster. Access between the two
`Storage` resources follows the common access matrix.

### AWS

#### Bootstrap AWS IAM

For a Kind cluster, use the `static-user` mode. This mode creates a persistent
controller credential user. Its access key only allows
`sts:AssumeRole`. The controller runtime role holds the permissions used by
the provider to manage buckets, policies, users, and access keys.

The account ID creates the default `aws-<account-id>` bucket base. If you set
`CROSSPLANE_AWS_RESOURCE_PREFIX`, choose its value before bootstrap and reuse
it when you run the test. The bootstrap embeds this base in the runtime IAM
policy.

Use an AWS CLI session for the bootstrap administrator, then prepare the
controller IAM resources:

```bash
export CROSSPLANE_AWS_ACCOUNT_ID=<account-id>
export CROSSPLANE_AWS_AUTH_MODE=static-user
export CROSSPLANE_AWS_NAMESPACE=provider-storage-it

aws/dependencies/iam.sh status
aws/dependencies/iam.sh apply
aws/dependencies/iam.sh verify
```

The credential file defaults to
`~/.config/provider-storage/aws-creds.json`.

#### Publish the AWS controller credentials

Render the controller Secret and apply it to the dedicated cluster:

```bash
aws/dependencies/iam.sh render-secrets |
  kubectl --context kind-provider-storage-it apply -f -
```

#### Run the AWS test

Run the integration test from any shell with the account and region set:

```bash
tests/integration/run.bash aws
```

The Secret identifies the controller credential user, but it does not tell
Crossplane which role to assume. The integration script therefore writes a
role ARN into the AWS `ProviderConfig`. It derives the default
`arn:aws:iam::<account-id>:role/provider-storage/crossplane` from
`CROSSPLANE_AWS_ACCOUNT_ID`. Set `CROSSPLANE_AWS_RUNTIME_ROLE_ARN` to the ARN
printed by `iam.sh` only if you used a custom role name or path.

AWS creates users `it` and `it2` under `/provider-storage/managed/`. Managed
policy names start with `provider-storage`. The test adds the suffixes from
the common access matrix to the selected bucket base.

### OTC

#### Bootstrap OTC IAM

Use an OpenStack CLI session for the bootstrap administrator. It needs OTC
`Security Administrator` permission in a dedicated domain.

The domain ID creates the default `otc-<domain-id>` bucket base. If you set
`CROSSPLANE_OTC_RESOURCE_PREFIX`, choose its value before bootstrap and reuse
it when you run the test. This reduces collisions in OBS's global namespace.

`CROSSPLANE_OTC_PROJECT_ID` is the regional project used by the provider.
The bootstrap assigns the system-defined `OBS Administrator` policy to all
existing and future projects, and `Security Administrator` at domain scope to
the controller group. The script verifies the inherited assignment. These
system-defined permissions cannot be limited to the test bucket prefix.

Create the controller identity:

```bash
export CROSSPLANE_OTC_DOMAIN_ID=<domain-id>
export CROSSPLANE_OTC_PROJECT_ID=<project-id>
export CROSSPLANE_OTC_REGION=eu-nl
export CROSSPLANE_OTC_NAMESPACE=provider-storage-it

otc/dependencies/iam.sh status
otc/dependencies/iam.sh apply
otc/dependencies/iam.sh verify
```

The credential file defaults to
`~/.config/provider-storage/otc-creds.json`.

#### Publish the OTC controller credentials

Render the controller Secret and apply it:

```bash
otc/dependencies/iam.sh render-secrets |
  kubectl --context kind-provider-storage-it apply -f -
```

#### Run the OTC test

Deploy and verify OTC:

```bash
tests/integration/run.bash otc
```

The provider-native users are
`provider-storage-managed-it` and `provider-storage-managed-it2`.
The test adds the suffixes from the common access matrix to the selected
bucket base.

### OVHcloud

#### Bootstrap OVHcloud IAM

Use an `ovhcloud` CLI session for the bootstrap administrator in the target
Public Cloud project and API region, then create the project-scoped controller
identity:

```bash
export CROSSPLANE_OVH_PROJECT_ID=<project-id>
export CROSSPLANE_OVH_API_REGION=EU
export CROSSPLANE_OVH_NAMESPACE=provider-storage-it

ovh/dependencies/iam.sh status
ovh/dependencies/iam.sh apply
ovh/dependencies/iam.sh verify
```

The credential file defaults to
`~/.config/provider-storage/ovh-creds.json`.

The API region is separate from the Object Storage region. The administrator
login remains in `~/.ovh.conf`. `verify` checks that the controller can read
the selected project and list its users.

#### Publish the OVHcloud controller credentials

Render the controller Secret and apply it:

```bash
ovh/dependencies/iam.sh render-secrets |
  kubectl --context kind-provider-storage-it apply -f -
```

#### Run the OVHcloud test

Deploy and verify OVHcloud:

```bash
tests/integration/run.bash ovh
```

The project ID supplies the first 12 characters in each bucket name. The test
bucket base is `ovh-<project-prefix>`. Set
`CROSSPLANE_OVH_STORAGE_REGION=gra` if the project needs that Object Storage
region; the region selects the endpoint and does not change the bucket names.
The Composition creates stable owner users and separate credential users for
`it` and `it2`.

### CloudFerro

#### Bootstrap CloudFerro IAM

Create and activate the target projects before IAM bootstrap. Their names must
match `CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN`. See the
[dependency guide](../../cloudferro/dependencies/README.md) for project and
permission requirements.

Use an active project- or domain-scoped CREODIAS `v3token` shell login.
This login needs permission to create a user in the project domain and assign
the configured member role in each selected project.
For a project-scoped login, the bootstrap re-scopes the token to the configured
domain for user operations and to each selected project for role assignments.
For a domain-scoped login, use `OS_DOMAIN_ID` instead of
`OS_PROJECT_DOMAIN_ID` below.

```bash
export CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN='^.+-[0-9]{4}$'
export CROSSPLANE_CLOUDFERRO_DOMAIN_ID="${OS_PROJECT_DOMAIN_ID}"
export CROSSPLANE_CLOUDFERRO_ADMIN_CLOUD=current
export CROSSPLANE_CLOUDFERRO_CONTROLLER_NAME=provider-storage-controller
export CROSSPLANE_CLOUDFERRO_AUTH_URL="${OS_AUTH_URL}"
export CROSSPLANE_CLOUDFERRO_REGION="${OS_REGION_NAME}"
export CROSSPLANE_CLOUDFERRO_NAMESPACE=provider-storage-it

cloudferro/dependencies/iam.sh status
```

Inspect the selected projects. Continue only if `status` shows the expected
names and IDs. Selection does not prove that the login has the required user
and role-assignment permissions. Then create the shared controller user:

```bash
cloudferro/dependencies/iam.sh apply
cloudferro/dependencies/iam.sh verify
```

The credential file defaults to
`~/.config/provider-storage/cloudferro-creds.json`.

#### Publish the CloudFerro controller credentials

Render one controller `Secret` for each selected project and apply the
manifests:

```bash
cloudferro/dependencies/iam.sh render-secrets |
  kubectl --context kind-provider-storage-it apply -f -
```

#### Run the CloudFerro test

Select two different bootstrapped project IDs and run the test:

```bash
export CROSSPLANE_CLOUDFERRO_PROJECT_ID=1d64010bd5aa4e26b267a74c72e8e07a # example project-id
export CROSSPLANE_CLOUDFERRO_IT2_PROJECT_ID=5e5a59562f4b4b95b2e5699bd27393c0 # example project-id
tests/integration/run.bash cloudferro
```

The provider deployment verifies that both project Secrets exist and applies
the common `storage` EnvironmentConfig.

The test creates one Storage with four buckets in the first project and one
Storage with one bucket in the second project. It verifies each Storage's own
bucket access, the cross-project cases in the common access matrix, and
lifecycle cleanup. It also proves that the controller can create EC2
credentials and that the AWS S3 provider can manage a CloudFerro bucket policy.
If a command fails, share only redacted resource conditions and events. Do not
share generated credentials or tokens.

## CI scope

Pull requests to `main`, pushes to `main`, and manual workflow runs execute the
unit suite and the full MinIO integration path. The workflow does not use
cloud-provider credentials. The managed cloud integration paths remain manual.
