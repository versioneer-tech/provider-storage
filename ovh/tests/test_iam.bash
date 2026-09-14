#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/ovh/dependencies/iam.sh"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

target_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
other_id=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
client_id=client-12345678
client_secret=fake-private-value
resource_urn="urn:v1:eu:resource:publicCloudProject:$target_id"
identity_urn="urn:v1:eu:identity:credential:$client_id"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$test_root/bin"
cat >"$test_root/bin/ovhcloud" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

state=$TEST_STATE_DIR
printf '%s\n' "$*" >>"$state/calls"
if [[ -n ${OVH_CLIENT_ID:-} ]]; then
  [[ $OVH_CLIENT_ID == "$TEST_CLIENT_ID" &&
     $OVH_CLIENT_SECRET == "$TEST_CLIENT_SECRET" &&
     $OVH_ENDPOINT == ovh-eu &&
     $HOME != "$TEST_ADMIN_HOME" &&
     -z ${OVH_APPLICATION_KEY:-} && -z ${OVH_APPLICATION_SECRET:-} &&
     -z ${OVH_CONSUMER_KEY:-} && -z ${OVH_ACCESS_TOKEN:-} &&
     ${OVH_PROFILE:-} == default && -f ./ovh.conf ]] || exit 55
  grep -Eq '^application_key=$' ./ovh.conf || exit 59
  grep -Eq '^application_secret=$' ./ovh.conf || exit 59
  grep -Eq '^consumer_key=$' ./ovh.conf || exit 59
  grep -Eq '^access_token=$' ./ovh.conf || exit 59
  printf 'isolated\n' >>"$state/service-calls"
else
  [[ $HOME == "$TEST_ADMIN_HOME" ]] || exit 56
fi

command_line="$*"
if [[ $command_line == 'cloud project get '* ]]; then
  id=$4
  if [[ -z ${OVH_CLIENT_ID:-} && $id == "$TEST_TARGET_ID" &&
        $TEST_PROJECT_MODE == wrong ]]; then
    id=$TEST_OTHER_ID
  fi
  printf '{"id":"%s","iam":{"urn":"%s"}}\n' "$id" "$TEST_RESOURCE_URN"
elif [[ $command_line == 'account get '* ]]; then
  printf '{"nichandle":"admin-account"}\n'
elif [[ $command_line == 'iam resource get '* ]]; then
  owner=admin-account
  [[ $TEST_RESOURCE_MODE != foreign ]] || owner=another-account
  printf '{"urn":"%s","owner":"%s"}\n' "$TEST_RESOURCE_URN" "$owner"
elif [[ $command_line == 'account api oauth2 client list '* ]]; then
  if [[ -f $state/client.json ]]; then jq -s '.' "$state/client.json"; else printf '[]\n'; fi
elif [[ $command_line == 'account api oauth2 client get '* ]]; then
  cat "$state/client.json"
elif [[ $command_line == 'iam policy list '* ]]; then
  if [[ -f $state/policy.json ]]; then
    jq -s '[.[] | {id,name,owner,readOnly}]' "$state/policy.json"
  else
    printf 'null\n'
  fi
elif [[ $command_line == 'iam policy get '* ]]; then
  cat "$state/policy.json"
elif [[ $command_line == 'account api oauth2 client create '* ]]; then
  if [[ $TEST_CREATE_MODE == failure ]]; then
    printf '{"message":"403 Forbidden","error":true}\n'
    exit 1
  fi
  name= description= flow=
  while (($#)); do
    case $1 in
      --name) name=$2; shift 2 ;;
      --description) description=$2; shift 2 ;;
      --flow) flow=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ $flow == CLIENT_CREDENTIALS ]] || exit 57
  jq -n --arg id "$TEST_CLIENT_ID" --arg name "$name" \
    --arg description "$description" --arg identity "$TEST_IDENTITY_URN" \
    '{clientId:$id,name:$name,description:$description,flow:"CLIENT_CREDENTIALS",identity:$identity}' \
    >"$state/client.json"
  jq -n --arg id "$TEST_CLIENT_ID" --arg secret "$TEST_CLIENT_SECRET" \
    '{message:("client secret: " + $secret),details:{clientId:$id,clientSecret:$secret}}'
