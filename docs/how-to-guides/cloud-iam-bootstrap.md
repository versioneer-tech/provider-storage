# Cloud IAM bootstrap

This guide uses these terms:

- **Bootstrap administrator:** The person who runs `iam.sh` with an existing
  privileged login. Crossplane does not use this login.
- **Controller identity:** The persistent machine identity that Crossplane
  uses through a `ProviderConfig`.
- **Consumer identity:** An identity that Provider Storage creates for access
  to a bucket.

!!! danger "Review before deployment"

    Provider Storage needs permission to manage buckets, identities, policies,
    and access credentials. A cloud administrator must review the backend's
    `iam.sh` and policy files before running the bootstrap.

Run the IAM bootstrap before you render and apply its Kubernetes Secret
manifest. No `iam.sh` accesses Kubernetes. For each backend that uses a static
controller credential, `apply` writes a private local credential file.
`render-secrets` reads only that file and prints the Secret manifest. Do not
send this output to CI logs.

| Backend | Default controller credential file |
| --- | --- |
| AWS | `~/.config/provider-storage/aws-creds.json` |
| OTC | `~/.config/provider-storage/otc-creds.json` |
| OVHcloud | `~/.config/provider-storage/ovh-creds.json` |
| CloudFerro | `~/.config/provider-storage/cloudferro-creds.json` |

Each backend-specific `CROSSPLANE_<CLOUD>_CREDENTIALS_FILE` variable can
override its default.

The managed-cloud scripts use the same command model:

| Command | Behavior |
| --- | --- |
| `status` | Reads the cloud setup and local credential-file state. It does not change resources. |
| `apply` | Creates or updates the controller resources. It writes the local credential file when the selected mode uses one. |
| `verify` | Fails unless the required controller resources and credentials are ready. The exact live check depends on the backend. |
| `render-secrets` | Reads only the local credential file and prints Kubernetes Secret manifests. It does not call the cloud API or Kubernetes. |

OTC also provides `rotate-credential` to replace its controller AK/SK. Run
`<cloud>/dependencies/iam.sh --help` for required variables and backend-specific
options.

!!! warning "Choose the bucket prefix during IAM bootstrap"

    Bucket names are user-facing. For AWS and OTC, the default prefixes are
    `aws-<account-id>` and `otc-<domain-id>`. Configure an override before
    bootstrap and use it for every `Storage` deployment. AWS enforces this
    prefix in IAM. The OTC prefix is only a naming rule. It does not limit the
    `OBS Administrator` permission.

## AWS

### AWS identity model

The bootstrap administrator runs
[`iam.sh`](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/iam.sh)
with AWS administrator credentials. The script creates a controller runtime
role and its inline policy.

The provider can use one of these base controller identities:

| Mode | Base controller identity |
| --- | --- |
| `assume-role` | An existing workload identity, such as IRSA or EKS Pod Identity |
| `static-user` | A dedicated IAM user with a static access key |

The IAM user is a persistent controller credential user. It is not the
bootstrap administrator. Its default path is
`/provider-storage/controller/crossplane`.

In both modes, the base identity assumes the controller runtime role. The
runtime role creates S3 buckets, consumer users, access keys, and policies.

### AWS permissions

