#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

# Controller passwords must never be traced or printed.
set +x
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: cloudferro/dependencies/iam.sh <check-login|status|apply|verify|delete>

Discover existing numbered CloudFerro projects visible to the login and
publish one project-scoped provider-openstack ProviderConfig per project.
Only project names matching the anchored pattern are selected. Review
dependencies/README.md first.

Environment for status and apply:
  CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN   Anchored regex with one four-digit
                                         capture (default ^.+-([0-9]{4})$)
  CROSSPLANE_CLOUDFERRO_DOMAIN_ID         Keystone domain ID for slot projects
  CROSSPLANE_CLOUDFERRO_ADMIN_CLOUD       Bootstrap OpenStack profile, or current
  CROSSPLANE_CLOUDFERRO_CONTROLLER_NAME   Optional shared controller user name
  CROSSPLANE_CLOUDFERRO_PROJECT_ROLE      Project role name or ID (default member)
  CROSSPLANE_CLOUDFERRO_AUTH_URL          Keystone v3 URL
  CROSSPLANE_CLOUDFERRO_REGION            OpenStack region, for example WAW3-2
  CROSSPLANE_CLOUDFERRO_S3_REGION         S3 signing region, for example RegionOne
  CROSSPLANE_CLOUDFERRO_S3_ENDPOINT       S3 endpoint URL for this region
  CROSSPLANE_CLOUDFERRO_KUBE_CONTEXT      Explicit target Kubernetes context
  CROSSPLANE_CLOUDFERRO_NAMESPACE         Namespace containing Storage resources
  CROSSPLANE_CLOUDFERRO_CREDENTIALS_DIR   Private directory outside this repo

The script creates one controller user in the domain and assigns it to every
matching project. One shared Secret stores a project-scoped configuration key
for each ProviderConfig.
It never creates or deletes projects. Delete removes this bootstrap's slot
resources and project role assignments after checking that no Storage uses the
slot. It does not delete the shared controller user.
The script does not perform portal activation or wallet setup. It prints no secrets.
Use check-login with an active project- or domain-scoped v3token shell before
setting the other variables.
The special profile name current uses that shell token; the script verifies
the token user and project scope before publishing any slot.
EOF
}

die() { printf 'Error: %s\n' "$1" >&2; exit 1; }

