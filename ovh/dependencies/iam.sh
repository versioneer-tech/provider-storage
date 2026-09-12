#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

# Never trace the one-time OAuth2 client secret, even when called with bash -x.
set +x
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: ovh/dependencies/iam.sh <status|apply|verify>

Prepare a project-scoped OVHcloud controller service account. Review this
script and ovh/dependencies/README.md before apply.

Required environment:
  CROSSPLANE_OVH_PROJECT_ID        Exact 32-character Public Cloud project ID.

Optional environment:
  CROSSPLANE_OVH_API_REGION        EU, CA, or US (default EU).
  CROSSPLANE_OVH_CREDENTIALS_FILE  Override the controller JSON output path.
                                   Default: ~/.ovh-provider-storage-<project-id>.json
  CROSSPLANE_OVH_OTHER_PROJECT_ID  Optional second project for a denied-access check.

Install the official ovhcloud CLI and jq. By default, the CLI reads the
administrator login from ~/.ovh.conf. The script writes a separate controller
JSON file in your home directory; never set its path to ~/.ovh.conf. Run
status before apply. No credential or client secret is printed.
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  status|apply|verify)
    if (($# != 1)); then usage >&2; exit 2; fi
    action=$1
    ;;
  *) usage >&2; exit 2 ;;
esac

for dependency in ovhcloud jq realpath stat mktemp; do
  command -v "$dependency" >/dev/null 2>&1 || die "Install $dependency before running IAM bootstrap."
done

project_id=${CROSSPLANE_OVH_PROJECT_ID:-}
[[ $project_id =~ ^[0-9a-f]{32}$ ]] || die 'CROSSPLANE_OVH_PROJECT_ID must be an exact 32-character lowercase hexadecimal ID.'
api_region=${CROSSPLANE_OVH_API_REGION:-EU}
[[ $api_region =~ ^(EU|CA|US)$ ]] || die 'CROSSPLANE_OVH_API_REGION must be EU, CA, or US.'
endpoint="ovh-${api_region,,}"
if [[ -n ${OVH_ENDPOINT:-} && ${OVH_ENDPOINT} != "$endpoint" ]]; then
  die "OVH_ENDPOINT must be $endpoint for this project."
fi
other_project_id=${CROSSPLANE_OVH_OTHER_PROJECT_ID:-}
if [[ -n $other_project_id ]]; then
  [[ $other_project_id =~ ^[0-9a-f]{32}$ && $other_project_id != "$project_id" ]] || die 'The second project ID must be different and contain exactly 32 lowercase hexadecimal characters.'
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_dir=$(realpath -- "$script_dir/../..")
if [[ -n ${CROSSPLANE_OVH_CREDENTIALS_FILE:-} ]]; then
  credentials_file=$CROSSPLANE_OVH_CREDENTIALS_FILE
else
  [[ ${HOME:-} = /* && -d ${HOME:-} ]] || die 'HOME must be an existing absolute directory for the default controller credential file.'
  credentials_file="$HOME/.ovh-provider-storage-${project_id}.json"
fi
recovery_file=

check_credentials_path() {
  [[ $credentials_file = /* ]] || die 'CROSSPLANE_OVH_CREDENTIALS_FILE must be an absolute path.'
  [[ $(basename -- "$credentials_file") != .ovh.conf ]] || die 'The controller JSON must not replace the CLI login. Unset CROSSPLANE_OVH_CREDENTIALS_FILE to use a separate default.'
  [[ ! -L $credentials_file ]] || die 'The credential file must not be a symbolic link.'
  local parent resolved
  parent=$(dirname -- "$credentials_file")
  [[ -d $parent ]] || die 'The credential-file parent directory must exist.'
  resolved="$(realpath -e -- "$parent")/$(basename -- "$credentials_file")"
  [[ $resolved != "$repository_dir"/* ]] || die 'The credential file must be outside the Git repository.'
  if [[ -e $credentials_file ]]; then
    [[ -f $credentials_file ]] || die 'The credential path must be a regular file.'
    [[ $(stat -c '%a:%u' -- "$credentials_file") == "600:$(id -u)" ]] || die 'The existing credential file must be owned by you and mode 0600.'
  fi
}

check_credentials_path
recovery_file="${credentials_file}.recovery"
[[ ! -L $recovery_file ]] || die 'The recovery path must not be a symbolic link.'
if [[ -e $recovery_file ]]; then
  [[ -f $recovery_file ]] || die 'The recovery path must be a regular file.'
  [[ $(stat -c '%a:%u' -- "$recovery_file") == "600:$(id -u)" ]] || die 'The recovery file must be owned by you and mode 0600.'
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
  publicCloudProject:apiovh:region/storage/edit
  publicCloudProject:apiovh:region/storage/get
)
actions_json=$(printf '%s\n' "${required_actions[@]}" | jq -R . | jq -s .)
previous_actions_json=$(jq -c 'map(select(. != "publicCloudProject:apiovh:user/openrc/get"))' <<<"$actions_json")
duplicated_actions_json=$(jq -nc \
  --argjson previous "$previous_actions_json" --argjson current "$actions_json" \
  '$previous + $current | sort')
client_name="provider-storage-bootstrap-${project_id:0:12}"
policy_name="provider-storage-controller-${project_id:0:12}"
description="Provider Storage controller for project $project_id. Managed by ovh/dependencies/iam.sh."

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
    die "ovhcloud ${1:-request} failed. Check administrator authentication and the selected project."
  fi
  printf '%s\n' "$result"
}

read_credentials() {
  [[ -f $credentials_file ]] || die 'The private credential file is missing.'
  check_credentials_path
  jq -e --arg endpoint "$endpoint" '
    type == "object" and
    (keys | sort) == ["client_id", "client_secret", "endpoint"] and
    .endpoint == $endpoint and
    (.client_id | type == "string" and length > 0) and
    (.client_secret | type == "string" and length > 0)
  ' "$credentials_file" >/dev/null || die 'The credential file has the wrong format or API region.'
}

publish_credentials() {
  local source=$1 expected_client_id=$2 temporary
  temporary=$(mktemp "$(dirname -- "$credentials_file")/.provider-ovh.XXXXXXXX") ||
    die 'Could not prepare the private credential file. The recovery file is retained.'
  if ! jq -e --arg endpoint "$endpoint" --arg id "$expected_client_id" '
    select(.details.clientId == $id and
      (.details.clientSecret | type == "string" and length > 0)) |
    {endpoint: $endpoint, client_id: .details.clientId, client_secret: .details.clientSecret}
  ' "$source" >"$temporary"; then
    rm -f -- "$temporary"
    die 'Could not convert the one-time secret. The recovery file is retained.'
  fi
  chmod 600 -- "$temporary"
  if ! ln -T -- "$temporary" "$credentials_file"; then
    rm -f -- "$temporary"
    die 'Could not publish credentials without overwriting a file. The recovery file is retained.'
  fi
  rm -f -- "$temporary"
}

check_recovery_client() {
  local expected_client_id=$1
  [[ -f $recovery_file ]] || die 'The credential file is missing and no recovery file exists.'
  jq -e --arg id "$expected_client_id" '
    .details.clientId == $id and
    (.details.clientSecret | type == "string" and length > 0)
  ' "$recovery_file" >/dev/null || die 'The recovery file does not match the managed service account.'
}

service_json() (
  local client_id client_secret
  read_credentials
  client_id=$(jq -er '.client_id' "$credentials_file")
  client_secret=$(jq -er '.client_secret' "$credentials_file")
  cd -- "$work_dir"
  export HOME="$work_dir" OVH_ENDPOINT="$endpoint" OVH_CLIENT_ID="$client_id" OVH_CLIENT_SECRET="$client_secret" OVH_PROFILE=default
  unset OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY OVH_ACCESS_TOKEN
  ovhcloud "$@" -o json 2>/dev/null
)

project=$(admin_json cloud project get "$project_id")
jq -e --arg id "$project_id" '.id == $id' <<<"$project" >/dev/null || die 'The administrator session returned a different project.'
resource_urn=$(jq -er '.iam.urn | strings' <<<"$project") || die 'The project has no IAM resource URN.'
[[ $resource_urn == "urn:v1:${api_region,,}:resource:"* ]] || die 'The project IAM resource is on another API region.'
me=$(admin_json account get)
owner=$(jq -er '.nichandle | strings' <<<"$me") || die 'The administrator account could not be identified.'
resource=$(admin_json iam resource get "$resource_urn")
jq -e --arg urn "$resource_urn" --arg owner "$owner" '.urn == $urn and .owner == $owner' <<<"$resource" >/dev/null || die 'The project IAM resource is not owned by this administrator.'

clients=$(admin_json account api oauth2 client list)
[[ $(jq -r 'if . == null then "array" else type end' <<<"$clients") == array ]] || die 'The service-account list is invalid.'
client_count=$(jq --arg name "$client_name" '[.[]? | select(.name == $name)] | length' <<<"$clients")
((client_count <= 1)) || die 'More than one service account has the managed name.'
client_id=
identity=
if ((client_count == 1)); then
  client_id=$(jq -er --arg name "$client_name" '.[] | select(.name == $name) | .clientId' <<<"$clients")
  client=$(admin_json account api oauth2 client get "$client_id")
  jq -e --arg name "$client_name" --arg description "$description" --arg id "$client_id" '
    .name == $name and .description == $description and
    .flow == "CLIENT_CREDENTIALS" and .clientId == $id
  ' <<<"$client" >/dev/null || die 'A service account has the managed name but different settings.'
  identity=$(jq -er '.identity | strings' <<<"$client") || die 'The service-account IAM identity is not ready. Retry later.'
  [[ $identity == "urn:v1:${api_region,,}:identity:"* ]] || die 'The service-account identity is on another API region.'
fi

policies=$(admin_json iam policy list)
[[ $(jq -r 'if . == null then "array" else type end' <<<"$policies") == array ]] || die 'The IAM policy list is invalid.'
policy_count=$(jq --arg name "$policy_name" '[.[]? | select(.name == $name)] | length' <<<"$policies")
((policy_count <= 1)) || die 'More than one IAM policy has the managed name.'
policy_id=
policy_needs_update=false
if ((policy_count == 1)); then
  ((client_count == 1)) || die 'The managed IAM policy exists without its service account.'
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
  ' <<<"$policy" >/dev/null || die 'The existing IAM policy differs from the reviewed project scope or actions.'
  policy_actions=$(jq -c '[.permissions.allow[]?.action] | sort' <<<"$policy")
  if [[ $policy_actions == "$(jq -c 'sort' <<<"$actions_json")" ]]; then
    :
  elif [[ $policy_actions == "$(jq -c 'sort' <<<"$previous_actions_json")" ||
          $policy_actions == "$duplicated_actions_json" ]]; then
    policy_needs_update=true
  else
    die 'The existing IAM policy differs from the reviewed project scope or actions.'
  fi
fi

case $action in
  status)
    printf 'Project: %s\nAPI region: %s\nIAM resource: %s\n' "$project_id" "$api_region" "$resource_urn"
    printf 'Controller service account: %s (%s)\n' "$client_name" "$([[ -n $client_id ]] && printf present || printf missing)"
    policy_state=missing
    if [[ -n $policy_id ]]; then
      policy_state=present
      [[ $policy_needs_update == false ]] || policy_state='needs action update'
    fi
    printf 'IAM policy: %s (%s)\n' "$policy_name" "$policy_state"
    printf 'Requested project actions:\n'
    printf '  %s\n' "${required_actions[@]}"
    [[ -f $credentials_file ]] && printf 'Credentials file: %s (present, mode 0600)\n' "$credentials_file" || printf 'Credentials file: %s (missing)\n' "$credentials_file"
    [[ ! -f $recovery_file ]] || printf 'One-time secret recovery file: %s (present, mode 0600)\n' "$recovery_file"
    ;;
  apply)
    if [[ -z $client_id ]]; then
      [[ ! -e $credentials_file && ! -e $recovery_file ]] || die 'Credential or recovery file exists without the managed service account.'
      if ! (set -C; ovhcloud account api oauth2 client create \
        --name "$client_name" --description "$description" \
        --flow CLIENT_CREDENTIALS -o json >"$recovery_file" 2>/dev/null); then
        if ! jq -e '
          (.details.clientId | type == "string" and length > 0) and
          (.details.clientSecret | type == "string" and length > 0)
        ' "$recovery_file" >/dev/null 2>&1; then
          rm -f -- "$recovery_file"
        fi
        die 'Service-account creation failed. Check administrator rights and the account list before retrying.'
      fi
      client_id=$(jq -er '.details.clientId | strings' "$recovery_file") || die 'The service-account response has no client ID. The recovery file is retained.'
      check_recovery_client "$client_id"
      publish_credentials "$recovery_file" "$client_id"
      client=$(admin_json account api oauth2 client get "$client_id")
      identity=$(jq -er '.identity | strings' <<<"$client") || die 'The service-account identity is not ready. Retry apply later.'
    else
      if [[ ! -e $credentials_file && -f $recovery_file ]]; then
        check_recovery_client "$client_id"
        publish_credentials "$recovery_file" "$client_id"
      fi
      read_credentials
      [[ $(jq -er '.client_id' "$credentials_file") == "$client_id" ]] || die 'The credential file belongs to another service account.'
      if [[ -f $recovery_file ]]; then
        check_recovery_client "$client_id"
        [[ $(jq -er '.details.clientSecret' "$recovery_file") == "$(jq -er '.client_secret' "$credentials_file")" ]] ||
          die 'The recovery file conflicts with the credential file.'
      fi
    fi
    [[ $identity == "urn:v1:${api_region,,}:identity:"* ]] || die 'The service-account IAM identity is not ready. Retry apply later.'
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
      [[ $policy_updated == true ]] || die 'The IAM policy edit did not publish the exact required actions.'
    elif [[ -z $policy_id ]]; then
      create_policy=(iam policy create --name "$policy_name" --description "$description" --identity "$identity" --resource "$resource_urn")
      for permission in "${required_actions[@]}"; do create_policy+=(--allow "$permission"); done
      policy_response=$(admin_json "${create_policy[@]}")
      jq -e '.details.id | type == "string" and length > 0' <<<"$policy_response" >/dev/null || die 'The policy create response is invalid.'
    fi
    [[ ! -f $recovery_file ]] || rm -f -- "$recovery_file"
    printf 'OVHcloud Provider Storage controller identity is ready.\n'
    printf 'Project: %s\nAPI region: %s\n' "$project_id" "$api_region"
    printf 'Controller service account: %s\nIAM policy: %s\n' "$client_name" "$policy_name"
    printf 'IAM resource: %s\nCredentials file: %s\n' "$resource_urn" "$credentials_file"
    ;;
  verify)
    [[ -n $client_id && -n $policy_id ]] || die 'Run apply before verify.'
    [[ $policy_needs_update == false ]] || die 'The IAM policy needs the user/openrc/get action. Run apply before verify.'
    read_credentials
    [[ $(jq -er '.client_id' "$credentials_file") == "$client_id" ]] || die 'The credential file belongs to another service account.'
    service_project=$(service_json cloud project get "$project_id") || die 'The service account could not read the target project.'
    jq -e --arg id "$project_id" '.id == $id' <<<"$service_project" >/dev/null || die 'The service account read a different project.'
    service_json cloud user list --cloud-project "$project_id" >/dev/null || die 'The service account could not list target-project users.'
    printf 'Service account read the target project and its users.\n'
    if [[ -z $other_project_id ]]; then
      printf 'Optional second-project denial check skipped; no second project is required.\n'
      exit 0
    fi
    other=$(admin_json cloud project get "$other_project_id")
    jq -e --arg id "$other_project_id" '.id == $id' <<<"$other" >/dev/null || die 'The administrator could not confirm the second project.'
    if denied_result=$(service_json cloud project get "$other_project_id"); then
      die 'The service account can read the second project.'
    fi
    jq -e '.message | type == "string" and test("403|forbidden|access denied"; "i")' <<<"$denied_result" >/dev/null || die 'The second-project result was not a clear forbidden-access response.'
    printf 'Cross-project project read was denied by OVHcloud.\n'
    ;;
esac
