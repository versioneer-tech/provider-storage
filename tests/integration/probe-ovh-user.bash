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

require_cluster
owner_name="xyz-ovh-owner-${CROSSPLANE_OVH_PROJECT_ID:0:12}"
if ! kube get providerconfig.ovh.m.edixos.io/provider-ovh \
  --namespace "${INTEGRATION_NAMESPACE}" >/dev/null 2>&1; then
  printf 'The OVHcloud ProviderConfig is missing. Run tests/integration/deploy-ovh-probe.bash first.\n' >&2
  exit 1
fi

apply_template "${MANIFEST_DIR}/ovh-probe/user.yaml" \
  OVH_OWNER_NAME "${owner_name}" \
  OVH_PROJECT_ID "${CROSSPLANE_OVH_PROJECT_ID}"
kube wait "user.cloud.ovh.m.edixos.io/${owner_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  --for=condition=Ready --timeout=5m

owner_id=$(kube get "user.cloud.ovh.m.edixos.io/${owner_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  -o jsonpath='{.status.atProvider.id}')
if [[ ! ${owner_id} =~ ^[0-9]+$ ]]; then
  printf 'The OVHcloud user is Ready but has no numeric observed ID.\n' >&2
  exit 1
fi
printf 'OVHcloud owner probe user is Ready with a numeric observed ID.\n'