case ${1:-} in
  -h|--help) usage; exit 0 ;;
  check-login) (($# == 1)) || { usage >&2; exit 2; }; action=$1 ;;
  status|apply|verify|delete) (($# == 1)) || { usage >&2; exit 2; }; action=$1 ;;
  *) usage >&2; exit 2 ;;
esac

for dependency in openstack jq; do
  command -v "$dependency" >/dev/null 2>&1 || die "Install $dependency before running IAM bootstrap."
done

active_login() {
  [[ ${OS_AUTH_TYPE:-} == v3token && -n ${OS_TOKEN:-} ]] || die 'Source an active v3token OpenStack login; do not paste its token into a file or command.'
  [[ ${OS_AUTH_URL:-} =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/v3$ &&
     ${OS_REGION_NAME:-} =~ ^[A-Za-z0-9._-]+$ ]] || die 'The active token login needs a Keystone v3 URL and OpenStack region.'
  local token token_project token_domain token_user project_domain
  token=$(openstack token issue -f json 2>/dev/null) || die 'The active OpenStack token could not be verified.'
  token_user=$(jq -er '.user_id | select(type == "string")' <<<"$token") || die 'The active OpenStack token has no user ID.'
  token_project=$(jq -r '.project_id // empty' <<<"$token")
  token_domain=$(jq -r '.domain_id // empty' <<<"$token")
  [[ $token_user =~ ^[a-fA-F0-9]{32}$ ]] || die 'The active OpenStack token user ID is invalid.'
  if [[ -n $token_project ]]; then
    [[ $token_project =~ ^[a-fA-F0-9]{32}$ ]] || die 'The active OpenStack token project ID is invalid.'
    project_domain=$(openstack project show "$token_project" -f value -c domain_id 2>/dev/null) || die 'The active OpenStack project domain could not be verified.'
    [[ $project_domain =~ ^[a-fA-F0-9]{32}$ ]] || die 'The active OpenStack project domain ID is invalid.'
    [[ -z ${OS_PROJECT_ID:-} || $token_project == "$OS_PROJECT_ID" ]] || die 'The active token and OS_PROJECT_ID disagree.'
    [[ -z ${OS_PROJECT_DOMAIN_ID:-} || $project_domain == "$OS_PROJECT_DOMAIN_ID" ]] || die 'The active token and OS_PROJECT_DOMAIN_ID disagree.'
    printf '%s\tproject\t%s\t%s\n' "$token_user" "$token_project" "$project_domain"
    return
  fi
  [[ $token_domain =~ ^[a-fA-F0-9]{32}$ ]] || die 'The active OpenStack token must be scoped to a project or domain.'
  [[ -z ${OS_DOMAIN_ID:-} || $token_domain == "$OS_DOMAIN_ID" ]] || die 'The active token and OS_DOMAIN_ID disagree.'
  printf '%s\tdomain\t%s\t%s\n' "$token_user" "$token_domain" "$token_domain"
}

if [[ $action == check-login ]]; then
  login=$(active_login)
  IFS=$'\t' read -r login_user login_scope login_scope_id login_domain <<<"$login"
  if [[ $login_scope == project ]]; then
    printf 'Active login: user_id=%s project_id=%s project_domain_id=%s OpenStack_region=%s\n' \
      "$login_user" "$login_scope_id" "$login_domain" "$OS_REGION_NAME"
  else
    printf 'Active login: user_id=%s domain_id=%s OpenStack_region=%s\n' \
      "$login_user" "$login_scope_id" "$OS_REGION_NAME"
  fi
  if openstack project list --long -f json >/dev/null 2>&1; then
    printf 'Project listing: available.\n'
  else
    printf 'Project listing: unavailable; status/apply need a login that can list projects.\n'
  fi
  printf 'This check is read-only. It does not prove user-creation or role-assignment permission.\n'
  exit 0
fi

for dependency in kubectl realpath stat mktemp sed sort wc openssl python3 base64; do
  command -v "$dependency" >/dev/null 2>&1 || die "Install $dependency before running IAM bootstrap."
done

required() {
  local value=${!1:-}
  [[ -n $value ]] || die "$1 must be set."
  printf '%s' "$value"
}

project_pattern=${CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN:-}
[[ -n $project_pattern ]] || project_pattern='^.+-([0-9]{4})$'
domain_id=$(required CROSSPLANE_CLOUDFERRO_DOMAIN_ID)
admin_cloud=$(required CROSSPLANE_CLOUDFERRO_ADMIN_CLOUD)
controller_name=${CROSSPLANE_CLOUDFERRO_CONTROLLER_NAME:-provider-storage-controller}
project_role=${CROSSPLANE_CLOUDFERRO_PROJECT_ROLE:-member}
auth_url=$(required CROSSPLANE_CLOUDFERRO_AUTH_URL)
region=$(required CROSSPLANE_CLOUDFERRO_REGION)
s3_region=$(required CROSSPLANE_CLOUDFERRO_S3_REGION)
s3_endpoint=$(required CROSSPLANE_CLOUDFERRO_S3_ENDPOINT)
kube_context=$(required CROSSPLANE_CLOUDFERRO_KUBE_CONTEXT)
namespace=$(required CROSSPLANE_CLOUDFERRO_NAMESPACE)
credentials_dir=$(required CROSSPLANE_CLOUDFERRO_CREDENTIALS_DIR)

[[ ${project_pattern:0:1} == ^ && ${project_pattern: -1} == '$' ]] || die 'The project pattern must be anchored with ^ and $.'
if [[ xyz =~ $project_pattern ]]; then :; elif (( $? == 2 )); then die 'The project pattern is not a valid extended regex.'; fi
[[ $credentials_dir = /* && ! -L $credentials_dir ]] || die 'The credentials directory must be an absolute path, not a symlink.'
[[ $domain_id =~ ^[a-fA-F0-9]{32}$ ]] || die 'The domain ID must be 32 hexadecimal characters.'
[[ $admin_cloud =~ ^[A-Za-z0-9._-]+$ ]] || die 'The cloud profile name contains invalid characters.'
[[ $controller_name =~ ^[A-Za-z0-9._-]+$ ]] || die 'The controller user name contains invalid characters.'
[[ $project_role =~ ^[A-Za-z0-9._-]+$ ]] || die 'The project role name or ID contains invalid characters.'
[[ $region =~ ^[A-Za-z0-9._-]+$ && $s3_region =~ ^[A-Za-z0-9._-]+$ ]] || die 'An OpenStack or S3 region contains invalid characters.'
[[ $auth_url =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/v3$ &&
   $s3_endpoint =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die 'Keystone and S3 endpoints must be HTTPS origins; Keystone must end in /v3.'
[[ $kube_context =~ ^[A-Za-z0-9._@:/-]+$ && $namespace =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die 'The Kubernetes context or namespace is invalid.'

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(realpath -- "$script_dir/../..")
parent_dir=$(dirname -- "$credentials_dir")
[[ -d $parent_dir ]] || die 'The credentials-directory parent must exist.'
resolved_dir="$(realpath -e -- "$parent_dir")/$(basename -- "$credentials_dir")"
[[ $resolved_dir != "$repo_dir" && $resolved_dir != "$repo_dir"/* ]] || die 'Keep controller credentials outside the Git repository.'

if [[ -e $credentials_dir ]]; then
  [[ -d $credentials_dir ]] || die 'The credentials path must be a directory.'
  [[ $(stat -c '%a:%u' -- "$credentials_dir") == "700:$(id -u)" ]] || die 'The credentials directory must be owned by you and mode 0700.'
fi

work_dir=$(mktemp -d /tmp/provider-storage-cloudferro.XXXXXXXX)
trap 'rm -rf -- "$work_dir"' EXIT
managed_by=provider-storage-cloudferro-iam

# A named profile isolates its credentials. The explicit current mode uses the
# operator's already scoped shell token, including an optional project rescope.
openstack_profile() (
  local profile=$1 target_project='' argument
  local -a arguments=()
  shift
  cd -- "$work_dir"
  unset OS_DEBUG
  if [[ $profile == current ]]; then
    unset OS_CLOUD OS_CLIENT_CONFIG_FILE OS_AUTH_TOKEN OS_ENDPOINT
    unset OS_USERNAME OS_PASSWORD OS_USER_ID OS_USER_DOMAIN_ID OS_USER_DOMAIN_NAME
    unset OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET
    while (($#)); do
      if [[ $1 == --os-project-id ]]; then
        shift
        (($#)) || die 'A project scope is missing its ID.'
        target_project=$1
      else
        arguments+=("$1")
      fi
      shift
    done
    if [[ -n $target_project ]]; then
      [[ $target_project =~ ^[a-fA-F0-9]{32}$ ]] || die 'The target project ID is invalid.'
      unset OS_PROJECT_NAME
      export OS_PROJECT_ID=$target_project
    fi
    if [[ ${OPENSTACK_PASSWORD_PROMPT:-} == 1 ]]; then
      python3 "$script_dir/password_prompt.py" "$work_dir/controller-password" \
        openstack --os-region-name "$region" "${arguments[@]}"
    else
      openstack --os-region-name "$region" "${arguments[@]}"
    fi
    exit
  fi
  unset OS_AUTH_URL OS_AUTH_TYPE OS_USERNAME OS_PASSWORD OS_PROJECT_ID OS_PROJECT_NAME
  unset OS_USER_ID OS_USER_DOMAIN_ID OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_ID
  unset OS_PROJECT_DOMAIN_NAME OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET
  unset OS_TOKEN OS_AUTH_TOKEN OS_ENDPOINT OS_REGION_NAME
  if [[ ${OPENSTACK_PASSWORD_PROMPT:-} == 1 ]]; then
    python3 "$script_dir/password_prompt.py" "$work_dir/controller-password" \
      openstack --os-cloud "$profile" --os-region-name "$region" "$@"
  else
    openstack --os-cloud "$profile" --os-region-name "$region" "$@"
  fi
)

admin_json() {
  local result
  if ! result=$(openstack_profile "$admin_cloud" "$@" -f json 2>/dev/null); then
    if [[ ${1:-} == project && ${2:-} == list ]]; then
      die 'OpenStack project listing failed. Run openstack project list --long -f json in the same shell to inspect the CLI error.'
    fi
    die "Bootstrap OpenStack ${1:-request} failed. Check the token or profile and domain permissions."
  fi
  printf '%s\n' "$result"
}

kube() { kubectl --context "$kube_context" --namespace "$namespace" "$@"; }

check_cluster() {
  kube get namespace "$namespace" -o name >/dev/null 2>&1 || die 'The selected namespace is not present in the explicit Kubernetes context.'
  kube get crd providerconfigs.openstack.m.crossplane.io -o name >/dev/null 2>&1 || die 'Install provider-openstack before IAM apply.'
  kube get crd environmentconfigs.apiextensions.crossplane.io -o name >/dev/null 2>&1 || die 'Install Crossplane EnvironmentConfig before IAM apply.'
  kube get crd storages.pkg.internal -o name >/dev/null 2>&1 || die 'Install the Storage XRD before IAM apply.'
}

check_owned() {
  local kind=$1 name=$2 scope=$3 existing
  if [[ $scope == cluster ]]; then
    existing=$(kubectl --context "$kube_context" get "$kind" "$name" --ignore-not-found -o json 2>/dev/null) || die "Could not inspect $kind/$name."
  else
    existing=$(kube get "$kind" "$name" --ignore-not-found -o json 2>/dev/null) || die "Could not inspect $kind/$name."
  fi
  [[ -z $existing ]] || jq -e --arg manager "$managed_by" '.metadata.labels["app.kubernetes.io/managed-by"] == $manager' <<<"$existing" >/dev/null || die "Refusing to adopt existing $kind/$name."
}

check_slot_resources() {
  local slot=$1
  check_owned providerconfig.openstack.m.crossplane.io "$slot" namespaced
  check_owned environmentconfig "storage-$slot" cluster
  check_owned composition "storage-$slot" cluster
}

slot_binding() {
  local slot=$1 project_name=$2 project_id=$3 must_exist=${4:-false} object user_id=''
  if [[ -f $(identity_path) && ! -L $(identity_path) ]]; then
    user_id=$(jq -r '.user_id' "$(identity_path)")
  fi
  object=$(kube get providerconfig.openstack.m.crossplane.io "$slot" --ignore-not-found -o json 2>/dev/null) || die "Could not inspect ProviderConfig for $slot."
  if [[ -n $object ]]; then
    jq -e --arg name "cloudferro-provider-creds" --arg ns "$namespace" --arg key "$slot" \
      --arg projectName "$project_name" --arg projectId "$project_id" --arg userId "$user_id" '
      .spec.credentials.source == "Secret" and .spec.credentials.secretRef.name == $name and
      .spec.credentials.secretRef.namespace == $ns and .spec.credentials.secretRef.key == $key and
      .metadata.annotations["storages.pkg.internal/project-name"] == $projectName and
      .metadata.annotations["storages.pkg.internal/project-id"] == $projectId and
      .metadata.annotations["storages.pkg.internal/controller-user-id"] == $userId
    ' <<<"$object" >/dev/null || die "Slot $slot ProviderConfig has a different project binding or credential reference."
  elif [[ $must_exist == true ]]; then
    die "Slot $slot ProviderConfig is missing."
  fi
  object=$(kube get secret cloudferro-provider-creds --ignore-not-found -o json 2>/dev/null) || die 'Could not inspect the shared controller Secret.'
  if [[ -n $object ]]; then
    jq -e --arg user "$user_id" '
      .metadata.annotations["storages.pkg.internal/controller-user-id"] == $user
    ' <<<"$object" >/dev/null || die 'The shared controller Secret belongs to another user.'
    if jq -e --arg slot "$slot" '.data[$slot] | type == "string" and length > 0' \
        <<<"$object" >/dev/null; then
      jq -e --arg slot "$slot" --arg project "$project_id" \
        --arg url "$auth_url" --arg region "$region" --arg domain "$domain_id" \
        --arg user "$user_id" --slurpfile identity "$(identity_path)" '
        .data[$slot] | @base64d | fromjson |
        .auth_url == $url and .region == $region and
        .user_id == $user and .password == $identity[0].password and
        .user_domain_id == $domain and .tenant_id == $project
      ' <<<"$object" >/dev/null || die "The shared controller Secret has a different authentication binding for $slot."
    elif [[ $must_exist == true ]]; then
      die "The shared controller Secret has no configuration for $slot."
    fi
  elif [[ $must_exist == true ]]; then
    die 'The shared controller Secret is missing.'
  fi
  object=$(kubectl --context "$kube_context" get environmentconfig "storage-$slot" --ignore-not-found -o json 2>/dev/null) || die "Could not inspect EnvironmentConfig for $slot."
  if [[ -n $object ]]; then
    jq -e --arg id "$project_id" --arg controller "$user_id" \
      --arg region "$region" --arg s3region "$s3_region" --arg endpoint "$s3_endpoint" '
      .data.storage.serviceName == $id and .data.storage.controllerUserId == $controller and
      .data.storage.region == $region and
      .data.storage.s3Region == $s3region and
      .data.storage.endpoint == $endpoint and .data.storage.type == "s3" and
      .data.storage.force_path_style == "true"
    ' <<<"$object" >/dev/null || die "Slot $slot EnvironmentConfig has a different project, controller, region, or endpoint."
  elif [[ $must_exist == true ]]; then
    die "Slot $slot EnvironmentConfig is missing."
  fi
  object=$(kubectl --context "$kube_context" get composition "storage-$slot" --ignore-not-found -o json 2>/dev/null) || die "Could not inspect Composition for $slot."
  if [[ -n $object ]]; then
    jq -e --arg slot "$slot" '.metadata.labels.provider == $slot' <<<"$object" >/dev/null || die "Slot $slot Composition has a different selector."
  elif [[ $must_exist == true ]]; then
    die "Slot $slot Composition is missing."
  fi
}

identity_path() { printf '%s/controller.identity.json' "$credentials_dir"; }

check_identity_file() {
  local file user_id user
  file=$(identity_path)
  [[ ! -L $file && -f $file ]] || die 'Missing shared controller identity file.'
  [[ $(stat -c '%a:%u' -- "$file") == "600:$(id -u)" ]] || die 'A controller identity file must be owned by you and mode 0600.'
  jq -e --arg url "$auth_url" --arg region "$region" --arg domain "$domain_id" --arg name "$controller_name" '
    .auth_url == $url and .region == $region and .domain_id == $domain and
    .user_name == $name and
    (.user_id | type == "string" and test("^[a-fA-F0-9]{32}$")) and
    (.password | type == "string" and length > 0)
  ' "$file" >/dev/null || die 'The shared controller identity file has an invalid format or binding.'
  user_id=$(jq -r '.user_id' "$file")
  user=$(admin_json user show "$user_id")
  jq -e --arg id "$user_id" --arg domain "$domain_id" --arg name "$controller_name" \
    --arg description 'Provider Storage shared controller' '
    (.id // .ID) == $id and .domain_id == $domain and .name == $name and
    (.default_project_id == null or .default_project_id == "None" or .default_project_id == "") and
    .description == $description and
    (.enabled == true or .Enabled == true)
  ' <<<"$user" >/dev/null || die 'The shared controller user has changed; refusing to use it.'
}

slot_for_name() {
  local project_name=$1 suffix
  [[ $project_name =~ $project_pattern ]] || return 1
  suffix=${BASH_REMATCH[1]:-}
  [[ $suffix =~ ^[0-9]{4}$ ]] || return 2
  printf 'cloudferro-%s' "$suffix"
}

slot_openstack() (
  local project_id=$1 identity
  shift
  identity=$(identity_path)
  cd -- "$work_dir"
  jq -n --arg project "$project_id" --arg domain "$domain_id" \
    --slurpfile identity "$identity" '
    {clouds:{"provider-storage-slot":{
      auth_type:"v3password", region_name:$identity[0].region,
      auth:{auth_url:$identity[0].auth_url,user_id:$identity[0].user_id,
            password:$identity[0].password,user_domain_id:$domain,
            project_id:$project,project_domain_id:$domain}
    }}}
  ' >"$work_dir/clouds.yaml"
  chmod 600 -- "$work_dir/clouds.yaml"
  unset OS_AUTH_URL OS_AUTH_TYPE OS_USERNAME OS_PASSWORD OS_PROJECT_ID OS_PROJECT_NAME
  unset OS_USER_ID OS_USER_DOMAIN_ID OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_ID
  unset OS_PROJECT_DOMAIN_NAME OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET
  unset OS_TOKEN OS_AUTH_TOKEN OS_ENDPOINT OS_REGION_NAME
  unset OS_DEBUG
  OS_CLIENT_CONFIG_FILE="$work_dir/clouds.yaml" openstack --os-cloud provider-storage-slot "$@"
)

verify_credential() {
  local slot=$1 project_id=$2 user_id=$3 token_project token_user
  check_identity_file
  token_project=$(slot_openstack "$project_id" token issue -f value -c project_id 2>/dev/null) || die "The controller cannot issue a token for $slot."
  token_user=$(slot_openstack "$project_id" token issue -f value -c user_id 2>/dev/null) || die "The controller cannot identify itself in $slot."
  [[ $token_project == "$project_id" && $token_user == "$user_id" ]] || die "Slot $slot credential is scoped to a different project or user."
  slot_openstack "$project_id" container list -f json >/dev/null 2>&1 || die "Slot $slot cannot list Object Storage containers; check activation, region, and role."
}

delete_slot() {
  local slot=$1 project_id=$2 secret
  kube delete providerconfig.openstack.m.crossplane.io "$slot" --ignore-not-found >/dev/null
  kubectl --context "$kube_context" delete composition "storage-$slot" --ignore-not-found >/dev/null
  kubectl --context "$kube_context" delete environmentconfig "storage-$slot" --ignore-not-found >/dev/null
  openstack_profile "$admin_cloud" role remove --user "$controller_user_id" \
    --project "$project_id" "$project_role" >/dev/null 2>&1 || \
    die "Could not remove role $project_role from the controller in $slot."
  secret=$(kube get secret cloudferro-provider-creds --ignore-not-found -o json 2>/dev/null) || die 'Could not inspect the shared controller Secret.'
  if [[ -n $secret ]]; then
    jq --arg slot "$slot" '
      {apiVersion:"v1",kind:"Secret",
       metadata:{name:.metadata.name,namespace:.metadata.namespace,
                 labels:(.metadata.labels // {}),
                 annotations:(.metadata.annotations // {})},
       type:(.type // "Opaque"),data:(.data // {})} |
      del(.data[$slot])
    ' <<<"$secret" >"$work_dir/secret.json"
    if jq -e '(.data // {}) | length == 0' "$work_dir/secret.json" >/dev/null; then
      kube delete secret cloudferro-provider-creds --ignore-not-found >/dev/null
    else
      kube apply --server-side --field-manager="$managed_by" -f "$work_dir/secret.json" >/dev/null
    fi
  fi
  printf '%s: project=%s role assignments and managed slot resources deleted\n' "$slot" "$project_id"
}

ensure_user() {
  local identity user user_id password temporary error_file
  identity=$(identity_path)
  if [[ -e $identity || -L $identity ]]; then
    check_identity_file
    return
  fi
  password=$(openssl rand -hex 32) || die 'Could not generate a controller password.'
  printf '%s' "$password" >"$work_dir/controller-password"
  error_file="$work_dir/user-create.stderr"
  if ! user=$(printf '%s\n%s\n' "$password" "$password" |
      OPENSTACK_PASSWORD_PROMPT=1 openstack_profile "$admin_cloud" user create \
        --domain "$domain_id" --password-prompt \
        --description 'Provider Storage shared controller' "$controller_name" -f json 2>"$error_file"); then
    if grep -Eqi '(^|[^0-9])403([^0-9]|$)|forbidden|not authorized|identity:create_user|policy does not allow' "$error_file"; then
      die "OpenStack denied shared controller user creation (HTTP 403). The bootstrap login needs identity:create_user permission in domain $domain_id."
    fi
    if grep -Eqi '(^|[^0-9])409([^0-9]|$)|conflict|already exists|duplicate' "$error_file"; then
      die "Controller user name $controller_name already exists in domain $domain_id. Resolve the existing user before retrying; this script cannot adopt it without its private identity file."
    fi
    if grep -Eqi '(^|[^0-9])401([^0-9]|$)|unauthorized|invalid token|token expired' "$error_file"; then
      die 'OpenStack rejected the bootstrap login while creating the shared controller user (HTTP 401). Refresh the login and retry.'
    fi
    if grep -Eqi 'password prompt|no terminal detected|no tty|not a tty|end of file|eoferror|input/output error' "$error_file"; then
      die 'OpenStack could not read the password prompt for the shared controller. Check that the CLI accepts password input without a terminal.'
    fi
    die 'OpenStack could not create the shared controller user. Check the bootstrap login, domain permissions, and OpenStack CLI error.'
  fi
  user_id=$(jq -er '.id // .ID' <<<"$user") || die 'The shared controller user response has no ID.'
  [[ $user_id =~ ^[a-fA-F0-9]{32}$ ]] || die 'The shared controller user ID is invalid.'
  temporary=$(mktemp "$credentials_dir/.provider-storage.XXXXXXXX")
  jq -n --arg url "$auth_url" --arg region "$region" --arg domain "$domain_id" \
    --arg user "$user_id" --arg userName "$controller_name" \
    --rawfile password "$work_dir/controller-password" \
    '{auth_url:$url,region:$region,domain_id:$domain,user_id:$user,user_name:$userName,password:$password}' >"$temporary"
  chmod 600 -- "$temporary"
  mv -- "$temporary" "$identity"
  rm -f -- "$work_dir/controller-password"
  check_identity_file
}

ensure_role() {
  local slot=$1 project_id=$2 user_id=$3 error_file
  error_file="$work_dir/role-add.stderr"
  if ! openstack_profile "$admin_cloud" role add --user "$user_id" \
      --project "$project_id" "$project_role" >/dev/null 2>"$error_file"; then
    if grep -Eqi '(^|[^0-9])403([^0-9]|$)|forbidden|not authorized|identity:create_grant|policy does not allow' "$error_file"; then
      die "OpenStack denied project role assignment (HTTP 403). The bootstrap login needs identity:create_grant permission on project $project_id."
    fi
    if grep -Eqi '(^|[^0-9])401([^0-9]|$)|unauthorized|invalid token|token expired' "$error_file"; then
      die 'OpenStack rejected the bootstrap login during project role assignment (HTTP 401). Refresh the login and retry.'
    fi
    if grep -Eqi 'no role found|role .* not found|could not find role' "$error_file"; then
      die "OpenStack could not resolve project role $project_role. Set CROSSPLANE_CLOUDFERRO_PROJECT_ROLE to a valid role name or ID."
    fi
    die "Could not assign project role $project_role to the controller for $slot. Check the role and identity:create_grant permission."
  fi
}

publish_slot() {
  local slot=$1 project_id=$2 project_name=$3 user_id=$4 secret encoded
  jq --arg project "$project_id" --arg domain "$domain_id" '
    {auth_url,region,user_id,password,user_domain_id:$domain,tenant_id:$project}
  ' "$(identity_path)" >"$work_dir/config.json"
  encoded=$(base64 -w0 "$work_dir/config.json")
  secret=$(kube get secret cloudferro-provider-creds --ignore-not-found -o json 2>/dev/null) || die 'Could not inspect the shared controller Secret.'
  if [[ -z $secret ]]; then
    secret='{"apiVersion":"v1","kind":"Secret","metadata":{"name":"cloudferro-provider-creds"},"type":"Opaque","data":{}}'
  else
    secret=$(jq '
      {apiVersion:"v1",kind:"Secret",
       metadata:{name:.metadata.name,namespace:.metadata.namespace,
                 labels:(.metadata.labels // {}),
                 annotations:(.metadata.annotations // {})},
       type:(.type // "Opaque"),data:(.data // {})}
    ' <<<"$secret")
  fi
  jq --arg manager "$managed_by" --arg user "$user_id" --arg slot "$slot" --arg config "$encoded" '
    .metadata.labels["app.kubernetes.io/managed-by"] = $manager |
    .metadata.annotations["storages.pkg.internal/controller-user-id"] = $user |
    .data[$slot] = $config
  ' <<<"$secret" >"$work_dir/secret.json"
  kube apply --server-side --field-manager="$managed_by" -f "$work_dir/secret.json" >/dev/null
  rm -f -- "$work_dir/secret.json"

  jq -n --arg slot "$slot" --arg namespace "$namespace" --arg manager "$managed_by" \
    --arg projectName "$project_name" --arg projectId "$project_id" --arg userId "$user_id" '
    {apiVersion:"openstack.m.crossplane.io/v1beta1",kind:"ProviderConfig",
     metadata:{name:$slot,namespace:$namespace,labels:{"app.kubernetes.io/managed-by":$manager},
               annotations:{"storages.pkg.internal/project-name":$projectName,
                            "storages.pkg.internal/project-id":$projectId,
                            "storages.pkg.internal/controller-user-id":$userId}},
     spec:{credentials:{source:"Secret",secretRef:{name:"cloudferro-provider-creds",namespace:$namespace,key:$slot}}}}
  ' >"$work_dir/providerconfig.json"
  kube apply --server-side --field-manager="$managed_by" -f "$work_dir/providerconfig.json" >/dev/null

  jq -n --arg slot "$slot" --arg namespace "$namespace" --arg manager "$managed_by" \
    --arg project "$project_id" --arg controller "$user_id" \
    --arg endpoint "$s3_endpoint" --arg region "$region" --arg s3region "$s3_region" '
    {apiVersion:"apiextensions.crossplane.io/v1beta1",kind:"EnvironmentConfig",
     metadata:{name:("storage-"+$slot),labels:{"app.kubernetes.io/managed-by":$manager}},
     data:{storage:{endpoint:$endpoint,force_path_style:"true",provider:"Other",region:$region,
                    s3Region:$s3region,serviceName:$project,
                    controllerUserId:$controller,type:"s3"}}}
  ' >"$work_dir/environment.json"
  kubectl --context "$kube_context" apply --server-side --field-manager="$managed_by" -f "$work_dir/environment.json" >/dev/null

  sed "s/cloudferro-0001/$slot/g" "$repo_dir/cloudferro/composition.yaml" >"$work_dir/composition.yaml"
  kubectl --context "$kube_context" apply --server-side --force-conflicts \
    --field-manager="$managed_by" -f "$work_dir/composition.yaml" >/dev/null
}

if [[ $admin_cloud == current ]]; then
  login=$(active_login)
  IFS=$'\t' read -r login_user login_scope login_scope_id login_domain <<<"$login"
  [[ ${OS_AUTH_URL:-} == "$auth_url" && ${OS_REGION_NAME:-} == "$region" &&
     $login_domain == "$domain_id" ]] || die 'The active login does not match the configured Keystone URL, OpenStack region, or slot domain.'
fi
projects=$(admin_json project list --long)
jq -e 'type == "array" and all(.[]; type == "object" and
  ((.ID // .id) | type == "string") and ((.Name // .name) | type == "string"))' \
  <<<"$projects" >/dev/null || die 'Project list is invalid.'
selected="$work_dir/selected-projects.tsv"
: >"$selected"
declare -A seen_slots=()
while IFS=$'\t' read -r project_id project_name project_domain project_enabled; do
  if slot=$(slot_for_name "$project_name"); then
    :
  else
    status=$?
    ((status == 1)) && continue
    die 'The project pattern must capture exactly four digits in its first group.'
  fi
  [[ $project_id =~ ^[a-fA-F0-9]{32}$ ]] || die "Matching project $project_name has an invalid ID."
  [[ $project_domain != - ]] || die "Matching project $project_name has no domain ID in the project list."
  [[ $project_domain == "$domain_id" ]] || continue
  [[ $project_enabled == true ]] || die "Matching project $project_name is disabled or has no enabled state in the project list."
  [[ -z ${seen_slots[$slot]:-} ]] || die "More than one visible project maps to $slot. Narrow the project pattern."
  seen_slots[$slot]=$project_id
  printf '%s\t%s\t%s\n' "$slot" "$project_name" "$project_id" >>"$selected"
done < <(jq -r '.[] | [(.ID // .id),(.Name // .name),
  (."Domain ID" // .domain_id // "-"),
  (if has("Enabled") then .Enabled elif has("enabled") then .enabled else .is_enabled end | tostring)] | @tsv' <<<"$projects")
if [[ ! -s $selected ]]; then
  if [[ $action == delete ]]; then
    printf 'No visible projects in the selected domain match the numbered project pattern; nothing to delete.\n'
    exit 0
  fi
  die 'No visible projects in the selected domain match the numbered project pattern.'
fi
[[ $(wc -l <"$selected") -le 10000 ]] || die 'The project pattern selected more than 10000 slots.'
LC_ALL=C sort -t $'\t' -k1,1 "$selected" -o "$selected"
if [[ $action == status ]]; then
  identity=$(identity_path)
  user_id=missing
  if [[ -f $identity && ! -L $identity ]]; then
    user_id=$(jq -er '.user_id' "$identity") || die 'The shared controller identity file is invalid.'
  fi
  while IFS=$'\t' read -r slot project_name project_id; do
    printf '%s: project=%s project_name=%s controller_user_id=%s\n' \
      "$slot" "$project_id" "$project_name" "$user_id"
  done <"$selected"
  exit 0
fi

check_cluster
check_owned secret cloudferro-provider-creds namespaced

# Check every cluster name and existing project before the first mutation.
if [[ $action == delete ]]; then
  claims=$(kubectl --context "$kube_context" get storages.pkg.internal --all-namespaces -o json 2>/dev/null) || die 'Could not inspect Storage resources across namespaces before delete.'
  jq -e '.items | type == "array"' <<<"$claims" >/dev/null || die 'Storage list is invalid.'
fi
while IFS=$'\t' read -r slot project_name project_id; do
  check_slot_resources "$slot"
  slot_binding "$slot" "$project_name" "$project_id" "$(if [[ $action == verify ]]; then printf true; else printf false; fi)"
  if [[ $action == delete ]]; then
    jq -e --arg slot "$slot" --arg name "storage-$slot" '
      [.items[] | select(
        .spec.crossplane.compositionSelector.matchLabels.provider == $slot or
        .spec.crossplane.compositionRef.name == $name or
        .metadata.labels["storages.pkg.internal/backend"] == $slot
      )] | length == 0
    ' <<<"$claims" >/dev/null || die "Storage still selects $slot; remove it before deleting bootstrap access."
  fi
done <"$selected"

if [[ $action == apply ]]; then
  if [[ ! -e $credentials_dir ]]; then mkdir -m 700 -- "$credentials_dir"; fi
  ensure_user
else
  check_identity_file
fi
controller_user_id=$(jq -r '.user_id' "$(identity_path)")

while IFS=$'\t' read -r slot project_name project_id; do
  if [[ $action == delete ]]; then
    delete_slot "$slot" "$project_id"
    continue
  fi
  if [[ $action == apply ]]; then
    ensure_role "$slot" "$project_id" "$controller_user_id"
  fi
  verify_credential "$slot" "$project_id" "$controller_user_id"
  if [[ $action == apply ]]; then publish_slot "$slot" "$project_id" "$project_name" "$controller_user_id"; fi
  printf '%s: project=%s controller verified%s\n' "$slot" "$project_id" \
    "$(if [[ $action == apply ]]; then printf ', cluster slot published'; fi)"
done <"$selected"
