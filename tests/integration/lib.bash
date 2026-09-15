#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${INTEGRATION_DIR}/../.." && pwd)"
MANIFEST_DIR="${INTEGRATION_DIR}/manifests"

readonly KIND_CLUSTER_NAME=provider-storage-it
readonly KUBECTL_CONTEXT=kind-provider-storage-it
readonly INTEGRATION_NAMESPACE=provider-storage-it
readonly CROSSPLANE_NAMESPACE=crossplane
: "${CROSSPLANE_VERSION:=2.0.2}"
: "${RCLONE_IMAGE:=rclone/rclone:1.75.1}"

log() {
  printf '\n==> %s\n' "$*"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

kube() {
  command kubectl --context "${KUBECTL_CONTEXT}" "$@"
}

kind_cluster_exists() {
  kind get clusters 2>/dev/null | grep -Fxq "${KIND_CLUSTER_NAME}"
}

require_cluster() {
  require_command kind
  require_command kubectl

  if ! kind_cluster_exists || ! kube cluster-info >/dev/null 2>&1; then
    printf 'The dedicated kind cluster %s is not available.\n' "${KIND_CLUSTER_NAME}" >&2
    printf 'After approval, create it with: tests/integration/create-cluster.bash\n' >&2
    exit 2
  fi
}

selected_backend() {
  local value="${1:-}"
  case "${value}" in
    minio|aws|otc|ovh|cloudferro)
      printf '%s\n' "${value}"
      ;;
    *)
      printf 'Usage: %s <minio|aws|otc|ovh|cloudferro>\n' "$2" >&2
      exit 1
      ;;
  esac
}

validate_dns_label() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || ((${#value} > 63)); then
    printf '%s must be a valid DNS label: %s\n' "${name}" "${value}" >&2
    exit 1
  fi
}

validate_resource_prefix() {
  local name="$1"
  local value="$2"
  validate_dns_label "${name}" "${value}"
  if ((${#value} > 50)); then
    printf '%s must be at most 50 characters so the test bucket fits.\n' "${name}" >&2
    exit 1
  fi
}

validate_aws_resource_prefix() {
  local value="$1"
  if [[ ! "${value}" =~ ^[a-z0-9][a-z0-9-]{2,39}$ ]]; then
    printf 'CROSSPLANE_AWS_RESOURCE_PREFIX must be 3-40 lowercase letters, digits, or hyphens.\n' >&2
    exit 1
  fi
}

aws_resource_prefix() {
  local value="${CROSSPLANE_AWS_RESOURCE_PREFIX:-}"
  if [[ -z "${value}" ]]; then
    if [[ ! "${CROSSPLANE_AWS_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]]; then
      printf 'Set CROSSPLANE_AWS_ACCOUNT_ID or CROSSPLANE_AWS_RESOURCE_PREFIX.\n' >&2
      exit 1
    fi
    value="aws-${CROSSPLANE_AWS_ACCOUNT_ID}"
  fi
  validate_aws_resource_prefix "${value}"
  printf '%s\n' "${value}"
}

otc_resource_prefix() {
  local value="${CROSSPLANE_OTC_RESOURCE_PREFIX:-}"
  if [[ -z "${value}" ]]; then
    if [[ ! "${CROSSPLANE_OTC_DOMAIN_ID:-}" =~ ^[0-9a-f]{32}$ ]]; then
      printf 'Set CROSSPLANE_OTC_DOMAIN_ID or CROSSPLANE_OTC_RESOURCE_PREFIX.\n' >&2
      exit 1
    fi
    value="otc-${CROSSPLANE_OTC_DOMAIN_ID}"
  fi
  validate_resource_prefix CROSSPLANE_OTC_RESOURCE_PREFIX "${value}"
  printf '%s\n' "${value}"
}

ovh_project_prefix() {
  local value="${CROSSPLANE_OVH_PROJECT_ID:-}"
  if [[ ! "${value}" =~ ^[0-9a-f]{32}$ ]]; then
    printf 'CROSSPLANE_OVH_PROJECT_ID must be a 32-character lowercase hexadecimal ID.\n' >&2
    exit 1
  fi
  printf '%s\n' "${value:0:12}"
}

ovh_storage_region() {
  local value="${CROSSPLANE_OVH_STORAGE_REGION:-de}"
  case "${value}" in
    de|gra) printf '%s\n' "${value}" ;;
    *) printf 'CROSSPLANE_OVH_STORAGE_REGION must be de or gra.\n' >&2; exit 1 ;;
  esac
}

cloudferro_slot() {
  local value="${CROSSPLANE_CLOUDFERRO_SLOT:-cloudferro-0001}"
  if [[ ! "${value}" =~ ^cloudferro-[0-9]{4}$ ]]; then
    printf 'CROSSPLANE_CLOUDFERRO_SLOT must be cloudferro- plus four digits.\n' >&2
    exit 1
  fi
  printf '%s\n' "${value}"
}

cloudferro_it2_enabled() {
  case "${CROSSPLANE_CLOUDFERRO_IT2:-false}" in
    true) return 0 ;;
    false) return 1 ;;
    *)
      printf 'CROSSPLANE_CLOUDFERRO_IT2 must be true or false.\n' >&2
      exit 1
      ;;
  esac
}

cloudferro_project_prefix() {
  local slot project
  slot="$(cloudferro_slot)"
  if ! project="$(kube get "environmentconfig/storage-${slot}" \
    -o jsonpath='{.data.storage.serviceName}' 2>/dev/null)"; then
    printf 'CloudFerro slot %s is missing. Run cloudferro/dependencies/iam.sh apply first.\n' \
      "${slot}" >&2
    exit 1
  fi
  if [[ ! "${project}" =~ ^[0-9a-f]{32}$ ]]; then
    printf 'CloudFerro slot %s has no valid project ID.\n' "${slot}" >&2
    exit 1
  fi
  printf '%s\n' "${project:0:12}"
}

validate_region() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    printf '%s contains unsupported characters: %s\n' "${name}" "${value}" >&2
    exit 1
  fi
}

render_template() {
  local source="$1"
  shift
  local rendered placeholder value

  rendered="$(<"${source}")"
  while (($#)); do
    if (($# < 2)); then
      printf 'Template variable has no value for %s\n' "${source}" >&2
      exit 1
    fi
    placeholder="__$1__"
    value="$2"
    rendered="${rendered//${placeholder}/${value}}"
    shift 2
  done

  if grep -Eq '__[A-Z0-9_]+__' <<<"${rendered}"; then
    printf 'Unresolved placeholder in %s\n' "${source}" >&2
    exit 1
  fi
  printf '%s\n' "${rendered}"
}

apply_template() {
  local source="$1"
  shift
  render_template "${source}" "$@" | kube apply -f -
}

wait_for_job() {
  local name="$1"
  if ! kube wait "job/${name}" \
    --namespace "${INTEGRATION_NAMESPACE}" \
    --for=condition=Complete \
    --timeout=5m; then
    kube logs "job/${name}" \
      --namespace "${INTEGRATION_NAMESPACE}" \
      --all-containers=true || true
    kube describe "job/${name}" --namespace "${INTEGRATION_NAMESPACE}" || true
    exit 1
  fi
  kube logs "job/${name}" \
    --namespace "${INTEGRATION_NAMESPACE}" \
    --all-containers=true
}