elif [[ $command_line == 'iam policy create '* ]]; then
  name= description= identity= resource=
  actions=()
  while (($#)); do
    case $1 in
      --name) name=$2; shift 2 ;;
      --description) description=$2; shift 2 ;;
      --identity) identity=$2; shift 2 ;;
      --resource) resource=$2; shift 2 ;;
      --allow) actions+=("$2"); shift 2 ;;
      *) shift ;;
    esac
  done
  permissions=$(printf '%s\n' "${actions[@]}" | jq -R . | jq -s 'map({action:.})')
  jq -n --arg name "$name" --arg description "$description" \
    --arg identity "$identity" --arg resource "$resource" \
    --argjson allow "$permissions" \
    '{id:"policy-test",name:$name,description:$description,owner:"admin-account",
      readOnly:false,expiredAt:null,identities:[$identity],resources:[{urn:$resource}],
      permissions:{allow:$allow}}' >"$state/policy.json"
  printf '{"message":"policy created","details":{"id":"policy-test"}}\n'
elif [[ $command_line == 'iam policy edit '* ]]; then
  [[ $TEST_EDIT_MODE != failure ]] || exit 60
  [[ $4 == policy-test ]] || exit 61
  [[ $command_line == *' --editor '* && -x ${EDITOR:-} &&
     -f ${OVH_POLICY_ACTIONS_FILE:-} ]] || exit 62
  cp "$state/policy.json" "$state/policy-editor-input.json"
  "$EDITOR" "$state/policy-editor-input.json"
  mv "$state/policy-editor-input.json" "$state/policy.json"
  printf '{"message":"policy edited"}\n'
elif [[ $command_line == 'cloud user list '* ]]; then
  printf '[]\n'
else
  printf 'unexpected mock command: %s\n' "$command_line" >&2
  exit 58
fi
MOCK
chmod +x "$test_root/bin/ovhcloud"

new_case() {
  case_dir=$(mktemp -d "$test_root/case.XXXXXX")
  mkdir -p "$case_dir/state" "$case_dir/admin-home"
  credentials_file="$case_dir/provider.json"
  project_mode=correct
  resource_mode=owned
  create_mode=success
  edit_mode=success
  default_mode=false
}

run_iam() {
  local -a credential_environment=()
  if [[ $default_mode != true ]]; then
    credential_environment=(CROSSPLANE_OVH_CREDENTIALS_FILE="$credentials_file")
  fi
  env -i \
    PATH="$test_root/bin:/usr/bin:/bin" \
    HOME="$case_dir/admin-home" OVH_ENDPOINT=ovh-eu \
    CROSSPLANE_OVH_PROJECT_ID="$target_id" \
    CROSSPLANE_OVH_API_REGION=EU \
    "${credential_environment[@]}" \
    TEST_STATE_DIR="$case_dir/state" TEST_TARGET_ID="$target_id" \
    TEST_OTHER_ID="$other_id" TEST_CLIENT_ID="$client_id" \
    TEST_CLIENT_SECRET="$client_secret" TEST_RESOURCE_URN="$resource_urn" \
    TEST_IDENTITY_URN="$identity_urn" TEST_ADMIN_HOME="$case_dir/admin-home" \
    TEST_PROJECT_MODE="$project_mode" TEST_RESOURCE_MODE="$resource_mode" \
    TEST_CREATE_MODE="$create_mode" TEST_EDIT_MODE="$edit_mode" \
    bash "$script" "$1" >"$case_dir/stdout" 2>"$case_dir/stderr"
}

expect_success() {
  run_iam "$1" || fail "$1 failed: $(cat "$case_dir/stderr")"
}

expect_failure() {
  if run_iam "$1"; then fail "$1 unexpectedly succeeded"; fi
}

