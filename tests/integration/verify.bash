#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.bash
source "${INTEGRATION_DIR}/lib.bash"

backend="$(selected_backend "${1:-}" "$0")"
: "${LIFECYCLE_WAIT_SECONDS:=40}"
if [[ ! "${LIFECYCLE_WAIT_SECONDS}" =~ ^[0-9]+$ ]] ||
  ((LIFECYCLE_WAIT_SECONDS < 35 || LIFECYCLE_WAIT_SECONDS > 60)); then
  printf 'LIFECYCLE_WAIT_SECONDS must be an integer from 35 through 60.\n' >&2
  exit 1
fi

storage_name() {
  printf 'storage-%s-it%s\n' "$1" "${2:-}"
}

principal_name() {
  printf 'provider-storage-%s-it%s\n' "$1" "${2:-}"
}

bucket_prefix() {
  case "$1" in
    minio) printf '%s\n' minio-default ;;
    aws) aws_resource_prefix ;;
    otc) otc_resource_prefix ;;
    ovh) printf 'ovh-%s\n' "$(ovh_project_prefix)" ;;
    cloudferro)
      local project
      project="$(cloudferro_project_id)"
      if [[ "${2:-owner}" == requester ]]; then
        project="$(cloudferro_it2_project_id)"
      fi
      printf 'cloudferro-%s\n' "$(cloudferro_project_prefix "${project}")"
      ;;
  esac
}

second_bucket_name() {
  printf '%s-it2-a\n' "$(bucket_prefix "$1" requester)"
}

bucket_names() {
  local prefix suffix
  prefix="$(bucket_prefix "$1")"
  for suffix in a b c d; do
    printf '%s-it-%s\n' "${prefix}" "${suffix}"
  done
}

rclone_provider() {
  case "$1" in
    minio) printf 'Minio\n' ;;
    aws) printf 'AWS\n' ;;
    ovh) printf 'OVHcloud\n' ;;
    otc|cloudferro) printf 'Other\n' ;;
  esac
}

validate_backend_configuration() {
  case "$1" in
    minio) ;;
    aws) aws_resource_prefix >/dev/null ;;
    otc) otc_resource_prefix >/dev/null ;;
    ovh) ovh_project_prefix >/dev/null ;;
    cloudferro)
      cloudferro_project_prefix >/dev/null
      cloudferro_project_prefix "$(cloudferro_it2_project_id)" >/dev/null
      ;;
  esac
}

verify_consumer_secret() {
  local secret="$1"
  local key

  while IFS= read -r key; do
    [[ -z "${key}" ]] || case "${key}" in
      AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_ENDPOINT_URL|AWS_REGION|AWS_S3_FORCE_PATH_STYLE) ;;
      *)
        printf 'Secret %s/%s contains provider-native key %s.\n' \
          "${INTEGRATION_NAMESPACE}" "${secret}" "${key}" >&2
        exit 1
        ;;
    esac
  done < <(
    kube get "secret/${secret}" \
      --namespace "${INTEGRATION_NAMESPACE}" \
      -o go-template='{{range $key, $_ := .data}}{{printf "%s\n" $key}}{{end}}'
  )
}

verify_bucket_roundtrip() {
  local job="$1" principal="$2" bucket="$3" provider="$4"
  kube delete "job/${job}" \
    --namespace "${INTEGRATION_NAMESPACE}" \
    --ignore-not-found \
    --wait=true
  apply_template \
    "${MANIFEST_DIR}/jobs/roundtrip.yaml" \
    INTEGRATION_NAMESPACE "${INTEGRATION_NAMESPACE}" \
    JOB_NAME "${job}" \
    PRINCIPAL "${principal}" \
    BUCKET "${bucket}" \
    RCLONE_PROVIDER "${provider}" \
    RCLONE_IMAGE "${RCLONE_IMAGE}"
  wait_for_job "${job}"
}

verify_storage_ready() {
  local storage="$1" principal="$2"
  log "Waiting for Storage ${storage}"
  if ! kube wait "storage.pkg.internal/${storage}" \
    --namespace "${INTEGRATION_NAMESPACE}" \
    --for=condition=Ready \
    --timeout=15m; then
    kube describe "storage.pkg.internal/${storage}" \
      --namespace "${INTEGRATION_NAMESPACE}" || true
    exit 1
  fi

  log "Waiting for consumer Secret ${principal}"
  kube wait "secret/${principal}" \
    --namespace "${INTEGRATION_NAMESPACE}" \
    --for=create \
    --timeout=5m
  kube wait "secret/${principal}" \
    --namespace "${INTEGRATION_NAMESPACE}" \
    --for=jsonpath='{.data.AWS_ACCESS_KEY_ID}' \
    --timeout=5m
  kube wait "secret/${principal}" \
    --namespace "${INTEGRATION_NAMESPACE}" \
    --for=jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' \
    --timeout=5m
  verify_consumer_secret "${principal}"
}

run_access_job() {
  local name="$1" phase="$2" principal="$3" bucket="$4"
  kube delete "job/${name}" \
    --namespace "${INTEGRATION_NAMESPACE}" \
    --ignore-not-found \
    --wait=true
  apply_template \
    "${MANIFEST_DIR}/jobs/access.yaml" \
    INTEGRATION_NAMESPACE "${INTEGRATION_NAMESPACE}" \
    JOB_NAME "${name}" \
    PRINCIPAL "${principal}" \
    BUCKET "${bucket}" \
    S3_PROBE_IMAGE "${S3_PROBE_IMAGE}" \
    TEST_PHASE "${phase}"
  wait_for_job "${name}"
}

