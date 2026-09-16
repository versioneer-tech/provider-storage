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

validate_ovh_provider_identity() {
  local input="${TMP_DIR}/ovh-provider-identity-input.yaml"
  local rendered="${TMP_DIR}/ovh-provider-identity.yaml"

  printf 'Validate OVHcloud providerIdentity resource names\n'
  sed '/^  principal: s-joe$/a\  providerIdentity: it' \
    "${REPO_ROOT}/examples/base/001-buckets.yaml" >"${input}"
  crossplane render \
    "${input}" \
    "${REPO_ROOT}/ovh/composition.yaml" \
    "${REPO_ROOT}/ovh/dependencies/functions.yaml" \
    --required-resources "${REPO_ROOT}/ovh/tests/required/environment.yaml" \
    -x >"${rendered}"
  grep -Fxq '  name: it-owner' "${rendered}"
  grep -Fxq '  name: it' "${rendered}"
  grep -Fxq '      name: it' "${rendered}"
  ! grep -Fxq '  name: s-joe-owner' "${rendered}"
  validate_schemas ovh "${rendered}"
}

validate_cloudferro_composition() {
  local input="${REPO_ROOT}/cloudferro/tests/fixtures/001-buckets.yaml"
  local composition="${REPO_ROOT}/cloudferro/composition.yaml"
  local functions="${REPO_ROOT}/cloudferro/dependencies/functions.yaml"
  local required="${REPO_ROOT}/cloudferro/tests/required/001x-buckets.yaml"
  local observed="${REPO_ROOT}/cloudferro/tests/observed"
  local base="${TMP_DIR}/cloudferro-base.yaml"
  local credential="${TMP_DIR}/cloudferro-credential.yaml"
  local denied="${TMP_DIR}/cloudferro-grant-error.out"
  local second="${TMP_DIR}/cloudferro-second-slot.yaml"
  local wrong_label="${TMP_DIR}/cloudferro-wrong-label.yaml"
  local expected_user_id=778899aabbccddeeff00112233445566

  printf 'Validate CloudFerro project slot, resource ordering, and consumer Secret\n'
  crossplane render "${input}" "${composition}" "${functions}" \
    --required-resources "${required}" -x >"${base}"
  grep -Fq 'kind: ContainerV1' "${base}"
  grep -Fq 'kind: EC2CredentialV3' "${base}"
  grep -Fq "userId: ${expected_user_id}" "${base}"
  ! grep -Fq 'kind: UserV3' "${base}"
  ! grep -Fq 'kind: RoleAssignmentV3' "${base}"
  ! grep -Fq 'kind: CronJob' "${base}"
  ! grep -Fq 'kind: ConfigMap' "${base}"
  grep -Fq 'name: cloudferro-0001' "${base}"
  grep -Fq 'kind: BucketPolicy' "${base}"
  grep -Fq 'arn:aws:iam::fedcba9876543210fedcba9876543210:root' "${base}"
  ! grep -Fq 'managementPolicies:' "${base}"
  ! grep -Fq 'AWS_SECRET_ACCESS_KEY' "${base}"
  validate_schemas cloudferro "${base}"

  crossplane render "${input}" "${composition}" "${functions}" \
    --required-resources "${required}" \
    --observed-resources "${observed}/credential-ready.yaml" -x >"${credential}"
  grep -Fq 'AWS_ACCESS_KEY_ID: RVhBTVBMRUFDQ0VTU0tFWQ==' "${credential}"
  grep -Fq 'AWS_SECRET_ACCESS_KEY: RVhBTVBMRVNFQ1JFVEtFWQ==' "${credential}"
  grep -Fq 'AWS_REGION: UmVnaW9uT25l' "${credential}"
  grep -Fq 'kind: ProviderConfig' "${credential}"
  grep -Fq 'name: cloudferro-s3-s-joe' "${credential}"
  grep -Fq 'name: aws-provider-secret-s-joe' "${credential}"
  grep -Fq 'name: usage-aws-provider-s-joe' "${credential}"
  grep -Fq 'name: usage-bucketpolicy-s-joe' "${credential}"
  grep -Fq 'name: usage-credential-bucketpolicy-s-joe' "${credential}"
  validate_schemas cloudferro "${credential}"

  sed 's/cloudferro-0001/cloudferro-0002/g' "${composition}" >"${TMP_DIR}/cloudferro-slot-0002-composition.yaml"
  crossplane render "${REPO_ROOT}/cloudferro/tests/fixtures/002-buckets.yaml" \
    "${TMP_DIR}/cloudferro-slot-0002-composition.yaml" "${functions}" \
    --required-resources "${REPO_ROOT}/cloudferro/tests/required/002x-buckets.yaml" \
    -x >"${second}"
  grep -Fq 'name: cloudferro-0002' "${second}"
  ! grep -Fq 'name: cloudferro-0001' "${second}"
  grep -Fq 'kind: CronJob' "${second}"
  grep -Fq 'kind: ConfigMap' "${second}"
  grep -Fq 'RCLONE_CONFIG_STORAGE_REGION' "${second}"
  grep -Fq 'value: RegionOne' "${second}"
  grep -Fq 'arn:aws:iam::0123456789abcdef0123456789abcdef:root' "${second}"
  validate_schemas cloudferro "${second}"

  sed 's/storages.pkg.internal\/backend: cloudferro-0001/storages.pkg.internal\/backend: cloudferro-0002/' \
    "${input}" >"${wrong_label}"
  if crossplane render "${wrong_label}" "${composition}" "${functions}" \
    --required-resources "${required}" -x >"${denied}" 2>&1; then
    printf 'CloudFerro accepted a backend label that disagrees with its slot selector.\n' >&2
    return 1
  fi
  grep -Fq 'backend label and Composition selector must name the same slot' "${denied}"
}