create_count() {
  awk '/^(account api oauth2 client create|iam policy create) / {n++} END {print n+0}' \
    "$case_dir/state/calls"
}

new_case
expect_success status
[[ $(create_count) == 0 && ! -e $credentials_file ]] || fail 'status changed state'
grep -Fxq "Project: $target_id" "$case_dir/stdout" || fail 'status omitted project'
grep -Fxq "Credentials file: $credentials_file (missing)" "$case_dir/stdout" ||
  fail 'status omitted the missing credential path'

new_case
default_mode=true
credentials_file="$case_dir/admin-home/.ovh-provider-storage-${target_id}.json"
expect_success status
[[ ! -e $credentials_file ]] || fail 'status created the default credential file'
expect_success apply
[[ -f $credentials_file && $(stat -c '%a' "$credentials_file") == 600 ]] ||
  fail 'apply did not use the private project-specific default path'
grep -Fxq "Credentials file: $credentials_file" "$case_dir/stdout" ||
  fail 'apply omitted the default credential path'

new_case
project_mode=wrong
expect_failure apply
[[ $(create_count) == 0 && ! -e $credentials_file ]] || fail 'wrong project created state'

new_case
resource_mode=foreign
expect_failure apply
[[ $(create_count) == 0 && ! -e $credentials_file ]] || fail 'foreign resource created state'

new_case
credentials_file="$case_dir/.ovh.conf"
expect_failure apply
[[ ! -e $credentials_file ]] || fail 'bootstrap replaced the CLI login file'

new_case
create_mode=failure
expect_failure apply
[[ ! -e $credentials_file && ! -e ${credentials_file}.recovery ]] ||
  fail 'failed create left a blocking credential artifact'
create_mode=success
expect_success apply
[[ $(create_count) == 3 ]] || fail 'failed create did not allow a safe retry'

new_case
expect_success apply
[[ $(create_count) == 2 ]] || fail 'first apply did not create account and policy'
grep -Fxq 'OVHcloud Provider Storage controller identity is ready.' "$case_dir/stdout" ||
  fail 'apply omitted its readiness summary'
grep -Fxq "Project: $target_id" "$case_dir/stdout" || fail 'apply omitted project'
grep -Fxq 'API region: EU' "$case_dir/stdout" || fail 'apply omitted API region'
grep -Fxq "Controller service account: provider-storage-bootstrap-${target_id:0:12}" "$case_dir/stdout" ||
  fail 'apply omitted the service account name'
grep -Fxq "Credentials file: $credentials_file" "$case_dir/stdout" ||
  fail 'apply omitted the credential path'
[[ $(stat -c '%a' "$credentials_file") == 600 ]] || fail 'credential mode is not 0600'
[[ ! -e ${credentials_file}.recovery ]] || fail 'successful apply left the recovery file'
jq -e --arg id "$client_id" --arg secret "$client_secret" '
  (keys | sort) == ["client_id","client_secret","endpoint"] and
  .endpoint == "ovh-eu" and .client_id == $id and .client_secret == $secret
' "$credentials_file" >/dev/null || fail 'credential JSON is wrong'
if grep -Fq "$client_secret" "$case_dir/stdout" "$case_dir/stderr" "$case_dir/state/calls"; then
  fail 'apply exposed the client secret'
fi
jq -e --arg urn "$resource_urn" --arg identity "$identity_urn" '
  .resources == [{urn:$urn}] and .identities == [$identity] and
  (.permissions.allow | length) == 21 and
  ([.permissions.allow[].action] | index("publicCloudProject:apiovh:region/storage/delete") != null) and
  ([.permissions.allow[].action] | index("publicCloudProject:apiovh:region/storage/object/get") != null) and
  ([.permissions.allow[].action] | all(startswith("publicCloudProject:apiovh:")))