verify_readonly_access() {
  local backend="$1" owner="$2" grantee="$3" bucket="$4"
  log "Verifying ${backend} ReadOnly access to ${bucket}"
  run_access_job "storage-${backend}-readonly-seed" seed \
    "${owner}" "${bucket}"
  run_access_job "storage-${backend}-readonly-verify" readonly \
    "${grantee}" "${bucket}"
  run_access_job "storage-${backend}-readonly-cleanup" cleanup \
    "${owner}" "${bucket}"
}

verify_no_access() {
  local backend="$1" scenario="$2" owner="$3" principal="$4" bucket="$5"
  log "Verifying ${backend} no access to ${bucket}"
  run_access_job "storage-${backend}-${scenario}-seed" seed \
    "${owner}" "${bucket}"
  run_access_job "storage-${backend}-${scenario}-verify" deny \
    "${principal}" "${bucket}"
  run_access_job "storage-${backend}-${scenario}-cleanup" cleanup \
    "${owner}" "${bucket}"
}

verify_backend() {
  local backend="$1"
  local storage principal second_storage second_principal second_bucket
  local bucket provider job
  local -a owned_buckets
  validate_backend_configuration "${backend}"
  storage="$(storage_name "${backend}")"
  principal="$(principal_name "${backend}")"
  second_storage="$(storage_name "${backend}" 2)"
  second_principal="$(principal_name "${backend}" 2)"
  second_bucket="$(second_bucket_name "${backend}")"
  provider="$(rclone_provider "${backend}")"
  job="${storage}-roundtrip"
  mapfile -t owned_buckets < <(bucket_names "${backend}")

  verify_storage_ready "${storage}" "${principal}"

  for bucket in "${owned_buckets[@]}"; do
    verify_bucket_roundtrip "${job}" "${principal}" "${bucket}" "${provider}"
  done

  verify_storage_ready "${second_storage}" "${second_principal}"
  verify_bucket_roundtrip "${second_storage}-roundtrip" \
    "${second_principal}" "${second_bucket}" "${provider}"
  verify_no_access "${backend}" ungranted "${principal}" "${second_principal}" \
    "${owned_buckets[0]}"
  verify_readonly_access "${backend}" "${principal}" "${second_principal}" \
    "${owned_buckets[1]}"
  verify_no_access "${backend}" denied "${principal}" "${second_principal}" \
    "${owned_buckets[2]}"
  verify_no_access "${backend}" pending "${principal}" "${second_principal}" \
    "${owned_buckets[3]}"
}

run_lifecycle_job() {
  local name="$1" phase="$2" principal="$3" bucket="$4" provider="$5"
  kube delete "job/${name}" \
    --namespace "${INTEGRATION_NAMESPACE}" \
    --ignore-not-found \
    --wait=true
  apply_template \
    "${MANIFEST_DIR}/jobs/lifecycle.yaml" \
    INTEGRATION_NAMESPACE "${INTEGRATION_NAMESPACE}" \
    JOB_NAME "${name}" \
    PRINCIPAL "${principal}" \
    BUCKET "${bucket}" \
    RCLONE_PROVIDER "${provider}" \
    RCLONE_IMAGE "${RCLONE_IMAGE}" \
    TEST_PHASE "${phase}"
  wait_for_job "${name}"
}

verify_lifecycle() {
  local backend="$1" principal bucket cronjob seed_job cleanup_job verify_job
  local -a buckets
  principal="$(principal_name "${backend}")"
  mapfile -t buckets < <(bucket_names "${backend}")
  bucket="${buckets[0]}"
  cronjob="${principal}-lifecycle"
  seed_job="storage-${backend}-it-lifecycle-seed"
  cleanup_job="storage-${backend}-it-lifecycle-cleanup"
  verify_job="storage-${backend}-it-lifecycle-verify"

  log "Verifying ${backend} lifecycle cleanup"
  kube wait "cronjob/${cronjob}" --namespace "${INTEGRATION_NAMESPACE}" \
    --for=create --timeout=2m
  run_lifecycle_job "${seed_job}" seed "${principal}" "${bucket}" "$(rclone_provider "${backend}")"
  printf 'Waiting %s seconds for the lifecycle minimum age.\n' \
    "${LIFECYCLE_WAIT_SECONDS}"
  sleep "${LIFECYCLE_WAIT_SECONDS}"
  kube delete "job/${cleanup_job}" --namespace "${INTEGRATION_NAMESPACE}" \
    --ignore-not-found --wait=true
  kube create job "${cleanup_job}" --namespace "${INTEGRATION_NAMESPACE}" \
    --from="cronjob/${cronjob}"
  wait_for_job "${cleanup_job}"
  run_lifecycle_job "${verify_job}" verify "${principal}" "${bucket}" "$(rclone_provider "${backend}")"
}

main() {
  require_cluster
  verify_backend "${backend}"
  case "${backend}" in
    minio|cloudferro) verify_lifecycle "${backend}" ;;
  esac
  if [[ "${backend}" == minio ]]; then
    "${PROVIDER_STORAGE_PYTHON:-python3}" "${INTEGRATION_DIR}/credentials.py" rollover
    verify_storage_ready storage-minio-it2 provider-storage-minio-it2
    verify_bucket_roundtrip storage-minio-it2-roundtrip \
      provider-storage-minio-it2 minio-default-it2-a Minio
  fi

  log "Provider Storage integration state"
  kube get storages.pkg.internal \
    --namespace "${INTEGRATION_NAMESPACE}"
}

main
