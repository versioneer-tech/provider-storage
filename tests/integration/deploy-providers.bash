#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.bash
source "${INTEGRATION_DIR}/lib.bash"

backend="$(selected_backend "${1:-}" "$0")"

install_crossplane() {
  require_command helm
  log "Installing Crossplane ${CROSSPLANE_VERSION}"
  helm repo add crossplane-stable https://charts.crossplane.io/stable --force-update
  helm repo update crossplane-stable
  helm upgrade --install crossplane crossplane-stable/crossplane \
    --kube-context "${KUBECTL_CONTEXT}" \
    --namespace "${CROSSPLANE_NAMESPACE}" \
    --version "${CROSSPLANE_VERSION}" \
    --set 'provider.defaultActivations={}' \
    --wait \
    --timeout 10m
}

install_common_api() {
  kube apply -f "${REPO_ROOT}/xrd.yaml"
  kube wait crd/storages.pkg.internal --for=condition=Established --timeout=2m
}

install_dependencies() {
  local backend="$1"
  kube apply -f "${REPO_ROOT}/${backend}/dependencies/00-mrap.yaml"
  kube apply -f "${REPO_ROOT}/${backend}/dependencies/01-deploymentRuntimeConfigs.yaml"
  kube apply -f "${REPO_ROOT}/${backend}/dependencies/02-providers.yaml"
  kube apply -f "${REPO_ROOT}/${backend}/dependencies/functions.yaml"
  kube apply -f "${REPO_ROOT}/${backend}/dependencies/rbac.yaml"

  kube wait provider.pkg.crossplane.io/provider-kubernetes \
    --for=condition=Healthy --timeout=10m
  kube wait function.pkg.crossplane.io/crossplane-contrib-function-python \
    --for=condition=Healthy --timeout=10m
  kube wait function.pkg.crossplane.io/crossplane-contrib-function-auto-ready \
    --for=condition=Healthy --timeout=10m
}

preflight_minio() {
  return
}

preflight_aws() {
  : "${CROSSPLANE_AWS_ACCOUNT_ID:?Set CROSSPLANE_AWS_ACCOUNT_ID to the 12-digit account used by aws/dependencies/iam.sh.}"
  : "${CROSSPLANE_AWS_REGION:=eu-central-1}"
  if [[ ! "${CROSSPLANE_AWS_ACCOUNT_ID}" =~ ^[0-9]{12}$ ]]; then
    printf 'CROSSPLANE_AWS_ACCOUNT_ID must be a 12-digit AWS account ID.\n' >&2
    exit 1
  fi
  : "${CROSSPLANE_AWS_RUNTIME_ROLE_ARN:=arn:aws:iam::${CROSSPLANE_AWS_ACCOUNT_ID}:role/provider-storage/crossplane}"
  validate_region CROSSPLANE_AWS_REGION "${CROSSPLANE_AWS_REGION}"
  if [[ ! "${CROSSPLANE_AWS_RUNTIME_ROLE_ARN}" =~ ^arn:aws:iam::${CROSSPLANE_AWS_ACCOUNT_ID}:role/.+[^/]$ ]]; then
    printf 'CROSSPLANE_AWS_RUNTIME_ROLE_ARN must be a role in CROSSPLANE_AWS_ACCOUNT_ID.\n' >&2
    exit 1
  fi
  if ! kube get secret/aws-provider-creds --namespace "${INTEGRATION_NAMESPACE}" >/dev/null 2>&1; then
    printf '%s\n' \
      "Secret ${INTEGRATION_NAMESPACE}/aws-provider-creds is missing. Create it with the kubectl command in tests/integration/README.md." >&2
    exit 1
  fi
}

