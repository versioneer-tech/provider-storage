# Integration tests

Use the dedicated Kind cluster `provider-storage-it` and the explicit
`kind-provider-storage-it` context. The tests do not use another cluster or
create a missing cluster.

Each backend creates two Storage resources in namespace `provider-storage-it`:

| Role | Storage | Principal | Owned buckets |
| --- | --- | --- | --- |
| Owner | `storage-<backend>-it` | `provider-storage-<backend>-it` | `<prefix>-it-a` through `<prefix>-it-d` |
| Requester | `storage-<backend>-it2` | `provider-storage-<backend>-it2` | `<second-prefix>-it2-a` |

Bucket prefixes use these values:

| Backend | Prefix | Second prefix |
| --- | --- | --- |
| MinIO | `minio-default` | Same |
| AWS | `aws-<account-id>` | Same |
| OTC | `otc-<domain-id>` | Same |
| OVHcloud | `ovh-<project-prefix>` | Same |
| CloudFerro | `cloudferro-<project-one-prefix>` | `cloudferro-<project-two-prefix>` |

Project prefixes are the first 12 characters of the project ID. AWS and OTC
can use their configured resource prefix instead of the default. Choose that
prefix before IAM bootstrap and use the same value for the tests.

## Access checks

The requester records requests for the owner's buckets `b`, `c`, and `d`.
The owner grants `ReadOnly` for `b`, sets `None` for `c`, and makes no decision
for `d`.

| Target | Owner | Requester |
| --- | --- | --- |
| Owner bucket `a` | Read, write, delete | No access |
| Owner bucket `b` | Read, write, delete | Read only |
| Owner bucket `c` | Read, write, delete | No access; denied |
| Owner bucket `d` | Read, write, delete | No access; pending |
| Requester's own bucket | No grant tested | Read, write, delete |

`verify.bash` waits for both Storage resources and their consumer Secrets.
It checks the portable Secret keys, runs object round trips in every owned
bucket, and checks the access matrix. Read-only access must reject write and
delete operations. No access must reject list, read, write, and delete.
Access probes call each S3 operation directly with Boto3. The Python image is
pinned by digest and includes the SDK. Each negative probe requires
`AccessDenied`, HTTP 403, and the requested operation. It does not depend on
the optional error message, which CloudFerro can leave empty.
Network errors, invalid credentials, missing objects, and failures from another
operation fail the test.

The request `reason` describes intended access. The request has no permission
field; the owner's grant sets the permission. The local manifest test keeps
these inputs consistent with the verifier.

MinIO and CloudFerro also test lifecycle deletion in bucket `a`.
MinIO changes the requester's credential generation and verifies that the
consumer Secret keeps its UID and receives both keys from the requested
generation's native Secret. The fixture must start without rollover.
The test restores that setting and repeats the requester's owned-bucket
round trip.
The full MinIO run also checks Storage ownership and credential copies in
Objects and current provider logs. A separate Storage with no buckets checks
Secret and User deletion. These checks do not inspect retained logs from
older provider pods.

## Prepare the cluster

Install Docker, Kind, kubectl, Helm, Crossplane CLI, dyff, yq, and jq.
Run the full [unit suite](../README.md#unit-suite) before cluster tests:

```bash
tests/unit.bash
```

Get the operator's approval before creating the test cluster:

```bash
tests/integration/create-cluster.bash
```

The command creates or reuses the cluster and creates its namespaces. Use a
separate `KUBECONFIG` file if your shell has another cluster configured.
Reuse this cluster during a validation cycle. Remove it only when the
operator directs you to do so.

## Run a backend

`run.bash` deploys providers, the Composition, and both Storages, then calls
`verify.bash`. Cloud backends need controller credentials before this step.
See [Cloud IAM bootstrap](../../docs/how-to-guides/cloud-iam-bootstrap.md)
for controller permissions and the backend dependency guides for setup.

For each cloud backend, set `CROSSPLANE_<CLOUD>_NAMESPACE=provider-storage-it`
before `render-secrets`. Apply its output only to the dedicated context:

```bash
bootstrap-iam.sh <backend> render-secrets |
  kubectl --context kind-provider-storage-it apply --server-side -f -
```

Replace `<backend>` with `aws`, `otc`, `ovh`, or `cloudferro`. The default
credential file is `~/.config/provider-storage/<backend>-creds.json`.

### MinIO

MinIO needs no cloud bootstrap:

```bash
tests/integration/run.bash minio
```

### AWS

Follow the [AWS dependency guide](../../aws/dependencies/README.md).
Use `static-user` mode for Kind. The controller user's key permits only
`sts:AssumeRole`; the runtime role manages storage resources.

```bash
export CROSSPLANE_AWS_ACCOUNT_ID=<account-id>
export CROSSPLANE_AWS_REGION=eu-central-1
tests/integration/run.bash aws
```

The runner derives the runtime role ARN from the account ID:
`arn:aws:iam::<account-id>:role/provider-storage/crossplane`.
For a custom role name or path, set `CROSSPLANE_AWS_RUNTIME_ROLE_ARN` to the
ARN from bootstrap.
Consumer users are `it` and `it2` under `/provider-storage/managed/`.

### OTC

Follow the [OTC dependency guide](../../otc/dependencies/README.md) with an
administrator login in a dedicated domain. Set the domain, regional project,
region, and target namespace before bootstrap.

Apply the rendered Secret, then run with the same domain and region settings:

```bash
tests/integration/run.bash otc
```

Consumer user names start with `provider-storage-managed-`.

### OVHcloud

Follow the [OVHcloud dependency guide](../../ovh/dependencies/README.md).
Set the exact project ID, API region, and target namespace before bootstrap.
The API region is separate from the Object Storage region.

Apply the rendered Secret, then run:

```bash
tests/integration/run.bash ovh
```

Set `CROSSPLANE_OVH_STORAGE_REGION=gra` if that project uses the GRA region.
This changes the endpoint, not bucket names. The Composition creates stable
bucket-owner users and separate credential users for `it` and `it2`.

### CloudFerro

Follow the [CloudFerro dependency guide](../../cloudferro/dependencies/README.md).
Create and activate the projects first. Limit the project-name pattern to
the projects under test. The bootstrap login needs permission to create the
controller user and assign its project role.

Review the project pattern with `bootstrap-iam.sh cloudferro show`, then run
`apply` and `verify`. Apply the rendered project Secrets. Select two different
bootstrapped projects:

```bash
export CROSSPLANE_CLOUDFERRO_PROJECT_ID=<project-one-id>
export CROSSPLANE_CLOUDFERRO_IT2_PROJECT_ID=<project-two-id>
tests/integration/run.bash cloudferro
```

Both Storages select `storage-cloudferro` through their environment
annotation. The test checks owned-bucket access, cross-project grants,
lifecycle cleanup, EC2 credential creation, and bucket-policy management
through the AWS S3 provider.

## Run all backends

Prepare and verify all four cloud controller identities first. Use
`provider-storage-it` as the bootstrap target namespace and pipe
`render-secrets` into kubectl with `--context kind-provider-storage-it`.
Keep the account, project, region, prefix, and role settings in the shell that
starts the tests. The CloudFerro fixture uses WAW3-2 and the RegionOne S3
signing region.

After the complete local suite passes, run the backends in order:

```bash
bash -euo pipefail <<'BASH'
for backend in minio aws otc ovh cloudferro; do
  tests/integration/run.bash "$backend"
done
BASH
```

The loop stops at the first failure. Inspect that failure before restarting.
