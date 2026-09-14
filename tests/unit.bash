#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if (($#)); then
  BACKENDS=("$@")
else
  BACKENDS=(minio aws otc ovh)
fi
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
: "${CROSSPLANE_VERSION:=v2.0.2}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
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
  done < <(grep -Eo "${principal}-${suffix_pattern}" <<<"${content}" | sort -ru)

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

validate_schemas() {
  local backend="$1"
  local resources="$2"

  printf 'Validate %s render against extension schemas\n' "${backend}"
  crossplane beta validate \
    "${REPO_ROOT}/xrd.yaml,${REPO_ROOT}/${backend}/dependencies/02-providers.yaml" \
    "${resources}" \
    --cache-dir "${TMP_DIR}/crossplane-cache" \
    --crossplane-image "xpkg.crossplane.io/crossplane/crossplane:${CROSSPLANE_VERSION}" \
    --error-on-missing-schemas \
    --skip-success-results
}

validate_aws_iam_policy() {
  local policy="${REPO_ROOT}/aws/dependencies/policies/runtime-role-policy.json"
  local bootstrap_policy="${REPO_ROOT}/aws/dependencies/policies/bootstrap-user-policy.json"
  local script="${REPO_ROOT}/aws/dependencies/iam.sh"

  printf 'Validate AWS runtime IAM policy\n'
  bash -n "${script}"
  if "${script}" delete >"${TMP_DIR}/aws-delete.out" 2>&1; then
    printf 'AWS IAM bootstrap accepted an unsupported delete command.\n' >&2
    return 1
  fi
  grep -Fq 'Usage: aws/dependencies/iam.sh <apply|status>' \
    "${TMP_DIR}/aws-delete.out"
  grep -Fq ': "${CROSSPLANE_AWS_RESOURCE_PREFIX:=aws-${CROSSPLANE_AWS_ACCOUNT_ID:-}}"' \
    "${script}"
  grep -Fq ': "${CROSSPLANE_AWS_POLICY_NAME:=provider-storage}"' "${script}"
  jq -e '
    any(.Statement[];
      .Sid == "ReadUsersForReconciliation" and
      .Action == "iam:GetUser" and
      .Resource == "__ACCOUNT_USER_ARN_PATTERN__") and
    all(.Statement[] | select(.Sid == "ManageUsersAndAccessKeys") | .Action[];
      . != "iam:GetUser") and
    any(.Statement[];
      .Sid == "ManageUsersAndAccessKeys" and
      .Resource == "__MANAGED_USER_ARN_PATTERN__") and
    any(.Statement[];
      .Sid == "ManagePolicies" and
      .Resource == "__MANAGED_POLICY_ARN_PATTERN__") and
    any(.Statement[];
      .Sid == "ManagePrefixedBuckets" and
      .Resource == ["__BUCKET_ARN_PATTERN__", "__OBJECT_ARN_PATTERN__"]) and
    any(.Statement[];
      .Sid == "ProtectBootstrapUser" and .Effect == "Deny" and
      .Resource == "__BOOTSTRAP_USER_ARN__")
  ' "${policy}" >/dev/null
  jq -e '
    .Statement == [{Sid: "AssumeProviderStorageRuntimeRole", Effect: "Allow",
      Action: "sts:AssumeRole", Resource: "__RUNTIME_ROLE_ARN__"}]
  ' "${bootstrap_policy}" >/dev/null
}

validate_aws_secret_readiness() {
  local scenario="${REPO_ROOT}/aws/tests/readiness"
  local rendered="${TMP_DIR}/aws-secret-readiness.yaml"
  local composite="${TMP_DIR}/aws-secret-readiness-composite.yaml"

  printf 'Validate AWS readiness while the credential observer has no data\n'
  crossplane render \
    "${scenario}/input.yaml" \
    "${REPO_ROOT}/aws/composition.yaml" \
    "${REPO_ROOT}/aws/dependencies/functions.yaml" \
    --observed-resources "${scenario}/observed.yaml" \
    -x >"${rendered}"
  awk 'NR == 1 { next } /^---$/ { exit } { print }' \
    "${rendered}" >"${composite}"
  dyff between "${composite}" "${scenario}/expected.yaml" -s
  validate_schemas aws "${rendered}"
}

validate_ovh_secret_readiness() {
  local missing="${TMP_DIR}/ovh-missing-credential.yaml"

  printf 'Validate OVHcloud readiness while the credential Secret lacks its secret key\n'
  crossplane render \
    "${REPO_ROOT}/examples/base/001-buckets.yaml" \
    "${REPO_ROOT}/ovh/composition.yaml" \
    "${REPO_ROOT}/ovh/dependencies/functions.yaml" \
    --required-resources "${REPO_ROOT}/ovh/tests/required/001x-buckets.yaml" \
    --observed-resources "${REPO_ROOT}/ovh/tests/readiness/observed-missing.yaml" \
    -x >"${missing}"
  if grep -Fq 'crossplane.io/composition-resource-name: secret-s-joe' "${missing}"; then
    printf 'OVHcloud published a consumer Secret without a secret access key.\n' >&2
    return 1
  fi
  validate_schemas ovh "${missing}"
}

