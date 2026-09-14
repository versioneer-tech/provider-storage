#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.bash
source "${INTEGRATION_DIR}/lib.bash"

backend="${1:-}"
case "${backend}" in
  minio|ovh) ;;
  *) printf 'Usage: %s <minio|ovh>\n' "$0" >&2; exit 1 ;;
esac
# shellcheck source=capability-one/minio.bash
source "${INTEGRATION_DIR}/capability-one/${backend}.bash"

require_cluster
require_command jq
story_run_id="$(date +%s%N)"
story_prefix="xyz-story-${backend}-${story_run_id}"
story_namespace="xyz-story-${backend}-${story_run_id}"
story_composition_provider="${backend}"
if declare -F story_configure_run >/dev/null; then
  story_configure_run
fi
validate_dns_label story_namespace "${story_namespace}"
story_capture_dir="${STORY_CAPTURE_DIR:-/tmp/xyz-capability-one-${story_run_id}}"
mkdir -m 700 -p "${story_capture_dir}"
chmod 700 "${story_capture_dir}"
bucket_joe="$(story_bucket joe)"
bucket_jeff="$(story_bucket jeff)"
bucket_jeff_shared="$(story_bucket jeff-shared)"
bucket_jane="$(story_bucket jane)"
bucket_john="$(story_bucket john)"
: "${STORY_WAIT_SECONDS:=300}"
if [[ ! "${STORY_WAIT_SECONDS}" =~ ^[0-9]+$ ]] || ((STORY_WAIT_SECONDS < 30)); then
  printf 'STORY_WAIT_SECONDS must be an integer of at least 30.\n' >&2
  exit 1
fi

apply_story_step() {
  local filename="$1"
  apply_template "${INTEGRATION_DIR}/capability-one/steps/${filename}.yaml" \
    STORY_NAMESPACE "${story_namespace}" \
    STORY_ENVIRONMENT "${story_environment}" \
    BACKEND "${backend}" \
    COMPOSITION_PROVIDER "${story_composition_provider}" \
    IDENTITY_JOE "$(story_identity joe)" \
    IDENTITY_JEFF "$(story_identity jeff)" \
    IDENTITY_JANE "$(story_identity jane)" \
    IDENTITY_JOHN "$(story_identity john)" \
    BUCKET_JOE "${bucket_joe}" \
    BUCKET_JEFF "${bucket_jeff}" \
    BUCKET_JEFF_SHARED "${bucket_jeff_shared}" \
    BUCKET_JANE "${bucket_jane}" \
    BUCKET_JOHN "${bucket_john}"
}

wait_storage() {
  local name="$1" deadline=$((SECONDS + STORY_WAIT_SECONDS))
  until kube get storage.pkg.internal/"${name}" -n "${story_namespace}" -o json 2>/dev/null | \
    jq -e '.metadata.generation as $generation |
      any(.status.conditions[]?;
        .type == "Synced" and .status == "True" and
        .observedGeneration >= $generation) and
      any(.status.conditions[]?;
        .type == "Ready" and .status == "True" and
        .observedGeneration >= $generation)' >/dev/null; do
    if ((SECONDS >= deadline)); then
      printf 'Storage %s did not become Ready at its current generation.\n' "${name}" >&2
      kube get storage.pkg.internal/"${name}" -n "${story_namespace}" >&2 || true
      return 1
    fi
    sleep 5
  done
}

verify_secret() {
  local name="$1" deadline=$((SECONDS + STORY_WAIT_SECONDS))
  until kube get secret/"${name}" -n "${story_namespace}" -o json 2>/dev/null | jq -e '
    .data | (keys == ["AWS_ACCESS_KEY_ID","AWS_ENDPOINT_URL","AWS_REGION",
      "AWS_S3_FORCE_PATH_STYLE","AWS_SECRET_ACCESS_KEY"]) and
    all(.[]; length > 0)' >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      printf 'Normalized consumer Secret %s is not ready.\n' "${name}" >&2
      return 1
    fi
    sleep 5
  done
}

