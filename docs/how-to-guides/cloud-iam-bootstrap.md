# Cloud IAM bootstrap

Use `bootstrap-iam.sh` to prepare the cloud identity that Crossplane uses.
The script supports AWS, OTC, OVHcloud, and CloudFerro. MinIO uses its own
(in cluster) [controller setup](https://github.com/versioneer-tech/provider-storage/blob/main/minio/dependencies/README.md).

Three identities have different purposes:

- The bootstrap administrator creates the controller and assigns permissions.
- The controller manages buckets and consumer identities through a `ProviderConfig`.
- Consumers use the credentials that Provider Storage creates for bucket access.

Bootstrap needs broad IAM permissions to create identities and assign roles.
The operator decides where and when to run it: on a specific host, in a
CI/CD pipeline, or on a local machine. Protect the administrator login and
generated credentials with the access controls for that environment. Deploy
only the controller credential to the cluster.

Review the script and its embedded permission policies before `apply`.
Use a bootstrap login with the permissions listed for your backend below.
Crossplane does not use that administrator login.

## Install

Use Bash, `jq`, and GNU utilities, including `stat`, `mktemp`, and `realpath`.
Cloud operations also need these tools:

| Backend | Tools |
| --- | --- |
| AWS | AWS CLI |
| OTC | OpenStack CLI |
| OVHcloud | Official `ovhcloud` CLI |
| CloudFerro | OpenStack CLI |

Download the script and put it on your command path:

```bash
mkdir -p "$HOME/.local/bin"
curl --fail --silent --show-error --location \
  https://raw.githubusercontent.com/versioneer-tech/provider-storage/<!version!>/scripts/bootstrap-iam.sh \
  --output "$HOME/.local/bin/bootstrap-iam.sh"
chmod 0755 "$HOME/.local/bin/bootstrap-iam.sh"
export PATH="$HOME/.local/bin:$PATH"
bootstrap-iam.sh --help
```

## Configure and apply

Choose `aws`, `otc`, `ovh`, or `cloudferro` as the backend. For example:

```bash
bootstrap-iam.sh ovh configure
bootstrap-iam.sh ovh show
bootstrap-iam.sh ovh apply
bootstrap-iam.sh ovh verify
```

`configure` asks for the account or domain, project, region, and other
installation settings. It saves them locally without a cloud login. Backend
variables can supply prompt defaults. See the settings below for overrides.

`apply` needs the bootstrap administrator's cloud login. It creates or
updates the controller and reuses existing credentials. `verify` uses the
controller credential to test access; it needs no administrator login.
AWS `assume-role` mode needs its external credential source for verification.
Verify uses read-only checks and reports the target and each passed check.
It checks authentication and the operations listed below.
It does not prove every permission used during Storage reconciliation.

| Command | Result |
| --- | --- |
| `configure` | Saves and validates installation settings. |
| `show` | Shows saved settings and identity IDs without secret values. |
| `apply` | Creates or updates cloud resources and saves controller credentials. |
| `verify` | Tests controller authentication and backend access. |
| `render-secrets` | Prints Kubernetes Secret manifests from the local file. It makes no cloud or Kubernetes calls. |

### Settings

Set these variables before `configure` to supply prompt defaults or overrides.
Use the same saved settings for later operations.

| Backend | Variables |
| --- | --- |
| AWS | `CROSSPLANE_AWS_ACCOUNT_ID`, `AWS_REGION`, `CROSSPLANE_AWS_AUTH_MODE`, `CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN`, `CROSSPLANE_AWS_RESOURCE_PREFIX` |
| OTC | `CROSSPLANE_OTC_DOMAIN_ID`, `CROSSPLANE_OTC_PROJECT_ID`, `CROSSPLANE_OTC_REGION`, `CROSSPLANE_OTC_OBS_ENDPOINT`, `CROSSPLANE_OTC_RESOURCE_PREFIX` |
| OVHcloud | `CROSSPLANE_OVH_PROJECT_ID`, `CROSSPLANE_OVH_API_REGION`, `CROSSPLANE_OVH_STORAGE_REGION` |
| CloudFerro | `CROSSPLANE_CLOUDFERRO_DOMAIN_ID`, `CROSSPLANE_CLOUDFERRO_AUTH_URL`, `CROSSPLANE_CLOUDFERRO_REGION`, `CROSSPLANE_CLOUDFERRO_ADMIN_CLOUD`, `CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN`, `CROSSPLANE_CLOUDFERRO_PROJECT_ROLE` |

AWS IAM overrides also use the `CROSSPLANE_AWS_` prefix: `ROLE_NAME`,
`ROLE_PATH`, `POLICY_NAME`, `USER_NAME`, `USER_PATH`, `USER_POLICY_NAME`,
`MANAGED_USER_PATH`, and `MANAGED_POLICY_PATH`. OTC supports
`CROSSPLANE_OTC_USER_NAME`, `CROSSPLANE_OTC_GROUP_NAME`, and
`CROSSPLANE_OTC_AUTH_URL`. CloudFerro supports
`CROSSPLANE_CLOUDFERRO_CONTROLLER_NAME`.

### Local files

Each backend uses `~/.config/provider-storage/<backend>-creds.json`.
Set `PROVIDER_STORAGE_CONFIG_DIR` to another absolute directory, or set
`CROSSPLANE_<BACKEND>_CREDENTIALS_FILE` for one installation. Keep these files
outside Git repositories. They must be owned by you and have mode `0600`;
new directories use mode `0700`.

The JSON has a `config` section for installation settings and an `identity`
section for controller credentials. CloudFerro also saves a `projects` list.
Administrator passwords and tokens are not saved. Later cloud commands reuse
saved settings and reject conflicting variables before cloud access.
Namespace and credential-file overrides are not saved.
Identity metadata is not sent to providers. Secret rendering selects only
the fields used by that provider.

Run `configure` before the first `apply`. Once an identity exists, use a
separate file to change its account, project, or region. A CloudFerro pattern
change clears the saved project selection. Run `apply` to select matching
projects again. Earlier role grants and deployed Secrets remain; remove them
separately when access must be revoked.

AWS `assume-role` mode saves configuration without a static credential.
Use the external workload identity and `assumeRoleChain` in its ProviderConfig.
This mode does not need a rendered controller Secret.

### Deploy controller Secrets

Each Composition uses a `ProviderConfig` for cloud authentication. For static
credentials, that config points to a controller Secret. IAM `apply` creates
the cloud identity and saves credentials locally. Secret deployment is a
separate step; the IAM script has no Kubernetes client or context.

Set the namespace used by the ProviderConfig's Secret reference, then pipe
the manifest to kubectl:

```bash
set -o pipefail
export CROSSPLANE_OVH_NAMESPACE=workspace
bootstrap-iam.sh ovh render-secrets |
  kubectl --context storage-cluster apply --server-side -f -
```

Replace `storage-cluster` with your deployment context. Rendering prints
credentials, so keep its output out of logs. Apply the Secret in every
namespace that needs it. The default namespace is `workspace`.
`pipefail` makes a render failure fail the pipeline too.

Use the matching backend and `CROSSPLANE_<BACKEND>_NAMESPACE` variable:

| Backend | Controller Secret | Secret key |
| --- | --- | --- |
| AWS `static-user` | `aws-provider-creds` | `credentials` |
| OTC | `otc-provider-creds` | `credentials` |
| OVHcloud | `ovh-provider-creds` | `credentials` |
| CloudFerro | `cloudferro-project-<project-id>` for each selected project | `config` |

Set `credentials.secretRef.name`, `namespace`, and `key` in the ProviderConfig
to these values. CloudFerro creates its project-scoped OpenStack
ProviderConfigs from each Storage's project annotation. The project Secret
must exist in that Storage's namespace first.

AWS `assume-role` mode uses an external workload identity and role trust
instead of a static controller Secret. Both AWS modes need the runtime role
in `assumeRoleChain`. Keep project, region, endpoint, and role settings in the
dependency manifests consistent with bootstrap. Follow the
[installation guide](installation.md) for provider deployment.

### Rotate controller credentials

AWS `static-user`, OTC, and CloudFerro support rotation. Prepare the
replacement and check the verification result before you render or deploy
Secrets:

```bash
bootstrap-iam.sh otc apply --rotate-credentials
bootstrap-iam.sh otc verify
```

After verification succeeds, render and apply the Secret in each required
namespace:

```bash
set -o pipefail
export CROSSPLANE_OTC_NAMESPACE=workspace
bootstrap-iam.sh otc render-secrets |
  kubectl --context storage-cluster apply --server-side -f -
```

Rotation saves the replacement locally and verifies cloud access. AWS and
OTC then delete the previous key. CloudFerro invalidates the old password
when it changes the password. Existing cluster Secrets still contain the old
credentials until you replace them. Allow for that interruption, then check
that providers use the replacement. The IAM script does not check or update
the cluster.

If rotation fails, keep the local file and rerun `apply` to resume it. The
temporary `rotation` section supports recovery and blocks configuration
changes and Secret rendering until rotation succeeds. If Secret publication
fails, repeat the pipe with the saved credentials.

OVHcloud service-account rotation is manual. Rotate
AWS workload credentials through their external identity system.

## AWS

Choose a controller authentication mode during `configure`:

| Mode | Source |
| --- | --- |
| `assume-role` (default) | Existing same-account IAM role or user, such as a workload identity. Set its trusted principal ARN. |
| `static-user` | Dedicated IAM user and one access key saved in the local file. |

Both sources assume the controller runtime role. The bootstrap login must
manage that role, its trust and inline policies, and tags. Static mode also
needs permission to manage the dedicated user and access key.

The embedded runtime policy permits bucket operations under the configured
prefix and identity operations under the managed IAM paths. It includes
wider read and list actions needed by the provider and denies changes to
the controller credential user. Managed users and policies default to
`/provider-storage/managed/`; the controller user is outside that path.

Choose the bucket prefix before apply. Its default is `aws-<account-id>`.
Use the same prefix for Storage resources; IAM enforces it.

`verify` authenticates the credential source, assumes the configured role,
checks the resulting account and role, and lists S3 buckets. Set that role
in `assumeRoleChain` for both modes. See the
[AWS dependency guide](https://github.com/versioneer-tech/provider-storage/blob/main/aws/dependencies/README.md).

## OTC

Configure the domain ID, regional project ID, region, and OBS endpoint.
Use an OpenStack administrator login with `Security Administrator` in the
target domain. The script verifies domain scope before IAM operations.

Apply creates one programmatic controller user, one group, and a permanent
AK/SK. The group receives `Security Administrator` at domain scope and
`OBS Administrator` for all existing and future projects. The regional
project ID selects the provider project, not the OBS permission scope.

Use a dedicated domain. OTC cannot restrict these system permissions to a
bucket prefix, and an agency cannot receive `Security Administrator`.
The default bucket prefix, `otc-<domain-id>`, is a naming rule only.
IAM changes can take 10 to 15 minutes to take effect.

`verify` signs an OBS bucket-list request with the saved controller AK/SK.
It needs curl 7.87 or later to sign the payload header. Earlier curl versions
can return HTTP 400 even with valid credentials. No OpenStack administrator
session is needed. The ProviderConfig
reads `otc-provider-creds`. See the
[OTC dependency guide](https://github.com/versioneer-tech/provider-storage/blob/main/otc/dependencies/README.md).

## OVHcloud

Install the official CLI and run `ovhcloud login` outside this repository.

The bootstrap login must read the target project, create an OAuth2 service
account, and create or update its IAM policy. Apply limits that policy to
the exact project. It permits the Object Storage users, roles, policies,
S3 credentials, and regional storage operations used by the Composition.

The controller file is separate from the CLI login. Never use `~/.ovh.conf`
as its path. `verify` uses the saved service account to read the project and
list its users. The ProviderConfig reads `ovh-provider-creds`. See the
[OVHcloud dependency guide](https://github.com/versioneer-tech/provider-storage/blob/main/ovh/dependencies/README.md).

## CloudFerro

Create and activate billing projects in the
[CREODIAS portal](https://creodias.docs.cloudferro.com/en/latest/accountmanagement/Accounts-and-Projects-Management.html)
first. Bootstrap does not create projects or change wallets and billing.
Assign separate projects to teams that need isolated bucket access.

Configure the domain, Keystone v3 URL, OpenStack region, bootstrap profile,
and project-name pattern. Use `current` as the profile for an active
`v3token` login. Patterns must start with `^` and end with `$`; the default
is `^.+-[0-9]{4}$`. Limit the pattern to projects the controller must manage.

The bootstrap login must list projects, create a user in the target domain,
and grant the configured project role. The script verifies domain scope
before these operations. Re-scoping a token does not add permissions.

Apply creates or reuses one shared controller user. It assigns the project
role, `member` by default, in each matching enabled project in the domain.
The controller needs no user- or role-administration permission. It manages
containers and its own EC2/S3 credentials within each project.

After another project is active, rerun apply to include it:

```bash
bootstrap-iam.sh cloudferro apply
export CROSSPLANE_CLOUDFERRO_NAMESPACE=workspace
bootstrap-iam.sh cloudferro render-secrets |
  kubectl --context storage-cluster apply --server-side -f -
```

This reuses the controller and password. It adds grants and saves the selected
project IDs; it does not revoke earlier grants. There is no separate project
registration command.

Each `cloudferro-project-<project-id>` Secret contains the controller identity
with one project scope. The Composition creates the Storage's OpenStack
ProviderConfig. Restrict who can select the project annotation and read its
controller Secret. A user with S3 access in a project can access its containers;
a bucket policy cannot isolate users within that project.

`verify` reads each saved project's name, domain, and enabled state with the
controller login. It rejects a project outside the configured name pattern
before testing container listing. Each project report shows its name and ID.
The [integration suite](https://github.com/versioneer-tech/provider-storage/blob/main/tests/integration/README.md)
also checks EC2 credential creation and S3 access. See the
[CloudFerro dependency guide](https://github.com/versioneer-tech/provider-storage/blob/main/cloudferro/dependencies/README.md).
