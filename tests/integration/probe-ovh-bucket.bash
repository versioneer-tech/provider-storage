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
owner_name="xyz-ovh-owner-${project_prefix}"
bucket_name="xyz-ovh-${project_prefix}-${storage_region}-probe"
kube wait "user.cloud.ovh.m.edixos.io/${owner_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  --for=condition=Ready --timeout=30s
owner_id=$(kube get "user.cloud.ovh.m.edixos.io/${owner_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  -o jsonpath='{.status.atProvider.id}')
[[ $owner_id =~ ^[0-9]+$ ]] || {
  printf 'The OVHcloud owner User has no numeric observed ID.\n' >&2
  exit 1
}

apply_template "${MANIFEST_DIR}/ovh-probe/bucket.yaml" \
  OVH_BUCKET_NAME "${bucket_name}" \
  OVH_PROJECT_ID "${CROSSPLANE_OVH_PROJECT_ID}" \
  OVH_REGION_NAME "${storage_region^^}" \
  OVH_OWNER_ID "${owner_id}"
kube wait "projectstorage.cloud.ovh.m.edixos.io/${bucket_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  --for=condition=Ready --timeout=5m

observed_owner_id=$(kube get "projectstorage.cloud.ovh.m.edixos.io/${bucket_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  -o jsonpath='{.status.atProvider.ownerId}')
observed_region=$(kube get "projectstorage.cloud.ovh.m.edixos.io/${bucket_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  -o jsonpath='{.status.atProvider.regionName}')
[[ $observed_owner_id == "$owner_id" && ${observed_region,,} == "$storage_region" ]] || {
  printf 'The bucket is Ready but its observed owner or region differs.\n' >&2
  exit 1
}
printf 'OVHcloud bucket %s is Ready with the requested owner and region.\n' "$bucket_name"
