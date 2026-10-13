#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

# Controller passwords must never be traced or printed.
set +x
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: cloudferro/dependencies/iam.sh <status|apply|verify|render-secrets>

Prepare one shared CloudFerro controller identity for selected projects.
Only project names that match the anchored pattern are selected. Review
cloudferro/dependencies/README.md first.

Commands:
  status          Show the current setup. Does not change resources.
  apply           Create or update resources and the credential file.
  verify          Check that resources and credentials are ready.
  render-secrets  Read only the credential file and print Secret manifests.

Required environment for status, apply, and verify:
  CROSSPLANE_CLOUDFERRO_DOMAIN_ID         Keystone domain ID for projects
  CROSSPLANE_CLOUDFERRO_ADMIN_CLOUD       Bootstrap OpenStack profile, or current
  CROSSPLANE_CLOUDFERRO_AUTH_URL          Keystone v3 URL
  CROSSPLANE_CLOUDFERRO_REGION            OpenStack region, for example WAW3-2

Optional environment:
  CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN   Anchored project-name regex
                                         (default ^.+-[0-9]{4}$)
  CROSSPLANE_CLOUDFERRO_CONTROLLER_NAME   Shared controller user name
                                         (default provider-storage-controller)
  CROSSPLANE_CLOUDFERRO_PROJECT_ROLE      Project role name or ID (default member)
  CROSSPLANE_CLOUDFERRO_NAMESPACE         Namespace for generated Secret manifests
                                         (default workspace)
  CROSSPLANE_CLOUDFERRO_CREDENTIALS_FILE  Private JSON file outside this repo
                                         (default:
                                         ~/.config/provider-storage/cloudferro-creds.json)

The script creates one controller user in the domain and assigns it to every
matching project. Apply writes the credential file with mode 0600. The
separate render-secrets action reads only that file and prints one Secret
manifest named cloudferro-project-<project-id> for each project. The
Composition creates each Storage ProviderConfig.
The script does not access Kubernetes or manage the EnvironmentConfig.
It does not create or delete projects. If the credential file is missing for
an existing controller, apply finds the user by name and domain, asks for its
password, and restores the file.
EOF
}

die() { printf 'Error: %s\n' "$1" >&2; exit 1; }

