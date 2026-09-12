#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

: "${CROSSPLANE_OTC_REGION:=eu-nl}"
: "${CROSSPLANE_OTC_AUTH_URL:=https://iam.${CROSSPLANE_OTC_REGION}.otc.t-systems.com/v3}"
: "${CROSSPLANE_OTC_RESOURCE_PREFIX:=otc-${CROSSPLANE_OTC_DOMAIN_ID:-}}"
: "${CROSSPLANE_OTC_USER_NAME:=provider-storage-bootstrap-crossplane}"
: "${CROSSPLANE_OTC_GROUP_NAME:=provider-storage-bootstrap-crossplane}"

readonly USER_DESCRIPTION="Provider Storage controller for ${CROSSPLANE_OTC_RESOURCE_PREFIX}. Managed by otc/dependencies/iam.sh."
readonly GROUP_DESCRIPTION="Provider Storage controller permissions for ${CROSSPLANE_OTC_RESOURCE_PREFIX}. Managed by otc/dependencies/iam.sh."
readonly CREDENTIAL_DESCRIPTION="Provider Storage controller for ${CROSSPLANE_OTC_RESOURCE_PREFIX}"
readonly SECURITY_ADMIN_ROLE_NAME=secu_admin
readonly OBS_ADMIN_POLICY_NAME='OBS Administrator'

IAM_V3_ROOT=""
IAM_V30_ROOT=""
ADMIN_TOKEN=""
DOMAIN_NAME=""
PROJECT_NAME=""
TMP_DIR=""
IAM_RESPONSE=""
IAM_STATUS=""

