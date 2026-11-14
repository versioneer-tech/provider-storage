#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

# Disable tracing before any credential input.
set +x
set -euo pipefail
umask 077

bootstrap_fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

bootstrap_usage() {
  printf 'Usage: bootstrap-iam.sh %s <operation>\n' "${1:-<aws|otc|ovh|cloudferro>}"
  cat <<'EOF'

Operations:
  configure
  show
  apply [--rotate-credentials]
  verify
  render-secrets
EOF
}

# Check the resolved destination, including when a parent is a symlink.
reject_repository_credentials() {
  local directory
  directory=$(realpath -m -- "$(dirname -- "$1")")
  while [[ $directory != / ]]; do
    [[ ! -f $directory/.git && ! -f $directory/.git/HEAD ]] || bootstrap_fail 'Keep controller credentials outside Git repositories.'
    directory=${directory%/*}
    [[ -n $directory ]] || directory=/
  done
}

config_key() {
  local key=$1
  key=${key#CROSSPLANE_${BOOTSTRAP_BACKEND^^}_}
  key=${key#AWS_}
  printf '%s' "${key,,}"
}

validate_local_file() {
  reject_repository_credentials "$BOOTSTRAP_CREDENTIALS_FILE"
  [[ $(basename -- "$BOOTSTRAP_CREDENTIALS_FILE") != .ovh.conf ]] || bootstrap_fail 'The credential file must not replace the OVHcloud CLI login.'
  [[ ! -L $BOOTSTRAP_CREDENTIALS_FILE ]] || bootstrap_fail 'The credential file must not be a symbolic link.'
  [[ -e $BOOTSTRAP_CREDENTIALS_FILE ]] || return 0
  [[ -f $BOOTSTRAP_CREDENTIALS_FILE ]] || bootstrap_fail 'The credential file must be a regular file.'
  [[ $(stat -c '%a:%u' -- "$BOOTSTRAP_CREDENTIALS_FILE") == "600:$(id -u)" ]] \
    || bootstrap_fail 'The credential file must be owned by you and mode 0600.'
  jq -e --arg backend "$BOOTSTRAP_BACKEND" '
    type == "object" and
    all(keys[]; . == "config" or . == "identity" or . == "projects" or . == "rotation") and
    (.config | type == "object" and .backend == $backend and all(.[]; type == "string")) and
    (.identity | type == "object")
  ' "$BOOTSTRAP_CREDENTIALS_FILE" >/dev/null || bootstrap_fail 'Expected config and identity sections for the selected backend.'
}

identity_pending() {
  [[ -f $BOOTSTRAP_CREDENTIALS_FILE ]] && jq -e '
    .identity | length == 0
  ' "$BOOTSTRAP_CREDENTIALS_FILE" >/dev/null
}

saved_setting() {
  jq -r --arg key "$(config_key "$1")" '.config[$key] // empty' "$BOOTSTRAP_CREDENTIALS_FILE"
}

load_bootstrap_context() {
  local name value
  [[ -f $BOOTSTRAP_CREDENTIALS_FILE ]] || return 0
  for name in "${BOOTSTRAP_SETTINGS[@]}"; do
    value=$(saved_setting "$name")
    [[ -n $value ]] || continue
    if [[ -n ${!name:-} && ${!name} != "$value" && $BOOTSTRAP_OPERATION != configure ]]; then
      bootstrap_fail "$name conflicts with the saved credential settings. Use configure or a separate installation file."
    fi
    [[ -n ${!name:-} && $BOOTSTRAP_OPERATION == configure ]] || printf -v "$name" '%s' "$value"
  done
}

require_complete_configuration() {
  local name value
  [[ -f $BOOTSTRAP_CREDENTIALS_FILE ]] || bootstrap_fail 'Run configure first; the local configuration is missing.'
  for name in "${BOOTSTRAP_SETTINGS[@]}"; do
    [[ $name != AWS_DEFAULT_REGION ]] || continue
    if [[ $name == CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN && ${CROSSPLANE_AWS_AUTH_MODE:-} != assume-role ]]; then continue; fi
    value=$(saved_setting "$name")
    [[ -n $value ]] || bootstrap_fail "Run configure first; config.$(config_key "$name") is required."
  done
}

show_configuration() {
  printf 'file: %s\n' "$BOOTSTRAP_CREDENTIALS_FILE"
  jq -r '
    (.config | del(.backend) | to_entries[] | "\(.key): \(.value)"),
    (if .identity.controller_identity then "controller: " + .identity.controller_identity else empty end),
    (if .identity.user_id then "user: " + .identity.user_id else empty end),
    (if .identity.client_id then "client: " + .identity.client_id else empty end),
    (if .identity.endpoint then "endpoint: " + .identity.endpoint else empty end),
    (if .projects then (.projects[] | "project: " + .) else empty end)
  ' "$BOOTSTRAP_CREDENTIALS_FILE"
}

prompt_setting() {
  local name=$1 label=$2 default_value=${3:-} value reply
  value=${!name:-$default_value}
  printf '%s [%s]: ' "$label" "$value" >&2
  IFS= read -r reply || bootstrap_fail 'Configuration cancelled; no changes were saved.'
  [[ -z $reply ]] || value=$reply
  [[ -n $value ]] || bootstrap_fail "$label is required; no changes were saved."
  printf -v "$name" '%s' "$value"
}

configure_session() {
  case $BOOTSTRAP_BACKEND in
    aws)
      prompt_setting CROSSPLANE_AWS_ACCOUNT_ID 'AWS account ID'
      prompt_setting AWS_REGION 'AWS region' "${AWS_DEFAULT_REGION:-}"
      prompt_setting CROSSPLANE_AWS_AUTH_MODE 'Authentication mode' assume-role
      if [[ $CROSSPLANE_AWS_AUTH_MODE == assume-role ]]; then
        prompt_setting CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN 'Trusted IAM principal ARN'
      fi
      prompt_setting CROSSPLANE_AWS_RESOURCE_PREFIX 'Bucket prefix' "aws-$CROSSPLANE_AWS_ACCOUNT_ID"
      ;;
    otc)
      prompt_setting CROSSPLANE_OTC_DOMAIN_ID 'OTC domain ID'
      prompt_setting CROSSPLANE_OTC_PROJECT_ID 'OTC regional project ID'
      prompt_setting CROSSPLANE_OTC_REGION 'OTC region' eu-nl
      prompt_setting CROSSPLANE_OTC_OBS_ENDPOINT 'OBS endpoint' "https://obs.$CROSSPLANE_OTC_REGION.otc.t-systems.com"
      prompt_setting CROSSPLANE_OTC_RESOURCE_PREFIX 'Bucket prefix' "otc-$CROSSPLANE_OTC_DOMAIN_ID"
      ;;
    ovh)
      prompt_setting CROSSPLANE_OVH_PROJECT_ID 'OVHcloud project ID'
      prompt_setting CROSSPLANE_OVH_API_REGION 'API region' EU
      prompt_setting CROSSPLANE_OVH_STORAGE_REGION 'Object Storage region'
      ;;
    cloudferro)
      prompt_setting CROSSPLANE_CLOUDFERRO_DOMAIN_ID 'CloudFerro domain ID'
      prompt_setting CROSSPLANE_CLOUDFERRO_AUTH_URL 'Keystone v3 endpoint'
      prompt_setting CROSSPLANE_CLOUDFERRO_REGION 'OpenStack region'
      prompt_setting CROSSPLANE_CLOUDFERRO_ADMIN_CLOUD 'Bootstrap profile (or current)' current
      prompt_setting CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN 'Project name pattern' '^.+-[0-9]{4}$'
      prompt_setting CROSSPLANE_CLOUDFERRO_CONTROLLER_NAME 'Controller name' provider-storage-controller
      prompt_setting CROSSPLANE_CLOUDFERRO_PROJECT_ROLE 'Project role' member
      ;;
  esac
}

save_configuration() (
  [[ ${BOOTSTRAP_VALIDATE_ONLY:-0} != 1 ]] || return 0
  local parent temporary name previous
  local -a arguments=(--arg backend "$BOOTSTRAP_BACKEND")
  if [[ -f $BOOTSTRAP_CREDENTIALS_FILE ]] && ! identity_pending; then
    for name in "${BOOTSTRAP_SETTINGS[@]}"; do
      previous=$(saved_setting "$name")
      [[ $name == CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN || $previous == "${!name:-}" ]] \
        || bootstrap_fail "Cannot change $(config_key "$name") for an existing identity; use a separate installation file."
    done
  fi
  for name in "${BOOTSTRAP_SETTINGS[@]}"; do
    [[ -z ${!name:-} ]] || arguments+=(--arg "$(config_key "$name")" "${!name}")
  done
  parent=$(dirname -- "$BOOTSTRAP_CREDENTIALS_FILE")
  mkdir -p -m 700 -- "$parent"
  temporary=$(mktemp "$parent/.provider-storage-config.XXXXXXXX")
  trap 'rm -f -- "$temporary"' EXIT
  if [[ -f $BOOTSTRAP_CREDENTIALS_FILE ]]; then
    jq "${arguments[@]}" '
      if .config.backend == "cloudferro" and .config.project_pattern != $ARGS.named.project_pattern
      then .projects = [] else . end | .config = $ARGS.named
    ' "$BOOTSTRAP_CREDENTIALS_FILE" >"$temporary"
  else
    jq -n "${arguments[@]}" '{config:$ARGS.named,identity:{}} |
      if .config.backend == "cloudferro" then .projects = [] else . end' >"$temporary"
  fi
  BOOTSTRAP_CREDENTIALS_FILE=$temporary require_complete_configuration
  chmod 600 -- "$temporary"
  mv -f -- "$temporary" "$BOOTSTRAP_CREDENTIALS_FILE"
  printf 'Configuration saved: %s\n' "$BOOTSTRAP_CREDENTIALS_FILE"
)

update_local_json() (
  local filter=$1 temporary
  shift
  temporary=$(mktemp "$(dirname -- "$BOOTSTRAP_CREDENTIALS_FILE")/.provider-storage-update.XXXXXXXX") || return 1
  trap 'rm -f -- "$temporary"' EXIT
  jq "$@" "$filter" \
    "$BOOTSTRAP_CREDENTIALS_FILE" >"$temporary" || return 1
  chmod 600 -- "$temporary" || return 1
  mv -f -- "$temporary" "$BOOTSTRAP_CREDENTIALS_FILE" || return 1
)

save_identity() {
  update_local_json '.identity = $identity' --argjson identity "$1"
}

render_secret() {
  printf '%s\n' '---'
  jq -n --arg name "$1" --arg key "$2" --arg content "$3" --arg namespace "$BOOTSTRAP_NAMESPACE" '
    {apiVersion:"v1",kind:"Secret",metadata:{name:$name,namespace:$namespace},
     type:"Opaque",data:{($key):($content | @base64)}}'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || bootstrap_fail "Missing required command: $1"
}

rotation_pending() {
  [[ -f $BOOTSTRAP_CREDENTIALS_FILE ]] && jq -e '.rotation | type == "object"' "$BOOTSTRAP_CREDENTIALS_FILE" >/dev/null
}

promote_rotation() {
  update_local_json '.identity = .rotation.next_identity'
}

verification_header() {
  printf '%s controller verification\n' "$1"
  shift
  printf '  %s: %s\n' "$@"
}

verification_check() {
  printf '  OK %s\n' "$*"
}

verify_rotation() {
  BOOTSTRAP_OPERATION=verify bootstrap_"$BOOTSTRAP_BACKEND" verify \
    || bootstrap_fail 'Replacement verification failed. Rotation recovery state was retained; rerun apply to resume.'
}

# A separate session keeps getpass on stdin and passwords out of arguments.
cloudferro_password_prompt() (
  local password input_file
  password=$(<"$work_dir/controller-password")
  [[ -n $password && $password != *$'\n'* && $password != *$'\r'* ]] \
    || bootstrap_fail 'Invalid controller password input.'
  input_file=$(mktemp "$work_dir/password-input.XXXXXXXX")
  trap 'rm -f -- "$input_file"' EXIT
  printf '%s\n%s\n' "$password" "$password" >"$input_file"
  unset password
  setsid --fork --wait timeout --kill-after=5s 120 "$@" <"$input_file"
)

# AWS bootstrap
bootstrap_aws() (

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

ROLE_PURPOSE="runtime-controller"
USER_PURPOSE="static-controller-source"

usage() { bootstrap_usage aws; }

aws_cli() {
  command aws "$@" --region "${AWS_REGION}" --no-cli-pager
}

validate_render_inputs() {
  [[ -n "${CROSSPLANE_AWS_CREDENTIALS_FILE:-}" ]] \
    || bootstrap_fail "CROSSPLANE_AWS_CREDENTIALS_FILE is required for render-secrets."
  [[ -f "${CROSSPLANE_AWS_CREDENTIALS_FILE}" ]] \
    || bootstrap_fail "CROSSPLANE_AWS_CREDENTIALS_FILE must contain an existing credential file."
  jq -e '
    .identity |
    (.access_key_id | type == "string" and length > 0) and
    (.secret_access_key | type == "string" and length > 0)
  ' "${CROSSPLANE_AWS_CREDENTIALS_FILE}" >/dev/null \
    || bootstrap_fail "CROSSPLANE_AWS_CREDENTIALS_FILE has an invalid AWS credential format."
}

validate_iam_path() {
  local variable_name="$1"
  local path="$2"
  [[ ${#path} -le 512 && "${path}" =~ ^/([A-Za-z0-9+=,.@_-]+/)*$ ]] \
    || bootstrap_fail "${variable_name} must be a valid IAM path that starts and ends with a slash."
}

validate_inputs() {
  local action="$1"
  [[ "${CROSSPLANE_AWS_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]] \
    || bootstrap_fail "CROSSPLANE_AWS_ACCOUNT_ID must be the exact 12-digit target account ID."
  [[ "${CROSSPLANE_AWS_AUTH_MODE}" == "assume-role" || "${CROSSPLANE_AWS_AUTH_MODE}" == "static-user" ]] \
    || bootstrap_fail "CROSSPLANE_AWS_AUTH_MODE must be assume-role or static-user."
  [[ "${CROSSPLANE_AWS_RESOURCE_PREFIX}" =~ ^[a-z0-9][a-z0-9-]{2,39}$ ]] \
    || bootstrap_fail "CROSSPLANE_AWS_RESOURCE_PREFIX must be 3-40 lowercase letters, digits, or hyphens."
  [[ "${CROSSPLANE_AWS_ROLE_NAME}" =~ ^[A-Za-z0-9+=,.@_-]{1,64}$ ]] \
    || bootstrap_fail "CROSSPLANE_AWS_ROLE_NAME is not a valid IAM role name."
  [[ "${CROSSPLANE_AWS_POLICY_NAME}" =~ ^[A-Za-z0-9+=,.@_-]{1,128}$ ]] \
    || bootstrap_fail "CROSSPLANE_AWS_POLICY_NAME is not a valid IAM policy name."
  [[ "${CROSSPLANE_AWS_USER_NAME}" =~ ^[A-Za-z0-9+=,.@_-]{1,64}$ ]] \
    || bootstrap_fail "CROSSPLANE_AWS_USER_NAME is not a valid IAM user name."
  [[ "${CROSSPLANE_AWS_USER_POLICY_NAME}" =~ ^[A-Za-z0-9+=,.@_-]{1,128}$ ]] \
    || bootstrap_fail "CROSSPLANE_AWS_USER_POLICY_NAME is not a valid IAM policy name."
  validate_iam_path CROSSPLANE_AWS_ROLE_PATH "${CROSSPLANE_AWS_ROLE_PATH}"
  validate_iam_path CROSSPLANE_AWS_USER_PATH "${CROSSPLANE_AWS_USER_PATH}"
  validate_iam_path CROSSPLANE_AWS_MANAGED_USER_PATH "${CROSSPLANE_AWS_MANAGED_USER_PATH}"
  validate_iam_path CROSSPLANE_AWS_MANAGED_POLICY_PATH "${CROSSPLANE_AWS_MANAGED_POLICY_PATH}"
  [[ "${CROSSPLANE_AWS_MANAGED_USER_PATH}" != "/" ]] \
    || bootstrap_fail "CROSSPLANE_AWS_MANAGED_USER_PATH must not be the account root path."
  [[ "${CROSSPLANE_AWS_MANAGED_POLICY_PATH}" != "/" ]] \
    || bootstrap_fail "CROSSPLANE_AWS_MANAGED_POLICY_PATH must not be the account root path."
  [[ "${CROSSPLANE_AWS_USER_PATH}${CROSSPLANE_AWS_USER_NAME}" != "${CROSSPLANE_AWS_MANAGED_USER_PATH}"* ]] \
    || bootstrap_fail "The controller user must be outside CROSSPLANE_AWS_MANAGED_USER_PATH."

}

render_credentials_manifest() {
  render_secret aws-provider-creds credentials "$(jq -r '.identity |
    "[default]\naws_access_key_id = \(.access_key_id)\naws_secret_access_key = \(.secret_access_key)"' "$BOOTSTRAP_CREDENTIALS_FILE")"
}

verify_account() {
  local actual_account
  actual_account="$(aws_cli sts get-caller-identity --query Account --output text)"
  if [[ "${actual_account}" != "${CROSSPLANE_AWS_ACCOUNT_ID}" ]]; then
    bootstrap_fail "Refusing to operate on AWS account ${actual_account}; expected CROSSPLANE_AWS_ACCOUNT_ID=${CROSSPLANE_AWS_ACCOUNT_ID}."
  fi
}

current_partition() {
  local caller_arn partition
  caller_arn="$(aws_cli sts get-caller-identity --query Arn --output text)"
  partition="${caller_arn#arn:}"
  partition="${partition%%:*}"
  [[ "${partition}" =~ ^aws(-[a-z0-9-]+)?$ ]] \
    || bootstrap_fail "Could not derive an AWS partition from caller ARN ${caller_arn}."
  printf '%s\n' "${partition}"
}

validate_trusted_principal() {
  local partition="$1"
  local trusted_account trusted_partition
  [[ -n "${CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN:-}" ]] \
    || bootstrap_fail "CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN is required for apply."
  [[ "${CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN}" =~ ^arn:aws(-[a-z0-9-]+)?:iam::[0-9]{12}:(user|role)/[A-Za-z0-9+=,.@_/-]+$ ]] \
    || bootstrap_fail "CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN must be an IAM role or user ARN."
  trusted_account="${CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN#*::}"
  trusted_account="${trusted_account%%:*}"
  [[ "${trusted_account}" == "${CROSSPLANE_AWS_ACCOUNT_ID}" ]] \
    || bootstrap_fail "CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN must belong to CROSSPLANE_AWS_ACCOUNT_ID."
  trusted_partition="${CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN#arn:}"
  trusted_partition="${trusted_partition%%:*}"
  [[ "${trusted_partition}" == "${partition}" ]] \
    || bootstrap_fail "CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN must use the target AWS partition."
}

aws_policy_template() {
  case "$1" in
    runtime-role-policy.json) cat <<'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ProtectControllerUser",
      "Effect": "Deny",
      "Action": "iam:*",
      "Resource": "__CONTROLLER_USER_ARN__"
    },
    {
      "Sid": "ManageUsersAndAccessKeys",
      "Effect": "Allow",
      "Action": [
        "iam:CreateUser",
        "iam:DeleteUser",
        "iam:UpdateUser",
        "iam:TagUser",
        "iam:UntagUser",
        "iam:ListUserTags",
        "iam:ListGroupsForUser",
        "iam:CreateAccessKey",
        "iam:DeleteAccessKey",
        "iam:ListAccessKeys",
        "iam:UpdateAccessKey"
      ],
      "Resource": "__MANAGED_USER_ARN_PATTERN__"
    },
    {
      "Sid": "ReadUsersForReconciliation",
      "Effect": "Allow",
      "Action": "iam:GetUser",
      "Resource": "__ACCOUNT_USER_ARN_PATTERN__"
    },
    {
      "Sid": "ManagePolicies",
      "Effect": "Allow",
      "Action": [
        "iam:CreatePolicy",
        "iam:DeletePolicy",
        "iam:GetPolicy",
        "iam:GetPolicyVersion",
        "iam:CreatePolicyVersion",
        "iam:DeletePolicyVersion",
        "iam:ListPolicyVersions",
        "iam:ListEntitiesForPolicy",
        "iam:TagPolicy",
        "iam:UntagPolicy",
        "iam:ListPolicyTags"
      ],
      "Resource": "__MANAGED_POLICY_ARN_PATTERN__"
    },
    {
      "Sid": "AttachManagedPoliciesToManagedUsers",
      "Effect": "Allow",
      "Action": [
        "iam:AttachUserPolicy",
        "iam:DetachUserPolicy"
      ],
      "Resource": "__MANAGED_USER_ARN_PATTERN__",
      "Condition": {
        "ArnLike": {
          "iam:PolicyARN": "__MANAGED_POLICY_ARN_PATTERN__"
        }
      }
    },
    {
      "Sid": "ListManagedUserPolicyAttachments",
      "Effect": "Allow",
      "Action": "iam:ListAttachedUserPolicies",
      "Resource": "__MANAGED_USER_ARN_PATTERN__"
    },
    {
      "Sid": "ReadAccessKeyUsage",
      "Effect": "Allow",
      "Action": "iam:GetAccessKeyLastUsed",
      "Resource": "*"
    },
    {
      "Sid": "ListBuckets",
      "Effect": "Allow",
      "Action": [
        "s3:ListAllMyBuckets",
        "s3:GetAccountPublicAccessBlock"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ManagePrefixedBuckets",
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": [
        "__BUCKET_ARN_PATTERN__",
        "__OBJECT_ARN_PATTERN__"
      ]
    },
    {
      "Sid": "IdentifySession",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
POLICY
      ;;
    runtime-role-trust-policy.json) cat <<'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowProviderStorageController",
      "Effect": "Allow",
      "Principal": {
        "AWS": "__TRUSTED_PRINCIPAL_ARN__"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
      ;;
    static-user-policy.json) cat <<'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AssumeProviderStorageRuntimeRole",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "__RUNTIME_ROLE_ARN__"
    }
  ]
}
POLICY
      ;;
    *) bootstrap_fail "Unknown embedded AWS policy: $1" ;;
  esac
}

render_policy_template() {
  local template_name="$1"
  local destination="$2"
  local content placeholder replacement
  shift 2

  content="$(aws_policy_template "${template_name}")"
  while (($#)); do
    (($# >= 2)) \
      || bootstrap_fail "A replacement value is missing for policy template ${template_name}."
    placeholder="$1"
    replacement="$2"
    shift 2
    [[ "${content}" == *"${placeholder}"* ]] \
      || bootstrap_fail "Policy template ${template_name} does not contain ${placeholder}."
    content="${content//${placeholder}/${replacement}}"
  done
  if [[ "${content}" =~ __[A-Z][A-Z0-9_]*__ ]]; then
    bootstrap_fail "Policy template ${template_name} contains an unresolved placeholder."
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
    || bootstrap_fail "Runtime role ${CROSSPLANE_AWS_ROLE_NAME} exists at unexpected ARN ${actual_role_arn}."
  purpose="$(role_tag_value purpose)"
  if [[ "$(role_tag_value project)" != "provider-storage" || \
        ( "${purpose}" != "${ROLE_PURPOSE}" && "${purpose}" != "cloud-e2e" ) || \
        "$(role_tag_value resource-prefix)" != "${CROSSPLANE_AWS_RESOURCE_PREFIX}" ]]; then
    bootstrap_fail "Runtime role ${CROSSPLANE_AWS_ROLE_NAME} does not have the expected ownership tags."
  fi
}

verify_user_ownership() {
  local purpose
  purpose="$(user_tag_value purpose)"
  if [[ "$(user_tag_value project)" != "provider-storage" || \
        "${purpose}" != "${USER_PURPOSE}" || \
        "$(user_tag_value resource-prefix)" != "${CROSSPLANE_AWS_RESOURCE_PREFIX}" ]]; then
    bootstrap_fail "Controller user ${CROSSPLANE_AWS_USER_NAME} does not have the expected ownership tags."
  fi
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
    || bootstrap_fail "Controller user ${CROSSPLANE_AWS_USER_NAME} exists at unexpected ARN ${actual_user_arn}."
  verify_user_ownership
}

ensure_controller_user() {
  local partition="$1"
  if user_exists; then
    verify_controller_user_identity "$partition"
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

write_credentials_file() {
  save_identity "$(jq -n --arg access "$1" --arg secret "$2" \
    --arg controller "$(controller_user_arn "$partition")" \
    '{access_key_id:$access,secret_access_key:$secret,controller_identity:$controller}')"
}

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
    bootstrap_fail "Controller user has more than one access key; clean it up before apply."
  fi

  if ((${#access_key_ids[@]} == 1)); then
    access_key_id="${access_key_ids[0]}"
    ! identity_pending || bootstrap_fail 'The controller key exists but is not saved in this installation file.'
    jq -e --arg access_key_id "${access_key_id}" \
      '.identity | .access_key_id == $access_key_id and
       (.secret_access_key | type == "string" and length > 0)' \
      "${CROSSPLANE_AWS_CREDENTIALS_FILE}" >/dev/null \
      || bootstrap_fail "CROSSPLANE_AWS_CREDENTIALS_FILE does not match the existing access key."
    chmod 0600 "${CROSSPLANE_AWS_CREDENTIALS_FILE}"
    return
  fi

  [[ ! -e "${CROSSPLANE_AWS_CREDENTIALS_FILE}" ]] || identity_pending \
    || bootstrap_fail "Refusing to overwrite CROSSPLANE_AWS_CREDENTIALS_FILE for a new access key."
  created_key="$(
    aws_cli iam create-access-key \
      --user-name "${CROSSPLANE_AWS_USER_NAME}" \
      --query 'AccessKey.[AccessKeyId,SecretAccessKey]' \
      --output text
  )"
  IFS=$'\t' read -r access_key_id secret_access_key <<<"${created_key}"
  [[ -n "${access_key_id}" && -n "${secret_access_key}" ]] \
    || bootstrap_fail "AWS did not return both parts of the new access key."
  if ! write_credentials_file "${access_key_id}" "${secret_access_key}"; then
    aws_cli iam delete-access-key \
      --user-name "${CROSSPLANE_AWS_USER_NAME}" \
      --access-key-id "${access_key_id}"
    bootstrap_fail "Could not store the new access key; AWS access key was deleted."
  fi
  unset secret_access_key created_key
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
  printf 'AWS controller is ready.\nrole: %s\nfile: %s\n' "$role_arn" "$BOOTSTRAP_CREDENTIALS_FILE"

)

rotate_controller_key() {
  local created old_key new_key
  if ! rotation_pending; then
    old_key=$(jq -er '.identity.access_key_id' "$BOOTSTRAP_CREDENTIALS_FILE")
    created=$(aws_cli iam create-access-key --user-name "$CROSSPLANE_AWS_USER_NAME" --output json 2>/dev/null) \
      || bootstrap_fail 'Could not create the replacement AWS access key.'
    new_key=$(jq -er '.AccessKey.AccessKeyId' <<<"$created") || bootstrap_fail 'AWS returned no replacement access key ID.'
    if ! update_local_json '
      .rotation = {previous_identity:.identity,
        next_identity:(.identity + {access_key_id:$key.AccessKeyId,secret_access_key:$key.SecretAccessKey})}
    ' --argjson key "$(jq -ce '.AccessKey | select((.AccessKeyId | length > 0) and (.SecretAccessKey | length > 0))' <<<"$created")"; then
      aws_cli iam delete-access-key --user-name "$CROSSPLANE_AWS_USER_NAME" --access-key-id "$new_key" >/dev/null
      bootstrap_fail 'Could not save the replacement AWS key; it was deleted.'
    fi
    unset created
  fi
  old_key=$(jq -er '.rotation.previous_identity.access_key_id' "$BOOTSTRAP_CREDENTIALS_FILE")
  new_key=$(jq -er '.rotation.next_identity.access_key_id' "$BOOTSTRAP_CREDENTIALS_FILE")
  [[ $old_key != "$new_key" ]] || bootstrap_fail 'Rotation recovery refers to the same AWS key twice.'
  local actual_keys key old_present=0 new_present=0
  actual_keys=$(list_controller_access_keys)
  for key in $actual_keys; do
    case $key in
      "$old_key") old_present=1 ;;
      "$new_key") new_present=1 ;;
      *) bootstrap_fail 'The controller has an unrelated access key; rotation stopped.' ;;
    esac
  done
  [[ $new_present == 1 ]] || bootstrap_fail 'The replacement AWS key is missing.'
  promote_rotation
  verify_rotation
  if [[ $old_present == 1 ]]; then
    aws_cli iam delete-access-key --user-name "$CROSSPLANE_AWS_USER_NAME" --access-key-id "$old_key" >/dev/null
  fi
  update_local_json 'del(.rotation)'
  printf 'AWS controller credentials rotated.\n'
}

verify_controller() (
  local caller partition session account role_arn
  verification_header AWS account "$CROSSPLANE_AWS_ACCOUNT_ID" region "$AWS_REGION" \
    role "$CROSSPLANE_AWS_ROLE_PATH$CROSSPLANE_AWS_ROLE_NAME"
  if [[ $CROSSPLANE_AWS_AUTH_MODE == static-user ]]; then
    validate_render_inputs
    unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE
    unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI
    export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
    export AWS_ACCESS_KEY_ID=$(jq -er '.identity.access_key_id' "$BOOTSTRAP_CREDENTIALS_FILE")
    export AWS_SECRET_ACCESS_KEY=$(jq -er '.identity.secret_access_key' "$BOOTSTRAP_CREDENTIALS_FILE")
  fi
  caller=$(aws_cli sts get-caller-identity --output json 2>/dev/null) || bootstrap_fail 'The controller credential source could not authenticate.'
  verification_check 'Credential authentication'
  account=$(jq -r '.Account // empty' <<<"$caller")
  [[ $account == "$CROSSPLANE_AWS_ACCOUNT_ID" ]] || bootstrap_fail 'The controller credential source belongs to another AWS account.'
  verification_check 'Account scope'
  partition=$(jq -r '.Arn | split(":")[1]' <<<"$caller")
  [[ $partition =~ ^aws(-[a-z0-9-]+)?$ ]] || bootstrap_fail 'The AWS caller partition is invalid.'
  role_arn=$(runtime_role_arn "$partition")
  session=$(aws_cli sts assume-role --role-arn "$role_arn" --role-session-name provider-storage-verify --output json 2>/dev/null) \
    || bootstrap_fail 'The controller credential source cannot assume the configured runtime role.'
  verification_check 'Role assumption'
  export AWS_ACCESS_KEY_ID=$(jq -er '.Credentials.AccessKeyId | select(type == "string" and length > 0)' <<<"$session")
  export AWS_SECRET_ACCESS_KEY=$(jq -er '.Credentials.SecretAccessKey | select(type == "string" and length > 0)' <<<"$session")
  export AWS_SESSION_TOKEN=$(jq -er '.Credentials.SessionToken | select(type == "string" and length > 0)' <<<"$session")
  unset session caller AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE
  export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
  caller=$(aws_cli sts get-caller-identity --output json 2>/dev/null) || bootstrap_fail 'The controller runtime session could not authenticate.'
  jq -e --arg account "$CROSSPLANE_AWS_ACCOUNT_ID" \
    --arg arn "arn:$partition:sts::$CROSSPLANE_AWS_ACCOUNT_ID:assumed-role/$CROSSPLANE_AWS_ROLE_NAME/provider-storage-verify" \
    '.Account == $account and .Arn == $arn' <<<"$caller" >/dev/null || bootstrap_fail 'The runtime session has the wrong account or role.'
  verification_check 'Role scope'
  aws_cli s3api list-buckets >/dev/null 2>&1 || bootstrap_fail 'The controller runtime role cannot list S3 buckets.'
  verification_check 'S3 bucket listing'
)

main() {
  local action="${1:-}" partition
  case "${action}" in
    -h|--help|help|usage)
      usage
      return
      ;;
    configure|show|apply|verify|render-secrets) ;;
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
  fi
  validate_inputs "${action}"
  if [[ $action == configure ]]; then
    [[ ${AWS_REGION:-} =~ ^[a-z0-9][a-z0-9-]+$ ]] || bootstrap_fail 'The AWS region is invalid.'
    if [[ $CROSSPLANE_AWS_AUTH_MODE == assume-role ]]; then
      local principal_partition=${CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN#arn:}
      principal_partition=${principal_partition%%:*}
      validate_trusted_principal "$principal_partition"
    fi
    save_configuration
    return
  fi
  require_command aws
  if [[ $action == verify ]]; then verify_controller; return; fi

  case "${action}" in
    apply)
      verify_account
      partition="$(current_partition)"
      if rotation_pending; then
        verify_role_ownership "$partition"
        verify_controller_user_identity "$partition"
        rotate_controller_key
      else
        apply_role
        if [[ $BOOTSTRAP_ROTATE == 1 ]]; then rotate_controller_key; fi
      fi
      ;;

  esac
}

main "$@"

)

# OTC bootstrap
bootstrap_otc() (

: "${CROSSPLANE_OTC_REGION:=eu-nl}"
: "${CROSSPLANE_OTC_OBS_ENDPOINT:=https://obs.${CROSSPLANE_OTC_REGION}.otc.t-systems.com}"
: "${CROSSPLANE_OTC_AUTH_URL:=https://iam.${CROSSPLANE_OTC_REGION}.otc.t-systems.com/v3}"
: "${CROSSPLANE_OTC_RESOURCE_PREFIX:=otc-${CROSSPLANE_OTC_DOMAIN_ID:-}}"
: "${CROSSPLANE_OTC_USER_NAME:=provider-storage-controller-crossplane}"
: "${CROSSPLANE_OTC_GROUP_NAME:=provider-storage-controller-crossplane}"

local -r USER_DESCRIPTION="Provider Storage controller for ${CROSSPLANE_OTC_RESOURCE_PREFIX}."
local -r GROUP_DESCRIPTION="Provider Storage controller permissions for ${CROSSPLANE_OTC_RESOURCE_PREFIX}."
local -r CREDENTIAL_DESCRIPTION="Provider Storage controller for ${CROSSPLANE_OTC_RESOURCE_PREFIX}"
local -r SECURITY_ADMIN_ROLE_NAME=secu_admin
local -r OBS_ADMIN_POLICY_NAME='OBS Administrator'

IAM_V3_ROOT=""
IAM_V30_ROOT=""
ADMIN_TOKEN=""
DOMAIN_NAME=""
PROJECT_NAME=""
TMP_DIR=""
IAM_RESPONSE=""
IAM_STATUS=""

usage() { bootstrap_usage otc; }

validate_name() {
  local variable_name="$1"
  local value="$2"
  [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] \
    || bootstrap_fail "${variable_name} must contain 1-64 letters, digits, underscores, or hyphens."
}

validate_render_inputs() {
  [[ -n "${CROSSPLANE_OTC_CREDENTIALS_FILE:-}" ]] \
    || bootstrap_fail "CROSSPLANE_OTC_CREDENTIALS_FILE is required for render-secrets."
  [[ -f "${CROSSPLANE_OTC_CREDENTIALS_FILE}" ]] \
    || bootstrap_fail "CROSSPLANE_OTC_CREDENTIALS_FILE must contain an existing credential file."
  jq -e '
    .identity |
    (.access_key | type == "string" and length > 0) and
    (.secret_key | type == "string" and length > 0) and
    (.auth_url | type == "string" and test("^https://")) and
    (.domain_name | type == "string" and length > 0) and
    (.domain_id | type == "string" and test("^[0-9a-f]{32}$")) and
    (.tenant_id | type == "string" and test("^[0-9a-f]{32}$"))
  ' "${CROSSPLANE_OTC_CREDENTIALS_FILE}" >/dev/null \
    || bootstrap_fail "CROSSPLANE_OTC_CREDENTIALS_FILE has an invalid OTC credential format."
}

validate_inputs() {
  local action="$1"
  [[ "${CROSSPLANE_OTC_DOMAIN_ID:-}" =~ ^[0-9a-f]{32}$ ]] \
    || bootstrap_fail "CROSSPLANE_OTC_DOMAIN_ID must be the exact 32-character target domain ID."
  [[ "${CROSSPLANE_OTC_PROJECT_ID:-}" =~ ^[0-9a-f]{32}$ ]] \
    || bootstrap_fail "CROSSPLANE_OTC_PROJECT_ID must be the exact 32-character target project ID."
  [[ "${CROSSPLANE_OTC_REGION}" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || bootstrap_fail "CROSSPLANE_OTC_REGION contains unsupported characters."
  [[ "${CROSSPLANE_OTC_AUTH_URL}" =~ ^https://[A-Za-z0-9.-]+/v3/?$ ]] \
    || bootstrap_fail "CROSSPLANE_OTC_AUTH_URL must be an HTTPS IAM v3 endpoint without a query."
  [[ "${CROSSPLANE_OTC_RESOURCE_PREFIX}" =~ ^[a-z0-9][a-z0-9-]{2,49}$ ]] \
    || bootstrap_fail "CROSSPLANE_OTC_RESOURCE_PREFIX must be 3-50 lowercase letters, digits, or hyphens."
  validate_name CROSSPLANE_OTC_USER_NAME "${CROSSPLANE_OTC_USER_NAME}"
  validate_name CROSSPLANE_OTC_GROUP_NAME "${CROSSPLANE_OTC_GROUP_NAME}"
}

render_credentials_manifest() {
  render_secret otc-provider-creds credentials "$(jq -c '.identity | with_entries(select(.key as $key |
    ["access_key","secret_key","auth_url","domain_name","domain_id","tenant_id",
     "swauth","allow_reauth","max_retries","max_backoff_retries","backoff_retry_timeout","insecure"] |
    index($key)))' "$BOOTSTRAP_CREDENTIALS_FILE")"
}

init_session() {
  local token_json token_domain_id curl_config

  if ! token_json="$(
    unset OS_PROJECT_ID OS_PROJECT_NAME OS_PROJECT_DOMAIN_ID \
      OS_PROJECT_DOMAIN_NAME OS_DOMAIN_NAME OS_SYSTEM_SCOPE
    export OS_DOMAIN_ID="${CROSSPLANE_OTC_DOMAIN_ID}"
    command openstack token issue -f json
  )"; then
    bootstrap_fail "Could not obtain a domain-scoped OTC token from the openstack client."
  fi
  ADMIN_TOKEN="$(jq -r '.id // .ID // empty' <<<"${token_json}")"
  token_domain_id="$(jq -r '.domain_id // ."Domain ID" // empty' <<<"${token_json}")"
  unset token_json

  [[ "${ADMIN_TOKEN}" =~ ^[A-Za-z0-9._~+/=-]+$ ]] \
    || bootstrap_fail "The openstack client did not return a usable token."
  [[ "${token_domain_id}" == "${CROSSPLANE_OTC_DOMAIN_ID}" ]] \
    || bootstrap_fail "The openstack client did not return a token scoped to CROSSPLANE_OTC_DOMAIN_ID."

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
    bootstrap_fail "The OTC IAM API request did not complete."
  fi
  if [[ "${IAM_STATUS}" == 403 ]]; then
    bootstrap_fail "The OTC IAM API request ${method} ${url} failed with HTTP 403. The administrator session requires Security Administrator at domain scope."
  fi
  [[ " ${expected} " == *" ${IAM_STATUS} "* ]] \
    || bootstrap_fail "The OTC IAM API request ${method} ${url} failed with HTTP ${IAM_STATUS}."
}

verify_target() {
  local actual_domain_id actual_project_id project_domain_id

  iam_request GET "${IAM_V3_ROOT}/auth/domains" 200
  actual_domain_id="$(jq -r --arg domain "${CROSSPLANE_OTC_DOMAIN_ID}" \
    '.domains[] | select(.id == $domain) | .id' "${IAM_RESPONSE}")"
  DOMAIN_NAME="$(jq -r --arg domain "${CROSSPLANE_OTC_DOMAIN_ID}" \
    '.domains[] | select(.id == $domain) | .name' "${IAM_RESPONSE}")"
  [[ "${actual_domain_id}" == "${CROSSPLANE_OTC_DOMAIN_ID}" && -n "${DOMAIN_NAME}" ]] \
    || bootstrap_fail "The IAM endpoint did not return CROSSPLANE_OTC_DOMAIN_ID."

  iam_request GET "${IAM_V3_ROOT}/projects/${CROSSPLANE_OTC_PROJECT_ID}" 200
  actual_project_id="$(jq -r '.project.id // empty' "${IAM_RESPONSE}")"
  project_domain_id="$(jq -r '.project.domain_id // empty' "${IAM_RESPONSE}")"
  PROJECT_NAME="$(jq -r '.project.name // empty' "${IAM_RESPONSE}")"
  [[ "${actual_project_id}" == "${CROSSPLANE_OTC_PROJECT_ID}" && \
     "${project_domain_id}" == "${CROSSPLANE_OTC_DOMAIN_ID}" && \
     -n "${PROJECT_NAME}" ]] \
    || bootstrap_fail "CROSSPLANE_OTC_PROJECT_ID is not in CROSSPLANE_OTC_DOMAIN_ID."
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
  ((count <= 1)) || bootstrap_fail "More than one controller user has the configured name."
  if ((count == 0)); then
    return 0
  fi
  user_id="$(jq -r --arg name "${CROSSPLANE_OTC_USER_NAME}" \
    --arg domain "${CROSSPLANE_OTC_DOMAIN_ID}" \
    '.users[] | select(.name == $name and .domain_id == $domain) | .id' \
    "${IAM_RESPONSE}")"
  [[ "${user_id}" =~ ^[0-9a-f]{32}$ ]] \
    || bootstrap_fail "The existing controller user has an invalid ID."

  iam_request GET "${IAM_V30_ROOT}/OS-USER/users/${user_id}" 200
  description="$(jq -r '.user.description // empty' "${IAM_RESPONSE}")"
  domain_id="$(jq -r '.user.domain_id // empty' "${IAM_RESPONSE}")"
  access_mode="$(jq -r '.user.access_mode // empty' "${IAM_RESPONSE}")"
  enabled="$(jq -r '.user.enabled // empty' "${IAM_RESPONSE}")"
  [[ "${description}" == "${USER_DESCRIPTION}" && \
     "${domain_id}" == "${CROSSPLANE_OTC_DOMAIN_ID}" ]] \
    || bootstrap_fail "Controller user ${CROSSPLANE_OTC_USER_NAME} exists but is not owned by this bootstrap."
  [[ "${access_mode}" == programmatic && "${enabled}" == true ]] \
    || bootstrap_fail "The owned controller user is not enabled for programmatic access."
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
    || bootstrap_fail "OTC did not return the new controller user ID."
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
  ((count <= 1)) || bootstrap_fail "More than one controller group has the configured name."
  if ((count == 0)); then
    return 0
  fi
  group_id="$(jq -r --arg name "${CROSSPLANE_OTC_GROUP_NAME}" \
    --arg domain "${CROSSPLANE_OTC_DOMAIN_ID}" \
    '.groups[] | select(.name == $name and .domain_id == $domain) | .id' \
    "${IAM_RESPONSE}")"
  [[ "${group_id}" =~ ^[0-9a-f]{32}$ ]] \
    || bootstrap_fail "The existing controller group has an invalid ID."

  iam_request GET "${IAM_V3_ROOT}/groups/${group_id}" 200
  description="$(jq -r '.group.description // empty' "${IAM_RESPONSE}")"
  domain_id="$(jq -r '.group.domain_id // empty' "${IAM_RESPONSE}")"
  [[ "${description}" == "${GROUP_DESCRIPTION}" && \
     "${domain_id}" == "${CROSSPLANE_OTC_DOMAIN_ID}" ]] \
    || bootstrap_fail "Controller group ${CROSSPLANE_OTC_GROUP_NAME} exists but is not owned by this bootstrap."
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
    || bootstrap_fail "OTC did not return the new controller group ID."
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
    || bootstrap_fail "OTC did not return exactly one ${OBS_ADMIN_POLICY_NAME} system policy."
  policy_id="$(jq -r --arg name "${OBS_ADMIN_POLICY_NAME}" \
    '.roles[] | select(.display_name == $name and .type == "AX" and
      .domain_id == null) | .id' "${IAM_RESPONSE}")"
  [[ "${policy_id}" =~ ^[0-9a-f]{32}$ ]] \
    || bootstrap_fail "The ${OBS_ADMIN_POLICY_NAME} system policy has an invalid ID."
  printf '%s\n' "${policy_id}"
}

security_admin_role_id() {
  local count role_id
  iam_request GET "${IAM_V3_ROOT}/roles?name=${SECURITY_ADMIN_ROLE_NAME}" 200
  count="$(jq --arg name "${SECURITY_ADMIN_ROLE_NAME}" \
    '[.roles[] | select(.name == $name)] | length' "${IAM_RESPONSE}")"
  ((count == 1)) \
    || bootstrap_fail "OTC did not return exactly one ${SECURITY_ADMIN_ROLE_NAME} system role."
  role_id="$(jq -r --arg name "${SECURITY_ADMIN_ROLE_NAME}" \
    '.roles[] | select(.name == $name) | .id' "${IAM_RESPONSE}")"
  [[ "${role_id}" =~ ^[0-9a-f]{32}$ ]] \
    || bootstrap_fail "The ${SECURITY_ADMIN_ROLE_NAME} system role has an invalid ID."
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
    || bootstrap_fail "OBS Administrator is not assigned to all existing and future projects."
}

list_credentials() {
  local user_id="$1"
  iam_request GET \
    "${IAM_V30_ROOT}/OS-CREDENTIAL/credentials?user_id=${user_id}" 200
}

verify_credentials_file() {
  local access_key="$1"
  ! identity_pending || bootstrap_fail 'The controller key exists but is not saved in this installation file.'
  jq -e \
    --arg access_key "${access_key}" \
    --arg auth_url "${CROSSPLANE_OTC_AUTH_URL%/}" \
    --arg domain_name "${DOMAIN_NAME}" \
    --arg domain_id "${CROSSPLANE_OTC_DOMAIN_ID}" \
    --arg project_id "${CROSSPLANE_OTC_PROJECT_ID}" \
    '.identity | .access_key == $access_key and
     (.secret_key | strings | length > 0) and
     .auth_url == $auth_url and .domain_name == $domain_name and
     .domain_id == $domain_id and .tenant_id == $project_id' \
    "${CROSSPLANE_OTC_CREDENTIALS_FILE}" >/dev/null \
    || bootstrap_fail "CROSSPLANE_OTC_CREDENTIALS_FILE does not match the existing controller credential."
}

write_credentials_file() {
  save_identity "$(jq -n --arg access "$1" --arg secret "$2" \
    --arg url "${CROSSPLANE_OTC_AUTH_URL%/}" --arg domain "$CROSSPLANE_OTC_DOMAIN_ID" \
    --arg domain_name "$DOMAIN_NAME" --arg project "$CROSSPLANE_OTC_PROJECT_ID" \
    --arg controller "$user_id" \
    '{access_key:$access,secret_key:$secret,auth_url:$url,domain_name:$domain_name,
      domain_id:$domain,tenant_id:$project,controller_identity:$controller,
      swauth:"false",allow_reauth:"true",max_retries:"2",max_backoff_retries:"6",
      backoff_retry_timeout:"60",insecure:"false"}')"
}

ensure_controller_credential() {
  local user_id="$1"
  local total owned access_key secret_key body

  list_credentials "${user_id}"
  total="$(jq '.credentials | length' "${IAM_RESPONSE}")"
  owned="$(jq --arg description "${CREDENTIAL_DESCRIPTION}" \
    '[.credentials[] | select(.description == $description)] | length' \
    "${IAM_RESPONSE}")"
  ((total == owned)) \
    || bootstrap_fail "The owned controller user has a credential not created by this bootstrap."
  ((owned <= 1)) \
    || bootstrap_fail "The owned controller user has more than one bootstrap credential."

  if ((owned == 1)); then
    jq -e --arg description "${CREDENTIAL_DESCRIPTION}" \
      '.credentials[] | select(.description == $description) |
       .status == "active"' "${IAM_RESPONSE}" >/dev/null \
      || bootstrap_fail "The existing controller credential is not active."
    access_key="$(jq -r --arg description "${CREDENTIAL_DESCRIPTION}" \
      '.credentials[] | select(.description == $description) | .access' \
      "${IAM_RESPONSE}")"
    [[ "${access_key}" =~ ^[A-Za-z0-9]{16,128}$ ]] \
      || bootstrap_fail "The existing controller credential has an invalid access key ID."
    verify_credentials_file "${access_key}"
    return
  fi

  [[ ! -e "${CROSSPLANE_OTC_CREDENTIALS_FILE}" ]] || identity_pending \
    || bootstrap_fail "Refusing to overwrite CROSSPLANE_OTC_CREDENTIALS_FILE for a new credential."
  body="$(jq -n --arg user_id "${user_id}" \
    --arg description "${CREDENTIAL_DESCRIPTION}" \
    '{credential: {user_id: $user_id, description: $description}}')"
  iam_request POST "${IAM_V30_ROOT}/OS-CREDENTIAL/credentials" 201 "${body}"
  access_key="$(jq -r '.credential.access // empty' "${IAM_RESPONSE}")"
  secret_key="$(jq -r '.credential.secret // empty' "${IAM_RESPONSE}")"
  [[ "${access_key}" =~ ^[A-Za-z0-9]{16,128}$ && -n "${secret_key}" ]] \
    || bootstrap_fail "OTC did not return both parts of the new controller credential."
  if ! write_credentials_file "${access_key}" "${secret_key}"; then
    iam_request DELETE "${IAM_V30_ROOT}/OS-CREDENTIAL/credentials/${access_key}" '204 200'
    bootstrap_fail "Could not store the new credential; the OTC credential was deleted."
  fi
  unset secret_key body
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
    || bootstrap_fail "Credential rotation requires exactly one owned controller credential."
  old_access_key="$(jq -r --arg description "${CREDENTIAL_DESCRIPTION}" \
    '.credentials[] | select(.description == $description) | .access' \
    "${IAM_RESPONSE}")"
  [[ "${old_access_key}" =~ ^[A-Za-z0-9]{16,128}$ ]] \
    || bootstrap_fail "The existing controller credential has an invalid access key ID."

  body="$(jq -n --arg user_id "${user_id}" \
    --arg description "${CREDENTIAL_DESCRIPTION}" \
    '{credential: {user_id: $user_id, description: $description}}')"
  iam_request POST "${IAM_V30_ROOT}/OS-CREDENTIAL/credentials" 201 "${body}"
  new_access_key="$(jq -r '.credential.access // empty' "${IAM_RESPONSE}")"
  secret_key="$(jq -r '.credential.secret // empty' "${IAM_RESPONSE}")"
  [[ "${new_access_key}" =~ ^[A-Za-z0-9]{16,128}$ && \
     "${new_access_key}" != "${old_access_key}" && -n "${secret_key}" ]] \
    || bootstrap_fail "OTC did not return a valid replacement controller credential."

  if ! update_local_json '
    .rotation = {previous_identity:.identity,
      next_identity:(.identity + {access_key:$access,secret_key:$secret})}
  ' --arg access "$new_access_key" --arg secret "$secret_key"; then
    iam_request DELETE "${IAM_V30_ROOT}/OS-CREDENTIAL/credentials/${new_access_key}" '204 200'
    bootstrap_fail 'Could not save the replacement OTC credential; it was deleted.'
  fi
  unset secret_key body
  finish_controller_rotation

}

finish_controller_rotation() {
  local old_key
  old_key=$(jq -er '.rotation.previous_identity.access_key' "$BOOTSTRAP_CREDENTIALS_FILE")
  local next_key old_present
  next_key=$(jq -er '.rotation.next_identity.access_key' "$BOOTSTRAP_CREDENTIALS_FILE")
  [[ $old_key != "$next_key" && $old_key =~ ^[A-Za-z0-9]{16,128}$ && $next_key =~ ^[A-Za-z0-9]{16,128}$ ]] || bootstrap_fail 'Invalid OTC rotation key IDs.'
  list_credentials "$user_id"
  jq -e --arg old "$old_key" --arg next "$next_key" --arg description "$CREDENTIAL_DESCRIPTION" '
    any(.credentials[]; .access == $next) and
    all(.credentials[]; .description == $description and (.access == $old or .access == $next))
  ' "$IAM_RESPONSE" >/dev/null || bootstrap_fail 'OTC rotation recovery does not match the controller credentials.'
  old_present=$(jq --arg old "$old_key" '[.credentials[] | select(.access == $old)] | length' "$IAM_RESPONSE")
  promote_rotation
  verify_rotation
  if [[ $old_present == 1 ]]; then
    iam_request DELETE "${IAM_V30_ROOT}/OS-CREDENTIAL/credentials/${old_key}" '204 200'
  fi
  update_local_json 'del(.rotation)'
  printf 'OTC controller credentials rotated.\n'
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
  if rotation_pending; then
    finish_controller_rotation
  else
    ensure_controller_credential "${user_id}"
    if [[ $BOOTSTRAP_ROTATE == 1 ]]; then rotate_controller_credential "$user_id"; fi
  fi

  printf 'OTC controller is ready.\nfile: %s\n' "$BOOTSTRAP_CREDENTIALS_FILE"

}

verify_controller() (
  local directory status curl_version error_pattern='<Code>([A-Za-z][A-Za-z0-9]{0,63})</Code>'
  validate_render_inputs
  jq -e '.identity.domain_id == .config.domain_id and
    .identity.tenant_id == .config.project_id and
    .identity.auth_url == .config.auth_url' "$BOOTSTRAP_CREDENTIALS_FILE" >/dev/null \
    || bootstrap_fail 'The controller credential does not match the configured domain, project, or endpoint.'
  verification_header OTC domain "$CROSSPLANE_OTC_DOMAIN_ID" project "$CROSSPLANE_OTC_PROJECT_ID" \
    region "$CROSSPLANE_OTC_REGION" endpoint "$CROSSPLANE_OTC_OBS_ENDPOINT"
  require_command curl
  curl_version=$(command curl --version)
  [[ $curl_version =~ ^curl\ ([0-9]+)\.([0-9]+)\.([0-9]+) ]] \
    || bootstrap_fail 'Could not read the curl version.'
  # Older curl signs only a fixed set of headers, which OBS rejects.
  ((BASH_REMATCH[1] > 7 || (BASH_REMATCH[1] == 7 && BASH_REMATCH[2] >= 87))) \
    || bootstrap_fail 'OTC verification needs curl 7.87 or later to sign the OBS payload header.'
  directory=$(mktemp -d)
  trap 'rm -rf -- "$directory"' EXIT
  jq -r '.identity | "user = " + ((.access_key + ":" + .secret_key) | @json)' \
    "$BOOTSTRAP_CREDENTIALS_FILE" >"$directory/curl.conf"
  status=$(command curl -q --silent --show-error --config "$directory/curl.conf" \
    --aws-sigv4 "aws:amz:$CROSSPLANE_OTC_REGION:s3" \
    --header 'x-amz-content-sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' \
    --proto '=https' --connect-timeout 15 --max-time 60 \
    --output "$directory/response" --write-out '%{http_code}' \
    "${CROSSPLANE_OTC_OBS_ENDPOINT%/}/" 2>/dev/null) \
    || bootstrap_fail 'OTC controller verification failed; curl must support --aws-sigv4.'
  if [[ $status != 200 ]]; then
    if [[ $(<"$directory/response") =~ $error_pattern ]]; then
      status+=" (${BASH_REMATCH[1]})"
    fi
    bootstrap_fail "OTC controller bucket listing failed with HTTP $status."
  fi
  verification_check 'Credential authentication'
  grep -q 'ListAllMyBucketsResult' "$directory/response" || bootstrap_fail 'OBS returned an invalid bucket-list response.'
  verification_check 'OBS bucket listing'
)

main() {
  local action="${1:-}"
  case "${action}" in
    -h|--help|help|usage)
      usage
      return
      ;;
    configure|show|apply|verify|render-secrets) ;;
    *)
      usage >&2
      exit 2
      ;;
  esac

  require_command jq
  if [[ "${action}" == render-secrets ]]; then
    require_command stat
    validate_render_inputs
    render_credentials_manifest
    return
  fi
  require_command stat
  validate_inputs "${action}"
  [[ $CROSSPLANE_OTC_OBS_ENDPOINT =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || bootstrap_fail 'The OBS endpoint must use HTTPS without a path or query.'
  if [[ $action == configure ]]; then save_configuration; return; fi
  if [[ $action == verify ]]; then verify_controller; return; fi
  require_command openstack
  require_command curl
  trap cleanup EXIT
  init_session
  verify_target

  case "${action}" in
    apply)
      apply_resources
      ;;

  esac
}

main "$@"

)

# OVH bootstrap
bootstrap_ovh() (

usage() { bootstrap_usage ovh; }

case "${1:-}" in
  -h|--help|help|usage) usage; exit 0 ;;
  configure|show|apply|verify|render-secrets)
    if (($# != 1)); then usage >&2; exit 2; fi
    action=$1
    ;;
  *) usage >&2; exit 2 ;;
esac

namespace=$BOOTSTRAP_NAMESPACE
credentials_file=$BOOTSTRAP_CREDENTIALS_FILE

render_credentials_manifest() {
  render_secret ovh-provider-creds credentials "$(jq -c '.identity | {endpoint,client_id,client_secret}' "$BOOTSTRAP_CREDENTIALS_FILE")"
}

if [[ $action == render-secrets ]]; then
  [[ -f $credentials_file ]] || bootstrap_fail 'Run apply before render-secrets.'
  jq -e '
    .identity |
    (.endpoint == "ovh-eu" or .endpoint == "ovh-ca" or .endpoint == "ovh-us") and
    (.client_id | type == "string" and length > 0) and
    (.client_secret | type == "string" and length > 0)
  ' "$credentials_file" >/dev/null || bootstrap_fail 'The credential file has the wrong format.'
  render_credentials_manifest
  exit 0
fi

project_id=${CROSSPLANE_OVH_PROJECT_ID:-}
[[ $project_id =~ ^[0-9a-f]{32}$ ]] || bootstrap_fail 'CROSSPLANE_OVH_PROJECT_ID must be an exact 32-character lowercase hexadecimal ID.'
api_region=${CROSSPLANE_OVH_API_REGION:-EU}
[[ $api_region =~ ^(EU|CA|US)$ ]] || bootstrap_fail 'CROSSPLANE_OVH_API_REGION must be EU, CA, or US.'
endpoint="ovh-${api_region,,}"
if [[ -n ${OVH_ENDPOINT:-} && ${OVH_ENDPOINT} != "$endpoint" ]]; then
  bootstrap_fail "OVH_ENDPOINT must be $endpoint for this project."
fi
export OVH_ENDPOINT="$endpoint"
if [[ $action == configure ]]; then
  [[ ${CROSSPLANE_OVH_STORAGE_REGION:-} =~ ^[A-Z0-9-]+$ ]] || bootstrap_fail 'The Object Storage region is invalid.'
  save_configuration
  exit 0
fi
# Project actions required by the pinned provider. The CLI does not expose
# IAM action-reference discovery; review these actions before apply.
required_actions=(
  publicCloudProject:apiovh:get
  publicCloudProject:apiovh:role/get
  publicCloudProject:apiovh:user/create
  publicCloudProject:apiovh:user/delete
  publicCloudProject:apiovh:user/get
  publicCloudProject:apiovh:user/openrc/get
  publicCloudProject:apiovh:user/policy/create
  publicCloudProject:apiovh:user/policy/get
  publicCloudProject:apiovh:user/role/create
  publicCloudProject:apiovh:user/role/delete
  publicCloudProject:apiovh:user/role/edit
  publicCloudProject:apiovh:user/role/get
  publicCloudProject:apiovh:user/s3Credentials/create
  publicCloudProject:apiovh:user/s3Credentials/delete
  publicCloudProject:apiovh:user/s3Credentials/get
  publicCloudProject:apiovh:user/s3Credentials/secret/display
  publicCloudProject:apiovh:region/storage/create
  publicCloudProject:apiovh:region/storage/delete
  publicCloudProject:apiovh:region/storage/edit
  publicCloudProject:apiovh:region/storage/get
  publicCloudProject:apiovh:region/storage/object/get
)
actions_json=$(printf '%s\n' "${required_actions[@]}" | jq -R . | jq -s .)
client_name="provider-storage-controller-${project_id:0:12}"
policy_name="provider-storage-controller-${project_id:0:12}"
description="Provider Storage controller for project $project_id."

work_dir=$(mktemp -d /tmp/provider-storage-ovh.XXXXXXXX)
trap 'rm -rf -- "$work_dir"' EXIT

# go-ovh merges /etc/ovh.conf and the user's ~/.ovh.conf even when HOME is
# changed. Its local ./ovh.conf has the highest file priority. Empty values
# here clear any inherited administrator authentication for service checks.
printf '[default]\nendpoint=%s\n[%s]\napplication_key=\napplication_secret=\nconsumer_key=\naccess_token=\n' \
  "$endpoint" "$endpoint" >"$work_dir/ovh.conf"

admin_json() {
  local result
  if ! result=$(ovhcloud "$@" -o json 2>/dev/null); then
    bootstrap_fail "ovhcloud ${1:-request} failed. Check administrator authentication and the selected project."
  fi
  printf '%s\n' "$result"
}

read_credentials() {
  [[ -f $credentials_file ]] || bootstrap_fail 'The private credential file is missing.'
  jq -e --arg endpoint "$endpoint" '
    .identity |
    type == "object" and
    .endpoint == $endpoint and
    (.client_id | type == "string" and length > 0) and
    (.client_secret | type == "string" and length > 0)
  ' "$credentials_file" >/dev/null || bootstrap_fail 'The credential file has the wrong format or API region.'
}

service_json() (
  local client_id client_secret
  read_credentials
  client_id=$(jq -er '.identity.client_id' "$credentials_file")
  client_secret=$(jq -er '.identity.client_secret' "$credentials_file")
  cd -- "$work_dir"
  export HOME="$work_dir" OVH_ENDPOINT="$endpoint" OVH_CLIENT_ID="$client_id" OVH_CLIENT_SECRET="$client_secret" OVH_PROFILE=default
  unset OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY OVH_ACCESS_TOKEN
  ovhcloud "$@" -o json 2>/dev/null
)

if [[ $action == verify ]]; then
  read_credentials
  verification_header OVHcloud project "$project_id" region "$CROSSPLANE_OVH_STORAGE_REGION" \
    client "$(jq -r '.identity.client_id' "$credentials_file")" endpoint "$endpoint"
  service_project=$(service_json cloud project get "$project_id") || bootstrap_fail 'The controller could not read the target project.'
  verification_check 'Credential authentication'
  jq -e --arg id "$project_id" '.id == $id' <<<"$service_project" >/dev/null || bootstrap_fail 'The controller read another project.'
  verification_check 'Project scope'
  service_json cloud user list --cloud-project "$project_id" >/dev/null || bootstrap_fail 'The controller could not list project users.'
  verification_check 'Project user listing'
  exit 0
fi

project=$(admin_json cloud project get "$project_id")
jq -e --arg id "$project_id" '.id == $id' <<<"$project" >/dev/null || bootstrap_fail 'The administrator session returned a different project.'
resource_urn=$(jq -er '.iam.urn | strings' <<<"$project") || bootstrap_fail 'The project has no IAM resource URN.'
[[ $resource_urn == "urn:v1:${api_region,,}:resource:"* ]] || bootstrap_fail 'The project IAM resource is on another API region.'
me=$(admin_json account get)
owner=$(jq -er '.nichandle | strings' <<<"$me") || bootstrap_fail 'The administrator account could not be identified.'
resource=$(admin_json iam resource get "$resource_urn")
jq -e --arg urn "$resource_urn" --arg owner "$owner" '.urn == $urn and .owner == $owner' <<<"$resource" >/dev/null || bootstrap_fail 'The project IAM resource is not owned by this administrator.'

clients=$(admin_json account api oauth2 client list)
[[ $(jq -r 'if . == null then "array" else type end' <<<"$clients") == array ]] || bootstrap_fail 'The service-account list is invalid.'
client_count=$(jq --arg name "$client_name" '[.[]? | select(.name == $name)] | length' <<<"$clients")
((client_count <= 1)) || bootstrap_fail 'More than one service account has the managed name.'
client_id=
identity=
if ((client_count == 1)); then
  client_id=$(jq -er --arg name "$client_name" '.[] | select(.name == $name) | .clientId' <<<"$clients")
  client=$(admin_json account api oauth2 client get "$client_id")
  jq -e --arg name "$client_name" --arg description "$description" --arg id "$client_id" '
    .name == $name and .description == $description and
    .flow == "CLIENT_CREDENTIALS" and .clientId == $id
  ' <<<"$client" >/dev/null || bootstrap_fail 'A service account has the managed name but different settings.'
  identity=$(jq -er '.identity | strings' <<<"$client") || bootstrap_fail 'The service-account IAM identity is not ready. Retry later.'
  [[ $identity == "urn:v1:${api_region,,}:identity:"* ]] || bootstrap_fail 'The service-account identity is on another API region.'
fi

policies=$(admin_json iam policy list)
[[ $(jq -r 'if . == null then "array" else type end' <<<"$policies") == array ]] || bootstrap_fail 'The IAM policy list is invalid.'
policy_count=$(jq --arg name "$policy_name" '[.[]? | select(.name == $name)] | length' <<<"$policies")
((policy_count <= 1)) || bootstrap_fail 'More than one IAM policy has the managed name.'
policy_id=
policy_needs_update=false
if ((policy_count == 1)); then
  ((client_count == 1)) || bootstrap_fail 'The managed IAM policy exists without its service account.'
  policy_id=$(jq -er --arg name "$policy_name" '.[] | select(.name == $name) | .id' <<<"$policies")
  policy=$(admin_json iam policy get "$policy_id")
  jq -e --arg name "$policy_name" --arg description "$description" \
    --arg owner "$owner" --arg identity "$identity" --arg urn "$resource_urn" \
    '
    .name == $name and .description == $description and .owner == $owner and
    .readOnly == false and .expiredAt == null and
    .identities == [$identity] and
    ([.resources[]?.urn] == [$urn]) and
    ((.permissions.deny // []) | length == 0) and
    ((.permissions.except // []) | length == 0) and
    ((.permissionsGroups // []) | length == 0) and
    ((.conditions // []) | length == 0)
  ' <<<"$policy" >/dev/null || bootstrap_fail 'The existing IAM policy differs from the reviewed project scope or actions.'
  policy_actions=$(jq -c '[.permissions.allow[]?.action] | sort' <<<"$policy")
  [[ $policy_actions == "$(jq -c 'sort' <<<"$actions_json")" ]] || policy_needs_update=true
fi

case $action in
  apply)
    if [[ -z $client_id ]]; then
      identity_pending || bootstrap_fail 'Local credentials exist without the managed service account.'
      client=$(admin_json account api oauth2 client create --name "$client_name" \
        --description "$description" --flow CLIENT_CREDENTIALS)
      client_id=$(jq -er '.details.clientId | select(type == "string" and length > 0)' <<<"$client") \
        || bootstrap_fail 'The service-account response has no client ID.'
      saved_identity=$(jq -ce --arg endpoint "$endpoint" '
        .details | select(.clientSecret | type == "string" and length > 0) |
        {endpoint:$endpoint,client_id:.clientId,client_secret:.clientSecret}' <<<"$client") \
        || bootstrap_fail 'The service-account response has no client secret.'
      save_identity "$saved_identity" || bootstrap_fail 'Could not save the new service-account credential.'
      unset client saved_identity
      client=$(admin_json account api oauth2 client get "$client_id")
      identity=$(jq -er '.identity | strings' <<<"$client") || bootstrap_fail 'The service-account identity is not ready. Retry apply later.'
    else
      ! identity_pending || bootstrap_fail 'The service account exists but its credential is not saved in this installation file.'
      read_credentials
      [[ $(jq -er '.identity.client_id' "$credentials_file") == "$client_id" ]] || bootstrap_fail 'The credential file belongs to another service account.'
    fi
    [[ $identity == "urn:v1:${api_region,,}:identity:"* ]] || bootstrap_fail 'The service-account IAM identity is not ready. Retry apply later.'
    if [[ $policy_needs_update == true ]]; then
      printf '%s\n' "$actions_json" >"$work_dir/policy-actions.json"
      cat >"$work_dir/policy-editor.sh" <<'EOF'
#!/bin/sh
set -eu
temporary=$(mktemp "${1}.XXXXXXXX")
trap 'rm -f -- "$temporary"' EXIT
jq --slurpfile actions "$OVH_POLICY_ACTIONS_FILE" \
  '.permissions.allow = ($actions[0] | map({action: .}))' "$1" >"$temporary"
mv -- "$temporary" "$1"
EOF
      chmod 700 "$work_dir/policy-editor.sh"
      OVH_POLICY_ACTIONS_FILE="$work_dir/policy-actions.json" \
        EDITOR="$work_dir/policy-editor.sh" \
        admin_json iam policy edit "$policy_id" --editor >/dev/null
      policy_updated=false
      for attempt in {1..10}; do
        policy=$(admin_json iam policy get "$policy_id")
        if jq -e --argjson actions "$actions_json" '
          (.permissions.allow // [] | map(.action) | sort) == ($actions | sort)
        ' <<<"$policy" >/dev/null; then
          policy_updated=true
          break
        fi
        ((attempt < 10)) || break
        sleep 2
      done
      [[ $policy_updated == true ]] || bootstrap_fail 'The IAM policy edit did not publish the exact required actions.'
    elif [[ -z $policy_id ]]; then
      create_policy=(iam policy create --name "$policy_name" --description "$description" --identity "$identity" --resource "$resource_urn")
      for permission in "${required_actions[@]}"; do create_policy+=(--allow "$permission"); done
      policy_response=$(admin_json "${create_policy[@]}")
      jq -e '.details.id | type == "string" and length > 0' <<<"$policy_response" >/dev/null || bootstrap_fail 'The policy create response is invalid.'
    fi
    printf 'OVHcloud controller is ready.\nfile: %s\n' "$BOOTSTRAP_CREDENTIALS_FILE"
    ;;

esac

)

# CLOUDFERRO bootstrap
bootstrap_cloudferro() (

usage() { bootstrap_usage cloudferro; }

case ${1:-} in
  -h|--help|help|usage) usage; exit 0 ;;
  configure|show|apply|verify|render-secrets) (($# == 1)) || { usage >&2; exit 2; }; action=$1 ;;
  *) usage >&2; exit 2 ;;
esac

required() {
  local value=${!1:-}
  [[ -n $value ]] || bootstrap_fail "$1 must be set."
  printf '%s' "$value"
}

namespace=$BOOTSTRAP_NAMESPACE
credentials_file=$BOOTSTRAP_CREDENTIALS_FILE

check_project_credentials_file() {
  [[ ! -L $credentials_file && -f $credentials_file ]] || bootstrap_fail 'Run apply before render-secrets; the credential file is missing.'
  [[ $(stat -c '%a:%u' -- "$credentials_file") == "600:$(id -u)" ]] || bootstrap_fail 'The credential file must be owned by you and mode 0600.'
  jq -e '.projects | type == "array" and length > 0' "$credentials_file" >/dev/null \
    || bootstrap_fail 'Run apply to select projects for the configured pattern.'
  jq -e '
    (.identity.auth_url | type == "string" and test("^https://[A-Za-z0-9.-]+(:[0-9]+)?/v3$")) and
    (.identity.region | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.identity.domain_id | type == "string" and test("^[0-9a-fA-F]{32}$")) and
    (.identity.user_id | type == "string" and test("^[0-9a-fA-F]{32}$")) and
    (.identity.user_name | type == "string" and length > 0) and
    (.identity.password | type == "string" and length > 0) and
    all(.projects[]; type == "string" and test("^[0-9a-f]{32}$")) and
    ((.projects | unique | length) == (.projects | length))
  ' "$credentials_file" >/dev/null || bootstrap_fail 'The credential file has an invalid identity or project list.'
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

[[ $action == configure ]] || command -v openstack >/dev/null 2>&1 || bootstrap_fail 'Install openstack before running IAM bootstrap.'

active_login() {
  [[ ${OS_AUTH_TYPE:-} == v3token && -n ${OS_TOKEN:-} ]] || bootstrap_fail 'Source an active v3token OpenStack login; do not paste its token into a file or command.'
  [[ ${OS_AUTH_URL:-} =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/v3$ &&
     ${OS_REGION_NAME:-} =~ ^[A-Za-z0-9._-]+$ ]] || bootstrap_fail 'The active token login needs a Keystone v3 URL and OpenStack region.'
  local token token_project token_domain token_user project_domain
  token=$(openstack token issue -f json 2>/dev/null) || bootstrap_fail 'The active OpenStack token could not be verified.'
  token_user=$(jq -er '.user_id | select(type == "string")' <<<"$token") || bootstrap_fail 'The active OpenStack token has no user ID.'
  token_project=$(jq -r '.project_id // empty' <<<"$token")
  token_domain=$(jq -r '.domain_id // empty' <<<"$token")
  [[ $token_user =~ ^[a-fA-F0-9]{32}$ ]] || bootstrap_fail 'The active OpenStack token user ID is invalid.'
  if [[ -n $token_project ]]; then
    [[ $token_project =~ ^[a-fA-F0-9]{32}$ ]] || bootstrap_fail 'The active OpenStack token project ID is invalid.'
    project_domain=$(openstack project show "$token_project" -f value -c domain_id 2>/dev/null) || bootstrap_fail 'The active OpenStack project domain could not be verified.'
    [[ $project_domain =~ ^[a-fA-F0-9]{32}$ ]] || bootstrap_fail 'The active OpenStack project domain ID is invalid.'
    [[ -z ${OS_PROJECT_ID:-} || $token_project == "$OS_PROJECT_ID" ]] || bootstrap_fail 'The active token and OS_PROJECT_ID disagree.'
    [[ -z ${OS_PROJECT_DOMAIN_ID:-} || $project_domain == "$OS_PROJECT_DOMAIN_ID" ]] || bootstrap_fail 'The active token and OS_PROJECT_DOMAIN_ID disagree.'
    printf '%s\tproject\t%s\t%s\n' "$token_user" "$token_project" "$project_domain"
    return
  fi
  [[ $token_domain =~ ^[a-fA-F0-9]{32}$ ]] || bootstrap_fail 'The active OpenStack token must be scoped to a project or domain.'
  [[ -z ${OS_DOMAIN_ID:-} || $token_domain == "$OS_DOMAIN_ID" ]] || bootstrap_fail 'The active token and OS_DOMAIN_ID disagree.'
  printf '%s\tdomain\t%s\t%s\n' "$token_user" "$token_domain" "$token_domain"
}

for dependency in mktemp sort wc sleep; do
  command -v "$dependency" >/dev/null 2>&1 || bootstrap_fail "Install $dependency before running IAM bootstrap."
done

if [[ $action == apply ]]; then
  for dependency in openssl setsid timeout; do
    command -v "$dependency" >/dev/null 2>&1 || bootstrap_fail "Install $dependency before running IAM bootstrap."
  done
fi
project_pattern=${CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN:-}
[[ -n $project_pattern ]] || project_pattern='^.+-[0-9]{4}$'
domain_id=$(required CROSSPLANE_CLOUDFERRO_DOMAIN_ID)
admin_cloud=$(required CROSSPLANE_CLOUDFERRO_ADMIN_CLOUD)
controller_name=${CROSSPLANE_CLOUDFERRO_CONTROLLER_NAME:-provider-storage-controller}
project_role=${CROSSPLANE_CLOUDFERRO_PROJECT_ROLE:-member}
auth_url=$(required CROSSPLANE_CLOUDFERRO_AUTH_URL)
region=$(required CROSSPLANE_CLOUDFERRO_REGION)

[[ ${project_pattern:0:1} == ^ && ${project_pattern: -1} == '$' ]] || bootstrap_fail 'The project pattern must be anchored with ^ and $.'
if [[ xyz =~ $project_pattern ]]; then :; elif (( $? == 2 )); then bootstrap_fail 'The project pattern is not a valid extended regex.'; fi
[[ $domain_id =~ ^[a-fA-F0-9]{32}$ ]] || bootstrap_fail 'The domain ID must be 32 hexadecimal characters.'
[[ $admin_cloud =~ ^[A-Za-z0-9._-]+$ ]] || bootstrap_fail 'The cloud profile name contains invalid characters.'
[[ $controller_name =~ ^[A-Za-z0-9._-]+$ ]] || bootstrap_fail 'The controller user name contains invalid characters.'
[[ $project_role =~ ^[A-Za-z0-9._-]+$ ]] || bootstrap_fail 'The project role name or ID contains invalid characters.'
[[ $region =~ ^[A-Za-z0-9._-]+$ ]] || bootstrap_fail 'The OpenStack region contains invalid characters.'
[[ $auth_url =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/v3$ ]] || bootstrap_fail 'The Keystone endpoint must be an HTTPS URL that ends in /v3.'

if [[ $action == configure ]]; then save_configuration; exit 0; fi

work_dir=$(mktemp -d /tmp/provider-storage-cloudferro.XXXXXXXX)
trap 'rm -rf -- "$work_dir"' EXIT

# A named profile isolates its source credentials. Before IAM operations, the
# script replaces either source login with one verified domain-scoped token.
openstack_profile() (
  local profile=$1 target_domain=''
  local -a arguments=()
  shift
  cd -- "$work_dir"
  unset OS_DEBUG
  if [[ -n ${bootstrap_domain_token:-} ]]; then
    unset OS_CLOUD OS_CLIENT_CONFIG_FILE OS_AUTH_TOKEN OS_ENDPOINT
    unset OS_USERNAME OS_PASSWORD OS_USER_ID OS_USER_DOMAIN_ID OS_USER_DOMAIN_NAME
    unset OS_PROJECT_ID OS_PROJECT_NAME OS_PROJECT_DOMAIN_ID OS_PROJECT_DOMAIN_NAME
    unset OS_DOMAIN_NAME OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET
    export OS_AUTH_URL=$auth_url
    export OS_AUTH_TYPE=v3token
    export OS_TOKEN=$bootstrap_domain_token
    export OS_DOMAIN_ID=$domain_id
    export OS_REGION_NAME=$region
    if [[ ${OPENSTACK_PASSWORD_PROMPT:-} == 1 ]]; then
      cloudferro_password_prompt openstack "${@}"
    else
      openstack "${@}"
    fi
    exit
  fi
  if [[ $profile == current ]]; then
    unset OS_CLOUD OS_CLIENT_CONFIG_FILE OS_AUTH_TOKEN OS_ENDPOINT
    unset OS_USERNAME OS_PASSWORD OS_USER_ID OS_USER_DOMAIN_ID OS_USER_DOMAIN_NAME
    unset OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET
    while (($#)); do
      case $1 in
        --os-domain-id)
          shift
          (($#)) || bootstrap_fail 'A domain scope is missing its ID.'
          target_domain=$1
          ;;
        *) arguments+=("$1") ;;
      esac
      shift
    done
    if [[ -n $target_domain ]]; then
      [[ $target_domain =~ ^[a-fA-F0-9]{32}$ ]] || bootstrap_fail 'The target domain ID is invalid.'
      unset OS_PROJECT_ID OS_PROJECT_NAME OS_PROJECT_DOMAIN_ID OS_PROJECT_DOMAIN_NAME OS_DOMAIN_NAME
      export OS_DOMAIN_ID=$target_domain
    fi
    if [[ ${OPENSTACK_PASSWORD_PROMPT:-} == 1 ]]; then
      cloudferro_password_prompt openstack --os-region-name "$region" "${arguments[@]}"
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
    cloudferro_password_prompt openstack --os-cloud "$profile" --os-region-name "$region" "$@"
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
      bootstrap_fail 'OpenStack project listing failed. Run openstack project list --long -f json in the same shell to inspect the CLI error.'
    fi
    if [[ ${1:-} == user && ${2:-} == list ]]; then
      scope_description="bootstrap profile $admin_cloud"
      if [[ $admin_cloud == current ]]; then
        scope_description="${login_scope}-scoped login after domain re-scoping"
      fi
      bootstrap_fail "Controller-user discovery failed for the $scope_description. The login needs a domain role that permits identity:list_users in domain $domain_id when the local credential file is missing."
    fi
    bootstrap_fail "Bootstrap OpenStack ${1:-request} failed. Check the token or profile and domain permissions."
  fi
  printf '%s\n' "$result"
}

check_identity_file() {
  [[ ! -L $credentials_file && -f $credentials_file ]] || bootstrap_fail 'Missing shared controller credential file.'
  [[ $(stat -c '%a:%u' -- "$credentials_file") == "600:$(id -u)" ]] || bootstrap_fail 'The controller credential file must be owned by you and mode 0600.'
  jq -e --arg url "$auth_url" --arg region "$region" --arg domain "$domain_id" --arg name "$controller_name" '
    .identity.auth_url == $url and .identity.region == $region and
    .identity.domain_id == $domain and .identity.user_name == $name and
    (.identity.user_id | type == "string" and test("^[a-fA-F0-9]{32}$")) and
    (.identity.password | type == "string" and length > 0) and
    (.projects | type == "array")
  ' "$credentials_file" >/dev/null || bootstrap_fail 'The shared controller credential file has an invalid format or binding.'
}

store_controller_identity() {
  save_identity "$(jq -n --arg url "$auth_url" --arg region "$region" --arg domain "$domain_id" \
    --arg user "$1" --arg userName "$controller_name" --rawfile password "$work_dir/controller-password" \
    '{auth_url:$url,region:$region,domain_id:$domain,user_id:$user,user_name:$userName,password:$password}')"
}

existing_controller_user_id() {
  local users matches count user_id
  if ! users=$(admin_json user list --domain "$domain_id" --long); then
    return 1
  fi
  jq -e 'type == "array" and all(.[]; type == "object" and
    ((.ID // .id) | type == "string") and ((.Name // .name) | type == "string"))' \
    <<<"$users" >/dev/null || bootstrap_fail 'The OpenStack user list is invalid.'
  matches=$(jq --arg name "$controller_name" '
    [.[] | select((.Name // .name) == $name)]
  ' <<<"$users")
  count=$(jq 'length' <<<"$matches")
  ((count <= 1)) || bootstrap_fail "More than one controller user named $controller_name exists in domain $domain_id."
  ((count == 1)) || return 0
  jq -e '.[0] | (if has("Enabled") then .Enabled else .enabled end) == true' \
    <<<"$matches" >/dev/null || bootstrap_fail "Existing controller user $controller_name is disabled."
  user_id=$(jq -er '.[0].ID // .[0].id' <<<"$matches") \
    || bootstrap_fail 'The existing controller user has no ID.'
  [[ $user_id =~ ^[a-fA-F0-9]{32}$ ]] || bootstrap_fail 'The existing controller user ID is invalid.'
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
  ' >"$work_dir/project-clouds.json"
  chmod 600 -- "$work_dir/project-clouds.json"
  unset OS_AUTH_URL OS_AUTH_TYPE OS_USERNAME OS_PASSWORD OS_PROJECT_ID OS_PROJECT_NAME
  unset OS_USER_ID OS_USER_DOMAIN_ID OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_ID
  unset OS_PROJECT_DOMAIN_NAME OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET
  unset OS_TOKEN OS_AUTH_TOKEN OS_ENDPOINT OS_REGION_NAME
  unset OS_DOMAIN_ID OS_DOMAIN_NAME OS_SYSTEM_SCOPE OS_CLOUD
  unset OS_DEBUG
  OS_CLIENT_CONFIG_FILE="$work_dir/project-clouds.json" openstack --os-cloud provider-storage-project "$@"
)

verify_credential() {
  local project_id=$1 user_id=$2 token token_project token_user attempt project project_name
  local max_attempts=12
  check_identity_file
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
  [[ -n $token ]] || bootstrap_fail "The controller cannot issue a token for project $project_id after $max_attempts attempts. Check the project role assignment and activation."
  token_project=$(jq -er '.project_id | select(type == "string")' <<<"$token") || bootstrap_fail "The project-scoped token response for project $project_id has no project ID."
  token_user=$(jq -er '.user_id | select(type == "string")' <<<"$token") || bootstrap_fail "The project-scoped token response for project $project_id has no user ID."
  [[ $token_project == "$project_id" && $token_user == "$user_id" ]] || bootstrap_fail 'The controller credential is scoped to a different project or user.'
  project=$(project_openstack "$project_id" project show "$project_id" -f json 2>/dev/null) \
    || bootstrap_fail "The controller cannot read project $project_id."
  jq -e --arg id "$project_id" --arg domain "$domain_id" '
    .id == $id and .domain_id == $domain and .enabled == true
  ' <<<"$project" >/dev/null || bootstrap_fail "Project $project_id has the wrong domain or is disabled."
  project_name=$(jq -er '.name | select(type == "string" and length > 0)' <<<"$project") \
    || bootstrap_fail "Project $project_id has no name."
  [[ $project_name =~ $project_pattern ]] \
    || bootstrap_fail "Project $project_name ($project_id) does not match $project_pattern. Run apply to refresh the project selection."
  if [[ $BOOTSTRAP_OPERATION == verify ]]; then
    printf '  project: %s (%s)\n' "$project_name" "$project_id"
    verification_check 'Credential authentication'
    verification_check 'Project scope and pattern'
  fi
  project_openstack "$project_id" container list -f json >/dev/null 2>&1 || bootstrap_fail "Project $project_id cannot list Object Storage containers; check activation, region, and role."
  if [[ $BOOTSTRAP_OPERATION == verify ]]; then verification_check 'Object Storage container listing'; fi
}

ensure_user() {
  local user user_id password error_file existing_user_id scope_description
  if [[ -e $credentials_file || -L $credentials_file ]] && ! identity_pending; then
    check_identity_file
    return
  fi
  if ! existing_user_id=$(existing_controller_user_id); then
    return 1
  fi
  if [[ -n $existing_user_id ]]; then
    bootstrap_fail "Controller user $controller_name already exists without saved credentials; use a new controller name or the original installation file."
  fi
  password=$(openssl rand -hex 32) || bootstrap_fail 'Could not generate a controller password.'
  printf '%s' "$password" >"$work_dir/controller-password"
  error_file="$work_dir/user-create.stderr"
  if ! user=$(OPENSTACK_PASSWORD_PROMPT=1 domain_admin user create \
        --domain "$domain_id" --password-prompt \
        --description 'Provider Storage shared controller' "$controller_name" -f json 2>"$error_file"); then
    if grep -Eqi '(^|[^0-9])403([^0-9]|$)|forbidden|not authorized|identity:create_user|policy does not allow' "$error_file"; then
      scope_description="bootstrap profile $admin_cloud"
      if [[ $admin_cloud == current ]]; then
        scope_description="${login_scope}-scoped login after domain re-scoping"
      fi
      bootstrap_fail "OpenStack denied shared controller user creation (HTTP 403). The $scope_description needs identity:create_user permission in domain $domain_id."
    fi
    if grep -Eqi '(^|[^0-9])409([^0-9]|$)|conflict|already exists|duplicate' "$error_file"; then
      bootstrap_fail "Controller user name $controller_name already exists in domain $domain_id. Retry so the script can discover it."
    fi
    if grep -Eqi '(^|[^0-9])401([^0-9]|$)|unauthorized|invalid token|token expired' "$error_file"; then
      bootstrap_fail 'OpenStack rejected the bootstrap login while creating the shared controller user (HTTP 401). Refresh the login and retry.'
    fi
    if grep -Eqi 'password prompt|no terminal detected|no tty|not a tty|end of file|eoferror|input/output error' "$error_file"; then
      bootstrap_fail 'OpenStack could not read the password prompt for the shared controller. Check that the CLI accepts password input without a terminal.'
    fi
    bootstrap_fail 'OpenStack could not create the shared controller user. Check the bootstrap login, domain permissions, and OpenStack CLI error.'
  fi
  user_id=$(jq -er '.id // .ID' <<<"$user") || bootstrap_fail 'The shared controller user response has no ID.'
  [[ $user_id =~ ^[a-fA-F0-9]{32}$ ]] || bootstrap_fail 'The shared controller user ID is invalid.'
  store_controller_identity "$user_id"
  rm -f -- "$work_dir/controller-password"
  check_identity_file
}

ensure_role() {
  local project_id=$1 user_id=$2 error_file
  error_file="$work_dir/role-add.stderr"
  if ! domain_admin role add --user "$user_id" \
      --project "$project_id" "$project_role" >/dev/null 2>"$error_file"; then
    if grep -Eqi '(^|[^0-9])403([^0-9]|$)|forbidden|not authorized|identity:create_grant|policy does not allow' "$error_file"; then
      bootstrap_fail "OpenStack denied project role assignment (HTTP 403). The bootstrap login needs identity:create_grant permission on project $project_id."
    fi
    if grep -Eqi '(^|[^0-9])401([^0-9]|$)|unauthorized|invalid token|token expired' "$error_file"; then
      bootstrap_fail 'OpenStack rejected the bootstrap login during project role assignment (HTTP 401). Refresh the login and retry.'
    fi
    if grep -Eqi 'no role found|role .* not found|could not find role' "$error_file"; then
      bootstrap_fail "OpenStack could not resolve project role $project_role. Set CROSSPLANE_CLOUDFERRO_PROJECT_ROLE to a valid role name or ID."
    fi
    bootstrap_fail "Could not assign project role $project_role to the controller for project $project_id. Check the role and identity:create_grant permission."
  fi
}

write_project_credentials() {
  update_local_json '.projects = $projects' --argjson projects "$(jq -Rn '[inputs | split("\t")[0]]' <"$selected")"
  check_project_credentials_file
}

replacement_password_is_active() (
  local candidate project token
  candidate=$(mktemp "$work_dir/password-check.XXXXXXXX") || return 1
  trap 'rm -f -- "$candidate"' EXIT
  jq '.identity = .rotation.next_identity' "$credentials_file" >"$candidate" || return 1
  credentials_file=$candidate
  project=$(jq -er '.projects[0]' "$candidate") || return 1
  token=$(project_openstack "$project" token issue -f json 2>/dev/null) || return 1
  jq -e --arg user "$controller_user_id" --arg project "$project" \
    '.user_id == $user and .project_id == $project' <<<"$token" >/dev/null
)

rotate_controller_password() {
  local password new_rotation=0
  if ! rotation_pending; then
    new_rotation=1
    password=$(openssl rand -hex 32) || bootstrap_fail 'Could not generate a controller password.'
    update_local_json '.rotation = {previous_identity:.identity,next_identity:(.identity + {password:$password})}' \
      --arg password "$password"
    unset password
  fi
  jq -e --arg user "$controller_user_id" '
    .rotation as $rotation |
    $rotation.next_identity.user_id == $user and
    ($rotation.next_identity | del(.password)) == ($rotation.previous_identity | del(.password)) and
    ($rotation.next_identity.password | type == "string" and length > 0 and (test("[\\r\\n]") | not))
  ' "$credentials_file" >/dev/null || bootstrap_fail 'Invalid CloudFerro rotation identity.'
  if ! jq -e '.identity.password == .rotation.next_identity.password' "$credentials_file" >/dev/null; then
    # Resolve an interrupted cloud update before attempting another password reset.
    if [[ $new_rotation == 0 ]] && replacement_password_is_active; then
      promote_rotation
    else
      jq -jr '.rotation.next_identity.password' "$credentials_file" >"$work_dir/controller-password"
      if ! OPENSTACK_PASSWORD_PROMPT=1 domain_admin user set --password-prompt "$controller_user_id" \
          >/dev/null 2>"$work_dir/password-update.stderr"; then
        bootstrap_fail 'Could not change the controller password. Recovery state is retained; rerun apply.'
      fi
      rm -f -- "$work_dir/controller-password"
      promote_rotation
    fi
  fi
  verify_rotation
  update_local_json 'del(.rotation)'
  printf 'CloudFerro controller credentials rotated.\n'
}

if [[ $action == verify ]]; then
  check_project_credentials_file
  controller_user_id=$(jq -er '.identity.user_id' "$credentials_file")
  verification_header CloudFerro domain "$domain_id" region "$region" \
    user "$controller_user_id" endpoint "$auth_url"
  while IFS= read -r project_id; do
    verify_credential "$project_id" "$controller_user_id"
  done < <(jq -r '.projects[]' "$credentials_file")
  exit 0
fi

if [[ $admin_cloud == current ]]; then
  login=$(active_login)
  IFS=$'\t' read -r login_user login_scope login_scope_id login_domain <<<"$login"
  [[ ${OS_AUTH_URL:-} == "$auth_url" && ${OS_REGION_NAME:-} == "$region" &&
     $login_domain == "$domain_id" ]] || bootstrap_fail 'The active login does not match the configured Keystone URL, OpenStack region, or project domain.'

fi
bootstrap_domain_token=$(openstack_profile "$admin_cloud" --os-domain-id "$domain_id" \
  token issue -f value -c id 2>/dev/null) \
  || bootstrap_fail "Could not issue a token scoped to domain $domain_id."
[[ -n $bootstrap_domain_token && $bootstrap_domain_token != *$'\n'* &&
   $bootstrap_domain_token != *$'\r'* ]] \
  || bootstrap_fail 'The domain-scoped OpenStack token is empty or invalid.'
domain_token_details=$(openstack_profile "$admin_cloud" token issue -f json 2>/dev/null) \
  || bootstrap_fail 'The domain-scoped OpenStack token could not be verified.'
domain_token_user=$(jq -er '.user_id | select(type == "string")' \
  <<<"$domain_token_details") || bootstrap_fail 'The domain-scoped OpenStack token has no user ID.'
domain_token_domain=$(jq -er '.domain_id | select(type == "string")' \
  <<<"$domain_token_details") || bootstrap_fail 'The OpenStack bootstrap token is not domain-scoped.'
domain_token_project=$(jq -r '.project_id // empty' <<<"$domain_token_details")
[[ $domain_token_user =~ ^[a-fA-F0-9]{32}$ &&
   $domain_token_domain == "$domain_id" && -z $domain_token_project ]] \
  || bootstrap_fail 'The OpenStack bootstrap token has the wrong user, domain, or project scope.'
if [[ $admin_cloud == current ]]; then
  [[ $domain_token_user == "$login_user" ]] \
    || bootstrap_fail 'Domain re-scoping changed the OpenStack bootstrap user.'
fi
projects=$(admin_json project list --long)
jq -e 'type == "array" and all(.[]; type == "object" and
  ((.ID // .id) | type == "string") and ((.Name // .name) | type == "string"))' \
  <<<"$projects" >/dev/null || bootstrap_fail 'Project list is invalid.'
selected="$work_dir/selected-projects.tsv"
: >"$selected"
while IFS=$'\t' read -r project_id project_name project_domain project_enabled; do
  [[ $project_name =~ $project_pattern ]] || continue
  [[ $project_id =~ ^[a-f0-9]{32}$ ]] || bootstrap_fail "Matching project $project_name has an invalid ID."
  [[ $project_domain != - ]] || bootstrap_fail "Matching project $project_name has no domain ID in the project list."
  [[ $project_domain == "$domain_id" ]] || continue
  [[ $project_enabled == true ]] || bootstrap_fail "Matching project $project_name is disabled or has no enabled state in the project list."
  printf '%s\t%s\n' "$project_id" "$project_name" >>"$selected"
done < <(jq -r '.[] | [(.ID // .id),(.Name // .name),
  (."Domain ID" // .domain_id // "-"),
  (if has("Enabled") then .Enabled elif has("enabled") then .enabled else .is_enabled end | tostring)] | @tsv' <<<"$projects")
if [[ ! -s $selected ]]; then
  bootstrap_fail 'No visible projects in the selected domain match the project pattern.'
fi
[[ $(wc -l <"$selected") -le 10000 ]] || bootstrap_fail 'The project pattern selected more than 10000 projects.'
LC_ALL=C sort -t $'\t' -k1,1 "$selected" -o "$selected"
ensure_user

controller_user_id=$(jq -r '.identity.user_id' "$credentials_file")

if [[ $action == apply ]]; then
  if rotation_pending; then
    rotate_controller_password
    exit 0
  fi
  while IFS=$'\t' read -r project_id project_name; do
    ensure_role "$project_id" "$controller_user_id"
    verify_credential "$project_id" "$controller_user_id"
  done <"$selected"

  write_project_credentials
  if [[ $BOOTSTRAP_ROTATE == 1 ]]; then rotate_controller_password; fi
  printf 'CloudFerro controller is ready.\nfile: %s\n' "$credentials_file"
  exit 0
fi

)

case ${1:-} in
  -h|--help|help|usage) bootstrap_usage; exit 0 ;;
  aws|otc|ovh|cloudferro) BOOTSTRAP_BACKEND=$1 ;;
  *) bootstrap_usage >&2; exit 2 ;;
esac
shift
operation=${1:-}
(($#)) && shift
BOOTSTRAP_ROTATE=0
while (($#)); do
  case $1 in
    --rotate-credentials) BOOTSTRAP_ROTATE=1; shift ;;
    *) bootstrap_fail "Unknown argument: $1" ;;
  esac
done
case $operation in
  -h|--help|help|usage) bootstrap_usage "$BOOTSTRAP_BACKEND"; exit ;;
  configure|show|apply|verify|render-secrets) ;;
  *) bootstrap_usage >&2; exit 2 ;;
esac
if [[ $BOOTSTRAP_ROTATE == 1 ]]; then
  [[ $operation == apply ]] \
    || bootstrap_fail '--rotate-credentials requires apply.'
  [[ $BOOTSTRAP_BACKEND != ovh ]] || bootstrap_fail 'OVHcloud service-account rotation is manual; --rotate-credentials is not supported.'
fi
set -- "$operation"

case $BOOTSTRAP_BACKEND in
  aws) BOOTSTRAP_SETTINGS=(
    AWS_REGION
    AWS_DEFAULT_REGION
    CROSSPLANE_AWS_ACCOUNT_ID
    CROSSPLANE_AWS_AUTH_MODE
    CROSSPLANE_AWS_MANAGED_POLICY_PATH
    CROSSPLANE_AWS_MANAGED_USER_PATH
    CROSSPLANE_AWS_POLICY_NAME
    CROSSPLANE_AWS_RESOURCE_PREFIX
    CROSSPLANE_AWS_ROLE_NAME
    CROSSPLANE_AWS_ROLE_PATH
    CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN
    CROSSPLANE_AWS_USER_NAME
    CROSSPLANE_AWS_USER_PATH
    CROSSPLANE_AWS_USER_POLICY_NAME
) ;;
  otc) BOOTSTRAP_SETTINGS=(
    CROSSPLANE_OTC_AUTH_URL
    CROSSPLANE_OTC_DOMAIN_ID
    CROSSPLANE_OTC_GROUP_NAME
    CROSSPLANE_OTC_PROJECT_ID
    CROSSPLANE_OTC_REGION
    CROSSPLANE_OTC_OBS_ENDPOINT
    CROSSPLANE_OTC_RESOURCE_PREFIX
    CROSSPLANE_OTC_USER_NAME
) ;;
  ovh) BOOTSTRAP_SETTINGS=(
    CROSSPLANE_OVH_API_REGION
    CROSSPLANE_OVH_PROJECT_ID
    CROSSPLANE_OVH_STORAGE_REGION
) ;;
  cloudferro) BOOTSTRAP_SETTINGS=(
    CROSSPLANE_CLOUDFERRO_ADMIN_CLOUD
    CROSSPLANE_CLOUDFERRO_AUTH_URL
    CROSSPLANE_CLOUDFERRO_CONTROLLER_NAME
    CROSSPLANE_CLOUDFERRO_DOMAIN_ID
    CROSSPLANE_CLOUDFERRO_PROJECT_PATTERN
    CROSSPLANE_CLOUDFERRO_PROJECT_ROLE
    CROSSPLANE_CLOUDFERRO_REGION
) ;;
esac
for dependency in jq stat dirname basename id realpath; do
  command -v "$dependency" >/dev/null 2>&1 || bootstrap_fail "Missing required command: $dependency"
done
BOOTSTRAP_NAMESPACE_VARIABLE="CROSSPLANE_${BOOTSTRAP_BACKEND^^}_NAMESPACE"
BOOTSTRAP_NAMESPACE=${!BOOTSTRAP_NAMESPACE_VARIABLE:-workspace}
[[ $BOOTSTRAP_NAMESPACE =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#BOOTSTRAP_NAMESPACE} -le 63 ]] \
  || bootstrap_fail 'The Kubernetes namespace is invalid.'
credentials_variable="CROSSPLANE_${BOOTSTRAP_BACKEND^^}_CREDENTIALS_FILE"
BOOTSTRAP_CREDENTIALS_FILE=${!credentials_variable:-}
if [[ -z $BOOTSTRAP_CREDENTIALS_FILE ]]; then
  config_directory=${PROVIDER_STORAGE_CONFIG_DIR:-}
  if [[ -z $config_directory ]]; then
    [[ ${HOME:-} == /* ]] || bootstrap_fail 'HOME must be an absolute path for the default credential directory.'
    config_directory="$HOME/.config/provider-storage"
  fi
  [[ $config_directory == /* ]] || bootstrap_fail 'PROVIDER_STORAGE_CONFIG_DIR must be an absolute path.'
  BOOTSTRAP_CREDENTIALS_FILE="$config_directory/$BOOTSTRAP_BACKEND-creds.json"
fi
[[ $BOOTSTRAP_CREDENTIALS_FILE == /* ]] || bootstrap_fail "$credentials_variable must be an absolute path."
printf -v "$credentials_variable" '%s' "$BOOTSTRAP_CREDENTIALS_FILE"
BOOTSTRAP_OPERATION=$1
validate_local_file
if [[ $1 != render-secrets && $1 != show ]]; then
  load_bootstrap_context
  if [[ $1 == configure ]]; then
    ! rotation_pending || bootstrap_fail 'Rerun apply to finish the pending rotation before configuring this installation.'
    for dependency in realpath mktemp chmod mkdir mv rm cmp cat; do
      command -v "$dependency" >/dev/null 2>&1 || bootstrap_fail "Missing required command: $dependency"
    done
    configure_session
    bootstrap_"$BOOTSTRAP_BACKEND" configure
    exit
  fi
  require_complete_configuration
  BOOTSTRAP_VALIDATE_ONLY=1 bootstrap_"$BOOTSTRAP_BACKEND" configure
  if [[ $BOOTSTRAP_ROTATE == 1 ]]; then
    ! identity_pending || bootstrap_fail 'Apply the installation before rotating its credentials.'
    if [[ $BOOTSTRAP_BACKEND == aws && $CROSSPLANE_AWS_AUTH_MODE != static-user ]]; then
      bootstrap_fail 'AWS assume-role source credentials are managed externally; only static-user credentials can be rotated.'
    fi
  fi
  dependencies=(mktemp chmod mkdir mv rm)
  case $BOOTSTRAP_BACKEND in
    aws) dependencies+=(aws grep sleep) ;;
    otc) if [[ $1 == verify ]]; then dependencies+=(curl grep); else dependencies+=(openstack curl grep); fi ;;
    ovh) dependencies+=(ovhcloud sleep) ;;
    cloudferro) dependencies+=(openstack sort wc sleep grep) ;;
  esac
  for dependency in "${dependencies[@]}"; do
    command -v "$dependency" >/dev/null 2>&1 || bootstrap_fail "Missing required command: $dependency"
  done
  if [[ $BOOTSTRAP_BACKEND == ovh && $1 == apply ]]; then
    [[ -n ${CROSSPLANE_OVH_STORAGE_REGION:-} ]] || bootstrap_fail 'Run configure to set the Object Storage region.'
  fi
  if [[ $BOOTSTRAP_BACKEND == ovh && -n ${CROSSPLANE_OVH_STORAGE_REGION:-} ]]; then
    [[ $CROSSPLANE_OVH_STORAGE_REGION =~ ^[A-Z0-9-]+$ ]] || bootstrap_fail 'The OVHcloud Object Storage region is invalid.'
  fi
fi
BOOTSTRAP_OPERATION=$1
if [[ $BOOTSTRAP_OPERATION == show ]]; then
  if [[ ! -e $BOOTSTRAP_CREDENTIALS_FILE ]]; then
    printf 'file: %s (missing)\n' "$BOOTSTRAP_CREDENTIALS_FILE"
  else
    show_configuration
  fi
else
  if [[ $BOOTSTRAP_OPERATION == render-secrets ]] && identity_pending; then
    bootstrap_fail 'Run apply before render-secrets; the identity section has no credentials.'
  fi
  if [[ $BOOTSTRAP_OPERATION == render-secrets ]] && rotation_pending; then
    bootstrap_fail 'Rerun apply to finish the pending rotation before render-secrets.'
  fi
  bootstrap_"$BOOTSTRAP_BACKEND" "$@"
fi