The bootstrap administrator must be able to inspect and manage the IAM role,
trust policy, inline policy, and tags. In `static-user` mode, it must also
be able to manage the dedicated controller credential user and its access key.
Review the templates in
[`policies/`](https://github.com/versioneer-tech/provider-storage/tree/main/aws/dependencies/policies)
before `apply`.

The base controller identity can only call `sts:AssumeRole` for the controller
runtime role. The runtime role can:

- Manage users, access keys, and policies in the configured managed IAM paths.
- Manage S3 buckets and objects with the configured bucket prefix.
- Use the wider read and list actions that the provider needs.

The runtime policy denies changes to the controller credential user. Managed
users and policies use `/provider-storage/managed/`. The default bucket prefix
is `aws-<account-id>`.

### Run AWS bootstrap

Follow the [AWS dependency README](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/README.md) for the
required variables, both authentication modes, and the command sequence. Set
the bucket prefix before `apply`; the runtime policy contains that prefix.

### Configure the AWS provider

Both modes set the controller runtime role in `assumeRoleChain`.
`assume-role` uses a workload credential source. `static-user` uses the
generated `aws-provider-creds` Secret.

### Inspect AWS

Use the same account, mode, prefix, names, paths, and credential-file value for
all commands. `status` reports missing resources without changes. `verify`
fails if the controller resources or credentials are not ready. See the
[integration test guide](https://github.com/versioneer-tech/provider-storage/blob/main/tests/integration/README.md#aws)
for the full deployment and S3 test.

## OTC

### OTC identity model

The bootstrap administrator runs
[`iam.sh`](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/iam.sh)
with an existing OTC administrator login. The script creates one programmatic
controller user, one controller group, and one permanent AK/SK. Crossplane
uses that controller credential through its `ProviderConfig`.

The default user and group name is `provider-storage-controller-crossplane`.
The IAM script does not adopt or delete resources that use older names.
Consumer users start with `provider-storage-managed-`.

### OTC permissions

The bootstrap administrator must have `Security Administrator` at domain
scope. The script re-scopes its OpenStack token to the target domain for the
OTC IAM API.

The controller group receives:

- `Security Administrator` at domain scope, so the controller can create
  consumer users and permanent credentials.
- `OBS Administrator` for all existing and future projects, so the controller
  can manage OBS resources.

OTC cannot limit these system permissions to one bucket or bucket prefix. Use
a dedicated domain for Provider Storage. An agency cannot replace the
controller identity because OTC does not allow `Security Administrator` on an
agency.

### Run OTC bootstrap

Follow the [OTC dependency README](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/README.md) for the
required variables and command sequence. The regional project ID selects the
provider project. It is not the scope of the `OBS Administrator` assignment.
IAM changes can take 10 to 15 minutes to take effect.

### Configure the OTC provider

The `ProviderConfig` reads `otc-provider-creds`. After credential rotation,
render and apply the Secret again.

### Inspect OTC

`status` checks the group membership and both role assignments without
changes. `verify` fails if the controller resources or credential are not
ready. See the
[integration test guide](https://github.com/versioneer-tech/provider-storage/blob/main/tests/integration/README.md#otc)
for the full deployment test.

## OVHcloud

### OVHcloud identity model

The bootstrap administrator runs
[`iam.sh`](https://github.com/versioneer-tech/provider-storage/blob/main/ovh/dependencies/iam.sh)
with an existing OVHcloud administrator session. The script creates an OAuth2
controller service account and a project-scoped IAM policy. Crossplane uses
the service account through its `ProviderConfig`.

The service account and IAM policy names start with
`provider-storage-controller-`.

### OVHcloud permissions

The bootstrap administrator must be able to:

- Read the target Public Cloud project.
- Create an OAuth2 service account.
- Create and update an IAM policy for that service account.

The controller policy is limited to the exact target `publicCloudProject`.
It lets the controller manage the project resources that the Composition
needs, including Object Storage users, roles, user policies, S3 credentials,
and regional storage. Run `status` to see the exact action list before
`apply`.

### Run OVHcloud bootstrap

Follow the [OVHcloud dependency README](https://github.com/versioneer-tech/provider-storage/blob/main/ovh/dependencies/README.md) for
the CLI preparation, required variables, and command sequence. The OVHcloud
API region is separate from the Object Storage region.

### Configure the OVHcloud provider

The `ProviderConfig` reads `ovh-provider-creds`. The EnvironmentConfig must
contain the exact project ID and Object Storage settings.

### Inspect OVHcloud

`status` reads the target project and matching IAM resources without changes.
`verify` uses the controller credential to read the selected project and list
its users. Share only redacted output. See the
[integration test guide](https://github.com/versioneer-tech/provider-storage/blob/main/tests/integration/README.md#ovhcloud)
for the provider Secret and bucket test.

## CloudFerro

### CloudFerro identity model

The bootstrap administrator runs
[`iam.sh`](https://github.com/versioneer-tech/provider-storage/blob/main/cloudferro/dependencies/iam.sh)
with an existing OpenStack login. The script creates one shared controller
user without a default project. It assigns that user to each selected project.
Crossplane uses a project-scoped configuration for this controller user.

The OpenStack project is the S3 access boundary. A user with S3 access in a
project can access that project's containers. A bucket policy can share a
bucket with another project's `root` ARN, but it cannot isolate users in the
owner project.

### CloudFerro permissions

The bootstrap administrator must be able to:

- List the projects that the configured name pattern selects.
- Create one user in the project domain.
- Assign the configured project role in every selected project.
- Re-scope its token to the domain and projects when its initial login is
  project-scoped.

Re-scoping does not add permissions. The bootstrap administrator must already
have the required domain and project permissions.

The controller user needs only the configured project role, which defaults to
`member`. It must not have user-administration or role-administration
permission. As a project member, it manages containers and creates an EC2/S3
credential for itself. The Composition also manages bucket policies.

### Run CloudFerro bootstrap

CloudFerro projects are billing resources and the access boundary for buckets.
Create and activate all required projects in the
[CREODIAS billing portal](https://creodias.docs.cloudferro.com/en/latest/accountmanagement/Accounts-and-Projects-Management.html)
before bootstrap.

Follow the
[CloudFerro dependency README](https://github.com/versioneer-tech/provider-storage/blob/main/cloudferro/dependencies/README.md) for
project preparation, required variables, and the command sequence. Limit the
project pattern to the projects that the controller must manage. The script
does not create projects or configure portal activation, wallets, or billing.

### Configure the CloudFerro provider

Each `cloudferro-project-<project-id>` Secret contains the controller identity
and one project scope. The Composition creates a separate OpenStack
`ProviderConfig` for each `Storage`.

Treat the project ID annotation as a privileged field. Restrict who can select
a project and who can read its controller Secret.

### Inspect CloudFerro

`status` checks the bootstrap login, project access, and selected projects
without changes. `verify` checks project-scoped controller authentication and
Object Storage access. The first live Composition run must also prove that the
controller can create an EC2 credential for itself.