validate_otc_iam_bootstrap() {
  local script="${REPO_ROOT}/otc/dependencies/iam.sh"
  local source_only="${TMP_DIR}/otc-iam-source.sh"
  local system_roles="${TMP_DIR}/otc-system-roles.json"
  local missing_global="${TMP_DIR}/otc-missing-global-role.json"
  local global_obs_role_id=0123456789abcdef0123456789abcdef
  local domain_obs_role_id=abcdef0123456789abcdef0123456789
  local legacy_obs_role_id=00112233445566778899aabbccddeeff
  local domain_id=1234567890abcdef1234567890abcdef
  local group_id=11223344556677889900aabbccddeeff
  local policy_id=fedcba9876543210fedcba9876543210

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
  jq -n --arg global "${global_obs_role_id}" \
    --arg domain_role "${domain_obs_role_id}" \
    --arg legacy "${legacy_obs_role_id}" --arg domain "${domain_id}" '{roles: [
    {display_name: "OBS Administrator", type: "AX", domain_id: null, id: $global},
    {display_name: "OBS Administrator", type: "AX", domain_id: $domain, id: $domain_role},
    {display_name: "OBS Administrator", type: "XA", domain_id: null, id: $legacy}
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
  ' bash "${source_only}" "${system_roles}")" == "${global_obs_role_id}" ]]
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
    CROSSPLANE_OTC_DOMAIN_ID=$2
    group_id=$3
    policy_id=$4
    expected_url="${IAM_V3_ROOT}/OS-INHERIT/domains/${CROSSPLANE_OTC_DOMAIN_ID}/groups/${group_id}/roles/${policy_id}/inherited_to_projects"
    iam_request() {
      [[ "$1" == PUT &&
         "$2" == "$expected_url" ]] || return 1
      IAM_STATUS=204
    }
    ensure_group_inherited_role_assignment "$group_id" "$policy_id"
    group_inherited_assignment_state() { printf "assigned\\n"; }
    verify_obs_admin_assignment "$group_id" "$policy_id"
  ' bash "${source_only}" "${domain_id}" "${group_id}" "${policy_id}"
  bash -c '
    source "$1"
    IAM_V3_ROOT=https://example.test/v3
    CROSSPLANE_OTC_DOMAIN_ID=$2
    group_id=$3
    policy_id=$4
    expected_url="${IAM_V3_ROOT}/OS-INHERIT/domains/${CROSSPLANE_OTC_DOMAIN_ID}/groups/${group_id}/roles/${policy_id}/inherited_to_projects"
    iam_request() {
      [[ "$1" == HEAD && "$2" == "$expected_url" ]] || return 1
      IAM_STATUS=204
    }
    [[ "$(group_inherited_assignment_state "$group_id" "$policy_id")" == assigned ]]
  ' bash "${source_only}" "${domain_id}" "${group_id}" "${policy_id}"
  if bash -c '
    source "$1"
    group_id=$2
    policy_id=$3
    iam_request() { IAM_STATUS=400; }
    ensure_group_inherited_role_assignment "$group_id" "$policy_id"
  ' bash "${source_only}" "${group_id}" "${policy_id}" >/dev/null 2>&1; then
    printf 'OTC IAM bootstrap accepted a rejected all-projects assignment.\n' >&2
    return 1
  fi
  if bash -c '
    source "$1"
    group_id=$2
    policy_id=$3
    group_inherited_assignment_state() { printf "not assigned\\n"; }
    verify_obs_admin_assignment "$group_id" "$policy_id"
  ' bash "${source_only}" "${group_id}" "${policy_id}" >/dev/null 2>&1; then
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

  printf 'Validate CloudFerro IAM bootstrap\n'
  bash "${REPO_ROOT}/cloudferro/tests/test_iam.bash"

  printf 'Validate CloudFerro integration Storage selection\n'
  bash "${REPO_ROOT}/tests/integration/test_cloudferro_selection.bash"

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
    if [[ "${backend}" == "cloudferro" ]]; then
      validate_cloudferro_composition
      continue
    fi
    run_backend "${backend}"
    if [[ "${backend}" == "aws" ]]; then
      validate_aws_secret_readiness
    fi
    if [[ "${backend}" == "ovh" ]]; then
      validate_ovh_secret_readiness
      validate_ovh_provider_identity
    fi
  done

  printf 'All Composition unit tests passed.\n'
}

main
