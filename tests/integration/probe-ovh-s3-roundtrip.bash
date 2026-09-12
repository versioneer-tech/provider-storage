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
project_prefix=${CROSSPLANE_OVH_PROJECT_ID:0:12}
bucket_name="xyz-ovh-${project_prefix}-${storage_region}-probe"
principal=${CROSSPLANE_OVH_S3_PRINCIPAL:-owner}
case $principal in
  owner) credentials_name="xyz-ovh-s3-${project_prefix}" ;;
  writer) credentials_name="xyz-ovh-writer-s3-${project_prefix}" ;;
  *) printf 'CROSSPLANE_OVH_S3_PRINCIPAL must be owner or writer.\n' >&2; exit 1 ;;
esac
connection_name="${credentials_name}-connection"
kube wait "projectstorage.cloud.ovh.m.edixos.io/${bucket_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  --for=condition=Ready --timeout=30s
kube wait "s3credentials.cloud.ovh.m.edixos.io/${credentials_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  --for=condition=Ready --timeout=30s

job_name="xyz-ovh-${principal}-rt-${project_prefix}-$(date -u +%s)"
apply_template "${MANIFEST_DIR}/ovh-probe/s3-roundtrip.yaml" \
  JOB_NAME "${job_name}" \
  RCLONE_IMAGE "${RCLONE_IMAGE}" \
  CONNECTION_NAME "${connection_name}" \
  OVH_STORAGE_REGION "${storage_region}" \
  OVH_BUCKET_NAME "${bucket_name}"
wait_for_job "${job_name}"