case ${1:-} in
  -h|--help|help|usage) usage; exit 0 ;;
  status|apply|verify|render-secrets) (($# == 1)) || { usage >&2; exit 2; }; action=$1 ;;
  *) usage >&2; exit 2 ;;
esac

for dependency in jq; do
  command -v "$dependency" >/dev/null 2>&1 || die "Install $dependency before running IAM bootstrap."
done

required() {
  local value=${!1:-}
  [[ -n $value ]] || die "$1 must be set."
  printf '%s' "$value"
}

namespace=${CROSSPLANE_CLOUDFERRO_NAMESPACE:-workspace}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for dependency in realpath stat; do
  command -v "$dependency" >/dev/null 2>&1 || die "Install $dependency before running IAM bootstrap."
done
credentials_file=${CROSSPLANE_CLOUDFERRO_CREDENTIALS_FILE:-}
if [[ -z $credentials_file ]]; then
  [[ ${HOME:-} = /* ]] || die 'HOME must be an absolute path for the default CloudFerro credential file.'
  credentials_file="$HOME/.config/provider-storage/cloudferro-creds.json"
fi
[[ $namespace =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die 'The Kubernetes namespace is invalid.'
[[ $credentials_file = /* && ! -L $credentials_file ]] || die 'The credential file must use an absolute path and must not be a symlink.'
repo_dir=$(realpath -- "$script_dir/../..")
credentials_dir=$(dirname -- "$credentials_file")
if [[ $action == apply && ! -e $credentials_dir ]]; then
  mkdir -p -m 700 -- "$credentials_dir" || die 'Could not create the CloudFerro credential directory.'
fi
[[ ! -e $credentials_dir || -d $credentials_dir ]] || die 'The credential-file parent path is not a directory.'
if [[ -d $credentials_dir ]]; then
  resolved_file="$(realpath -e -- "$credentials_dir")/$(basename -- "$credentials_file")"
  [[ $resolved_file != "$repo_dir" && $resolved_file != "$repo_dir"/* ]] || die 'Keep controller credentials outside the Git repository.'
fi
if [[ -e $credentials_file ]]; then
  [[ -f $credentials_file ]] || die 'The credential path must be a regular file.'
  [[ $(stat -c '%a:%u' -- "$credentials_file") == "600:$(id -u)" ]] || die 'The credential file must be owned by you and mode 0600.'
fi

check_project_credentials_file() {
  [[ ! -L $credentials_file && -f $credentials_file ]] || die 'Run apply before render-secrets; the credential file is missing.'
  [[ $(stat -c '%a:%u' -- "$credentials_file") == "600:$(id -u)" ]] || die 'The credential file must be owned by you and mode 0600.'
  jq -e '
    (keys | sort) == ["identity","projects"] and
    (.identity | keys | sort) ==
      ["auth_url","domain_id","password","region","user_id","user_name"] and
    (.identity.auth_url | type == "string" and test("^https://[A-Za-z0-9.-]+(:[0-9]+)?/v3$")) and
    (.identity.region | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.identity.domain_id | type == "string" and test("^[0-9a-fA-F]{32}$")) and
    (.identity.user_id | type == "string" and test("^[0-9a-fA-F]{32}$")) and
    (.identity.user_name | type == "string" and length > 0) and
    (.identity.password | type == "string" and length > 0) and
    (.projects | type == "array" and length > 0) and
    all(.projects[]; type == "string" and test("^[0-9a-f]{32}$")) and
    ((.projects | unique | length) == (.projects | length))
  ' "$credentials_file" >/dev/null || die 'The credential file has an invalid identity or project list.'
}

render_secrets() {
  local project_id secret_name
  check_project_credentials_file
  while IFS= read -r project_id; do
    secret_name="cloudferro-project-$project_id"
    printf '%s\n' '---'
    jq -n --arg name "$secret_name" --arg namespace "$namespace" \
      --arg manager provider-storage-cloudferro-iam --arg project "$project_id" \
      --slurpfile credentials "$credentials_file" '
      ($credentials[0].identity |
        {auth_url,region,user_id,password,default_domain:"",tenant_id:$project} |
        tojson) as $config |
      {apiVersion:"v1",kind:"Secret",
       metadata:{name:$name,namespace:$namespace,
                 labels:{"app.kubernetes.io/managed-by":$manager}},
       type:"Opaque",data:{config:($config | @base64)}}
    '
  done < <(jq -r '.projects[]' "$credentials_file")
}

if [[ $action == render-secrets ]]; then
  render_secrets
  exit 0
fi

command -v openstack >/dev/null 2>&1 || die 'Install openstack before running IAM bootstrap.'

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

for dependency in mktemp sed sort wc openssl python3 sleep; do
  command -v "$dependency" >/dev/null 2>&1 || die "Install $dependency before running IAM bootstrap."
done

project_pattern=${CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN:-}
[[ -n $project_pattern ]] || project_pattern='^.+-[0-9]{4}$'
domain_id=$(required CROSSPLANE_CLOUDFERRO_DOMAIN_ID)
admin_cloud=$(required CROSSPLANE_CLOUDFERRO_ADMIN_CLOUD)
controller_name=${CROSSPLANE_CLOUDFERRO_CONTROLLER_NAME:-provider-storage-controller}
project_role=${CROSSPLANE_CLOUDFERRO_PROJECT_ROLE:-member}
auth_url=$(required CROSSPLANE_CLOUDFERRO_AUTH_URL)
region=$(required CROSSPLANE_CLOUDFERRO_REGION)

[[ ${project_pattern:0:1} == ^ && ${project_pattern: -1} == '$' ]] || die 'The project pattern must be anchored with ^ and $.'
if [[ xyz =~ $project_pattern ]]; then :; elif (( $? == 2 )); then die 'The project pattern is not a valid extended regex.'; fi
[[ $domain_id =~ ^[a-fA-F0-9]{32}$ ]] || die 'The domain ID must be 32 hexadecimal characters.'
[[ $admin_cloud =~ ^[A-Za-z0-9._-]+$ ]] || die 'The cloud profile name contains invalid characters.'
[[ $controller_name =~ ^[A-Za-z0-9._-]+$ ]] || die 'The controller user name contains invalid characters.'
[[ $project_role =~ ^[A-Za-z0-9._-]+$ ]] || die 'The project role name or ID contains invalid characters.'
[[ $region =~ ^[A-Za-z0-9._-]+$ ]] || die 'The OpenStack region contains invalid characters.'
[[ $auth_url =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/v3$ ]] || die 'The Keystone endpoint must be an HTTPS URL that ends in /v3.'

work_dir=$(mktemp -d /tmp/provider-storage-cloudferro.XXXXXXXX)
trap 'rm -rf -- "$work_dir"' EXIT

# A named profile isolates its credentials. The explicit current mode uses the
# operator's shell token, including an optional project or domain rescope.
openstack_profile() (
  local profile=$1 target_project='' target_domain=''
  local -a arguments=()
  shift
  cd -- "$work_dir"
  unset OS_DEBUG
  if [[ $profile == current ]]; then
    unset OS_CLOUD OS_CLIENT_CONFIG_FILE OS_AUTH_TOKEN OS_ENDPOINT
    unset OS_USERNAME OS_PASSWORD OS_USER_ID OS_USER_DOMAIN_ID OS_USER_DOMAIN_NAME
    unset OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET
    while (($#)); do
      case $1 in
        --os-project-id)
          shift
          (($#)) || die 'A project scope is missing its ID.'
          target_project=$1
          ;;
        --os-domain-id)
          shift
          (($#)) || die 'A domain scope is missing its ID.'
          target_domain=$1
          ;;
        *) arguments+=("$1") ;;
      esac
      shift
    done
    [[ -z $target_project || -z $target_domain ]] \
      || die 'Project and domain scope cannot be requested together.'
    if [[ -n $target_project ]]; then
      [[ $target_project =~ ^[a-fA-F0-9]{32}$ ]] || die 'The target project ID is invalid.'
      unset OS_DOMAIN_ID OS_DOMAIN_NAME OS_PROJECT_NAME OS_PROJECT_DOMAIN_ID OS_PROJECT_DOMAIN_NAME
      export OS_PROJECT_ID=$target_project
    elif [[ -n $target_domain ]]; then
      [[ $target_domain =~ ^[a-fA-F0-9]{32}$ ]] || die 'The target domain ID is invalid.'
      unset OS_PROJECT_ID OS_PROJECT_NAME OS_PROJECT_DOMAIN_ID OS_PROJECT_DOMAIN_NAME OS_DOMAIN_NAME
      export OS_DOMAIN_ID=$target_domain
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

domain_admin() {
  if [[ $admin_cloud == current ]]; then
    openstack_profile "$admin_cloud" --os-domain-id "$domain_id" "$@"
  else
    openstack_profile "$admin_cloud" "$@"
  fi
}

admin_json() {
  local result scope_description
  if [[ ${1:-} == user && ${2:-} == list ]]; then
    result=$(domain_admin "$@" -f json 2>/dev/null) || result=''
  else
    result=$(openstack_profile "$admin_cloud" "$@" -f json 2>/dev/null) || result=''
  fi
  if [[ -z $result ]]; then
    if [[ ${1:-} == project && ${2:-} == list ]]; then
      die 'OpenStack project listing failed. Run openstack project list --long -f json in the same shell to inspect the CLI error.'
    fi
    if [[ ${1:-} == user && ${2:-} == list ]]; then
      scope_description="bootstrap profile $admin_cloud"
      if [[ $admin_cloud == current ]]; then
        scope_description="${login_scope}-scoped login after domain re-scoping"
      fi
      die "Controller-user discovery failed for the $scope_description. The login needs a domain role that permits identity:list_users in domain $domain_id when the local credential file is missing."
    fi
    die "Bootstrap OpenStack ${1:-request} failed. Check the token or profile and domain permissions."
  fi
  printf '%s\n' "$result"
}

project_admin() {
  local project_id=$1
  shift
  if [[ $admin_cloud == current && ${login_scope:-} == project ]]; then
    openstack_profile "$admin_cloud" --os-project-id "$project_id" "$@"
  else
    openstack_profile "$admin_cloud" "$@"
  fi
}

check_identity_file() {
  [[ ! -L $credentials_file && -f $credentials_file ]] || die 'Missing shared controller credential file.'
  [[ $(stat -c '%a:%u' -- "$credentials_file") == "600:$(id -u)" ]] || die 'The controller credential file must be owned by you and mode 0600.'
  jq -e --arg url "$auth_url" --arg region "$region" --arg domain "$domain_id" --arg name "$controller_name" '
    .identity.auth_url == $url and .identity.region == $region and
    .identity.domain_id == $domain and .identity.user_name == $name and
    (.identity.user_id | type == "string" and test("^[a-fA-F0-9]{32}$")) and
    (.identity.password | type == "string" and length > 0) and
    (.projects | type == "array")
  ' "$credentials_file" >/dev/null || die 'The shared controller credential file has an invalid format or binding.'
}

store_controller_identity() {
  local user_id=$1 temporary
  temporary=$(mktemp "$credentials_dir/.provider-storage.XXXXXXXX")
  jq -n --arg url "$auth_url" --arg region "$region" --arg domain "$domain_id" \
    --arg user "$user_id" --arg userName "$controller_name" \
    --rawfile password "$work_dir/controller-password" \
    '{identity:{auth_url:$url,region:$region,domain_id:$domain,user_id:$user,
                user_name:$userName,password:$password},projects:[]}' >"$temporary"
  chmod 600 -- "$temporary"
  mv -- "$temporary" "$credentials_file"
}

recover_identity() {
  local user_id=$1 password
  printf 'Enter the password for existing controller %s (%s): ' \
    "$controller_name" "$user_id"
  if ! IFS= read -r -s password; then
    printf '\n'
    die 'Could not read the existing controller password from the terminal.'
  fi
  printf '\n'
  [[ -n $password && $password != *$'\n'* && $password != *$'\r'* ]] || die 'The existing controller password is empty or invalid.'
  printf '%s' "$password" >"$work_dir/controller-password"
  unset password
  store_controller_identity "$user_id"
  rm -f -- "$work_dir/controller-password"
  check_identity_file
  printf 'Restored the local controller identity for the discovered user\n'
}

existing_controller_user_id() {
  local users matches count user_id
  if ! users=$(admin_json user list --domain "$domain_id" --long); then
    return 1
  fi
  jq -e 'type == "array" and all(.[]; type == "object" and
    ((.ID // .id) | type == "string") and ((.Name // .name) | type == "string"))' \
    <<<"$users" >/dev/null || die 'The OpenStack user list is invalid.'
  matches=$(jq --arg name "$controller_name" '
    [.[] | select((.Name // .name) == $name)]
  ' <<<"$users")
  count=$(jq 'length' <<<"$matches")
  ((count <= 1)) || die "More than one controller user named $controller_name exists in domain $domain_id."
  ((count == 1)) || return 0
  jq -e '.[0] | (if has("Enabled") then .Enabled else .enabled end) == true' \
    <<<"$matches" >/dev/null || die "Existing controller user $controller_name is disabled."
  user_id=$(jq -er '.[0].ID // .[0].id' <<<"$matches") \
    || die 'The existing controller user has no ID.'
  [[ $user_id =~ ^[a-fA-F0-9]{32}$ ]] || die 'The existing controller user ID is invalid.'
  printf '%s' "$user_id"
}

project_openstack() (
  local project_id=$1
  shift
  cd -- "$work_dir"
  jq -n --arg project "$project_id" \
    --slurpfile credentials "$credentials_file" '
    {clouds:{"provider-storage-project":{
      auth_type:"v3password", region_name:$credentials[0].identity.region,
      auth:{auth_url:$credentials[0].identity.auth_url,
            user_id:$credentials[0].identity.user_id,
            password:$credentials[0].identity.password,project_id:$project}
    }}}
  ' >"$work_dir/clouds.yaml"
  chmod 600 -- "$work_dir/clouds.yaml"
  unset OS_AUTH_URL OS_AUTH_TYPE OS_USERNAME OS_PASSWORD OS_PROJECT_ID OS_PROJECT_NAME
  unset OS_USER_ID OS_USER_DOMAIN_ID OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_ID
  unset OS_PROJECT_DOMAIN_NAME OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET
  unset OS_TOKEN OS_AUTH_TOKEN OS_ENDPOINT OS_REGION_NAME
  unset OS_DEBUG
  OS_CLIENT_CONFIG_FILE="$work_dir/clouds.yaml" openstack --os-cloud provider-storage-project "$@"
)

verify_credential() {
  local project_id=$1 user_id=$2 token token_project token_user attempt
  local max_attempts=12
  check_identity_file
  printf 'project=%s: verifying scoped controller authentication\n' "$project_id"
  token=''
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if token=$(project_openstack "$project_id" token issue -f json 2>/dev/null); then
      break
    fi
    if ((attempt < max_attempts)); then
      printf 'project=%s: scoped authentication is not ready; retrying in 5 seconds (%s/%s)\n' \
        "$project_id" "$attempt" "$max_attempts"
      sleep 5
    fi
  done
  [[ -n $token ]] || die "The controller cannot issue a token for project $project_id after $max_attempts attempts. Check the project role assignment and activation."
  token_project=$(jq -er '.project_id | select(type == "string")' <<<"$token") || die "The project-scoped token response for project $project_id has no project ID."
  token_user=$(jq -er '.user_id | select(type == "string")' <<<"$token") || die "The project-scoped token response for project $project_id has no user ID."
  [[ $token_project == "$project_id" && $token_user == "$user_id" ]] || die 'The controller credential is scoped to a different project or user.'
  printf 'project=%s: checking Object Storage access\n' "$project_id"
  project_openstack "$project_id" container list -f json >/dev/null 2>&1 || die "Project $project_id cannot list Object Storage containers; check activation, region, and role."
}

ensure_user() {
  local user user_id password error_file existing_user_id scope_description
  if [[ -e $credentials_file || -L $credentials_file ]]; then
    check_identity_file
    return
  fi
  if ! existing_user_id=$(existing_controller_user_id); then
    return 1
  fi
  if [[ -n $existing_user_id ]]; then
    recover_identity "$existing_user_id"
    return
  fi
  password=$(openssl rand -hex 32) || die 'Could not generate a controller password.'
  printf '%s' "$password" >"$work_dir/controller-password"
  error_file="$work_dir/user-create.stderr"
  if ! user=$(printf '%s\n%s\n' "$password" "$password" |
      OPENSTACK_PASSWORD_PROMPT=1 domain_admin user create \
        --domain "$domain_id" --password-prompt \
        --description 'Provider Storage shared controller' "$controller_name" -f json 2>"$error_file"); then
    if grep -Eqi '(^|[^0-9])403([^0-9]|$)|forbidden|not authorized|identity:create_user|policy does not allow' "$error_file"; then
      scope_description="bootstrap profile $admin_cloud"
      if [[ $admin_cloud == current ]]; then
        scope_description="${login_scope}-scoped login after domain re-scoping"
      fi
      die "OpenStack denied shared controller user creation (HTTP 403). The $scope_description needs identity:create_user permission in domain $domain_id."
    fi
    if grep -Eqi '(^|[^0-9])409([^0-9]|$)|conflict|already exists|duplicate' "$error_file"; then
      die "Controller user name $controller_name already exists in domain $domain_id. Retry so the script can discover it."
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
  store_controller_identity "$user_id"
  rm -f -- "$work_dir/controller-password"
  check_identity_file
}

ensure_role() {
  local project_id=$1 user_id=$2 error_file
  error_file="$work_dir/role-add.stderr"
  if ! project_admin "$project_id" role add --user "$user_id" \
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
    die "Could not assign project role $project_role to the controller for project $project_id. Check the role and identity:create_grant permission."
  fi
}

write_project_credentials() {
  local temporary project_ids
  temporary=$(mktemp "$credentials_dir/.provider-storage-credentials.XXXXXXXX")
  project_ids=$(jq -Rn '[inputs | split("\t")[0]]' <"$selected")
  jq -n --argjson projects "$project_ids" --slurpfile credentials "$credentials_file" '
    {identity:$credentials[0].identity,projects:$projects}
  ' >"$temporary"
  chmod 600 -- "$temporary"
  mv -- "$temporary" "$credentials_file"
  check_project_credentials_file
}

if [[ $admin_cloud == current ]]; then
  printf 'Checking the active OpenStack bootstrap login\n'
  login=$(active_login)
  IFS=$'\t' read -r login_user login_scope login_scope_id login_domain <<<"$login"
  [[ ${OS_AUTH_URL:-} == "$auth_url" && ${OS_REGION_NAME:-} == "$region" &&
     $login_domain == "$domain_id" ]] || die 'The active login does not match the configured Keystone URL, OpenStack region, or project domain.'
  if [[ $login_scope == project ]]; then
    printf 'Active login: user_id=%s project_id=%s project_domain_id=%s OpenStack_region=%s\n' \
      "$login_user" "$login_scope_id" "$login_domain" "$OS_REGION_NAME"
  else
    printf 'Active login: user_id=%s domain_id=%s OpenStack_region=%s\n' \
      "$login_user" "$login_scope_id" "$OS_REGION_NAME"
  fi
fi
printf 'Discovering matching OpenStack projects\n'
projects=$(admin_json project list --long)
jq -e 'type == "array" and all(.[]; type == "object" and
  ((.ID // .id) | type == "string") and ((.Name // .name) | type == "string"))' \
  <<<"$projects" >/dev/null || die 'Project list is invalid.'
selected="$work_dir/selected-projects.tsv"
: >"$selected"
while IFS=$'\t' read -r project_id project_name project_domain project_enabled; do
  [[ $project_name =~ $project_pattern ]] || continue
  [[ $project_id =~ ^[a-f0-9]{32}$ ]] || die "Matching project $project_name has an invalid ID."
  [[ $project_domain != - ]] || die "Matching project $project_name has no domain ID in the project list."
  [[ $project_domain == "$domain_id" ]] || continue
  [[ $project_enabled == true ]] || die "Matching project $project_name is disabled or has no enabled state in the project list."
  printf '%s\t%s\n' "$project_id" "$project_name" >>"$selected"
done < <(jq -r '.[] | [(.ID // .id),(.Name // .name),
  (."Domain ID" // .domain_id // "-"),
  (if has("Enabled") then .Enabled elif has("enabled") then .enabled else .is_enabled end | tostring)] | @tsv' <<<"$projects")
if [[ ! -s $selected ]]; then
  die 'No visible projects in the selected domain match the project pattern.'
fi
[[ $(wc -l <"$selected") -le 10000 ]] || die 'The project pattern selected more than 10000 projects.'
LC_ALL=C sort -t $'\t' -k1,1 "$selected" -o "$selected"
printf 'Selected %s project(s)\n' "$(wc -l <"$selected")"
if [[ $action == status ]]; then
  user_id=missing
  if [[ -f $credentials_file && ! -L $credentials_file ]]; then
    user_id=$(jq -er '.identity.user_id' "$credentials_file") || die 'The shared controller credential file is invalid.'
  fi
  while IFS=$'\t' read -r project_id project_name; do
    printf 'project=%s project_name=%s controller_user_id=%s\n' \
      "$project_id" "$project_name" "$user_id"
  done <"$selected"
  exit 0
fi

if [[ $action == apply ]]; then
  printf 'Preparing the shared controller identity\n'
  ensure_user
else
  check_identity_file
fi

controller_user_id=$(jq -r '.identity.user_id' "$credentials_file")

if [[ $action == apply ]]; then
  while IFS=$'\t' read -r project_id project_name; do
    printf 'project=%s: assigning controller role %s\n' "$project_id" "$project_role"
    ensure_role "$project_id" "$controller_user_id"
    verify_credential "$project_id" "$controller_user_id"
  done <"$selected"

  write_project_credentials
  printf 'All selected projects passed verification\n'
  printf 'Credentials file: %s (mode 0600)\n' "$credentials_file"
  exit 0
fi

while IFS=$'\t' read -r project_id project_name; do
  verify_credential "$project_id" "$controller_user_id"
  printf 'project=%s controller verified\n' "$project_id"
done <"$selected"