usage() {
  cat <<'EOF'
Usage: otc/dependencies/iam.sh <apply|status|rotate-credential>

Bootstrap the OTC IAM resources that Provider Storage needs before deployment.
Run apply before you deploy the OTC provider components or ProviderConfig.
Review this script before running it.

Required environment:
  CROSSPLANE_OTC_DOMAIN_ID
      Exact 32-character target OTC domain ID.
  CROSSPLANE_OTC_PROJECT_ID
      Exact 32-character regional project ID used by the OTC provider.
  CROSSPLANE_OTC_CREDENTIALS_FILE
      Absolute output path for the provider credential JSON. Required by apply
      and rotate-credential.

Optional environment:
  CROSSPLANE_OTC_REGION
      OTC region (default: eu-nl).
  CROSSPLANE_OTC_AUTH_URL
      IAM v3 endpoint (default: the public endpoint for the selected region).
  CROSSPLANE_OTC_RESOURCE_PREFIX
      Naming prefix for Provider Storage buckets (default:
      otc-<domain-id>). Set an explicit installation-specific value during IAM
      bootstrap if the domain has multiple installs.
  CROSSPLANE_OTC_USER_NAME
      Controller user name (default: provider-storage-bootstrap-crossplane).
  CROSSPLANE_OTC_GROUP_NAME
      Controller group name (default: provider-storage-bootstrap-crossplane).
  OS_CLOUD or standard OS_* variables
      Select the administrator session used by the openstack client. The
      script re-scopes an existing token to the target domain for IAM calls.

The script creates one programmatic controller user and one permission group.
It writes the user's permanent AK/SK only to
CROSSPLANE_OTC_CREDENTIALS_FILE with mode 0600. It never prints the token, AK,
or SK.

OTC requires the Security Administrator system role to manage permanent
credentials for other IAM users. The script assigns that role at domain scope
and assigns the system-defined OBS Administrator policy to all existing and
future projects. The regional project ID is used for the provider credential,
not for the OBS policy assignment. Use a dedicated OTC domain as the outer
boundary.
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

validate_name() {
  local variable_name="$1"
  local value="$2"
  [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] \
    || fail "${variable_name} must contain 1-64 letters, digits, underscores, or hyphens."
}

validate_credentials_path() {
  local path="${CROSSPLANE_OTC_CREDENTIALS_FILE:-}"
  [[ -n "${path}" ]] || return 0
  [[ "${path}" == /* ]] \
    || fail "CROSSPLANE_OTC_CREDENTIALS_FILE must be an absolute path."
  [[ ! -L "${path}" ]] \
    || fail "CROSSPLANE_OTC_CREDENTIALS_FILE must not be a symbolic link."
  if [[ -e "${path}" && ! -f "${path}" ]]; then
    fail "CROSSPLANE_OTC_CREDENTIALS_FILE must be a regular file when it exists."
  fi
  [[ -d "$(dirname -- "${path}")" ]] \
    || fail "The CROSSPLANE_OTC_CREDENTIALS_FILE parent directory does not exist."
}

validate_inputs() {
  local action="$1"
  [[ "${CROSSPLANE_OTC_DOMAIN_ID:-}" =~ ^[0-9a-f]{32}$ ]] \
    || fail "CROSSPLANE_OTC_DOMAIN_ID must be the exact 32-character target domain ID."
  [[ "${CROSSPLANE_OTC_PROJECT_ID:-}" =~ ^[0-9a-f]{32}$ ]] \
    || fail "CROSSPLANE_OTC_PROJECT_ID must be the exact 32-character target project ID."
  [[ "${CROSSPLANE_OTC_REGION}" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || fail "CROSSPLANE_OTC_REGION contains unsupported characters."
  [[ "${CROSSPLANE_OTC_AUTH_URL}" =~ ^https://[A-Za-z0-9.-]+/v3/?$ ]] \
    || fail "CROSSPLANE_OTC_AUTH_URL must be an HTTPS IAM v3 endpoint without a query."
  [[ "${CROSSPLANE_OTC_RESOURCE_PREFIX}" =~ ^[a-z0-9][a-z0-9-]{2,49}$ ]] \
    || fail "CROSSPLANE_OTC_RESOURCE_PREFIX must be 3-50 lowercase letters, digits, or hyphens."
  validate_name CROSSPLANE_OTC_USER_NAME "${CROSSPLANE_OTC_USER_NAME}"
  validate_name CROSSPLANE_OTC_GROUP_NAME "${CROSSPLANE_OTC_GROUP_NAME}"
  if [[ ("${action}" == apply || "${action}" == rotate-credential) && \
        -z "${CROSSPLANE_OTC_CREDENTIALS_FILE:-}" ]]; then
    fail "CROSSPLANE_OTC_CREDENTIALS_FILE is required for ${action}."
  fi
  validate_credentials_path
}

init_session() {
  local token_json token_domain_id curl_config

  if ! token_json="$(
    unset OS_PROJECT_ID OS_PROJECT_NAME OS_PROJECT_DOMAIN_ID \
      OS_PROJECT_DOMAIN_NAME OS_DOMAIN_NAME OS_SYSTEM_SCOPE
    export OS_DOMAIN_ID="${CROSSPLANE_OTC_DOMAIN_ID}"
    command openstack token issue -f json
  )"; then
    fail "Could not obtain a domain-scoped OTC token from the openstack client."
  fi
  ADMIN_TOKEN="$(jq -r '.id // .ID // empty' <<<"${token_json}")"
  token_domain_id="$(jq -r '.domain_id // ."Domain ID" // empty' <<<"${token_json}")"
  unset token_json

  [[ "${ADMIN_TOKEN}" =~ ^[A-Za-z0-9._~+/=-]+$ ]] \
    || fail "The openstack client did not return a usable token."
  [[ "${token_domain_id}" == "${CROSSPLANE_OTC_DOMAIN_ID}" ]] \
    || fail "The openstack client did not return a token scoped to CROSSPLANE_OTC_DOMAIN_ID."

  IAM_V3_ROOT="${CROSSPLANE_OTC_AUTH_URL%/}"
  IAM_V30_ROOT="${IAM_V3_ROOT%/v3}/v3.0"
  TMP_DIR="$(mktemp -d)"
  chmod 0700 "${TMP_DIR}"
  curl_config="${TMP_DIR}/curl.conf"
  umask 077
  {
    printf 'silent\n'
    printf 'show-error\n'
    printf 'header = "Accept: application/json"\n'
    printf 'header = "Content-Type: application/json;charset=utf8"\n'
    printf 'header = "X-Auth-Token: %s"\n' "${ADMIN_TOKEN}"
  } >"${curl_config}"
}

cleanup() {
  ADMIN_TOKEN=""
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf -- "${TMP_DIR}"
  fi
}

iam_request() {
  local method="$1"
  local url="$2"
  local expected="$3"
  local body="${4:-}"
  local request_file=""
  local -a args

  IAM_RESPONSE="$(mktemp "${TMP_DIR}/response.XXXXXX")"
  args=(
    --config "${TMP_DIR}/curl.conf"
    --output "${IAM_RESPONSE}"
    --write-out '%{http_code}'
    --request "${method}"
  )
  if [[ -n "${body}" ]]; then
    request_file="$(mktemp "${TMP_DIR}/request.XXXXXX")"
    printf '%s' "${body}" >"${request_file}"
    args+=(--data-binary "@${request_file}")
  fi

  if ! IAM_STATUS="$(command curl "${args[@]}" "${url}")"; then
    fail "The OTC IAM API request did not complete."
  fi
  if [[ "${IAM_STATUS}" == 403 ]]; then
    fail "The OTC IAM API request ${method} ${url} failed with HTTP 403. The administrator session requires Security Administrator at domain scope."
  fi
  [[ " ${expected} " == *" ${IAM_STATUS} "* ]] \
    || fail "The OTC IAM API request ${method} ${url} failed with HTTP ${IAM_STATUS}."
}

verify_target() {
  local actual_domain_id actual_project_id project_domain_id

  iam_request GET "${IAM_V3_ROOT}/auth/domains" 200
  actual_domain_id="$(jq -r --arg domain "${CROSSPLANE_OTC_DOMAIN_ID}" \
    '.domains[] | select(.id == $domain) | .id' "${IAM_RESPONSE}")"
  DOMAIN_NAME="$(jq -r --arg domain "${CROSSPLANE_OTC_DOMAIN_ID}" \
    '.domains[] | select(.id == $domain) | .name' "${IAM_RESPONSE}")"
  [[ "${actual_domain_id}" == "${CROSSPLANE_OTC_DOMAIN_ID}" && -n "${DOMAIN_NAME}" ]] \
    || fail "The IAM endpoint did not return CROSSPLANE_OTC_DOMAIN_ID."

  iam_request GET "${IAM_V3_ROOT}/projects/${CROSSPLANE_OTC_PROJECT_ID}" 200
  actual_project_id="$(jq -r '.project.id // empty' "${IAM_RESPONSE}")"
  project_domain_id="$(jq -r '.project.domain_id // empty' "${IAM_RESPONSE}")"
  PROJECT_NAME="$(jq -r '.project.name // empty' "${IAM_RESPONSE}")"
  [[ "${actual_project_id}" == "${CROSSPLANE_OTC_PROJECT_ID}" && \
     "${project_domain_id}" == "${CROSSPLANE_OTC_DOMAIN_ID}" && \
     -n "${PROJECT_NAME}" ]] \
    || fail "CROSSPLANE_OTC_PROJECT_ID is not in CROSSPLANE_OTC_DOMAIN_ID."
}

owned_user_id() {
  local count user_id description domain_id access_mode enabled

  iam_request GET \
    "${IAM_V3_ROOT}/users?domain_id=${CROSSPLANE_OTC_DOMAIN_ID}&name=${CROSSPLANE_OTC_USER_NAME}" \
    200
  count="$(jq --arg name "${CROSSPLANE_OTC_USER_NAME}" \
    --arg domain "${CROSSPLANE_OTC_DOMAIN_ID}" \
    '[.users[] | select(.name == $name and .domain_id == $domain)] | length' \
    "${IAM_RESPONSE}")"
  ((count <= 1)) || fail "More than one controller user has the configured name."
  if ((count == 0)); then
    return 0
  fi
  user_id="$(jq -r --arg name "${CROSSPLANE_OTC_USER_NAME}" \
    --arg domain "${CROSSPLANE_OTC_DOMAIN_ID}" \
    '.users[] | select(.name == $name and .domain_id == $domain) | .id' \
    "${IAM_RESPONSE}")"
  [[ "${user_id}" =~ ^[0-9a-f]{32}$ ]] \
    || fail "The existing controller user has an invalid ID."

  iam_request GET "${IAM_V30_ROOT}/OS-USER/users/${user_id}" 200
  description="$(jq -r '.user.description // empty' "${IAM_RESPONSE}")"
  domain_id="$(jq -r '.user.domain_id // empty' "${IAM_RESPONSE}")"
  access_mode="$(jq -r '.user.access_mode // empty' "${IAM_RESPONSE}")"
  enabled="$(jq -r '.user.enabled // empty' "${IAM_RESPONSE}")"
  [[ "${description}" == "${USER_DESCRIPTION}" && \
     "${domain_id}" == "${CROSSPLANE_OTC_DOMAIN_ID}" ]] \
    || fail "Controller user ${CROSSPLANE_OTC_USER_NAME} exists but is not owned by this bootstrap."
  [[ "${access_mode}" == programmatic && "${enabled}" == true ]] \
    || fail "The owned controller user is not enabled for programmatic access."
  printf '%s\n' "${user_id}"
}

ensure_user() {
  local user_id body
  user_id="$(owned_user_id)"
  if [[ -n "${user_id}" ]]; then
    printf '%s\n' "${user_id}"
    return
  fi

  body="$(jq -n \
    --arg name "${CROSSPLANE_OTC_USER_NAME}" \
    --arg domain_id "${CROSSPLANE_OTC_DOMAIN_ID}" \
    --arg description "${USER_DESCRIPTION}" \
    '{user: {name: $name, domain_id: $domain_id, description: $description,
      access_mode: "programmatic", enabled: true}}')"
  iam_request POST "${IAM_V30_ROOT}/OS-USER/users" 201 "${body}"
  user_id="$(jq -r '.user.id // empty' "${IAM_RESPONSE}")"
  [[ "${user_id}" =~ ^[0-9a-f]{32}$ ]] \
    || fail "OTC did not return the new controller user ID."
  printf '%s\n' "${user_id}"
}

owned_group_id() {
  local count group_id description domain_id

  iam_request GET \
    "${IAM_V3_ROOT}/groups?domain_id=${CROSSPLANE_OTC_DOMAIN_ID}&name=${CROSSPLANE_OTC_GROUP_NAME}" \
    200
  count="$(jq --arg name "${CROSSPLANE_OTC_GROUP_NAME}" \
    --arg domain "${CROSSPLANE_OTC_DOMAIN_ID}" \
    '[.groups[] | select(.name == $name and .domain_id == $domain)] | length' \
    "${IAM_RESPONSE}")"
  ((count <= 1)) || fail "More than one controller group has the configured name."
  if ((count == 0)); then
    return 0
  fi
  group_id="$(jq -r --arg name "${CROSSPLANE_OTC_GROUP_NAME}" \
    --arg domain "${CROSSPLANE_OTC_DOMAIN_ID}" \
    '.groups[] | select(.name == $name and .domain_id == $domain) | .id' \
    "${IAM_RESPONSE}")"
  [[ "${group_id}" =~ ^[0-9a-f]{32}$ ]] \
    || fail "The existing controller group has an invalid ID."

  iam_request GET "${IAM_V3_ROOT}/groups/${group_id}" 200
  description="$(jq -r '.group.description // empty' "${IAM_RESPONSE}")"
  domain_id="$(jq -r '.group.domain_id // empty' "${IAM_RESPONSE}")"
  [[ "${description}" == "${GROUP_DESCRIPTION}" && \
     "${domain_id}" == "${CROSSPLANE_OTC_DOMAIN_ID}" ]] \
    || fail "Controller group ${CROSSPLANE_OTC_GROUP_NAME} exists but is not owned by this bootstrap."
  printf '%s\n' "${group_id}"
}

ensure_group() {
  local group_id body
  group_id="$(owned_group_id)"
  if [[ -n "${group_id}" ]]; then
    printf '%s\n' "${group_id}"
    return
  fi

  body="$(jq -n \
    --arg name "${CROSSPLANE_OTC_GROUP_NAME}" \
    --arg domain_id "${CROSSPLANE_OTC_DOMAIN_ID}" \
    --arg description "${GROUP_DESCRIPTION}" \
    '{group: {name: $name, domain_id: $domain_id, description: $description}}')"
  iam_request POST "${IAM_V3_ROOT}/groups" 201 "${body}"
  group_id="$(jq -r '.group.id // empty' "${IAM_RESPONSE}")"
  [[ "${group_id}" =~ ^[0-9a-f]{32}$ ]] \
    || fail "OTC did not return the new controller group ID."
  printf '%s\n' "${group_id}"
}

obs_admin_policy_id() {
  local count policy_id
  iam_request GET \
    "${IAM_V3_ROOT}/roles?display_name=OBS%20Administrator&permission_type=policy" 200
  count="$(jq --arg name "${OBS_ADMIN_POLICY_NAME}" \
    '[.roles[] | select(.display_name == $name and .type == "AX" and
      .domain_id == null)] | length' "${IAM_RESPONSE}")"
  ((count == 1)) \
    || fail "OTC did not return exactly one ${OBS_ADMIN_POLICY_NAME} system policy."
  policy_id="$(jq -r --arg name "${OBS_ADMIN_POLICY_NAME}" \
    '.roles[] | select(.display_name == $name and .type == "AX" and
      .domain_id == null) | .id' "${IAM_RESPONSE}")"
  [[ "${policy_id}" =~ ^[0-9a-f]{32}$ ]] \
    || fail "The ${OBS_ADMIN_POLICY_NAME} system policy has an invalid ID."
  printf '%s\n' "${policy_id}"
}

security_admin_role_id() {
  local count role_id
  iam_request GET "${IAM_V3_ROOT}/roles?name=${SECURITY_ADMIN_ROLE_NAME}" 200
  count="$(jq --arg name "${SECURITY_ADMIN_ROLE_NAME}" \
    '[.roles[] | select(.name == $name)] | length' "${IAM_RESPONSE}")"
  ((count == 1)) \
    || fail "OTC did not return exactly one ${SECURITY_ADMIN_ROLE_NAME} system role."
  role_id="$(jq -r --arg name "${SECURITY_ADMIN_ROLE_NAME}" \
    '.roles[] | select(.name == $name) | .id' "${IAM_RESPONSE}")"
  [[ "${role_id}" =~ ^[0-9a-f]{32}$ ]] \
    || fail "The ${SECURITY_ADMIN_ROLE_NAME} system role has an invalid ID."
  printf '%s\n' "${role_id}"
}

ensure_group_membership() {
  local group_id="$1"
  local user_id="$2"
  iam_request PUT "${IAM_V3_ROOT}/groups/${group_id}/users/${user_id}" 204
}

ensure_group_domain_role_assignment() {
  local group_id="$1"
  local role_id="$2"
  iam_request PUT \
    "${IAM_V3_ROOT}/domains/${CROSSPLANE_OTC_DOMAIN_ID}/groups/${group_id}/roles/${role_id}" \
    204
}

ensure_group_inherited_role_assignment() {
  local group_id="$1"
  local role_id="$2"
  iam_request PUT \
    "${IAM_V3_ROOT}/OS-INHERIT/domains/${CROSSPLANE_OTC_DOMAIN_ID}/groups/${group_id}/roles/${role_id}/inherited_to_projects" \
    204
}

membership_state() {
  local group_id="$1"
  local user_id="$2"
  iam_request HEAD "${IAM_V3_ROOT}/groups/${group_id}/users/${user_id}" '204 404'
  if [[ "${IAM_STATUS}" == 204 ]]; then
    printf 'member\n'
  else
    printf 'not a member\n'
  fi
}

group_domain_assignment_state() {
  local group_id="$1"
  local role_id="$2"
  iam_request HEAD \
    "${IAM_V3_ROOT}/domains/${CROSSPLANE_OTC_DOMAIN_ID}/groups/${group_id}/roles/${role_id}" \
    '204 404'
  if [[ "${IAM_STATUS}" == 204 ]]; then
    printf 'assigned\n'
  else
    printf 'not assigned\n'
  fi
}

group_inherited_assignment_state() {
  local group_id="$1"
  local role_id="$2"
  iam_request HEAD \
    "${IAM_V3_ROOT}/OS-INHERIT/domains/${CROSSPLANE_OTC_DOMAIN_ID}/groups/${group_id}/roles/${role_id}/inherited_to_projects" \
    '204 404'
  if [[ "${IAM_STATUS}" == 204 ]]; then
    printf 'assigned\n'
  else
    printf 'not assigned\n'
  fi
}

verify_obs_admin_assignment() {
  local group_id="$1"
  local policy_id="$2"
  [[ "$(group_inherited_assignment_state "${group_id}" "${policy_id}")" == assigned ]] \
    || fail "OBS Administrator is not assigned to all existing and future projects."
}

list_credentials() {
  local user_id="$1"
  iam_request GET \
    "${IAM_V30_ROOT}/OS-CREDENTIAL/credentials?user_id=${user_id}" 200
}

verify_credentials_file() {
  local access_key="$1"
  [[ -f "${CROSSPLANE_OTC_CREDENTIALS_FILE}" ]] \
    || fail "The existing controller secret key cannot be recovered; restore the credentials file before apply."
  jq -e \
    --arg access_key "${access_key}" \
    --arg auth_url "${CROSSPLANE_OTC_AUTH_URL%/}" \
    --arg domain_name "${DOMAIN_NAME}" \
    --arg domain_id "${CROSSPLANE_OTC_DOMAIN_ID}" \
    --arg project_id "${CROSSPLANE_OTC_PROJECT_ID}" \
    '.access_key == $access_key and
     (.secret_key | strings | length > 0) and
     .auth_url == $auth_url and .domain_name == $domain_name and
     .domain_id == $domain_id and .tenant_id == $project_id' \
    "${CROSSPLANE_OTC_CREDENTIALS_FILE}" >/dev/null \
    || fail "CROSSPLANE_OTC_CREDENTIALS_FILE does not match the existing controller credential."
  chmod 0600 "${CROSSPLANE_OTC_CREDENTIALS_FILE}"
}

write_credentials_file() (
  local access_key="$1"
  local secret_key="$2"
  local destination="${CROSSPLANE_OTC_CREDENTIALS_FILE}"
  local parent temp_path
  parent="$(dirname -- "${destination}")"
  umask 077
  temp_path="$(mktemp "${parent}/.provider-storage-credentials.XXXXXX")"
  trap 'rm -f -- "${temp_path}"' EXIT
  jq -n \
    --arg access_key "${access_key}" \
    --arg secret_key "${secret_key}" \
    --arg auth_url "${CROSSPLANE_OTC_AUTH_URL%/}" \
    --arg domain_name "${DOMAIN_NAME}" \
    --arg domain_id "${CROSSPLANE_OTC_DOMAIN_ID}" \
    --arg project_id "${CROSSPLANE_OTC_PROJECT_ID}" \
    '{access_key: $access_key, secret_key: $secret_key, auth_url: $auth_url,
      domain_name: $domain_name, domain_id: $domain_id, tenant_id: $project_id,
      swauth: "false", allow_reauth: "true", max_retries: "2",
      max_backoff_retries: "6", backoff_retry_timeout: "60", insecure: "false"}' \
    >"${temp_path}" || return 1
  chmod 0600 "${temp_path}" || return 1
  mv -- "${temp_path}" "${destination}" || return 1
  trap - EXIT
)

ensure_controller_credential() {
  local user_id="$1"
  local total owned access_key secret_key body

  list_credentials "${user_id}"
  total="$(jq '.credentials | length' "${IAM_RESPONSE}")"
  owned="$(jq --arg description "${CREDENTIAL_DESCRIPTION}" \
    '[.credentials[] | select(.description == $description)] | length' \
    "${IAM_RESPONSE}")"
  ((total == owned)) \
    || fail "The owned controller user has a credential not created by this bootstrap."
  ((owned <= 1)) \
    || fail "The owned controller user has more than one bootstrap credential."

  if ((owned == 1)); then
    jq -e --arg description "${CREDENTIAL_DESCRIPTION}" \
      '.credentials[] | select(.description == $description) |
       .status == "active"' "${IAM_RESPONSE}" >/dev/null \
      || fail "The existing controller credential is not active."
    access_key="$(jq -r --arg description "${CREDENTIAL_DESCRIPTION}" \
      '.credentials[] | select(.description == $description) | .access' \
      "${IAM_RESPONSE}")"
    [[ "${access_key}" =~ ^[A-Za-z0-9]{16,128}$ ]] \
      || fail "The existing controller credential has an invalid access key ID."
    verify_credentials_file "${access_key}"
    printf 'Controller credential already exists; credentials file was preserved.\n'
    return
  fi

  [[ ! -e "${CROSSPLANE_OTC_CREDENTIALS_FILE}" ]] \
    || fail "Refusing to overwrite CROSSPLANE_OTC_CREDENTIALS_FILE for a new credential."
  body="$(jq -n --arg user_id "${user_id}" \
    --arg description "${CREDENTIAL_DESCRIPTION}" \
    '{credential: {user_id: $user_id, description: $description}}')"
  iam_request POST "${IAM_V30_ROOT}/OS-CREDENTIAL/credentials" 201 "${body}"
  access_key="$(jq -r '.credential.access // empty' "${IAM_RESPONSE}")"
  secret_key="$(jq -r '.credential.secret // empty' "${IAM_RESPONSE}")"
  [[ "${access_key}" =~ ^[A-Za-z0-9]{16,128}$ && -n "${secret_key}" ]] \
    || fail "OTC did not return both parts of the new controller credential."
  if ! write_credentials_file "${access_key}" "${secret_key}"; then
    iam_request DELETE "${IAM_V30_ROOT}/OS-CREDENTIAL/credentials/${access_key}" '204 200'
    fail "Could not store the new credential; the OTC credential was deleted."
  fi
  unset secret_key body
  printf 'Created one controller credential.\n'
}

rotate_controller_credential() {
  local user_id="$1"
  local total owned old_access_key new_access_key secret_key body

  list_credentials "${user_id}"
  total="$(jq '.credentials | length' "${IAM_RESPONSE}")"
  owned="$(jq --arg description "${CREDENTIAL_DESCRIPTION}" \
    '[.credentials[] | select(.description == $description)] | length' \
    "${IAM_RESPONSE}")"
  ((total == 1 && owned == 1)) \
    || fail "Credential rotation requires exactly one owned controller credential."
  old_access_key="$(jq -r --arg description "${CREDENTIAL_DESCRIPTION}" \
    '.credentials[] | select(.description == $description) | .access' \
    "${IAM_RESPONSE}")"
  [[ "${old_access_key}" =~ ^[A-Za-z0-9]{16,128}$ ]] \
    || fail "The existing controller credential has an invalid access key ID."

  body="$(jq -n --arg user_id "${user_id}" \
    --arg description "${CREDENTIAL_DESCRIPTION}" \
    '{credential: {user_id: $user_id, description: $description}}')"
  iam_request POST "${IAM_V30_ROOT}/OS-CREDENTIAL/credentials" 201 "${body}"
  new_access_key="$(jq -r '.credential.access // empty' "${IAM_RESPONSE}")"
  secret_key="$(jq -r '.credential.secret // empty' "${IAM_RESPONSE}")"
  [[ "${new_access_key}" =~ ^[A-Za-z0-9]{16,128}$ && \
     "${new_access_key}" != "${old_access_key}" && -n "${secret_key}" ]] \
    || fail "OTC did not return a valid replacement controller credential."

  if ! write_credentials_file "${new_access_key}" "${secret_key}"; then
    iam_request DELETE \
      "${IAM_V30_ROOT}/OS-CREDENTIAL/credentials/${new_access_key}" '204 200'
    fail "Could not store the replacement credential; it was deleted and the old credential remains active."
  fi
  unset secret_key body

  iam_request DELETE \
    "${IAM_V30_ROOT}/OS-CREDENTIAL/credentials/${old_access_key}" '204 200'
  printf 'Rotated the controller credential. Update the Kubernetes provider Secret.\n'
  printf 'Credentials file: %s\n' "${CROSSPLANE_OTC_CREDENTIALS_FILE}"
}

apply_resources() {
  local user_id group_id policy_id security_role_id

  group_id="$(ensure_group)"
  policy_id="$(obs_admin_policy_id)"
  ensure_group_inherited_role_assignment "${group_id}" "${policy_id}"
  verify_obs_admin_assignment "${group_id}" "${policy_id}"
  user_id="$(ensure_user)"
  ensure_group_membership "${group_id}" "${user_id}"
  security_role_id="$(security_admin_role_id)"
  ensure_group_domain_role_assignment "${group_id}" "${security_role_id}"
  ensure_controller_credential "${user_id}"

  printf 'OTC Provider Storage controller identity is ready.\n'
  printf 'Domain: %s (%s)\n' "${DOMAIN_NAME}" "${CROSSPLANE_OTC_DOMAIN_ID}"
  printf 'Project: %s (%s)\n' "${PROJECT_NAME}" "${CROSSPLANE_OTC_PROJECT_ID}"
  printf 'Controller user: %s\n' "${CROSSPLANE_OTC_USER_NAME}"
  printf 'Controller group: %s\n' "${CROSSPLANE_OTC_GROUP_NAME}"
  printf 'OBS system policy: %s (%s), all existing and future projects\n' \
    "${OBS_ADMIN_POLICY_NAME}" "${policy_id}"
  printf 'Resource prefix: %s\n' "${CROSSPLANE_OTC_RESOURCE_PREFIX}"
  printf 'Credentials file: %s\n' "${CROSSPLANE_OTC_CREDENTIALS_FILE}"
  printf '%s\n' \
    'Security boundary: only the dedicated OTC domain contains this controller.'
}

show_status() {
  local user_id group_id policy_id security_role_id
  local total owned file_state

  user_id="$(owned_user_id)"
  group_id="$(owned_group_id)"
  policy_id="$(obs_admin_policy_id)"
  security_role_id="$(security_admin_role_id)"

  printf 'Domain: %s (%s)\n' "${DOMAIN_NAME}" "${CROSSPLANE_OTC_DOMAIN_ID}"
  printf 'Project: %s (%s)\n' "${PROJECT_NAME}" "${CROSSPLANE_OTC_PROJECT_ID}"
  printf 'Resource prefix: %s\n' "${CROSSPLANE_OTC_RESOURCE_PREFIX}"
  if [[ -n "${user_id}" ]]; then
    printf 'Controller user: present\n'
  else
    printf 'Controller user: absent\n'
  fi
  if [[ -n "${group_id}" ]]; then
    printf 'Controller group: present\n'
  else
    printf 'Controller group: absent\n'
  fi
  printf 'OBS system policy: %s (%s)\n' \
    "${OBS_ADMIN_POLICY_NAME}" "${policy_id}"

  if [[ -n "${user_id}" && -n "${group_id}" ]]; then
    printf 'Controller group membership: %s\n' \
      "$(membership_state "${group_id}" "${user_id}")"
  fi
  if [[ -n "${group_id}" ]]; then
    printf 'Security Administrator: %s\n' \
      "$(group_domain_assignment_state "${group_id}" "${security_role_id}")"
  fi
  if [[ -n "${group_id}" ]]; then
    printf 'OBS Administrator all-projects assignment: %s\n' \
      "$(group_inherited_assignment_state "${group_id}" "${policy_id}")"
  fi
  if [[ -n "${user_id}" ]]; then
    list_credentials "${user_id}"
    total="$(jq '.credentials | length' "${IAM_RESPONSE}")"
    owned="$(jq --arg description "${CREDENTIAL_DESCRIPTION}" \
      '[.credentials[] | select(.description == $description)] | length' \
      "${IAM_RESPONSE}")"
    printf 'Controller credentials: %s owned, %s total\n' "${owned}" "${total}"
  fi
  if [[ -n "${CROSSPLANE_OTC_CREDENTIALS_FILE:-}" ]]; then
    file_state=absent
    [[ ! -f "${CROSSPLANE_OTC_CREDENTIALS_FILE}" ]] || file_state=present
    printf 'Credentials file: %s (%s)\n' \
      "${CROSSPLANE_OTC_CREDENTIALS_FILE}" "${file_state}"
  fi
  return 0
}

rotate_credential() {
  local user_id group_id policy_id security_role_id

  user_id="$(owned_user_id)"
  group_id="$(owned_group_id)"
  policy_id="$(obs_admin_policy_id)"
  [[ -n "${user_id}" && -n "${group_id}" ]] \
    || fail "Apply the complete OTC bootstrap before rotating its credential."
  [[ "$(membership_state "${group_id}" "${user_id}")" == member ]] \
    || fail "The controller user is not a member of its group."
  security_role_id="$(security_admin_role_id)"
  [[ "$(group_domain_assignment_state "${group_id}" "${security_role_id}")" == assigned ]] \
    || fail "Security Administrator is not assigned to the controller group."
  verify_obs_admin_assignment "${group_id}" "${policy_id}"

  rotate_controller_credential "${user_id}"
}

main() {
  local action="${1:-}"
  case "${action}" in
    -h|--help|help)
      usage
      return
      ;;
    apply|status|rotate-credential) ;;
    *)
      usage >&2
      exit 2
      ;;
  esac

  require_command openstack
  require_command curl
  require_command jq
  validate_inputs "${action}"
  trap cleanup EXIT
  init_session
  verify_target

  case "${action}" in
    apply) apply_resources ;;
    status) show_status ;;
    rotate-credential) rotate_credential ;;
  esac
}

main "$@"
