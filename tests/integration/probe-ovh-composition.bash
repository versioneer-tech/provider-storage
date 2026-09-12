#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.bash
source "${INTEGRATION_DIR}/lib.bash"

: "${CROSSPLANE_OVH_PROJECT_ID:?Set the project ID used by ovh/dependencies/iam.sh.}"
if [[ ! ${CROSSPLANE_OVH_PROJECT_ID} =~ ^[0-9a-f]{32}$ ]]; then
  printf 'CROSSPLANE_OVH_PROJECT_ID must be a 32-character lowercase hexadecimal ID.\n' >&2
  exit 1
fi
storage_region=${CROSSPLANE_OVH_STORAGE_REGION:-de}
case $storage_region in
  de|gra) ;;
  *) printf 'CROSSPLANE_OVH_STORAGE_REGION must be de or gra.\n' >&2; exit 1 ;;
esac

require_cluster
require_command jq
project_prefix=${CROSSPLANE_OVH_PROJECT_ID:0:12}
consumer_name="xyz-ovh-it-${project_prefix}"
bucket_name="xyz-ovh-${project_prefix}-${storage_region}-compose"
job_name="xyz-ovh-consumer-rt-${project_prefix}-$(date +%s)"

kube apply -f "${REPO_ROOT}/xrd.yaml"
kube wait compositeresourcedefinition.apiextensions.crossplane.io/storages.pkg.internal \
  --for=condition=Established --timeout=5m
kube apply -f "${REPO_ROOT}/ovh/composition.yaml"
apply_template "${MANIFEST_DIR}/storages/ovh.yaml" \
  OVH_PROJECT_PREFIX "${project_prefix}" \
  OVH_STORAGE_REGION "${storage_region}"
kube wait storage.pkg.internal/storage-ovh-it \
  --namespace "${INTEGRATION_NAMESPACE}" \
  --for=condition=Ready --timeout=5m
kube get secret "${consumer_name}" --namespace "${INTEGRATION_NAMESPACE}" -o json |
  jq -e '.data | (keys == ["AWS_ACCESS_KEY_ID", "AWS_ENDPOINT_URL", "AWS_REGION", "AWS_S3_FORCE_PATH_STYLE", "AWS_SECRET_ACCESS_KEY"]) and all(.[]; length > 0)' >/dev/null
kube get projectstorage.cloud.ovh.m.edixos.io "${bucket_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" -o json |
  jq -e '.spec.forProvider.hideObjects == true and (.spec.managementPolicies | index("Delete") | not)' >/dev/null

apply_template "${MANIFEST_DIR}/ovh-probe/consumer-roundtrip.yaml" \
  JOB_NAME "${job_name}" \
  RCLONE_IMAGE "${RCLONE_IMAGE}" \
  OVH_CONSUMER_NAME "${consumer_name}" \
  OVH_BUCKET_NAME "${bucket_name}"
kube wait "job/${job_name}" --namespace "${INTEGRATION_NAMESPACE}" \
  --for=condition=Complete --timeout=3m
kube logs "job/${job_name}" --namespace "${INTEGRATION_NAMESPACE}"