start_client() {
  local principal="$1" pod
  pod="xyz-story-client-${principal#s-}"
  cat <<EOF | kube apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${story_namespace}
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  containers:
    - name: s3
      image: ${RCLONE_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 36000"]
      envFrom:
        - secretRef:
            name: ${principal}
EOF
  kube wait pod/"${pod}" -n "${story_namespace}" \
    --for=condition=Ready --timeout=3m
}

run_s3() {
  local principal="$1" operation="$2" bucket="$3" object="$4"
  kube exec -n "${story_namespace}" "pod/xyz-story-client-${principal#s-}" \
    -- sh -c '
      set -eu
      export RCLONE_CONFIG=/dev/null
      export RCLONE_CONFIG_STORAGE_TYPE=s3
      export RCLONE_CONFIG_STORAGE_PROVIDER="$4"
      export RCLONE_CONFIG_STORAGE_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
      export RCLONE_CONFIG_STORAGE_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
      export RCLONE_CONFIG_STORAGE_ENDPOINT="$AWS_ENDPOINT_URL"
      export RCLONE_CONFIG_STORAGE_REGION="$AWS_REGION"
      export RCLONE_CONFIG_STORAGE_FORCE_PATH_STYLE="$AWS_S3_FORCE_PATH_STYLE"
      case "$1" in
        put)
          printf "provider-storage capability one\n" >/tmp/story-upload.txt
          rclone copyto /tmp/story-upload.txt "storage:$2/$3" \
            --s3-no-check-bucket --retries 1 --low-level-retries 1
          ;;
        get)
          rclone copyto "storage:$2/$3" /tmp/story-download.txt \
            --s3-no-check-bucket --retries 1 --low-level-retries 1
          printf "provider-storage capability one\n" >/tmp/story-expected.txt
          cmp /tmp/story-expected.txt /tmp/story-download.txt
          ;;
        *) exit 2 ;;
      esac
    ' story-s3 "${operation}" "${bucket}" "${object}" "${story_rclone_provider}"
}

check_s3() {
  local principal="$1" operation="$2" bucket="$3" object="$4" expected="$5"
  local deadline=$((SECONDS + STORY_WAIT_SECONDS)) result outcome
  while :; do
    if result="$(run_s3 "${principal}" "${operation}" "${bucket}" "${object}" 2>&1)"; then
      outcome=allow
    elif [[ "${result}" == *AccessDenied* || "${result}" == *Forbidden* || "${result}" == *403* ]]; then
      outcome=deny
    else
      printf 'Unexpected S3 failure for %s %s on %s.\n' \
        "${principal}" "${operation}" "${bucket}" >&2
      printf '%s\n' "${result}" >&2
      return 1
    fi
    if [[ "${outcome}" == "${expected}" ]]; then
      printf 'S3 %s %s on %s: %s\n' "${principal}" "${operation}" "${bucket}" "${expected}"
      return 0
    fi
    if ((SECONDS >= deadline)); then
      printf 'S3 %s %s on %s stayed %s; expected %s.\n' \
        "${principal}" "${operation}" "${bucket}" "${outcome}" "${expected}" >&2
      return 1
    fi
    sleep 10
  done
}

step() {
  log "Capability 1 $1: $2"
}

