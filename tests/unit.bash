#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if (($#)); then
  BACKENDS=("$@")
else
  BACKENDS=(minio aws otc ovh cloudferro)
fi
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
: "${CROSSPLANE_VERSION:=v2.4.3}"
if [[ -z "${PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR:-}" ]]; then
  [[ "${HOME:-}" == /* ]] || {
    printf 'HOME must be an absolute path for the default Crossplane cache.\n' >&2
    exit 1
  }
  PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR="${HOME}/.cache/provider-storage/crossplane"
fi
[[ "${PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR}" == /* ]] || {
  printf 'PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR must be an absolute path.\n' >&2
  exit 1
}
mkdir -p "${PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR}"
mkdir -p "${TMP_DIR}/validation"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

render() {
  local backend="$1" source="$2"
  shift 2
  crossplane render "${source}" \
    "${REPO_ROOT}/${backend}/composition.yaml" \
    "${REPO_ROOT}/${backend}/dependencies/functions.yaml" \
    --cache-dir="${PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR}" \
    --xrd="${REPO_ROOT}/xrd.yaml" \
    --crossplane-version="${CROSSPLANE_VERSION}" --timeout=5m -x "$@"
}

validate_shell_syntax() {
  local script
  printf 'Validate shell script syntax\n'
  while IFS= read -r -d '' script; do
    bash -n "${script}"
  done < <(
    find "${REPO_ROOT}" -type f \( -name '*.bash' -o -name '*.sh' \) -print0 |
      sort -z
  )
}

assert_yaml() {
  local file=$1 expression=$2 description=$3
  if ! yq eval-all -e "${expression}" "${file}" >/dev/null; then
    printf 'YAML assertion failed: %s (%s)\n' "${description}" "${file}" >&2
    return 1
  fi
}

normalize_principal_generations() {
  local content="$1"
  local principal="$2"
  local suffix_pattern="$3"
  local marker="$4"
  local generation index=0

  while IFS= read -r generation; do
    [[ -z "${generation}" ]] || {
      content="${content//${generation}/${principal}-${marker}-${index}}"
      index=$((index + 1))
    }
  done < <(
    local remaining="${content}"
    local expression="${principal}-${suffix_pattern}"
    while [[ "${remaining}" =~ ${expression} ]]; do
      printf '%s\n' "${BASH_REMATCH[0]}"
      remaining="${remaining#*"${BASH_REMATCH[0]}"}"
    done | sort -ru
  )

  printf '%s' "${content}"
}

normalize_generations() {
  local source="$1"
  local target="$2"
  local content

  content="$(<"${source}")"
  content="$(normalize_principal_generations "${content}" s-jeff '[0-9]{4}w[0-9]{2}' WEEK)"
  content="$(normalize_principal_generations "${content}" s-jane '[0-9]{4}q[1-4]' QUARTER)"
  content="$(normalize_principal_generations "${content}" s-john '[0-9]{8}' DAY)"
  printf '%s\n' "${content}" >"${target}"
}

queue_schema_validation() {
  local backend="$1"
  local resources="$2"
  local validation_resources="${TMP_DIR}/validation/${backend}.yaml"

  if [[ -s "${validation_resources}" ]]; then
    printf '%s\n' '---' >>"${validation_resources}"
  fi
  awk '
    /^---$/ {
      document++
      if (document == 1) next
    }
    document == 1 && /^      namespace:/ { next }
    { print }
  ' "${resources}" >>"${validation_resources}"
}

validate_schemas() {
  local backend="$1"
  local validation_resources="${TMP_DIR}/validation/${backend}.yaml"

  printf 'Validate %s render against extension schemas\n' "${backend}"
  [[ -s "${validation_resources}" ]] || {
    printf 'No rendered resources were queued for %s schema validation.\n' "${backend}" >&2
    return 1
  }
  local extensions="${TMP_DIR}/validation/${backend}-extensions.yaml"
  "${PROVIDER_STORAGE_PYTHON:-python3}" "${REPO_ROOT}/tests/schemas.py" \
    "${validation_resources}" "${extensions}"
  crossplane resource validate \
    "${REPO_ROOT}/xrd.yaml,${REPO_ROOT}/${backend}/dependencies/02-providers.yaml" \
    "${extensions}" \
    --cache-dir "${PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR}" \
    --crossplane-image "xpkg.crossplane.io/crossplane/crossplane:${CROSSPLANE_VERSION}" \
    --error-on-missing-schemas \
    --skip-success-results
}

validate_aws_secret_readiness() {
  local scenario="${REPO_ROOT}/aws/tests/readiness"
  local rendered="${TMP_DIR}/aws-secret-readiness.yaml"
  local composite="${TMP_DIR}/aws-secret-readiness-composite.yaml"

  printf 'Validate AWS readiness while the credential Secret is unavailable\n'
  render "aws" "${scenario}/input.yaml" \
    --observed-resources "${scenario}/observed.yaml" \
    >"${rendered}"
  awk 'NR == 1 { next } /^---$/ { exit } { print }' \
    "${rendered}" >"${composite}"
  dyff between "${composite}" "${scenario}/expected.yaml" -s
  queue_schema_validation aws "${rendered}"
}

validate_aws_none_grant() {
  local input="${TMP_DIR}/aws-none-grant-input.yaml"
  local rendered="${TMP_DIR}/aws-none-grant.yaml"

  printf 'Validate AWS None grant policy omission\n'
  sed 's/permission: ReadWrite/permission: None/' \
    "${REPO_ROOT}/examples/base/001-buckets.yaml" >"${input}"
  render "aws" "${input}" \
    >"${rendered}"
  assert_yaml "${rendered}" '
    [.] | (
    ([.[] | select(
      .kind == "Policy" and
      .metadata.name == "provider-storage.s-jeff.s-joe"
    )] | length) == 0 and
    ([.[] | select(.kind == "Policy") |
      .spec.forProvider.policy | from_json | .Statement | length] |
      all_c(. > 0)))
  ' 'AWS None grant policy omission'
  queue_schema_validation aws "${rendered}"
}

validate_ovh_provider_identity() {
  local input="${TMP_DIR}/ovh-provider-identity-input.yaml"
  local rendered="${TMP_DIR}/ovh-provider-identity.yaml"

  printf 'Validate OVHcloud providerIdentity resource names\n'
  sed '/^  principal: s-joe$/a\  providerIdentity: it' \
    "${REPO_ROOT}/examples/base/001-buckets.yaml" >"${input}"
  render "ovh" "${input}" \
    --required-resources "${REPO_ROOT}/ovh/tests/required/environment.yaml" \
    >"${rendered}"
  assert_yaml "${rendered}" '
    [.] | ((map("\(.kind)/\(.metadata.name)") | sort | to_json) == ([
      "Storage/s-joe",
      "User/it",
      "User/it-owner"
    ] | to_json))
  ' 'OVHcloud providerIdentity resource names'
  queue_schema_validation ovh "${rendered}"
}

validate_cloudferro_composition() {
  local input="${REPO_ROOT}/cloudferro/tests/fixtures/001-buckets.yaml"
  local required="${REPO_ROOT}/cloudferro/tests/required/001-buckets.yaml"
  local base="${TMP_DIR}/cloudferro-base.yaml"
  local credential="${TMP_DIR}/cloudferro-credential.yaml"
  local second="${TMP_DIR}/cloudferro-second-project.yaml"

  printf 'Validate CloudFerro project binding, credentials, and deletion order\n'
  render cloudferro "${input}" --required-resources "${required}" >"${base}"
  render cloudferro "${input}" --required-resources "${required}" \
    --observed-resources "${REPO_ROOT}/cloudferro/tests/observed/credential-ready.yaml" >"${credential}"
  render cloudferro "${REPO_ROOT}/cloudferro/tests/fixtures/002-buckets.yaml" \
    --required-resources "${REPO_ROOT}/cloudferro/tests/required/002-buckets.yaml" >"${second}"
  "${PROVIDER_STORAGE_PYTHON:-python3}" "${REPO_ROOT}/tests/cloudferro.py" \
    "${base}" "${credential}" "${second}"
  queue_schema_validation cloudferro "${base}"
  queue_schema_validation cloudferro "${credential}"
  queue_schema_validation cloudferro "${second}"
}

render_and_compare() {
  local backend="$1"
  local source="$2"
  local expected="$3"
  local actual="$4"
  shift 4

  printf 'Render %s with %s\n' "${source#"${REPO_ROOT}/"}" "${backend}"
  render "${backend}" "${source}" \
    "$@" \
    >"${actual}"
  normalize_generations "${actual}" "${actual}.normalized"
  normalize_generations "${expected}" "${actual}.expected.normalized"
  dyff between "${actual}.normalized" "${actual}.expected.normalized" -s
  queue_schema_validation "${backend}" "${actual}"
}

run_backend() {
  local backend="$1"
  local source name observed required
  local -a render_args base_args

  case "${backend}" in
    minio|aws|otc|ovh) ;;
    *)
      printf 'Unknown backend: %s (expected minio, aws, otc, ovh, or cloudferro)\n' "${backend}" >&2
      exit 1
      ;;
  esac

  base_args=()
  if [[ "${backend}" == "ovh" ]]; then
    base_args+=(--required-resources "${REPO_ROOT}/ovh/tests/required/environment.yaml")
  fi

  for source in "${REPO_ROOT}"/examples/base/00*-buckets.yaml; do
    name="$(basename "${source}")"

    render_and_compare \
      "${backend}" \
      "${source}" \
      "${REPO_ROOT}/${backend}/tests/expected/${name}" \
      "${TMP_DIR}/${backend}-${name}" \
      "${base_args[@]}"

    observed="${REPO_ROOT}/${backend}/tests/observed/${name}"
    required="${REPO_ROOT}/${backend}/tests/required/${name}"
    render_args=()
    [[ ! -f "${observed}" ]] || render_args+=(--observed-resources "${observed}")
    [[ ! -f "${required}" ]] || render_args+=(--required-resources "${required}")
    if ((${#render_args[@]})) && [[ "${backend}" == "ovh" && ! -f "${required}" ]]; then
      render_args+=("${base_args[@]}")
    fi

    if ((${#render_args[@]})); then
      render_and_compare \
        "${backend}" \
        "${source}" \
        "${REPO_ROOT}/${backend}/tests/expected/with-dependencies/${name}" \
        "${TMP_DIR}/${backend}-with-dependencies-${name}" \
        "${render_args[@]}"
    fi
  done
}

main() {
  require_command crossplane
  require_command dyff
  require_command yq
  require_command jq

  "${PROVIDER_STORAGE_PYTHON:-python3}" "${REPO_ROOT}/scripts/build-composition.py" --check
  "${PROVIDER_STORAGE_PYTHON:-python3}" "${REPO_ROOT}/tests/function-runtime.py" "${BACKENDS[@]}"
  "${PROVIDER_STORAGE_PYTHON:-python3}" "${REPO_ROOT}/tests/integration/access-checks.py" "${BACKENDS[@]}"
  validate_shell_syntax
  "${PROVIDER_STORAGE_PYTHON:-python3}" "${REPO_ROOT}/tests/bootstrap-iam.py"

  local backend
  for backend in "${BACKENDS[@]}"; do
    if [[ "${backend}" == "cloudferro" ]]; then
      validate_cloudferro_composition
      validate_schemas cloudferro
      continue
    fi
    run_backend "${backend}"
    if [[ "${backend}" == "aws" ]]; then
      validate_aws_secret_readiness
      validate_aws_none_grant
    fi
    if [[ "${backend}" == "ovh" ]]; then
      validate_ovh_provider_identity
    fi
    validate_schemas "${backend}"
  done

  printf 'All Composition unit tests passed.\n'
}

main