' "$case_dir/state/policy.json" >/dev/null || fail 'policy scope or actions are wrong'
cp "$credentials_file" "$case_dir/first-credentials.json"
expect_success apply
[[ $(create_count) == 2 ]] || fail 'second apply created another resource'
cmp -s "$credentials_file" "$case_dir/first-credentials.json" || fail 'second apply rewrote credentials'
expect_success status
[[ $(create_count) == 2 ]] || fail 'status changed existing resources'
grep -Fxq "Credentials file: $credentials_file (present, mode 0600)" "$case_dir/stdout" ||
  fail 'status omitted the existing credential path'

jq -n --arg id "$client_id" --arg secret "$client_secret" \
  '{details:{clientId:$id,clientSecret:$secret}}' >"${credentials_file}.recovery"
chmod 600 "${credentials_file}.recovery"
rm -- "$credentials_file"
expect_success apply
[[ $(create_count) == 2 && -f $credentials_file && ! -e ${credentials_file}.recovery ]] ||
  fail 'apply did not recover the one-time secret without creating another resource'
cmp -s "$credentials_file" "$case_dir/first-credentials.json" ||
  fail 'recovered credentials changed'

jq '.resources=[{urn:"urn:v1:eu:resource:publicCloudProject:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]' \
  "$case_dir/state/policy.json" >"$case_dir/state/drift.json"
mv "$case_dir/state/drift.json" "$case_dir/state/policy.json"
expect_failure apply
[[ $(create_count) == 2 ]] || fail 'policy drift led to a create'

new_case
expect_success apply
jq '.permissions.allow |= map(select(.action != "publicCloudProject:apiovh:user/openrc/get"))' \
  "$case_dir/state/policy.json" >"$case_dir/state/previous-policy.json"
mv "$case_dir/state/previous-policy.json" "$case_dir/state/policy.json"
expect_success status
grep -Fq '(needs action update)' "$case_dir/stdout" || fail 'status hid the previous action set'
expect_failure verify
edit_mode=failure
expect_failure apply
jq -e '(.permissions.allow | length) == 20' "$case_dir/state/policy.json" >/dev/null ||
  fail 'failed edit changed policy'
edit_mode=success
expect_success apply
jq -e '(.permissions.allow | length) == 21 and
  any(.permissions.allow[].action; . == "publicCloudProject:apiovh:user/openrc/get")' \
  "$case_dir/state/policy.json" >/dev/null || fail 'apply did not add the OpenRC action'
[[ $(create_count) == 2 ]] || fail 'policy update created another resource'
edit_count=$(grep -c '^iam policy edit ' "$case_dir/state/calls")
expect_success apply
[[ $(grep -c '^iam policy edit ' "$case_dir/state/calls") == "$edit_count" ]] ||
  fail 'repeat apply edited an up-to-date policy'

jq --arg action 'publicCloudProject:apiovh:user/openrc/get' '
  .permissions.allow =
    ([.permissions.allow[] | select(.action != $action)] + .permissions.allow)
' "$case_dir/state/policy.json" >"$case_dir/state/duplicated-policy.json"
mv "$case_dir/state/duplicated-policy.json" "$case_dir/state/policy.json"
expect_success status
grep -Fq '(needs action update)' "$case_dir/stdout" || fail 'status hid duplicated actions'
expect_success apply
jq -e '(.permissions.allow | length) == 21 and
  ([.permissions.allow[].action] | unique | length) == 21' \
  "$case_dir/state/policy.json" >/dev/null || fail 'apply did not repair duplicate actions'
[[ $(create_count) == 2 ]] || fail 'duplicate repair created another resource'

new_case
expect_success apply
expect_success verify
[[ $(wc -l <"$case_dir/state/service-calls") == 2 ]] || fail 'verify did not use isolated service credentials for target reads'
grep -Fxq 'Service account read the target project and its users.' "$case_dir/stdout" ||
  fail 'verify did not report target-project access'
if grep -Fq "$client_secret" "$case_dir/stdout" "$case_dir/stderr"; then
  fail 'verify exposed the client secret'
fi
printf 'OVHcloud IAM mock tests passed.\n'
