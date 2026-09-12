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
writer_name="xyz-ovh-writer-${project_prefix}"
credentials_name="xyz-ovh-writer-s3-${project_prefix}"
connection_name="${credentials_name}-connection"
policy_name="xyz-ovh-writer-policy-${project_prefix}"
kube wait "projectstorage.cloud.ovh.m.edixos.io/${bucket_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  --for=condition=Ready --timeout=30s

apply_template "${MANIFEST_DIR}/ovh-probe/writer.yaml" \
  OVH_WRITER_NAME "${writer_name}" \
  OVH_PROJECT_ID "${CROSSPLANE_OVH_PROJECT_ID}"
kube wait "user.cloud.ovh.m.edixos.io/${writer_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  --for=condition=Ready --timeout=5m

apply_template "${MANIFEST_DIR}/ovh-probe/s3-credentials.yaml" \
  OVH_CREDENTIALS_NAME "${credentials_name}" \
  OVH_CONNECTION_NAME "${connection_name}" \
  OVH_OWNER_NAME "${writer_name}" \
  OVH_PROJECT_ID "${CROSSPLANE_OVH_PROJECT_ID}"
kube wait "s3credentials.cloud.ovh.m.edixos.io/${credentials_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  --for=condition=Ready --timeout=5m
kube wait "secret/${connection_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  --for=create --timeout=1m

apply_template "${MANIFEST_DIR}/ovh-probe/writer-policy.yaml" \
  OVH_WRITER_POLICY_NAME "${policy_name}" \
  OVH_WRITER_NAME "${writer_name}" \
  OVH_BUCKET_NAME "${bucket_name}" \
  OVH_PROJECT_ID "${CROSSPLANE_OVH_PROJECT_ID}"
kube wait "s3policy.cloud.ovh.m.edixos.io/${policy_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  --for=condition=Ready --timeout=5m
printf 'OVHcloud writer User, S3 credential, and bucket-scoped S3 policy are Ready.\n'