capture_step() {
  local directory="${story_capture_dir}/${1}"
  local principal object_list
  mkdir -m 700 -p "${directory}"

  kube get storages.pkg.internal -n "${story_namespace}" \
    -l storages.pkg.internal/capability-one=true -o json |
    jq --arg prefix "${story_prefix}" '
      [.items[] | {apiVersion,kind,
        metadata:{name:.metadata.name,namespace:"default",
          annotations:{"storages.pkg.internal/environment":.metadata.annotations["storages.pkg.internal/environment"]},
          labels:(.metadata.labels | del(."crossplane.io/composite"))},
        spec:(.spec | .crossplane = {compositionSelector:.crossplane.compositionSelector})} |
        walk(if type == "string" then gsub($prefix;"xyz-story-fixture") else . end)]' \
      >"${directory}/claims.json"

  kube get environmentconfig.apiextensions.crossplane.io/"${story_environment}" -o json |
    jq -c --arg backend "${backend}" '
      {apiVersion,kind,metadata:{name:.metadata.name},data:.data} |
      if $backend == "ovh" then .data.storage.serviceName = "00000000000000000000000000000000"
      else . end' \
      >"${directory}/environment.json"

  for principal in s-joe s-jeff s-jane s-john; do
    if ! kube get storage.pkg.internal/"${principal}" -n "${story_namespace}" \
      >/dev/null 2>&1; then
      continue
    fi
    kube get storage.pkg.internal/"${principal}" -n "${story_namespace}" -o json |
      jq --arg prefix "${story_prefix}" \
        '{apiVersion,kind,metadata:{name:.metadata.name,namespace:"default",
          annotations:{"storages.pkg.internal/environment":.metadata.annotations["storages.pkg.internal/environment"]},
          labels:(.metadata.labels | del(."crossplane.io/composite"))},
          spec:(.spec | .crossplane = {compositionSelector:.crossplane.compositionSelector})} |
          walk(if type == "string" then gsub($prefix;"xyz-story-fixture") else . end)' \
        >"${directory}/input-${principal}.json"

    object_list="$(kube get objects.kubernetes.m.crossplane.io \
      -n "${story_namespace}" -l "crossplane.io/composite=${principal}" -o json)"
    jq '[.items[] | {name:.metadata.name,
      compositionResource:.metadata.annotations["crossplane.io/composition-resource-name"],
      ready:([.status.conditions[]? | select(.type == "Ready") | .status] | first // "Unknown")}]' \
      <<<"${object_list}" >"${directory}/inventory-${principal}.json"
    jq --arg prefix "${story_prefix}" --arg principal "${principal}" \
      --arg backend "${backend}" '
      [.items[] |
        (.metadata.annotations["crossplane.io/composition-resource-name"] // .metadata.name) as $key |
        {apiVersion,kind,
          metadata:{name:.metadata.name,namespace:"default",
            annotations:{"crossplane.io/composition-resource-name":$key}},
          status:{conditions:[.status.conditions[]? | {type,status,reason}],
            atProvider:(if $key == ("observe-secret-" + $principal) then
              {manifest:{apiVersion:"v1",kind:"Secret",
                metadata:{name:($principal + "-credentials"),namespace:"default"},
                data:(if $backend == "ovh" then
                  {access_key_id:"RVhBTVBMRUFDQ0VTU0tFWQ==",
                   "attribute.secret_access_key":"RVhBTVBMRVNFQ1JFVEtFWQ=="}
                  else {AWS_ACCESS_KEY_ID:"RVhBTVBMRUFDQ0VTU0tFWQ==",
                   AWS_SECRET_ACCESS_KEY:"RVhBTVBMRVNFQ1JFVEtFWQ=="} end)}}
              else {} end)}} |
        walk(if type == "string" then gsub($prefix;"xyz-story-fixture") else . end)]' \
      <<<"${object_list}" >"${directory}/observed-${principal}.json"
    if declare -F story_capture_managed >/dev/null; then
      story_capture_managed "${principal}" "${directory}"
    fi
  done
}

verify_final_examples() {
  local final_dir="${story_capture_dir}/t10-s-john_grant-readwrite_s-jane"
  local expected="${final_dir}/final-example-projection.json"
  local actual="${final_dir}/final-live-projection.json"
  local projection="${INTEGRATION_DIR}/capability-one/final-projection.jq"

  kube create --dry-run=client \
    -f "${REPO_ROOT}/examples/base/001-buckets.yaml" \
    -f "${REPO_ROOT}/examples/base/002-buckets.yaml" \
    -f "${REPO_ROOT}/examples/base/003-buckets.yaml" \
    -f "${REPO_ROOT}/examples/base/004-buckets.yaml" \
    -o json |
    jq -s -S --arg prefix "${story_prefix}" -f "${projection}" >"${expected}"
  kube get storages.pkg.internal -n "${story_namespace}" \
    -l storages.pkg.internal/capability-one=true -o json |
    jq -S --arg prefix "${story_prefix}" -f "${projection}" >"${actual}"
  if ! diff -u "${expected}" "${actual}"; then
    printf 'Final story claims do not match the capability-1 fields in examples/base.\n' >&2
    return 1
  fi
}

main() {
  story_setup
  printf 'Story namespace: %s\n' "${story_namespace}"
  printf 'Sanitized capture directory: %s\n' "${story_capture_dir}"

  step t00-start-empty 'start with no story claims'
  capture_step t00-start-empty
  step t01-s-joe_create-bucket_s-joe 'Joe creates a bucket'
  apply_story_step t01-s-joe_create-bucket_s-joe
  wait_storage s-joe
  verify_secret s-joe
  start_client s-joe
  check_s3 s-joe put "${bucket_joe}" story/owner.txt allow
  check_s3 s-joe get "${bucket_joe}" story/owner.txt allow
  capture_step t01-s-joe_create-bucket_s-joe

  step t02-s-jeff_create-buckets_s-jeff-and-s-jeff-shared 'Jeff creates two buckets'
  apply_story_step t02-s-jeff_create-buckets_s-jeff-and-s-jeff-shared
  wait_storage s-jeff
  verify_secret s-jeff
  start_client s-jeff
  check_s3 s-jeff put "${bucket_jeff}" story/owner.txt allow
  check_s3 s-jeff put "${bucket_jeff_shared}" story/shared.txt allow
  check_s3 s-jeff get "${bucket_jeff_shared}" story/shared.txt allow
  check_s3 s-joe get "${bucket_jeff_shared}" story/shared.txt deny
  capture_step t02-s-jeff_create-buckets_s-jeff-and-s-jeff-shared

  step t03-s-joe_request-access_s-jeff-shared 'Joe requests Jeff shared bucket'
  apply_story_step t03-s-joe_request-access_s-jeff-shared
  wait_storage s-joe
  check_s3 s-joe get "${bucket_jeff_shared}" story/shared.txt deny
  check_s3 s-joe put "${bucket_jeff_shared}" story/joe-pending.txt deny
  capture_step t03-s-joe_request-access_s-jeff-shared

  step t04-s-jeff_grant-readwrite_s-joe 'Jeff grants Joe ReadWrite'
  apply_story_step t04-s-jeff_grant-readwrite_s-joe
  wait_storage s-jeff
  check_s3 s-joe get "${bucket_jeff_shared}" story/shared.txt allow
  check_s3 s-joe put "${bucket_jeff_shared}" story/joe-write.txt allow
  capture_step t04-s-jeff_grant-readwrite_s-joe

  step t05-s-jeff_change-grant-readonly_s-joe 'Jeff changes Joe grant to ReadOnly'
  apply_story_step t05-s-jeff_change-grant-readonly_s-joe
  wait_storage s-jeff
  check_s3 s-joe get "${bucket_jeff_shared}" story/shared.txt allow
  check_s3 s-joe put "${bucket_jeff_shared}" story/joe-denied.txt deny
  capture_step t05-s-jeff_change-grant-readonly_s-joe

  step t06-s-jeff_request-access_s-joe 'Jeff requests Joe bucket'
  apply_story_step t06-s-jeff_request-access_s-joe
  wait_storage s-jeff
  check_s3 s-jeff get "${bucket_joe}" story/owner.txt deny
  capture_step t06-s-jeff_request-access_s-joe

  step t07-s-joe_grant-readwrite_s-jeff 'Joe grants Jeff ReadWrite'
  apply_story_step t07-s-joe_grant-readwrite_s-jeff
  wait_storage s-joe
  check_s3 s-jeff get "${bucket_joe}" story/owner.txt allow
  check_s3 s-jeff put "${bucket_joe}" story/jeff-write.txt allow
  capture_step t07-s-joe_grant-readwrite_s-jeff

  step t08-s-jane_request-access_s-john 'Jane requests the absent John bucket'
  apply_story_step t08-s-jane_request-access_s-john
  wait_storage s-jane
  verify_secret s-jane
  start_client s-jane
  if story_bucket_exists "${bucket_john}"; then
    printf 'John bucket exists before John claim.\n' >&2
    return 1
  fi
  capture_step t08-s-jane_request-access_s-john

  step t09-s-john_create-bucket-and-requests_s-john 'John creates a bucket and makes three requests'
  apply_story_step t09-s-john_create-bucket-and-requests_s-john
  wait_storage s-john
  verify_secret s-john
  start_client s-john
  check_s3 s-john put "${bucket_john}" story/owner.txt allow
  check_s3 s-john get "${bucket_john}" story/owner.txt allow
  check_s3 s-john get "${bucket_joe}" story/owner.txt deny
  check_s3 s-john get "${bucket_jeff}" story/owner.txt deny
  check_s3 s-jane get "${bucket_john}" story/owner.txt deny
  capture_step t09-s-john_create-bucket-and-requests_s-john

  step t10-s-john_grant-readwrite_s-jane 'John grants Jane ReadWrite'
  apply_story_step t10-s-john_grant-readwrite_s-jane
  wait_storage s-john
  check_s3 s-jane get "${bucket_john}" story/owner.txt allow
  check_s3 s-jane put "${bucket_john}" story/jane-write.txt allow
  capture_step t10-s-john_grant-readwrite_s-jane
  verify_final_examples

  log 'Capability 1 story passed'
  printf 'Review story resources in namespace %s before cleanup.\n' \
    "${story_namespace}"
  printf 'Cleanup: tests/integration/cleanup-capability-one.bash %s %s\n' \
    "${backend}" "${story_namespace}"
}

main "$@"
