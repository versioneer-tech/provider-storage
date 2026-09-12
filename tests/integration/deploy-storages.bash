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
        AWS_BUCKET_B "${CROSSPLANE_AWS_RESOURCE_PREFIX}-it-b"
      ;;
    otc)
      apply_template \
        "${MANIFEST_DIR}/storages/otc.yaml" \
        OTC_BUCKET_A "${CROSSPLANE_OTC_RESOURCE_PREFIX}-it-a" \
        OTC_BUCKET_B "${CROSSPLANE_OTC_RESOURCE_PREFIX}-it-b"
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
