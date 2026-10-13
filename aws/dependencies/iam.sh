#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

# Access-key secrets must never be traced or printed.
set +x
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
POLICY_DIR="${SCRIPT_DIR}/policies"

: "${CROSSPLANE_AWS_AUTH_MODE:=assume-role}"
: "${CROSSPLANE_AWS_RESOURCE_PREFIX:=aws-${CROSSPLANE_AWS_ACCOUNT_ID:-}}"
: "${CROSSPLANE_AWS_ROLE_NAME:=crossplane}"
: "${CROSSPLANE_AWS_ROLE_PATH:=/provider-storage/}"
: "${CROSSPLANE_AWS_POLICY_NAME:=provider-storage}"
: "${CROSSPLANE_AWS_USER_NAME:=crossplane}"
: "${CROSSPLANE_AWS_USER_PATH:=/provider-storage/controller/}"
: "${CROSSPLANE_AWS_USER_POLICY_NAME:=${CROSSPLANE_AWS_POLICY_NAME}-assume-role}"
: "${CROSSPLANE_AWS_MANAGED_USER_PATH:=/provider-storage/managed/}"
: "${CROSSPLANE_AWS_MANAGED_POLICY_PATH:=/provider-storage/managed/}"
: "${CROSSPLANE_AWS_NAMESPACE:=workspace}"

ROLE_PURPOSE="runtime-controller"
USER_PURPOSE="static-controller-source"
LEGACY_USER_PURPOSE="bootstrap-source"
LEGACY_USER_PATH="/provider-storage/bootstrap/"