preflight_otc() {
  : "${CROSSPLANE_OTC_REGION:=eu-nl}"
  : "${CROSSPLANE_OTC_ENDPOINT:=https://obs.eu-nl.otc.t-systems.com}"
  otc_resource_prefix >/dev/null
  validate_region CROSSPLANE_OTC_REGION "${CROSSPLANE_OTC_REGION}"
  if [[ ! "${CROSSPLANE_OTC_ENDPOINT}" =~ ^https://[A-Za-z0-9.-]+$ ]]; then
    printf 'CROSSPLANE_OTC_ENDPOINT must be an HTTPS origin without a path.\n' >&2
    exit 1
  fi
  if ! kube get secret/otc-provider-creds --namespace "${INTEGRATION_NAMESPACE}" >/dev/null 2>&1; then
    printf '%s\n' \
      "Secret ${INTEGRATION_NAMESPACE}/otc-provider-creds is missing. Create it with the kubectl command in tests/integration/README.md." >&2
    exit 1
  fi
}

preflight_ovh() {
  ovh_project_prefix >/dev/null
  ovh_storage_region >/dev/null
  if ! kube get secret/ovh-provider-creds --namespace "${INTEGRATION_NAMESPACE}" >/dev/null 2>&1; then
    printf 'Secret %s/ovh-provider-creds is missing. Create it with the command in tests/integration/README.md.\n' \
      "${INTEGRATION_NAMESPACE}" >&2
    exit 1
  fi
}

install_minio() {
  log "Deploying MinIO and its providers"
  kube apply -f "${MANIFEST_DIR}/minio.yaml"
  kube rollout status deployment/default --namespace minio --timeout=5m
  install_dependencies minio
  kube wait provider.pkg.crossplane.io/provider-minio \
    --for=condition=Healthy --timeout=10m
  apply_template \
    "${MANIFEST_DIR}/provider-configs/minio.yaml" \
    INTEGRATION_NAMESPACE "${INTEGRATION_NAMESPACE}"
  kube apply -f "${MANIFEST_DIR}/environment-configs/minio.yaml"
  kube apply -f "${REPO_ROOT}/minio/composition.yaml"
}

install_aws() {
  log "Deploying AWS providers"
  install_dependencies aws
  kube wait provider.pkg.crossplane.io/provider-aws-s3 \
    --for=condition=Healthy --timeout=10m
  kube wait provider.pkg.crossplane.io/provider-aws-iam \
    --for=condition=Healthy --timeout=10m
  kube wait provider.pkg.crossplane.io/upbound-provider-family-aws \
    --for=condition=Healthy --timeout=10m
  apply_template \
    "${MANIFEST_DIR}/provider-configs/aws.yaml" \
    INTEGRATION_NAMESPACE "${INTEGRATION_NAMESPACE}" \
    AWS_RUNTIME_ROLE_ARN "${CROSSPLANE_AWS_RUNTIME_ROLE_ARN}"
  apply_template \
    "${MANIFEST_DIR}/environment-configs/aws.yaml" \
    AWS_REGION "${CROSSPLANE_AWS_REGION}"
  kube apply -f "${REPO_ROOT}/aws/composition.yaml"
}

install_otc() {
  log "Deploying OTC providers"
  install_dependencies otc
  kube wait provider.pkg.crossplane.io/provider-otc \
    --for=condition=Healthy --timeout=10m
  apply_template \
    "${MANIFEST_DIR}/provider-configs/otc.yaml" \
    INTEGRATION_NAMESPACE "${INTEGRATION_NAMESPACE}"
  apply_template \
    "${MANIFEST_DIR}/environment-configs/otc.yaml" \
    OTC_ENDPOINT "${CROSSPLANE_OTC_ENDPOINT}" \
    OTC_REGION "${CROSSPLANE_OTC_REGION}"
  kube apply -f "${REPO_ROOT}/otc/composition.yaml"
}

install_ovh() {
  local region
  region="$(ovh_storage_region)"
  log "Deploying OVHcloud providers"
  install_dependencies ovh
  kube wait provider.pkg.crossplane.io/provider-ovh \
    --for=condition=Healthy --timeout=10m
  apply_template \
    "${MANIFEST_DIR}/provider-configs/ovh.yaml" \
    INTEGRATION_NAMESPACE "${INTEGRATION_NAMESPACE}"
  apply_template \
    "${MANIFEST_DIR}/environment-configs/ovh.yaml" \
    OVH_ENDPOINT "https://s3.${region}.io.cloud.ovh.net" \
    OVH_REGION "${region}" \
    OVH_PROJECT_ID "${CROSSPLANE_OVH_PROJECT_ID}"
  kube apply -f "${REPO_ROOT}/ovh/composition.yaml"
}

main() {
  require_cluster
  "preflight_${backend}"

  kube apply -f "${MANIFEST_DIR}/namespaces.yaml"
  install_crossplane
  install_common_api
  "install_${backend}"

  kube get providers.pkg.crossplane.io,functions.pkg.crossplane.io
}

main
