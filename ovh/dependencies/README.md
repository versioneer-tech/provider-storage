# OVHcloud Controller IAM Bootstrap

The first OVHcloud step is to create a controller identity for one disposable
Public Cloud project. This bootstrap does not deploy the OVHcloud provider or
run the `Storage` Composition. [ADR-004](../../docs/architecture/0004-add-an-ovhcloud-s3-backend.md)
records the backend design and the checks still needed.

Review [`iam.sh`](iam.sh) before you run it. Install the official
[`ovhcloud` CLI](https://github.com/ovh/ovhcloud-cli#installation) from its
release page, or install it with one of the official package methods:

```bash
# macOS or Linux with Homebrew
brew install --cask ovh/tap/ovhcloud-cli

# Or, if Go is installed
go install github.com/ovh/ovhcloud-cli/cmd/ovhcloud@latest
```

Install `jq` with your system package manager and check `ovhcloud version`
and `jq --version`. Run `ovhcloud login` from outside this repository to
start an administrator session. Select the EU API and save the login in your
user-level `~/.ovh.conf` when the CLI asks for a location. You can also use
the CLI's [supported `OVH_*` variables or configuration
file](https://github.com/ovh/ovhcloud-cli/blob/main/doc/authentication.md).
The session must be able to read the target project, create a service account,
and create its IAM policy. Use a disposable project. Keep administrator
credentials outside this repository.

`iam.sh` uses the CLI's default `~/.ovh.conf` login; no administrator
credential path is needed. It writes the new controller service account as
JSON to `~/.ovh-provider-storage-<project-id>.json` by default. You can set
`CROSSPLANE_OVH_CREDENTIALS_FILE` to an absolute path outside Git to override
this default. The script rejects `.ovh.conf` as the controller output path
to protect your administrator login.

## Select the project

Set the exact 32-character Public Cloud project ID and the API region. The API
region (`EU`, `CA`, or `US`) is separate from the Object Storage region that a
later `Storage` deployment will use. The API region defaults to `EU`.

```bash
export CROSSPLANE_OVH_PROJECT_ID=0123456789abcdef0123456789abcdef
export CROSSPLANE_OVH_API_REGION=EU
```

The selected administrator CLI endpoint must use the same API region. The
controller credential file will contain `endpoint`, `client_id`, and
`client_secret`. Do not print or share its contents. If you previously set
`CROSSPLANE_OVH_CREDENTIALS_FILE=~/.ovh.conf`, unset that variable before
`apply` so the script uses the separate default file.

For the later Object Storage test, use `de` (Frankfurt) first and `gra`
(Gravelines) if needed. These are S3 region codes, separate from the EU API
region used here. OVHcloud lists both as standard regional storage
[locations](https://docs.ovhcloud.com/en/guides/storage-and-backup/object-storage/s3-location).

## Inspect, apply, and verify

Run `status` first. It reads the target project and matching IAM resources but
does not create or change them. It does not need the credential file.

```bash
ovh/dependencies/iam.sh status
ovh/dependencies/iam.sh apply
ovh/dependencies/iam.sh status
ovh/dependencies/iam.sh apply
ovh/dependencies/iam.sh verify
```

`apply` creates the controller service account and a policy for the selected
`publicCloudProject`. It writes the one-time OAuth2 secret to the credential
file with mode `0600`. Like the AWS and OTC bootstrap scripts, `apply` prints
the controller identity, project scope, and credential file path without
printing the secret. `status` includes the path and whether the file is
present. The second `apply` checks that the existing resources and local file
match; it must not create another identity. If the local file
is lost, OVHcloud cannot return the existing `client_secret`. Stop and plan a
new identity and credential handoff instead of reusing an unknown secret.
If local publication is interrupted, `apply` can resume from a private
`<credential-file>.recovery` file. It removes that file after a successful
policy setup. Keep any retained recovery file private; it contains the
one-time secret.

A live `apply` for a disposable EU Public Cloud project succeeded on
2026-09-12. Its output had this shape, with the local values replaced here:

```text
OVHcloud Provider Storage controller identity is ready.
Project: <public-cloud-project-id>
API region: EU
Controller service account: provider-storage-bootstrap-<project-prefix>
IAM policy: provider-storage-controller-<project-prefix>
IAM resource: urn:v1:eu:resource:publicCloudProject:<public-cloud-project-id>
Credentials file: <private-credential-path>
```

The user then ran `status`, repeated `apply`, and ran `verify` for this EU
project. `status` reported that the managed service account and IAM policy
were present and that the credential file was present with mode `0600`.
The repeated `apply` returned the same ready summary and credential-file path
without an error. This checks that the command succeeds when run again; the
output does not show an independent resource count. The current `verify`
reports:

```text
Service account read the target project and its users.
Optional second-project denial check skipped; no second project is required.
```

The script also checks that the controller IAM policy names the exact target
project URN and reviewed actions. Object Storage Users and S3 credentials live
inside that project. A second project is not needed for backend setup or S3
access tests. Keep the JSON file private.

The script lists its exact project actions in `status`. The CLI does not
expose the IAM action-reference endpoint. Review these actions before
`apply`. The script checks the policy scope and actions on each later run.
The provider probe must confirm that these actions are sufficient.

The first live User probe created a project user, then the provider received
403 when it read that user's OpenRC details. The missing action was
`publicCloudProject:apiovh:user/openrc/get`. The script now includes it. If
you ran the earlier script, `status` reports `needs action update`. Run
`apply` again to edit the existing policy; it keeps the same service account,
policy, and controller credential file. The first live edit added the action,
but the CLI also duplicated the previous actions. The provider then reported
the User Ready. The script now recognizes that exact duplicate set and uses
the CLI editor to replace it with one copy of each action. It rejects other
policy drift. A live `apply`, `status`, and repeated `apply` passed with the
repaired policy. The existing controller credential file was reused.

`verify` uses the controller credential file to test access to the selected
project. The service account is an account identity with a policy scoped to
that project; it is separate from the project's Object Storage Users. If you
already have a second disposable project, you can add an optional denied-read
check before `verify`:

```bash
export CROSSPLANE_OVH_OTHER_PROJECT_ID=fedcba9876543210fedcba9876543210
ovh/dependencies/iam.sh verify
```

The second project must exist and differ from the target project. Do not create
one just for this check. Share only redacted `status` and `verify` results with
the development team. Never share administrator tokens, the credential JSON,
or the OAuth2 secret.

## Deploy the provider dependencies

Keep the credential file for the provider Secret handoff. The namespaced
[`ProviderConfig`](03-providerConfigs.yaml) expects a Secret named
`ovh-provider-creds` with a `credentials` key containing the controller JSON.
Apply it in each target `Storage` namespace; set the Secret reference's
`namespace` in `03-providerConfigs.yaml` to that same namespace. Set
`data.storage.serviceName` in [`04-environmentConfigs.yaml`](04-environmentConfigs.yaml)
to the exact project ID used above. The initial backend is configured for
Object Storage region `de` and `https://s3.de.io.cloud.ovh.net`, separate
from the `EU` control-plane API region. Never apply the placeholder project ID.

Install the dependency manifests before the `storage-ovh` Configuration:

1. `00-mrap.yaml`
2. `01-deploymentRuntimeConfigs.yaml`
3. `02-providers.yaml`
4. `03-providerConfigs.yaml` and `04-environmentConfigs.yaml`, in the chosen namespace
5. `functions.yaml` and `rbac.yaml`

The provider package is pinned to `edixos/provider-ovh:v2.19.1`. Follow the
[dedicated Kind handoff](../../tests/integration/README.md#ovhcloud) for
explicit-context commands and disposable direct-resource probes. Those probes
have reached Ready for a project User with a numeric ID, an S3 credential with
non-empty `access_key_id` and `attribute.secret_access_key` Secret fields, and
a DE bucket with the expected numeric owner ID. A direct writer policy passed
a positive bucket round trip and a denied write to a second bucket. One
production `Storage` reached Ready, published the exact five-key consumer
Secret, and passed an S3 round trip. A Composition-managed peer passed
ungranted denial, a `ReadOnly` download with denied write, and eventual `None`
revocation. A follow-up cycle updated peer policies automatically within about
a minute; S3 denial lagged that update. The production Composition omits the
`Delete` management policy for its bucket to preserve user data;
the disposable direct bucket probe includes `Delete` for cleanup. A separate
owner-key Job passed S3 upload, download, comparison, and delete against the
DE bucket through the regional endpoint. A read shortly after the `None`
policy was reported still succeeded; a fresh retry about a minute later was
denied. Credential rotation, owner replacement, lifecycle, quotas, and orphan
cleanup remain unverified.
