#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.bash
source "${INTEGRATION_DIR}/lib.bash"

: "${CROSSPLANE_OVH_PROJECT_ID:?Set the project ID used by ovh/dependencies/iam.sh.}"
: "${CROSSPLANE_OVH_STORAGE_REGION:=de}"
if [[ ! ${CROSSPLANE_OVH_PROJECT_ID} =~ ^[0-9a-f]{32}$ ]]; then
  printf 'CROSSPLANE_OVH_PROJECT_ID must be a 32-character lowercase hexadecimal ID.\n' >&2
  exit 1
fi
if [[ ${CROSSPLANE_OVH_STORAGE_REGION} != de && ${CROSSPLANE_OVH_STORAGE_REGION} != gra ]]; then
  printf 'CROSSPLANE_OVH_STORAGE_REGION must be de or gra for this probe.\n' >&2
  exit 1
fi

require_cluster
require_command helm
if ! kube get secret/ovh-provider-creds --namespace "${INTEGRATION_NAMESPACE}" >/dev/null 2>&1; then
  printf 'Secret %s/ovh-provider-creds is missing. Create it with the command in tests/integration/README.md.\n' \
    "${INTEGRATION_NAMESPACE}" >&2
  exit 1
fi

log "Installing Crossplane ${CROSSPLANE_VERSION} in the dedicated Kind cluster"
helm repo add crossplane-stable https://charts.crossplane.io/stable --force-update
helm repo update crossplane-stable
helm upgrade --install crossplane crossplane-stable/crossplane \
  --kube-context "${KUBECTL_CONTEXT}" \
  --namespace "${CROSSPLANE_NAMESPACE}" \
  --version "${CROSSPLANE_VERSION}" \
  --set 'provider.defaultActivations={}' \
  --wait --timeout 10m

log 'Installing OVHcloud provider dependencies'
kube apply -f "${REPO_ROOT}/ovh/dependencies/00-mrap.yaml"
kube apply -f "${REPO_ROOT}/ovh/dependencies/01-deploymentRuntimeConfigs.yaml"
kube apply -f "${REPO_ROOT}/ovh/dependencies/02-providers.yaml"
kube apply -f "${REPO_ROOT}/ovh/dependencies/functions.yaml"
kube apply -f "${REPO_ROOT}/ovh/dependencies/rbac.yaml"
kube wait provider.pkg.crossplane.io/provider-ovh --for=condition=Healthy --timeout=10m
kube wait provider.pkg.crossplane.io/provider-kubernetes --for=condition=Healthy --timeout=10m
kube wait function.pkg.crossplane.io/crossplane-contrib-function-python \
  --for=condition=Healthy --timeout=10m
kube wait function.pkg.crossplane.io/crossplane-contrib-function-auto-ready \
  --for=condition=Healthy --timeout=10m

apply_template "${MANIFEST_DIR}/provider-configs/ovh.yaml" \
  INTEGRATION_NAMESPACE "${INTEGRATION_NAMESPACE}"
apply_template "${MANIFEST_DIR}/environment-configs/ovh.yaml" \
  OVH_ENDPOINT "https://s3.${CROSSPLANE_OVH_STORAGE_REGION}.io.cloud.ovh.net" \
  OVH_REGION "${CROSSPLANE_OVH_STORAGE_REGION}" \
  OVH_PROJECT_ID "${CROSSPLANE_OVH_PROJECT_ID}"

printf 'OVHcloud provider is ready for direct-resource probes in %s.\n' \
  "${INTEGRATION_NAMESPACE}"
printf 'No OVHcloud storage resource was created by this command.\n'
