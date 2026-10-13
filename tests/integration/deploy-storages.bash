#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.bash
source "${INTEGRATION_DIR}/lib.bash"

backend="$(selected_backend "${1:-}" "$0")"

preflight_storage() {
  local backend="$1"
  case "${backend}" in
    minio) ;;
    aws)
      CROSSPLANE_AWS_RESOURCE_PREFIX="$(aws_resource_prefix)"
      ;;
    otc)
      CROSSPLANE_OTC_RESOURCE_PREFIX="$(otc_resource_prefix)"
      ;;
    ovh)
      CROSSPLANE_OVH_PROJECT_PREFIX="$(ovh_project_prefix)"
      ;;
    cloudferro)
      CROSSPLANE_CLOUDFERRO_PROJECT_ID="$(cloudferro_project_id)"
      CROSSPLANE_CLOUDFERRO_IT2_PROJECT_ID="$(cloudferro_it2_project_id)"
      CROSSPLANE_CLOUDFERRO_PROJECT_PREFIX="$(cloudferro_project_prefix "${CROSSPLANE_CLOUDFERRO_PROJECT_ID}")"
      CROSSPLANE_CLOUDFERRO_IT2_PROJECT_PREFIX="$(cloudferro_project_prefix "${CROSSPLANE_CLOUDFERRO_IT2_PROJECT_ID}")"
      if [[ "${CROSSPLANE_CLOUDFERRO_PROJECT_ID}" == "${CROSSPLANE_CLOUDFERRO_IT2_PROJECT_ID}" ]]; then
        printf 'CloudFerro integration Storages must use different project IDs.\n' >&2
        exit 1
      fi
      for project_id in "${CROSSPLANE_CLOUDFERRO_PROJECT_ID}" "${CROSSPLANE_CLOUDFERRO_IT2_PROJECT_ID}"; do
        if ! kube get "secret/cloudferro-project-${project_id}" --namespace "${INTEGRATION_NAMESPACE}" >/dev/null 2>&1; then
          printf 'CloudFerro project Secret for %s is missing. Apply the manifests printed by cloudferro/dependencies/iam.sh render-secrets.\n' "${project_id}" >&2
          exit 1
        fi
      done
      ;;
  esac
}

apply_storage() {
  local backend="$1"
  case "${backend}" in
    minio)
      kube apply -f "${MANIFEST_DIR}/storages/minio.yaml"
      ;;
    aws)
      apply_template \
        "${MANIFEST_DIR}/storages/aws.yaml" \
        AWS_BUCKET_A "${CROSSPLANE_AWS_RESOURCE_PREFIX}-it-a" \
        AWS_BUCKET_B "${CROSSPLANE_AWS_RESOURCE_PREFIX}-it-b" \
        AWS_BUCKET_C "${CROSSPLANE_AWS_RESOURCE_PREFIX}-it-c" \
        AWS_BUCKET_D "${CROSSPLANE_AWS_RESOURCE_PREFIX}-it-d" \
        AWS_BUCKET_IT2_A "${CROSSPLANE_AWS_RESOURCE_PREFIX}-it2-a"
      ;;
    otc)
      apply_template \
        "${MANIFEST_DIR}/storages/otc.yaml" \
        OTC_BUCKET_A "${CROSSPLANE_OTC_RESOURCE_PREFIX}-it-a" \
        OTC_BUCKET_B "${CROSSPLANE_OTC_RESOURCE_PREFIX}-it-b" \
        OTC_BUCKET_C "${CROSSPLANE_OTC_RESOURCE_PREFIX}-it-c" \
        OTC_BUCKET_D "${CROSSPLANE_OTC_RESOURCE_PREFIX}-it-d" \
        OTC_BUCKET_IT2_A "${CROSSPLANE_OTC_RESOURCE_PREFIX}-it2-a"
      ;;
    ovh)
      apply_template \
        "${MANIFEST_DIR}/storages/ovh.yaml" \
        OVH_PROJECT_PREFIX "${CROSSPLANE_OVH_PROJECT_PREFIX}"
      ;;
    cloudferro)
      apply_template \
        "${MANIFEST_DIR}/storages/cloudferro.yaml" \
        CLOUDFERRO_PROJECT_ID "${CROSSPLANE_CLOUDFERRO_PROJECT_ID}" \
        CLOUDFERRO_PROJECT_PREFIX "${CROSSPLANE_CLOUDFERRO_PROJECT_PREFIX}" \
        CLOUDFERRO_IT2_PROJECT_ID "${CROSSPLANE_CLOUDFERRO_IT2_PROJECT_ID}" \
        CLOUDFERRO_IT2_PROJECT_PREFIX "${CROSSPLANE_CLOUDFERRO_IT2_PROJECT_PREFIX}"
      ;;
  esac
}

main() {
  require_cluster
  preflight_storage "${backend}"
  apply_storage "${backend}"

  kube get storages.pkg.internal \
    --namespace "${INTEGRATION_NAMESPACE}" \
    -L storages.pkg.internal/backend
}

main