usage() {
  cat <<'EOF'
Usage: aws/dependencies/iam.sh <status|apply|verify|render-secrets>

Bootstrap the AWS IAM resources that Provider Storage needs before deployment.
Run apply before you deploy the AWS provider components or ProviderConfig.
Review this script and the JSON files in aws/dependencies/policies before you run it.

Commands:
  status          Show the current setup. Does not change resources.
  apply           Create or update resources and the credential file.
  verify          Check that resources and credentials are ready.
  render-secrets  Read only the credential file and print Secret manifests.

Required environment for status, apply, and verify:
  CROSSPLANE_AWS_ACCOUNT_ID
      Exact 12-digit target AWS account ID.

Authentication modes:
  assume-role
      Trust an existing same-account IAM role or user.
      CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN is required by apply. This is the
      default mode.
  static-user
      Create a dedicated IAM user with only sts:AssumeRole permission and one
      access key. Apply writes it to the configured credential file.

Optional environment:
  CROSSPLANE_AWS_AUTH_MODE
      assume-role or static-user (default: assume-role).
  CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN
      Existing principal for assume-role mode.
  CROSSPLANE_AWS_CREDENTIALS_FILE
      Absolute output path for the static-user AWS credentials file
      (default: ~/.config/provider-storage/aws-creds.json). Never place it in Git.
      This is the only cloud credential input used by render-secrets.
  CROSSPLANE_AWS_NAMESPACE
      Namespace for the generated Secret manifest (default: workspace).
  CROSSPLANE_AWS_RESOURCE_PREFIX
      Prefix allowed for Provider Storage buckets (default:
      aws-<account-id>). Set an explicit installation-specific value during
      IAM bootstrap if the account has multiple installs.
  CROSSPLANE_AWS_ROLE_NAME
      Runtime role name (default: crossplane).
  CROSSPLANE_AWS_ROLE_PATH
      Runtime role path (default: /provider-storage/).
  CROSSPLANE_AWS_POLICY_NAME
      Runtime inline policy name (default: provider-storage).
  CROSSPLANE_AWS_USER_NAME
      Controller user name (default: crossplane).
  CROSSPLANE_AWS_USER_PATH
      Controller user path (default: /provider-storage/controller/).
  CROSSPLANE_AWS_USER_POLICY_NAME
      Controller user inline policy name (default: <policy>-assume-role).
  CROSSPLANE_AWS_MANAGED_USER_PATH
      Path for Composition-created users (default: /provider-storage/managed/).
  CROSSPLANE_AWS_MANAGED_POLICY_PATH
      Path for Composition-created policies (default:
      /provider-storage/managed/).
  AWS_PROFILE, AWS_REGION
      Standard AWS CLI selection variables.

In static-user mode, apply writes the new access key to
CROSSPLANE_AWS_CREDENTIALS_FILE with mode 0600. The separate render-secrets
action prints a Kubernetes Secret manifest. The script does not access
Kubernetes. Use a dedicated account where possible and apply organization
guardrails. An assume-role mode principal still needs permission to call
sts:AssumeRole for the resulting runtime role.

If the credential file is missing for an existing access key, apply asks for
the secret access key and restores the file. AWS cannot return that secret.
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

if [[ -z ${CROSSPLANE_AWS_CREDENTIALS_FILE:-} ]]; then
  [[ ${HOME:-} == /* ]] || fail "HOME must be an absolute path for the default AWS credential file."
  CROSSPLANE_AWS_CREDENTIALS_FILE="${HOME}/.config/provider-storage/aws-creds.json"
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

aws_cli() {
  command aws "$@" --no-cli-pager
}

validate_credentials_path() {
  local path="${CROSSPLANE_AWS_CREDENTIALS_FILE:-}"
  [[ -n "${path}" ]] || return
  [[ "${path}" == /* ]] \
    || fail "CROSSPLANE_AWS_CREDENTIALS_FILE must be an absolute path."
  [[ ! -L "${path}" ]] \
    || fail "CROSSPLANE_AWS_CREDENTIALS_FILE must not be a symbolic link."
  if [[ -e "${path}" && ! -f "${path}" ]]; then
    fail "CROSSPLANE_AWS_CREDENTIALS_FILE must be a regular file when it exists."
  fi
  [[ ! -e "$(dirname -- "${path}")" || -d "$(dirname -- "${path}")" ]] \
    || fail "The CROSSPLANE_AWS_CREDENTIALS_FILE parent path is not a directory."
  if [[ -e "${path}" ]]; then
    [[ "$(stat -c '%a:%u' -- "${path}")" == "600:$(id -u)" ]] \
      || fail "The existing AWS credential file must be owned by you and mode 0600."
  fi
}

prepare_credentials_directory() {
  local parent
  parent="$(dirname -- "${CROSSPLANE_AWS_CREDENTIALS_FILE}")"
  if [[ ! -e "${parent}" ]]; then
    mkdir -p -m 0700 -- "${parent}" \
      || fail "Could not create the AWS credential directory."
  fi
  [[ -d "${parent}" ]] || fail "The AWS credential parent path is not a directory."
}

validate_render_inputs() {
  [[ -n "${CROSSPLANE_AWS_CREDENTIALS_FILE:-}" ]] \
    || fail "CROSSPLANE_AWS_CREDENTIALS_FILE is required for render-secrets."
  [[ "${CROSSPLANE_AWS_NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || fail "CROSSPLANE_AWS_NAMESPACE must be a valid Kubernetes namespace."
  validate_credentials_path
  [[ -f "${CROSSPLANE_AWS_CREDENTIALS_FILE}" ]] \
    || fail "CROSSPLANE_AWS_CREDENTIALS_FILE must contain an existing credential file."
  jq -e '
    (keys | sort) == ["access_key_id","secret_access_key"] and
    (.access_key_id | type == "string" and length > 0) and
    (.secret_access_key | type == "string" and length > 0)
  ' "${CROSSPLANE_AWS_CREDENTIALS_FILE}" >/dev/null \
    || fail "CROSSPLANE_AWS_CREDENTIALS_FILE has an invalid AWS credential format."
}

validate_iam_path() {
  local variable_name="$1"
  local path="$2"
  [[ ${#path} -le 512 && "${path}" =~ ^/([A-Za-z0-9+=,.@_-]+/)*$ ]] \
    || fail "${variable_name} must be a valid IAM path that starts and ends with a slash."
}

validate_inputs() {
  local action="$1"
  [[ "${CROSSPLANE_AWS_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]] \
    || fail "CROSSPLANE_AWS_ACCOUNT_ID must be the exact 12-digit target account ID."
  [[ "${CROSSPLANE_AWS_AUTH_MODE}" == "assume-role" || "${CROSSPLANE_AWS_AUTH_MODE}" == "static-user" ]] \
    || fail "CROSSPLANE_AWS_AUTH_MODE must be assume-role or static-user."
  [[ "${CROSSPLANE_AWS_RESOURCE_PREFIX}" =~ ^[a-z0-9][a-z0-9-]{2,39}$ ]] \
    || fail "CROSSPLANE_AWS_RESOURCE_PREFIX must be 3-40 lowercase letters, digits, or hyphens."
  [[ "${CROSSPLANE_AWS_ROLE_NAME}" =~ ^[A-Za-z0-9+=,.@_-]{1,64}$ ]] \
    || fail "CROSSPLANE_AWS_ROLE_NAME is not a valid IAM role name."
  [[ "${CROSSPLANE_AWS_POLICY_NAME}" =~ ^[A-Za-z0-9+=,.@_-]{1,128}$ ]] \
    || fail "CROSSPLANE_AWS_POLICY_NAME is not a valid IAM policy name."
  [[ "${CROSSPLANE_AWS_USER_NAME}" =~ ^[A-Za-z0-9+=,.@_-]{1,64}$ ]] \
    || fail "CROSSPLANE_AWS_USER_NAME is not a valid IAM user name."
  [[ "${CROSSPLANE_AWS_USER_POLICY_NAME}" =~ ^[A-Za-z0-9+=,.@_-]{1,128}$ ]] \
    || fail "CROSSPLANE_AWS_USER_POLICY_NAME is not a valid IAM policy name."
  validate_iam_path CROSSPLANE_AWS_ROLE_PATH "${CROSSPLANE_AWS_ROLE_PATH}"
  validate_iam_path CROSSPLANE_AWS_USER_PATH "${CROSSPLANE_AWS_USER_PATH}"
  validate_iam_path CROSSPLANE_AWS_MANAGED_USER_PATH "${CROSSPLANE_AWS_MANAGED_USER_PATH}"
  validate_iam_path CROSSPLANE_AWS_MANAGED_POLICY_PATH "${CROSSPLANE_AWS_MANAGED_POLICY_PATH}"
  [[ "${CROSSPLANE_AWS_MANAGED_USER_PATH}" != "/" ]] \
    || fail "CROSSPLANE_AWS_MANAGED_USER_PATH must not be the account root path."
  [[ "${CROSSPLANE_AWS_MANAGED_POLICY_PATH}" != "/" ]] \
    || fail "CROSSPLANE_AWS_MANAGED_POLICY_PATH must not be the account root path."
  [[ "${CROSSPLANE_AWS_NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || fail "CROSSPLANE_AWS_NAMESPACE must be a valid Kubernetes namespace."
  [[ "${CROSSPLANE_AWS_USER_PATH}${CROSSPLANE_AWS_USER_NAME}" != "${CROSSPLANE_AWS_MANAGED_USER_PATH}"* ]] \
    || fail "The controller user must be outside CROSSPLANE_AWS_MANAGED_USER_PATH."

  if [[ "${CROSSPLANE_AWS_AUTH_MODE}" == "static-user" ]]; then
    validate_credentials_path
  fi
}

render_credentials_manifest() {
  local encoded
  encoded="$(jq -r '
    "[default]\naws_access_key_id = \(.access_key_id)\naws_secret_access_key = \(.secret_access_key)" |
    @base64
  ' "${CROSSPLANE_AWS_CREDENTIALS_FILE}")"
  printf '\n%s\n' '# Kubernetes manifest follows. It contains controller credentials.'
  printf '%s\n' '---' 'apiVersion: v1' 'kind: Secret' 'metadata:' \
    '  name: aws-provider-creds'
  printf '  namespace: %s\n' "${CROSSPLANE_AWS_NAMESPACE}"
  printf '%s\n' 'type: Opaque' 'data:'
  printf '  credentials: %s\n' "${encoded}"
}

verify_account() {
  local actual_account
  actual_account="$(aws_cli sts get-caller-identity --query Account --output text)"
  if [[ "${actual_account}" != "${CROSSPLANE_AWS_ACCOUNT_ID}" ]]; then
    fail "Refusing to operate on AWS account ${actual_account}; expected CROSSPLANE_AWS_ACCOUNT_ID=${CROSSPLANE_AWS_ACCOUNT_ID}."
  fi
}

current_partition() {
  local caller_arn partition
  caller_arn="$(aws_cli sts get-caller-identity --query Arn --output text)"
  partition="${caller_arn#arn:}"
  partition="${partition%%:*}"
  [[ "${partition}" =~ ^aws(-[a-z0-9-]+)?$ ]] \
    || fail "Could not derive an AWS partition from caller ARN ${caller_arn}."
  printf '%s\n' "${partition}"
}

validate_trusted_principal() {
  local partition="$1"
  local trusted_account trusted_partition
  [[ -n "${CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN:-}" ]] \
    || fail "CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN is required for apply."
  [[ "${CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN}" =~ ^arn:aws(-[a-z0-9-]+)?:iam::[0-9]{12}:(user|role)/[A-Za-z0-9+=,.@_/-]+$ ]] \
    || fail "CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN must be an IAM role or user ARN."
  trusted_account="${CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN#*::}"
  trusted_account="${trusted_account%%:*}"
  [[ "${trusted_account}" == "${CROSSPLANE_AWS_ACCOUNT_ID}" ]] \
    || fail "CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN must belong to CROSSPLANE_AWS_ACCOUNT_ID."
  trusted_partition="${CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN#arn:}"
  trusted_partition="${trusted_partition%%:*}"
  [[ "${trusted_partition}" == "${partition}" ]] \
    || fail "CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN must use the target AWS partition."
}

validate_policy_templates() {
  local template_name
  for template_name in \
    runtime-role-trust-policy.json \
    runtime-role-policy.json \
    static-user-policy.json; do
    [[ -r "${POLICY_DIR}/${template_name}" ]] \
      || fail "Required policy template is not readable: ${POLICY_DIR}/${template_name}"
  done
}

render_policy_template() {
  local template_name="$1"
  local destination="$2"
  local content placeholder replacement
  shift 2

  content="$(<"${POLICY_DIR}/${template_name}")" \
    || fail "Could not read policy template: ${POLICY_DIR}/${template_name}"
  while (($#)); do
    (($# >= 2)) \
      || fail "A replacement value is missing for policy template ${template_name}."
    placeholder="$1"
    replacement="$2"
    shift 2
    [[ "${content}" == *"${placeholder}"* ]] \
      || fail "Policy template ${template_name} does not contain ${placeholder}."
    content="${content//${placeholder}/${replacement}}"
  done
  if [[ "${content}" =~ __[A-Z][A-Z0-9_]*__ ]]; then
    fail "Policy template ${template_name} contains an unresolved placeholder."
  fi
  printf '%s\n' "${content}" >"${destination}"
}

controller_user_arn() {
  local partition="$1"
  printf 'arn:%s:iam::%s:user%s%s\n' \
    "${partition}" "${CROSSPLANE_AWS_ACCOUNT_ID}" "${CROSSPLANE_AWS_USER_PATH}" \
    "${CROSSPLANE_AWS_USER_NAME}"
}

runtime_role_arn() {
  local partition="$1"
  printf 'arn:%s:iam::%s:role%s%s\n' \
    "${partition}" "${CROSSPLANE_AWS_ACCOUNT_ID}" "${CROSSPLANE_AWS_ROLE_PATH}" \
    "${CROSSPLANE_AWS_ROLE_NAME}"
}

role_exists() {
  aws_cli iam get-role --role-name "${CROSSPLANE_AWS_ROLE_NAME}" >/dev/null 2>&1
}

user_exists() {
  aws_cli iam get-user --user-name "${CROSSPLANE_AWS_USER_NAME}" >/dev/null 2>&1
}

role_tag_value() {
  local key="$1"
  aws_cli iam list-role-tags \
    --role-name "${CROSSPLANE_AWS_ROLE_NAME}" \
    --query "Tags[?Key=='${key}'].Value | [0]" \
    --output text
}

user_tag_value() {
  local key="$1"
  aws_cli iam list-user-tags \
    --user-name "${CROSSPLANE_AWS_USER_NAME}" \
    --query "Tags[?Key=='${key}'].Value | [0]" \
    --output text
}

verify_role_ownership() {
  local partition="$1"
  local actual_role_arn expected_role_arn purpose
  actual_role_arn="$(
    aws_cli iam get-role \
      --role-name "${CROSSPLANE_AWS_ROLE_NAME}" \
      --query Role.Arn \
      --output text
  )"
  expected_role_arn="$(runtime_role_arn "${partition}")"
  [[ "${actual_role_arn}" == "${expected_role_arn}" ]] \
    || fail "Runtime role ${CROSSPLANE_AWS_ROLE_NAME} exists at unexpected ARN ${actual_role_arn}."
  purpose="$(role_tag_value purpose)"
  if [[ "$(role_tag_value project)" != "provider-storage" || \
        ( "${purpose}" != "${ROLE_PURPOSE}" && "${purpose}" != "cloud-e2e" ) || \
        "$(role_tag_value resource-prefix)" != "${CROSSPLANE_AWS_RESOURCE_PREFIX}" ]]; then
    fail "Runtime role ${CROSSPLANE_AWS_ROLE_NAME} does not have the expected ownership tags."
  fi
}

verify_user_ownership() {
  local purpose
  purpose="$(user_tag_value purpose)"
  if [[ "$(user_tag_value project)" != "provider-storage" || \
        ( "${purpose}" != "${USER_PURPOSE}" && "${purpose}" != "cloud-e2e-source" ) || \
        "$(user_tag_value resource-prefix)" != "${CROSSPLANE_AWS_RESOURCE_PREFIX}" ]]; then
    fail "Controller user ${CROSSPLANE_AWS_USER_NAME} does not have the expected ownership tags."
  fi
}

verify_legacy_user_ownership() {
  if [[ "$(user_tag_value project)" != "provider-storage" || \
        "$(user_tag_value purpose)" != "${LEGACY_USER_PURPOSE}" || \
        "$(user_tag_value resource-prefix)" != "${CROSSPLANE_AWS_RESOURCE_PREFIX}" ]]; then
    fail "Controller user ${CROSSPLANE_AWS_USER_NAME} at the legacy path does not have the expected ownership tags."
  fi
}

legacy_controller_user_arn() {
  local partition="$1"
  printf 'arn:%s:iam::%s:user%s%s\n' \
    "${partition}" "${CROSSPLANE_AWS_ACCOUNT_ID}" "${LEGACY_USER_PATH}" \
    "${CROSSPLANE_AWS_USER_NAME}"
}

verify_controller_user_identity() {
  local partition="$1"
  local actual_user_arn expected_user_arn
  expected_user_arn="$(controller_user_arn "${partition}")"
  actual_user_arn="$(
    aws_cli iam get-user \
      --user-name "${CROSSPLANE_AWS_USER_NAME}" \
      --query User.Arn \
      --output text
  )"
  [[ "${actual_user_arn}" == "${expected_user_arn}" ]] \
    || fail "Controller user ${CROSSPLANE_AWS_USER_NAME} exists at unexpected ARN ${actual_user_arn}."
  verify_user_ownership
}

ensure_controller_user() {
  local partition="$1" actual_user_arn expected_user_arn legacy_user_arn
  if user_exists; then
    actual_user_arn="$(aws_cli iam get-user --user-name "${CROSSPLANE_AWS_USER_NAME}" \
      --query User.Arn --output text)"
    expected_user_arn="$(controller_user_arn "${partition}")"
    legacy_user_arn="$(legacy_controller_user_arn "${partition}")"
    if [[ "${actual_user_arn}" == "${legacy_user_arn}" && \
          "${actual_user_arn}" != "${expected_user_arn}" ]]; then
      verify_legacy_user_ownership
      aws_cli iam update-user \
        --user-name "${CROSSPLANE_AWS_USER_NAME}" \
        --new-path "${CROSSPLANE_AWS_USER_PATH}" \
        >/dev/null
      printf 'Moved the legacy controller user from %s to %s.\n' \
        "${LEGACY_USER_PATH}" "${CROSSPLANE_AWS_USER_PATH}"
    else
      verify_controller_user_identity "${partition}"
    fi
    aws_cli iam tag-user \
      --user-name "${CROSSPLANE_AWS_USER_NAME}" \
      --tags \
        Key=project,Value=provider-storage \
        Key=purpose,Value="${USER_PURPOSE}" \
        Key=resource-prefix,Value="${CROSSPLANE_AWS_RESOURCE_PREFIX}"
  else
    aws_cli iam create-user \
      --user-name "${CROSSPLANE_AWS_USER_NAME}" \
      --path "${CROSSPLANE_AWS_USER_PATH}" \
      --tags \
        Key=project,Value=provider-storage \
        Key=purpose,Value="${USER_PURPOSE}" \
        Key=resource-prefix,Value="${CROSSPLANE_AWS_RESOURCE_PREFIX}" \
      >/dev/null
  fi
}

write_credentials_file() (
  local access_key_id="$1"
  local secret_access_key="$2"
  local destination="${CROSSPLANE_AWS_CREDENTIALS_FILE}"
  local parent temp_path
  parent="$(dirname -- "${destination}")"
  umask 077
  temp_path="$(mktemp "${parent}/.provider-storage-credentials.XXXXXX")"
  trap 'rm -f -- "${temp_path}"' EXIT
  jq -n --arg access_key_id "${access_key_id}" \
    --arg secret_access_key "${secret_access_key}" \
    '{access_key_id:$access_key_id,secret_access_key:$secret_access_key}' \
    >"${temp_path}"
  chmod 0600 "${temp_path}"
  mv -f -- "${temp_path}" "${destination}"
  trap - EXIT
)

list_controller_access_keys() {
  aws_cli iam list-access-keys \
    --user-name "${CROSSPLANE_AWS_USER_NAME}" \
    --query 'AccessKeyMetadata[].AccessKeyId' \
    --output text
}

ensure_controller_access_key() {
  local access_key_id secret_access_key key_output created_key
  local -a access_key_ids=()
  key_output="$(list_controller_access_keys)"
  read -r -a access_key_ids <<<"${key_output}" || true

  if ((${#access_key_ids[@]} > 1)); then
    fail "Controller user has more than one access key; clean it up before apply."
  fi

  if ((${#access_key_ids[@]} == 1)); then
    access_key_id="${access_key_ids[0]}"
    if [[ ! -f "${CROSSPLANE_AWS_CREDENTIALS_FILE}" ]]; then
      printf 'Please provide the secret access key for AWS access key %s: ' \
        "${access_key_id}" >&2
      if ! IFS= read -r -s secret_access_key; then
        printf '\n' >&2
        fail "Could not read the AWS secret access key from the terminal."
      fi
      printf '\n' >&2
      [[ -n "${secret_access_key}" && "${secret_access_key}" != *$'\n'* && \
         "${secret_access_key}" != *$'\r'* ]] \
        || fail "The AWS secret access key is empty or invalid."
      write_credentials_file "${access_key_id}" "${secret_access_key}" \
        || fail "Could not restore CROSSPLANE_AWS_CREDENTIALS_FILE."
      unset secret_access_key
      printf 'Restored the static-user credential file.\n'
    fi
    jq -e --arg access_key_id "${access_key_id}" \
      '.access_key_id == $access_key_id and
       (.secret_access_key | type == "string" and length > 0)' \
      "${CROSSPLANE_AWS_CREDENTIALS_FILE}" >/dev/null \
      || fail "CROSSPLANE_AWS_CREDENTIALS_FILE does not match the existing access key."
    chmod 0600 "${CROSSPLANE_AWS_CREDENTIALS_FILE}"
    printf 'Bootstrap access key already exists; credentials file was preserved.\n'
    return
  fi

  [[ ! -e "${CROSSPLANE_AWS_CREDENTIALS_FILE}" ]] \
    || fail "Refusing to overwrite CROSSPLANE_AWS_CREDENTIALS_FILE for a new access key."
  created_key="$(
    aws_cli iam create-access-key \
      --user-name "${CROSSPLANE_AWS_USER_NAME}" \
      --query 'AccessKey.[AccessKeyId,SecretAccessKey]' \
      --output text
  )"
  IFS=$'\t' read -r access_key_id secret_access_key <<<"${created_key}"
  [[ -n "${access_key_id}" && -n "${secret_access_key}" ]] \
    || fail "AWS did not return both parts of the new access key."
  if ! write_credentials_file "${access_key_id}" "${secret_access_key}"; then
    aws_cli iam delete-access-key \
      --user-name "${CROSSPLANE_AWS_USER_NAME}" \
      --access-key-id "${access_key_id}"
    fail "Could not store the new access key; AWS access key was deleted."
  fi
  unset secret_access_key created_key
  printf 'Created one controller user access key.\n'
}

run_trust_policy_change() {
  local error_path="$1"
  shift
  local attempt=1
  local delay_seconds=1
  local max_attempts=7

  while true; do
    if "$@" >/dev/null 2>"${error_path}"; then
      return
    fi
    if ! grep -Fq -- "MalformedPolicyDocument" "${error_path}" || \
      ! grep -Fq -- "Invalid principal in policy" "${error_path}" || \
      ((attempt >= max_attempts)); then
      cat "${error_path}" >&2
      return 1
    fi
    printf 'AWS has not propagated the trusted IAM principal; retrying (%s/%s).\n' \
      "$((attempt + 1))" "${max_attempts}" >&2
    sleep "${delay_seconds}"
    attempt=$((attempt + 1))
    if ((delay_seconds < 8)); then
      delay_seconds=$((delay_seconds * 2))
    fi
  done
}

apply_role() (
  local partition temp_dir trust_path permissions_path user_permissions_path
  local trust_error_path
  local role_arn trusted_principal_arn controller_user_arn_value
  partition="$(current_partition)"
  if role_exists; then
    verify_role_ownership "${partition}"
  fi
  if [[ "${CROSSPLANE_AWS_AUTH_MODE}" == "assume-role" ]]; then
    validate_trusted_principal "${partition}"
    trusted_principal_arn="${CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN}"
  else
    controller_user_arn_value="$(controller_user_arn "${partition}")"
    trusted_principal_arn="${controller_user_arn_value}"
  fi
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "${temp_dir}"' EXIT
  trust_path="${temp_dir}/trust.json"
  trust_error_path="${temp_dir}/trust-error.log"
  permissions_path="${temp_dir}/permissions.json"
  user_permissions_path="${temp_dir}/user-permissions.json"
  render_policy_template runtime-role-trust-policy.json "${trust_path}" \
    __TRUSTED_PRINCIPAL_ARN__ "${trusted_principal_arn}"
  render_policy_template runtime-role-policy.json "${permissions_path}" \
    __CONTROLLER_USER_ARN__ "$(controller_user_arn "${partition}")" \
    __MANAGED_USER_ARN_PATTERN__ \
      "arn:${partition}:iam::${CROSSPLANE_AWS_ACCOUNT_ID}:user${CROSSPLANE_AWS_MANAGED_USER_PATH}*" \
    __ACCOUNT_USER_ARN_PATTERN__ \
      "arn:${partition}:iam::${CROSSPLANE_AWS_ACCOUNT_ID}:user/*" \
    __MANAGED_POLICY_ARN_PATTERN__ \
      "arn:${partition}:iam::${CROSSPLANE_AWS_ACCOUNT_ID}:policy${CROSSPLANE_AWS_MANAGED_POLICY_PATH}*" \
    __BUCKET_ARN_PATTERN__ \
      "arn:${partition}:s3:::${CROSSPLANE_AWS_RESOURCE_PREFIX}-*" \
    __OBJECT_ARN_PATTERN__ \
      "arn:${partition}:s3:::${CROSSPLANE_AWS_RESOURCE_PREFIX}-*/*"
  render_policy_template static-user-policy.json "${user_permissions_path}" \
    __RUNTIME_ROLE_ARN__ "$(runtime_role_arn "${partition}")"

  if [[ "${CROSSPLANE_AWS_AUTH_MODE}" == "static-user" ]]; then
    ensure_controller_user "${partition}"
  fi

  if role_exists; then
    run_trust_policy_change "${trust_error_path}" \
      aws_cli iam update-assume-role-policy \
      --role-name "${CROSSPLANE_AWS_ROLE_NAME}" \
      --policy-document "file://${trust_path}"
    aws_cli iam tag-role \
      --role-name "${CROSSPLANE_AWS_ROLE_NAME}" \
      --tags \
        Key=project,Value=provider-storage \
        Key=purpose,Value="${ROLE_PURPOSE}" \
        Key=resource-prefix,Value="${CROSSPLANE_AWS_RESOURCE_PREFIX}"
  else
    run_trust_policy_change "${trust_error_path}" \
      aws_cli iam create-role \
      --role-name "${CROSSPLANE_AWS_ROLE_NAME}" \
      --path "${CROSSPLANE_AWS_ROLE_PATH}" \
      --description "Provider Storage Crossplane runtime role" \
      --max-session-duration 3600 \
      --assume-role-policy-document "file://${trust_path}" \
      --tags \
        Key=project,Value=provider-storage \
        Key=purpose,Value="${ROLE_PURPOSE}" \
        Key=resource-prefix,Value="${CROSSPLANE_AWS_RESOURCE_PREFIX}"
  fi

  aws_cli iam put-role-policy \
    --role-name "${CROSSPLANE_AWS_ROLE_NAME}" \
    --policy-name "${CROSSPLANE_AWS_POLICY_NAME}" \
    --policy-document "file://${permissions_path}"

  if [[ "${CROSSPLANE_AWS_AUTH_MODE}" == "static-user" ]]; then
    aws_cli iam put-user-policy \
      --user-name "${CROSSPLANE_AWS_USER_NAME}" \
      --policy-name "${CROSSPLANE_AWS_USER_POLICY_NAME}" \
      --policy-document "file://${user_permissions_path}"
    ensure_controller_access_key
  fi

  role_arn="$(aws_cli iam get-role --role-name "${CROSSPLANE_AWS_ROLE_NAME}" --query Role.Arn --output text)"
  printf 'AWS Provider Storage runtime role is ready.\nRole ARN: %s\nRole path: %s\nResource prefix: %s\nAuthentication mode: %s\n' \
    "${role_arn}" "${CROSSPLANE_AWS_ROLE_PATH}" "${CROSSPLANE_AWS_RESOURCE_PREFIX}" \
    "${CROSSPLANE_AWS_AUTH_MODE}"
  printf 'Managed user path: %s\nManaged policy path: %s\n' \
    "${CROSSPLANE_AWS_MANAGED_USER_PATH}" "${CROSSPLANE_AWS_MANAGED_POLICY_PATH}"
  if [[ "${CROSSPLANE_AWS_AUTH_MODE}" == "static-user" ]]; then
    printf 'Controller user ARN: %s\nCredentials file: %s\n' \
      "${controller_user_arn_value}" "${CROSSPLANE_AWS_CREDENTIALS_FILE}"
  else
    printf 'Trusted principal ARN: %s\n' "${trusted_principal_arn}"
  fi
)

show_role_status() {
  local partition="$1"
  local role_arn
  if ! role_exists; then
    printf 'AWS Provider Storage role %s does not exist in account %s.\n' \
      "${CROSSPLANE_AWS_ROLE_NAME}" "${CROSSPLANE_AWS_ACCOUNT_ID}"
    return
  fi
  verify_role_ownership "${partition}"
  role_arn="$(aws_cli iam get-role --role-name "${CROSSPLANE_AWS_ROLE_NAME}" --query Role.Arn --output text)"
  aws_cli iam get-role-policy \
    --role-name "${CROSSPLANE_AWS_ROLE_NAME}" \
    --policy-name "${CROSSPLANE_AWS_POLICY_NAME}" \
    >/dev/null
  printf 'AWS Provider Storage runtime role exists.\nRole ARN: %s\nRole path: %s\nResource prefix: %s\nAuthentication mode: %s\nManaged user path: %s\nManaged policy path: %s\n' \
    "${role_arn}" "${CROSSPLANE_AWS_ROLE_PATH}" "${CROSSPLANE_AWS_RESOURCE_PREFIX}" \
    "${CROSSPLANE_AWS_AUTH_MODE}" "${CROSSPLANE_AWS_MANAGED_USER_PATH}" \
    "${CROSSPLANE_AWS_MANAGED_POLICY_PATH}"
}

show_controller_user_status() {
  local partition="$1" actual_user_arn legacy_user_arn
  local key_output
  local -a access_key_ids=()
  if ! user_exists; then
    printf 'Controller user %s is absent.\n' "${CROSSPLANE_AWS_USER_NAME}"
    return
  fi
  actual_user_arn="$(aws_cli iam get-user --user-name "${CROSSPLANE_AWS_USER_NAME}" \
    --query User.Arn --output text)"
  legacy_user_arn="$(legacy_controller_user_arn "${partition}")"
  if [[ "${actual_user_arn}" == "${legacy_user_arn}" ]]; then
    verify_legacy_user_ownership
    printf 'Controller user uses legacy path %s; run apply to move it to %s.\n' \
      "${LEGACY_USER_PATH}" "${CROSSPLANE_AWS_USER_PATH}"
  else
    verify_controller_user_identity "${partition}"
  fi
  aws_cli iam get-user-policy \
    --user-name "${CROSSPLANE_AWS_USER_NAME}" \
    --policy-name "${CROSSPLANE_AWS_USER_POLICY_NAME}" \
    >/dev/null
  key_output="$(list_controller_access_keys)"
  read -r -a access_key_ids <<<"${key_output}" || true
  printf 'Controller user exists.\nUser name: %s\nUser path: %s\nAccess keys: %s\n' \
    "${CROSSPLANE_AWS_USER_NAME}" "${CROSSPLANE_AWS_USER_PATH}" "${#access_key_ids[@]}"
  if [[ -n "${CROSSPLANE_AWS_CREDENTIALS_FILE:-}" ]]; then
    printf 'Credentials file: %s\n' "${CROSSPLANE_AWS_CREDENTIALS_FILE}"
  fi
}

verify_resources() {
  local partition="$1" key_output access_key_id
  local -a access_key_ids=()

  role_exists || fail "AWS Provider Storage role ${CROSSPLANE_AWS_ROLE_NAME} is absent."
  verify_role_ownership "${partition}"
  aws_cli iam get-role-policy \
    --role-name "${CROSSPLANE_AWS_ROLE_NAME}" \
    --policy-name "${CROSSPLANE_AWS_POLICY_NAME}" \
    >/dev/null

  if [[ "${CROSSPLANE_AWS_AUTH_MODE}" == static-user ]]; then
    user_exists || fail "Controller user ${CROSSPLANE_AWS_USER_NAME} is absent."
    verify_controller_user_identity "${partition}"
    aws_cli iam get-user-policy \
      --user-name "${CROSSPLANE_AWS_USER_NAME}" \
      --policy-name "${CROSSPLANE_AWS_USER_POLICY_NAME}" \
      >/dev/null
    key_output="$(list_controller_access_keys)"
    read -r -a access_key_ids <<<"${key_output}" || true
    ((${#access_key_ids[@]} == 1)) \
      || fail "Controller user must have exactly one access key."
    access_key_id="${access_key_ids[0]}"
    [[ -f "${CROSSPLANE_AWS_CREDENTIALS_FILE}" ]] \
      || fail "The static-user credential file is missing."
    jq -e --arg access_key_id "${access_key_id}" \
      '.access_key_id == $access_key_id and
       (.secret_access_key | type == "string" and length > 0)' \
      "${CROSSPLANE_AWS_CREDENTIALS_FILE}" >/dev/null \
      || fail "CROSSPLANE_AWS_CREDENTIALS_FILE does not match the existing access key."
  fi

  printf 'AWS Provider Storage bootstrap verified.\n'
}

main() {
  local action="${1:-}" partition
  case "${action}" in
    -h|--help|help|usage)
      usage
      return
      ;;
    status|apply|verify|render-secrets) ;;
    *)
      usage >&2
      exit 2
      ;;
  esac

  if [[ "${action}" == render-secrets ]]; then
    require_command jq
    require_command stat
    validate_render_inputs
    render_credentials_manifest
    return
  fi

  if [[ "${CROSSPLANE_AWS_AUTH_MODE}" == static-user ]]; then
    require_command jq
    require_command stat
    if [[ "${action}" == apply ]]; then
      prepare_credentials_directory
    fi
  fi
  validate_inputs "${action}"
  require_command aws

  case "${action}" in
    apply)
      printf 'Creating or updating AWS IAM resources\n'
      validate_policy_templates
      verify_account
      partition="$(current_partition)"
      apply_role
      ;;
    status)
      printf 'Checking AWS IAM resources\n'
      verify_account
      partition="$(current_partition)"
      show_role_status "${partition}"
      if [[ "${CROSSPLANE_AWS_AUTH_MODE}" == "static-user" ]]; then
        show_controller_user_status "${partition}"
      fi
      ;;
    verify)
      printf 'Verifying AWS IAM resources and credentials\n'
      verify_account
      partition="$(current_partition)"
      verify_resources "${partition}"
      ;;
  esac
}

main "$@"
