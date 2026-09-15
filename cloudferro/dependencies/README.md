# CloudFerro Project-Slot Bootstrap

CloudFerro uses an OpenStack project as the S3 team boundary. Users with S3
access in the same project can access its buckets. S3 bucket policies share
buckets with **other projects**; they do not restrict users in the owner
project. Assign one project slot to one team. See [ADR-005](../../docs/architecture/0005-add-a-cloudferro-s3-backend.md)
and CloudFerro's [bucket-sharing guide](https://docs.cloudferro.com/en/latest/s3/Bucket-sharing-using-s3-bucket-policy-on-CloudFerro-Cloud.html).

[`iam.sh`](iam.sh) lists projects visible to the bootstrap login with
`openstack project list --long`. That list also supplies each project's domain
and enabled state, so the bootstrap does not need to show every project.
It selects only names that match an
anchored pattern ending in four captured digits. For example,
`team-storage-0001` becomes slot `cloudferro-0001`. The default pattern is
`^.+-([0-9]{4})$`. It accepts any non-empty prefix followed by `-NNNN`, such
as `eoepca-slot-0001` or `team-b-0002`. Set
`CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN` to a narrower expression when needed.
The script never creates projects. It skips unmatched projects and stops if
two names map to the same slot.

## Prepare

1. Create and activate the numbered projects in the
   [CREODIAS portal](https://creodias.docs.cloudferro.com/en/latest/accountmanagement/Accounts-and-Projects-Management.html).
   Check their region and wallet assignments.
2. Log in with an OpenStack user that can list its projects, create one user in
   their domain, and assign project roles.
   The script assigns the `member` role at project scope. Set
   `CROSSPLANE_CLOUDFERRO_PROJECT_ROLE` if your deployment uses another role,
   such as `_member_`. The controller does not need the `admin` role: it
   creates EC2 credentials only for itself and manages containers in its
   selected project. Seeing a project in `openstack project list`
   does not prove that the login has `identity:create_user` permission in the
   project domain or `identity:create_grant` permission on the project. A
   project-scoped `admin` role alone might not permit user creation. An active
   project- or domain-scoped `v3token` shell works with the `current` profile
   setting; a named OpenStack cloud profile also works. Keep profiles and
   tokens outside Git.
3. Install the target namespace, Crossplane, CloudFerro provider dependencies,
   and the `storage-cloudferro` Configuration. For the dedicated Kind cluster,
   run `tests/integration/deploy-providers.bash cloudferro` first. It installs
   shared prerequisites; `iam.sh apply` publishes the numbered slots. See
   the [integration guide](../../tests/integration/README.md#cloudferro).

For an active `v3token` login, check its scope and project-list path first:

```bash
cloudferro/dependencies/iam.sh check-login
```

`check-login` is read-only. It accepts a project- or domain-scoped token and
prints the scope without printing the token. It cannot prove user-creation or
role-assignment permission. Set `CROSSPLANE_CLOUDFERRO_DOMAIN_ID` to the slot
project domain ID reported by `check-login`:

```bash
export CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN='^.+-([0-9]{4})$'
export CROSSPLANE_CLOUDFERRO_DOMAIN_ID=0123456789abcdef0123456789abcdef
export CROSSPLANE_CLOUDFERRO_ADMIN_CLOUD=current
# Optional: defaults to provider-storage-controller.
export CROSSPLANE_CLOUDFERRO_CONTROLLER_NAME=provider-storage-controller
export CROSSPLANE_CLOUDFERRO_AUTH_URL="$OS_AUTH_URL"
export CROSSPLANE_CLOUDFERRO_REGION="$OS_REGION_NAME"
export CROSSPLANE_CLOUDFERRO_S3_REGION=RegionOne
export CROSSPLANE_CLOUDFERRO_S3_ENDPOINT=https://s3.waw3-2.cloudferro.com
export CROSSPLANE_CLOUDFERRO_KUBE_CONTEXT=kind-provider-storage-it
export CROSSPLANE_CLOUDFERRO_NAMESPACE=provider-storage-it
export CROSSPLANE_CLOUDFERRO_CREDENTIALS_DIR=/secure/cloudferro-controller

cloudferro/dependencies/iam.sh status
```

For CREODIAS WAW3-2, the OpenStack region is `WAW3-2` and the S3 signing
region is `RegionOne`. `status` needs project-list access. It reports matching
project IDs and the shared controller user ID when its local identity file
exists. It does not list roles or inspect role assignments. The default
project role is `member`. Role names are preferred because role IDs differ
between OpenStack deployments. Keep the project pattern limited to the
projects that this controller must manage.

## Apply and verify

Review the selected project names and IDs from `status`, then run:

```bash
cloudferro/dependencies/iam.sh apply
cloudferro/dependencies/iam.sh verify
```

`apply` creates one controller user without a default project and assigns the
configured project role in every selected project. It tests password
authentication, project scope, and Object Storage listing. It then publishes
one namespaced OpenStack ProviderConfig, EnvironmentConfig, and Composition
per slot. One shared Secret contains one JSON configuration key per slot. Each
key has the same user ID and password and a different `tenant_id`. The
ProviderConfig selects its slot key because provider-openstack reads project
scope from the credential JSON, not from a separate ProviderConfig field.

The script records the project name, project ID, and shared controller user ID
on each ProviderConfig. It stores the controller identity and password in one
mode-0600 file in the configured private directory. It does not print secrets.
Re-running `apply` reconciles existing slots. It can take field ownership of a
slot Composition that has its bootstrap managed-by label, but it refuses an
unrelated Composition.

If `apply` stops at controller user creation, use its error category to check
the bootstrap login. A permission error needs a login that can create users
in the project domain. A name conflict means the shared controller user name
exists, but the private identity file is missing; the script will not
adopt that user. `status` checks local identity files, so
`controller_user_id=missing` does not prove that no matching user exists in
OpenStack. Do not delete an existing user until you know who owns it.

`verify` checks controller scope, Object Storage access, the shared Secret
keys, and cluster slot resources. It does not prove that the controller can
mint an EC2 credential for itself; the first live Storage test must do that.
If Object Storage listing fails, check portal region and wallet
activation before retrying. See the [integration guide](../../tests/integration/README.md#cloudferro)
for the two-bucket test and optional second consumer.

All ProviderConfigs from one run live in the selected namespace. Restrict
which team can select each slot through trusted admission or separate
namespaces. A Storage selects the slot with
`spec.crossplane.compositionSelector.matchLabels.provider: cloudferro-0001`.
The matching Composition uses ProviderConfig `cloudferro-0001`. Keep read
access to `cloudferro-provider-creds` limited to the provider and trusted
operators; it carries project-admin access to every selected project. The
Composition rejects active cross-project bucket grants until a bucket-policy
adapter and allow/deny tests exist.

## Remove managed access

Review `status` with the same project pattern before cleanup, then run
`cloudferro/dependencies/iam.sh delete`. It selects only matching projects
and refuses to remove a slot used by any Storage. It checks resource and
credential ownership, then removes the slot's ProviderConfig,
EnvironmentConfig, Composition, shared Secret key, and controller role
assignments. It deletes the shared Secret when its last key is removed. It
leaves the shared controller user, private identity file, projects, buckets,
and consumer resources in place. Keep the private identity file while any
slot uses the controller.