validate_capability_one() {
  local backend="$1" scenario actual composition="${REPO_ROOT}/${backend}/composition.yaml"
  local -a render_args

  if [[ "${backend}" == ovh ]]; then
    composition="${TMP_DIR}/composition-ovh-capability-one.yaml"
    yq eval '.metadata.name = "storage-ovh-capability-one" |
      .metadata.labels.provider = "ovh-capability-one"' \
      "${REPO_ROOT}/ovh/composition.yaml" >"${composition}"
  fi

  for scenario in "${REPO_ROOT}/${backend}/tests/capability-one"/t*; do
    printf 'Validate %s capability 1 transition %s\n' "${backend}" "${scenario##*/}"
    actual="${TMP_DIR}/${backend}-${scenario##*/}.yaml"
    render_args=(--required-resources "${scenario}/required.yaml")
    if [[ -f "${scenario}/observed.yaml" ]]; then
      render_args+=(--observed-resources "${scenario}/observed.yaml")
    fi
    crossplane render \
      "${scenario}/input.yaml" \
      "${composition}" \
      "${REPO_ROOT}/${backend}/dependencies/functions.yaml" \
      "${render_args[@]}" -x >"${actual}"
    dyff between "${scenario}/expected.yaml" "${actual}" -s
  done
}

validate_otc_iam_bootstrap() {
  local script="${REPO_ROOT}/otc/dependencies/iam.sh"
  local source_only="${TMP_DIR}/otc-iam-source.sh"
  local system_roles="${TMP_DIR}/otc-system-roles.json"
  local missing_global="${TMP_DIR}/otc-missing-global-role.json"
  local expected_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

  printf 'Validate OTC IAM bootstrap\n'
  bash -n "${script}"
  "${script}" --help | grep -Fq \
    'Bootstrap the OTC IAM resources that Provider Storage needs before deployment.'
  if "${script}" delete >"${TMP_DIR}/otc-delete.out" 2>&1; then
    printf 'OTC IAM bootstrap accepted an unsupported delete command.\n' >&2
    return 1
  fi
  grep -Fq 'Usage: otc/dependencies/iam.sh <apply|status|rotate-credential>' \
    "${TMP_DIR}/otc-delete.out"
  grep -Fq 'iam_request GET "${IAM_V3_ROOT}/auth/domains" 200' "${script}"
  grep -Fq 'The administrator session requires Security Administrator at domain scope.' \
    "${script}"
  grep -Fq 'export OS_DOMAIN_ID="${CROSSPLANE_OTC_DOMAIN_ID}"' "${script}"
  grep -Fq 'token_domain_id="$(jq -r' "${script}"
  grep -Fq ': "${CROSSPLANE_OTC_RESOURCE_PREFIX:=otc-${CROSSPLANE_OTC_DOMAIN_ID:-}}"' \
    "${script}"
  grep -Fq ': "${CROSSPLANE_OTC_USER_NAME:=provider-storage-bootstrap-crossplane}"' \
    "${script}"
  grep -Fq ': "${CROSSPLANE_OTC_GROUP_NAME:=provider-storage-bootstrap-crossplane}"' \
    "${script}"
  grep -Fq '"${IAM_V3_ROOT}/domains/${CROSSPLANE_OTC_DOMAIN_ID}/groups/${group_id}/roles/${role_id}"' \
    "${script}"
  grep -Fq 'verify_obs_admin_assignment "${group_id}" "${policy_id}"' "${script}"
  grep -Fq 'ensure_group_inherited_role_assignment "${group_id}" "${policy_id}"' "${script}"
  ! grep -Fq 'POLICY_TEMPLATE' "${script}"
  grep -Fq 'rotate-credential) rotate_credential' "${script}"

  sed '$d' "${script}" >"${source_only}"
  jq -n --arg id "${expected_id}" '{roles: [
    {display_name: "OBS Administrator", type: "AX", domain_id: null, id: $id},
    {display_name: "OBS Administrator", type: "AX", domain_id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", id: "cccccccccccccccccccccccccccccccc"},
    {display_name: "OBS Administrator", type: "XA", domain_id: null, id: "dddddddddddddddddddddddddddddddd"}
  ]}' >"${system_roles}"
  jq '{roles: [.roles[] | select(.domain_id != null)]}' \
    "${system_roles}" >"${missing_global}"
  [[ "$(bash -c '
    source "$1"
    fixture="$2"
    iam_request() {
      [[ "$1" == GET && "$2" == "https://example.test/v3/roles?display_name=OBS%20Administrator&permission_type=policy" ]] || return 1
      IAM_RESPONSE="$fixture"
    }
    IAM_V3_ROOT=https://example.test/v3
    obs_admin_policy_id
  ' bash "${source_only}" "${system_roles}")" == "${expected_id}" ]]
  if bash -c '
    source "$1"
    fixture="$2"
    iam_request() { IAM_RESPONSE="$fixture"; }
    obs_admin_policy_id
  ' bash "${source_only}" "${missing_global}" >/dev/null 2>&1; then
    printf 'OTC IAM bootstrap accepted a non-global OBS Administrator role.\n' >&2
    return 1
  fi

  bash -c '
    source "$1"
    IAM_V3_ROOT=https://example.test/v3
    CROSSPLANE_OTC_DOMAIN_ID=ffffffffffffffffffffffffffffffff
    iam_request() {
      [[ "$1" == PUT &&
         "$2" == "https://example.test/v3/OS-INHERIT/domains/ffffffffffffffffffffffffffffffff/groups/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/roles/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/inherited_to_projects" ]] || return 1
      IAM_STATUS=204
    }
    ensure_group_inherited_role_assignment aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    group_inherited_assignment_state() { printf "assigned\\n"; }
    verify_obs_admin_assignment aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  ' bash "${source_only}"
  bash -c '
    source "$1"
    IAM_V3_ROOT=https://example.test/v3
    CROSSPLANE_OTC_DOMAIN_ID=ffffffffffffffffffffffffffffffff
    expected_url=https://example.test/v3/OS-INHERIT/domains/ffffffffffffffffffffffffffffffff/groups/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/roles/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/inherited_to_projects
    iam_request() {
      [[ "$1" == HEAD && "$2" == "$expected_url" ]] || return 1
      IAM_STATUS=204
    }
    [[ "$(group_inherited_assignment_state aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)" == assigned ]]
  ' bash "${source_only}"
  if bash -c '
    source "$1"
    iam_request() { IAM_STATUS=400; }
    ensure_group_inherited_role_assignment aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  ' bash "${source_only}" >/dev/null 2>&1; then
    printf 'OTC IAM bootstrap accepted a rejected all-projects assignment.\n' >&2
    return 1
  fi
  if bash -c '
    source "$1"
    group_inherited_assignment_state() { printf "not assigned\\n"; }
    verify_obs_admin_assignment aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  ' bash "${source_only}" >/dev/null 2>&1; then
    printf 'OTC IAM bootstrap accepted a missing inherited OBS Administrator assignment.\n' >&2
    return 1
  fi
}

render_and_compare() {
  local backend="$1"
  local source="$2"
  local expected="$3"
  local actual="$4"
  shift 4

  printf 'Render %s with %s\n' "${source#"${REPO_ROOT}/"}" "${backend}"
  crossplane render \
    "${source}" \
    "${REPO_ROOT}/${backend}/composition.yaml" \
    "${REPO_ROOT}/${backend}/dependencies/functions.yaml" \
    "$@" \
    -x >"${actual}"
  normalize_generations "${actual}" "${actual}.normalized"
  normalize_generations "${expected}" "${actual}.expected.normalized"
  dyff between "${actual}.normalized" "${actual}.expected.normalized" -s
  validate_schemas "${backend}" "${actual}"
}

run_backend() {
  local backend="$1"
  local source name idx observed required
  local -a render_args base_args

  case "${backend}" in
    minio|aws|otc|ovh) ;;
    *)
      printf 'Unknown backend: %s (expected minio, aws, otc, or ovh)\n' "${backend}" >&2
      exit 1
      ;;
  esac

  base_args=()
  if [[ "${backend}" == "ovh" ]]; then
    base_args+=(--required-resources "${REPO_ROOT}/ovh/tests/required/environment.yaml")
  fi

  for source in "${REPO_ROOT}"/examples/base/00*-buckets.yaml; do
    name="$(basename "${source}")"
    idx="${name#00}"
    idx="${idx%-buckets.yaml}"

    render_and_compare \
      "${backend}" \
      "${source}" \
      "${REPO_ROOT}/${backend}/tests/expected/00${idx}-buckets.yaml" \
      "${TMP_DIR}/${backend}-00${idx}-buckets.yaml" \
      "${base_args[@]}"

    observed="${REPO_ROOT}/${backend}/tests/observed/00${idx}-buckets.yaml"
    required="${REPO_ROOT}/${backend}/tests/required/00${idx}x-buckets.yaml"
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
        "${REPO_ROOT}/${backend}/tests/expected/00${idx}x-buckets.yaml" \
        "${TMP_DIR}/${backend}-00${idx}x-buckets.yaml" \
        "${render_args[@]}"
    fi
  done
}

main() {
  require_command crossplane
  require_command dyff

  printf 'Validate OVHcloud IAM bootstrap\n'
  bash "${REPO_ROOT}/ovh/tests/test_iam.bash"

  local backend
  for backend in "${BACKENDS[@]}"; do
    if [[ "${backend}" == "aws" ]]; then
      require_command jq
      validate_aws_iam_policy
    fi
    if [[ "${backend}" == "otc" ]]; then
      require_command jq
      validate_otc_iam_bootstrap
    fi
    run_backend "${backend}"
    if [[ "${backend}" == minio ]]; then
      validate_capability_one minio
    fi
    if [[ "${backend}" == "aws" ]]; then
      validate_aws_secret_readiness
    fi
    if [[ "${backend}" == "ovh" ]]; then
      validate_ovh_secret_readiness
      validate_capability_one ovh
      bash "${REPO_ROOT}/ovh/tests/provider-identity/test.bash"
    fi
  done

  printf 'All Composition unit tests passed.\n'
}

main
