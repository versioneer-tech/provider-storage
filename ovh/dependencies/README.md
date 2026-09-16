# OVHcloud Controller IAM Bootstrap

The first OVHcloud step is to create a controller identity for the target
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
and create its IAM policy. Keep administrator credentials outside this
repository.

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
ovh/dependencies/iam.sh apply
```

`apply` creates the controller service account and a policy for the selected
`publicCloudProject`. It writes the one-time OAuth2 secret to the credential
file with mode `0600`. Like the AWS and OTC bootstrap scripts, `apply` prints
the controller identity, project scope, and credential file path without
printing the secret.

A successful `apply` prints this summary without exposing credentials:

```text
OVHcloud Provider Storage controller identity is ready.
Project: <public-cloud-project-id>
API region: EU
Controller service account: provider-storage-bootstrap-<project-prefix>
IAM policy: provider-storage-controller-<project-prefix>
IAM resource: urn:v1:eu:resource:publicCloudProject:<public-cloud-project-id>
Credentials file: <private-credential-path>
```

When the policy and credential are ready, `verify` reports:

```text
Service account read the target project and its users.
```

The script also checks that the controller IAM policy names the exact target
project URN and reviewed actions. Object Storage Users and S3 credentials live
inside that project. Keep the JSON file private.

The script lists its exact project actions in `status`. The CLI does not
expose the IAM action-reference endpoint. Review these actions before
`apply`. The script checks the policy scope and actions on each later run.
The policy includes bucket deletion and object reads for managed-resource
cleanup. The Composition uses the default Crossplane management policy for
buckets. Removing a bucket from `spec.buckets`, or removing its `Storage`
claim, requests deletion. OVHcloud rejects deletion while the bucket contains
data. If `status` reports `needs action update`, run `apply` to repair the
managed policy without replacing the controller identity or local credential
file.

`verify` uses the controller credential file to test access to the selected
project. The service account is an account identity with a policy scoped to
that project; it is separate from the project's Object Storage Users. Share
only redacted `status` and `verify` results with the development team. Never
share administrator tokens, the credential JSON, or the OAuth2 secret.

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

The provider package version is set in `02-providers.yaml`. Follow the
[integration test guide](../../tests/integration/README.md#ovhcloud) for the
credential Secret handoff and the standard one-Storage, two-bucket test.
Credential rotation, owner replacement, lifecycle, quotas, and orphan cleanup
remain unverified.
