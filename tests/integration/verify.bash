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

second_bucket_name() {
  case "$1" in
    minio)
      printf '%s\n' minio-default-it2-a
      ;;
    aws)
      printf '%s-it2-a\n' "$(aws_resource_prefix)"
      ;;
    otc)
      printf '%s-it2-a\n' "$(otc_resource_prefix)"
      ;;
    ovh)
      printf 'ovh-%s-it2-a\n' "$(ovh_project_prefix)"
      ;;
    cloudferro)
      printf 'cloudferro-%s-it2-a\n' \
        "$(cloudferro_project_prefix "$(cloudferro_it2_slot)")"
      ;;
  esac
}

bucket_names() {
  case "$1" in
    minio)
      printf '%s\n' minio-default-it-a minio-default-it-b
      ;;
    aws)
      printf '%s-it-a\n%s-it-b\n' "$(aws_resource_prefix)" "$(aws_resource_prefix)"
      ;;
    otc)
      printf '%s-it-a\n%s-it-b\n' "$(otc_resource_prefix)" "$(otc_resource_prefix)"
      ;;
    ovh)
      printf 'ovh-%s-it-a\novh-%s-it-b\n' \
        "$(ovh_project_prefix)" "$(ovh_project_prefix)"
      ;;
    cloudferro)
      printf 'cloudferro-%s-it-a\ncloudferro-%s-it-b\n' \
        "$(cloudferro_project_prefix)" "$(cloudferro_project_prefix)"
      ;;
  esac
}

rclone_provider() {
  case "$1" in
    minio) printf 'Minio\n' ;;
    aws) printf 'AWS\n' ;;
    otc|ovh|cloudferro) printf 'Other\n' ;;
  esac
}

verify_secret_key() {
  local secret="$1"
  local key="$2"
  local encoded
  encoded="$(kube get "secret/${secret}" \
    --namespace "${INTEGRATION_NAMESPACE}" \
    -o "jsonpath={.data.${key}}")"
  if [[ -z "${encoded}" ]]; then
    printf 'Secret %s/%s is missing %s.\n' \
      "${INTEGRATION_NAMESPACE}" "${secret}" "${key}" >&2
    exit 1
  fi
}

verify_consumer_secret() {
  local secret="$1"
  local key

  verify_secret_key "${secret}" AWS_ACCESS_KEY_ID
  verify_secret_key "${secret}" AWS_SECRET_ACCESS_KEY

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

apply_readonly_job() {
  local name="$1" phase="$2" principal="$3" bucket="$4" provider="$5"
  kube delete "job/${name}" \
    --namespace "${INTEGRATION_NAMESPACE}" \
    --ignore-not-found \
    --wait=true
  apply_template \
    "${MANIFEST_DIR}/jobs/readonly.yaml" \
    INTEGRATION_NAMESPACE "${INTEGRATION_NAMESPACE}" \
    JOB_NAME "${name}" \
    PRINCIPAL "${principal}" \
    BUCKET "${bucket}" \
    RCLONE_PROVIDER "${provider}" \
    RCLONE_IMAGE "${RCLONE_IMAGE}" \
    TEST_PHASE "${phase}"
  wait_for_job "${name}"
}

verify_readonly_access() {
  local backend="$1" owner="$2" grantee="$3" bucket="$4" provider="$5"
  log "Verifying ${backend} ReadOnly access to ${bucket}"
  apply_readonly_job "storage-${backend}-readonly-seed" seed \
    "${owner}" "${bucket}" "${provider}"
  apply_readonly_job "storage-${backend}-readonly-verify" verify \
    "${grantee}" "${bucket}" "${provider}"
  apply_readonly_job "storage-${backend}-readonly-cleanup" cleanup \
    "${owner}" "${bucket}" "${provider}"
}

verify_backend() {
  local backend="$1"
  local storage principal second_storage second_principal second_bucket
  local bucket provider job
  local -a owned_buckets
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
  verify_readonly_access "${backend}" "${principal}" "${second_principal}" \
    "${owned_buckets[1]}" "${provider}"
}

apply_lifecycle_job() {
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

verify_minio_lifecycle() {
  local cronjob=provider-storage-minio-it-lifecycle
  local seed_job=storage-minio-it-lifecycle-seed
  local cleanup_job=storage-minio-it-lifecycle-cleanup
  local verify_job=storage-minio-it-lifecycle-verify

  log "Verifying MinIO lifecycle cleanup"
  kube wait "cronjob/${cronjob}" \
    --namespace "${INTEGRATION_NAMESPACE}" \
    --for=create \
    --timeout=2m
  apply_lifecycle_job "${seed_job}" seed \
    provider-storage-minio-it minio-default-it-a Minio
  printf 'Waiting %s seconds for the lifecycle minimum age.\n' \
    "${LIFECYCLE_WAIT_SECONDS}"
  sleep "${LIFECYCLE_WAIT_SECONDS}"
  kube delete "job/${cleanup_job}" \
    --namespace "${INTEGRATION_NAMESPACE}" \
    --ignore-not-found \
    --wait=true
  kube create job "${cleanup_job}" \
    --namespace "${INTEGRATION_NAMESPACE}" \
    --from="cronjob/${cronjob}"
  wait_for_job "${cleanup_job}"
  apply_lifecycle_job "${verify_job}" verify \
    provider-storage-minio-it minio-default-it-a Minio
}

verify_cloudferro_lifecycle() {
  local principal=provider-storage-cloudferro-it
  local bucket cronjob seed_job cleanup_job verify_job
  bucket="cloudferro-$(cloudferro_project_prefix)-it-a"
  cronjob="${principal}-lifecycle"
  seed_job=storage-cloudferro-it-lifecycle-seed
  cleanup_job=storage-cloudferro-it-lifecycle-cleanup
  verify_job=storage-cloudferro-it-lifecycle-verify

  log "Verifying CloudFerro lifecycle cleanup"
  kube wait "cronjob/${cronjob}" --namespace "${INTEGRATION_NAMESPACE}" \
    --for=create --timeout=2m
  apply_lifecycle_job "${seed_job}" seed "${principal}" "${bucket}" Other
  printf 'Waiting %s seconds for the lifecycle minimum age.\n' \
    "${LIFECYCLE_WAIT_SECONDS}"
  sleep "${LIFECYCLE_WAIT_SECONDS}"
  kube delete "job/${cleanup_job}" --namespace "${INTEGRATION_NAMESPACE}" \
    --ignore-not-found --wait=true
  kube create job "${cleanup_job}" --namespace "${INTEGRATION_NAMESPACE}" \
    --from="cronjob/${cronjob}"
  wait_for_job "${cleanup_job}"
  apply_lifecycle_job "${verify_job}" verify "${principal}" "${bucket}" Other
}

main() {
  require_cluster
  bucket_names "${backend}" >/dev/null
  second_bucket_name "${backend}" >/dev/null
  verify_backend "${backend}"
  if [[ "${backend}" == minio ]]; then
    verify_minio_lifecycle
  elif [[ "${backend}" == cloudferro ]]; then
    verify_cloudferro_lifecycle
  fi

  log "Provider Storage integration state"
  kube get storages.pkg.internal \
    --namespace "${INTEGRATION_NAMESPACE}" \
    -L storages.pkg.internal/backend
}

main
