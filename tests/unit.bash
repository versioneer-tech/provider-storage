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
: "${CROSSPLANE_VERSION:=v2.4.1}"
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
  crossplane resource validate \
    "${REPO_ROOT}/xrd.yaml,${REPO_ROOT}/${backend}/dependencies/02-providers.yaml" \
    "${validation_resources}" \
    --cache-dir "${PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR}" \
    --crossplane-image "xpkg.crossplane.io/crossplane/crossplane:${CROSSPLANE_VERSION}" \
    --error-on-missing-schemas \
    --skip-success-results
}

validate_aws_iam_policy() {
  local policy="${REPO_ROOT}/aws/dependencies/policies/runtime-role-policy.json"
  local static_user_policy="${REPO_ROOT}/aws/dependencies/policies/static-user-policy.json"
  local script="${REPO_ROOT}/aws/dependencies/iam.sh"
  local credentials="${TMP_DIR}/aws-provider.credentials"
  local rendered_secret="${TMP_DIR}/aws-provider-secret.yaml"

  printf 'Validate AWS runtime IAM policy\n'
  jq -e '
    any(.Statement[];
      .Sid == "ReadUsersForReconciliation" and
      .Action == "iam:GetUser" and
      .Resource == "__ACCOUNT_USER_ARN_PATTERN__") and
    all(.Statement[] | select(.Sid == "ManageUsersAndAccessKeys") | .Action[];
      . != "iam:GetUser") and
    any(.Statement[];
      .Sid == "ManageUsersAndAccessKeys" and
      any(.Action[]; . == "iam:ListGroupsForUser") and
      .Resource == "__MANAGED_USER_ARN_PATTERN__") and
    any(.Statement[];
      .Sid == "ManagePolicies" and
      .Resource == "__MANAGED_POLICY_ARN_PATTERN__") and
    any(.Statement[];
      .Sid == "ManagePrefixedBuckets" and
      .Resource == ["__BUCKET_ARN_PATTERN__", "__OBJECT_ARN_PATTERN__"]) and
    any(.Statement[];
      .Sid == "ProtectControllerUser" and .Effect == "Deny" and
      .Resource == "__CONTROLLER_USER_ARN__")
  ' "${policy}" >/dev/null
  jq -e '
    .Statement == [{Sid: "AssumeProviderStorageRuntimeRole", Effect: "Allow",
      Action: "sts:AssumeRole", Resource: "__RUNTIME_ROLE_ARN__"}]
  ' "${static_user_policy}" >/dev/null

  jq -n '{access_key_id:"TESTACCESSKEY",secret_access_key:"test-secret-key"}' \
    >"${credentials}"
  chmod 600 "${credentials}"
  env -i PATH=/usr/bin:/bin \
    CROSSPLANE_AWS_CREDENTIALS_FILE="${credentials}" \
    CROSSPLANE_AWS_NAMESPACE=workspace \
    bash "${script}" render-secrets >"${rendered_secret}"
  assert_yaml "${rendered_secret}" '
    [.] | (length == 1 and
    .[0].kind == "Secret" and
    .[0].metadata.name == "aws-provider-creds" and
    .[0].metadata.namespace == "workspace" and
    .[0].type == "Opaque" and
    (.[0].data.credentials | @base64d) ==
      "[default]\naws_access_key_id = TESTACCESSKEY\naws_secret_access_key = test-secret-key")
  ' 'AWS credential Secret content'
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
    --cache-dir="${PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR}" \
    --xrd="${REPO_ROOT}/xrd.yaml" \
    --crossplane-version="${CROSSPLANE_VERSION}" \
    --timeout=5m \
    --observed-resources "${scenario}/observed.yaml" \
    -x >"${rendered}"
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
  crossplane render \
    "${input}" \
    "${REPO_ROOT}/aws/composition.yaml" \
    "${REPO_ROOT}/aws/dependencies/functions.yaml" \
    --cache-dir="${PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR}" \
    --xrd="${REPO_ROOT}/xrd.yaml" \
    --crossplane-version="${CROSSPLANE_VERSION}" \
    --timeout=5m \
    -x >"${rendered}"
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

validate_ovh_secret_readiness() {
  local missing="${TMP_DIR}/ovh-missing-credential.yaml"

  printf 'Validate OVHcloud readiness while the credential Secret lacks its secret key\n'
  crossplane render \
    "${REPO_ROOT}/examples/base/001-buckets.yaml" \
    "${REPO_ROOT}/ovh/composition.yaml" \
    "${REPO_ROOT}/ovh/dependencies/functions.yaml" \
    --cache-dir="${PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR}" \
    --xrd="${REPO_ROOT}/xrd.yaml" \
    --crossplane-version="${CROSSPLANE_VERSION}" \
    --timeout=5m \
    --required-resources "${REPO_ROOT}/ovh/tests/required/001x-buckets.yaml" \
    --observed-resources "${REPO_ROOT}/ovh/tests/readiness/observed-missing.yaml" \
    -x >"${missing}"
  assert_yaml "${missing}" '
    [.] | (map(select(
      .kind == "Object" and
      .metadata.annotations."crossplane.io/composition-resource-name" == "secret-s-joe"
    )) | length == 0)
  ' 'OVHcloud omits a consumer Secret without a secret access key'
  queue_schema_validation ovh "${missing}"
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
    --cache-dir="${PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR}" \
    --xrd="${REPO_ROOT}/xrd.yaml" \
    --crossplane-version="${CROSSPLANE_VERSION}" \
    --timeout=5m \
    --required-resources "${REPO_ROOT}/ovh/tests/required/environment.yaml" \
    -x >"${rendered}"
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
  local composition="${REPO_ROOT}/cloudferro/composition.yaml"
  local functions="${REPO_ROOT}/cloudferro/dependencies/functions.yaml"
  local required="${REPO_ROOT}/cloudferro/tests/required/001x-buckets.yaml"
  local observed="${REPO_ROOT}/cloudferro/tests/observed"
  local base="${TMP_DIR}/cloudferro-base.yaml"
  local credential="${TMP_DIR}/cloudferro-credential.yaml"
  local denied="${TMP_DIR}/cloudferro-grant-error.out"
  local second="${TMP_DIR}/cloudferro-second-project.yaml"
  local wrong_label="${TMP_DIR}/cloudferro-wrong-label.yaml"
  local denied_content

  printf 'Validate CloudFerro project binding, resource ordering, and consumer Secret\n'
  crossplane render "${input}" "${composition}" "${functions}" \
    --cache-dir="${PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR}" \
    --xrd="${REPO_ROOT}/xrd.yaml" \
    --crossplane-version="${CROSSPLANE_VERSION}" --timeout=5m \
    --required-resources "${required}" -x >"${base}"
  assert_yaml "${base}" '
    [.] | (({
      "inventory": (map("\(.kind)/\(.metadata.name)") | sort),
      "providerSecretRefs": map(
        select(.kind == "ProviderConfig") | .spec.credentials.secretRef
      ),
      "bucketPrincipals": (map(
        select(.kind == "BucketPolicy") |
        .spec.forProvider.policy | from_json | .Statement[].Principal.AWS
      ) | unique),
      "managementPolicyCount": (
        map(select(.spec.managementPolicies != null)) | length
      )
    } | to_json) == ({
      "inventory": [
        "BucketPolicy/bucketpolicy-s-joe",
        "ContainerV1/s-joe",
        "EC2CredentialV3/s-joe",
        "ProviderConfig/cloudferro-s-joe",
        "Storage/s-joe",
        "Usage/usage-bucketpolicy-s-joe",
        "Usage/usage-credential-bucketpolicy-s-joe"
      ],
      "providerSecretRefs": [{
        "key": "config",
        "name": "cloudferro-project-0123456789abcdef0123456789abcdef",
        "namespace": "default"
      }],
      "bucketPrincipals": [
        "arn:aws:iam::fedcba9876543210fedcba9876543210:root"
      ],
      "managementPolicyCount": 0
    } | to_json))
  ' 'CloudFerro base resource set and project binding'
  queue_schema_validation cloudferro "${base}"

  crossplane render "${input}" "${composition}" "${functions}" \
    --cache-dir="${PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR}" \
    --xrd="${REPO_ROOT}/xrd.yaml" \
    --crossplane-version="${CROSSPLANE_VERSION}" --timeout=5m \
    --required-resources "${required}" \
    --observed-resources "${observed}/credential-ready.yaml" -x >"${credential}"
  assert_yaml "${credential}" '
    [.] | (({
      "inventory": (map("\(.kind)/\(.metadata.name)") | sort),
      "secretData": map(
        select(.kind == "Object" and .metadata.name == "secret-s-joe") |
        .spec.forProvider.manifest.data
      )
    } | to_json) == ({
      "inventory": [
        "BucketPolicy/bucketpolicy-s-joe",
        "ContainerV1/s-joe",
        "EC2CredentialV3/s-joe",
        "Object/aws-provider-secret-s-joe",
        "Object/cloudferro-s3-s-joe",
        "Object/secret-s-joe",
        "ProviderConfig/cloudferro-s-joe",
        "Storage/s-joe",
        "Usage/usage-aws-provider-s-joe",
        "Usage/usage-bucketpolicy-s-joe",
        "Usage/usage-credential-bucketpolicy-s-joe"
      ],
      "secretData": [{
        "AWS_ACCESS_KEY_ID": "RVhBTVBMRUFDQ0VTU0tFWQ==",
        "AWS_ENDPOINT_URL": "aHR0cHM6Ly9zMy5leGFtcGxlLmNsb3VkZmVycm8udGVzdA==",
        "AWS_REGION": "UmVnaW9uT25l",
        "AWS_S3_FORCE_PATH_STYLE": "dHJ1ZQ==",
        "AWS_SECRET_ACCESS_KEY": "RVhBTVBMRVNFQ1JFVEtFWQ=="
      }]
    } | to_json))
  ' 'CloudFerro ready credential resources and consumer Secret'
  queue_schema_validation cloudferro "${credential}"

  crossplane render "${REPO_ROOT}/cloudferro/tests/fixtures/002-buckets.yaml" \
    "${composition}" "${functions}" \
    --cache-dir="${PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR}" \
    --xrd="${REPO_ROOT}/xrd.yaml" \
    --crossplane-version="${CROSSPLANE_VERSION}" --timeout=5m \
    --required-resources "${REPO_ROOT}/cloudferro/tests/required/002x-buckets.yaml" \
    -x >"${second}"
  assert_yaml "${second}" '
    [.] | (({
      "containers": (map(
        select(.kind == "ContainerV1") | .metadata.name
      ) | sort),
      "credentialCount": (
        map(select(.kind == "EC2CredentialV3")) | length
      ),
      "objectKinds": (map(
        select(.kind == "Object") | .spec.forProvider.manifest.kind
      ) | sort),
      "regions": (map(
        select(.kind == "Object") |
        .spec.forProvider.manifest.spec.jobTemplate.spec.template.spec.containers[].env[] |
        select(.name == "RCLONE_CONFIG_STORAGE_REGION") | .value
      ) | unique),
      "bucketPrincipals": (map(
        select(.kind == "BucketPolicy") |
        .spec.forProvider.policy | from_json | .Statement[].Principal.AWS
      ) | unique),
      "providerSecretNames": map(
        select(.kind == "ProviderConfig") | .spec.credentials.secretRef.name
      )
    } | to_json) == ({
      "containers": ["s-jeff", "s-jeff-shared"],
      "credentialCount": 2,
      "objectKinds": ["ConfigMap", "CronJob"],
      "regions": ["RegionOne"],
      "bucketPrincipals": [
        "arn:aws:iam::0123456789abcdef0123456789abcdef:root"
      ],
      "providerSecretNames": [
        "cloudferro-project-fedcba9876543210fedcba9876543210"
      ]
    } | to_json))
  ' 'CloudFerro second-project and lifecycle resources'
  queue_schema_validation cloudferro "${second}"

  sed 's/provider: cloudferro/provider: invalid/' \
    "${input}" >"${wrong_label}"
  if crossplane render "${wrong_label}" "${composition}" "${functions}" \
    --cache-dir="${PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR}" \
    --xrd="${REPO_ROOT}/xrd.yaml" \
    --crossplane-version="${CROSSPLANE_VERSION}" --timeout=5m \
    --required-resources "${required}" -x >"${denied}" 2>&1; then
    printf 'CloudFerro accepted an invalid Composition selector.\n' >&2
    return 1
  fi
  denied_content="$(<"${denied}")"
  [[ "${denied_content}" == *'incorrect value for label "provider"'* ]] || {
    printf 'CloudFerro selector failure did not report the provider label.\n' >&2
    return 1
  }
}

validate_otc_credential_rendering() {
  local script="${REPO_ROOT}/otc/dependencies/iam.sh"
  local domain_id=1234567890abcdef1234567890abcdef
  local credentials="${TMP_DIR}/otc-provider.json"
  local rendered_secret="${TMP_DIR}/otc-provider-secret.yaml"

  jq -n --arg domain "${domain_id}" --arg project 00112233445566778899aabbccddeeff '
    {access_key:"TESTACCESSKEY",secret_key:"test-secret-key",
     auth_url:"https://iam.example.test/v3",domain_name:"example",
     domain_id:$domain,tenant_id:$project}
  ' >"${credentials}"
  chmod 600 "${credentials}"
  env -i PATH=/usr/bin:/bin \
    CROSSPLANE_OTC_CREDENTIALS_FILE="${credentials}" \
    CROSSPLANE_OTC_NAMESPACE=workspace \
    bash "${script}" render-secrets >"${rendered_secret}"
  assert_yaml "${rendered_secret}" '
    [.] | (length == 1 and
    .[0].kind == "Secret" and
    .[0].metadata.name == "otc-provider-creds" and
    .[0].metadata.namespace == "workspace" and
    .[0].type == "Opaque" and
    ((.[0].data.credentials | @base64d | from_json | to_json) == ({
      "access_key":"TESTACCESSKEY",
      "secret_key":"test-secret-key",
      "auth_url":"https://iam.example.test/v3",
      "domain_name":"example",
      "domain_id":"1234567890abcdef1234567890abcdef",
      "tenant_id":"00112233445566778899aabbccddeeff"
    } | to_json)))
  ' 'OTC credential Secret content'
}

validate_ovh_credential_rendering() {
  local script="${REPO_ROOT}/ovh/dependencies/iam.sh"
  local credentials="${TMP_DIR}/ovh-provider.json"
  local rendered_secret="${TMP_DIR}/ovh-provider-secret.yaml"
  jq -n '{endpoint:"ovh-eu",client_id:"client-id",client_secret:"client-secret"}' \
    >"${credentials}"
  chmod 600 "${credentials}"
  env -i PATH=/usr/bin:/bin \
    CROSSPLANE_OVH_CREDENTIALS_FILE="${credentials}" \
    CROSSPLANE_OVH_NAMESPACE=workspace \
    bash "${script}" render-secrets >"${rendered_secret}"
  assert_yaml "${rendered_secret}" '
    [.] | (length == 1 and
    .[0].kind == "Secret" and
    .[0].metadata.name == "ovh-provider-creds" and
    .[0].metadata.namespace == "workspace" and
    .[0].type == "Opaque" and
    ((.[0].data.credentials | @base64d | from_json | to_json) == ({
      "endpoint":"ovh-eu",
      "client_id":"client-id",
      "client_secret":"client-secret"
    } | to_json)))
  ' 'OVHcloud credential Secret content'
}

validate_cloudferro_credential_rendering() {
  local script="${REPO_ROOT}/cloudferro/dependencies/iam.sh"
  local credentials="${TMP_DIR}/cloudferro-provider.json"
  local rendered_secrets="${TMP_DIR}/cloudferro-provider-secrets.yaml"
  local first=0123456789abcdef0123456789abcdef
  local second=fedcba9876543210fedcba9876543210
  jq -n --arg first "${first}" --arg second "${second}" '
    {identity:{auth_url:"https://keystone.example.test/v3",region:"RegionOne",
      domain_id:"1234567890abcdef1234567890abcdef",
      user_id:"abcdef0123456789abcdef0123456789",
      user_name:"provider-storage-controller",password:"controller-password"},
     projects:[$first,$second]}
  ' >"${credentials}"
  chmod 600 "${credentials}"
  env -i PATH=/usr/bin:/bin \
    CROSSPLANE_CLOUDFERRO_CREDENTIALS_FILE="${credentials}" \
    CROSSPLANE_CLOUDFERRO_NAMESPACE=workspace \
    bash "${script}" render-secrets >"${rendered_secrets}"
  assert_yaml "${rendered_secrets}" '
    [.] | ({
      "names": (map(.metadata.name) | sort),
      "namespaces": (map(.metadata.namespace) | unique),
      "types": (map(.type) | unique),
      "tenantIds": (
        map(.data.config | @base64d | from_json | .tenant_id) | sort
      )
    } | to_json) == ({
      "names": [
        "cloudferro-project-0123456789abcdef0123456789abcdef",
        "cloudferro-project-fedcba9876543210fedcba9876543210"
      ],
      "namespaces": ["workspace"],
      "types": ["Opaque"],
      "tenantIds": [
        "0123456789abcdef0123456789abcdef",
        "fedcba9876543210fedcba9876543210"
      ]
    } | to_json)
  ' 'CloudFerro project credential Secrets'
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
    --cache-dir="${PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR}" \
    --xrd="${REPO_ROOT}/xrd.yaml" \
    --crossplane-version="${CROSSPLANE_VERSION}" \
    --timeout=5m \
    "$@" \
    -x >"${actual}"
  normalize_generations "${actual}" "${actual}.normalized"
  normalize_generations "${expected}" "${actual}.expected.normalized"
  dyff between "${actual}.normalized" "${actual}.expected.normalized" -s
  queue_schema_validation "${backend}" "${actual}"
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
  require_command yq

  validate_shell_syntax

  local backend
  for backend in "${BACKENDS[@]}"; do
    printf 'Validate %s integration Storage manifest contract\n' "${backend}"
    bash "${REPO_ROOT}/tests/integration/test_storage_manifests.bash" \
      "${backend}"
    if [[ "${backend}" == "aws" ]]; then
      require_command jq
      validate_aws_iam_policy
    fi
    if [[ "${backend}" == "otc" ]]; then
      require_command jq
      validate_otc_credential_rendering
    fi
    if [[ "${backend}" == "ovh" ]]; then
      require_command jq
      printf 'Validate OVHcloud IAM credential rendering\n'
      validate_ovh_credential_rendering
    fi
    if [[ "${backend}" == "cloudferro" ]]; then
      require_command jq
      printf 'Validate CloudFerro IAM credential rendering\n'
      validate_cloudferro_credential_rendering
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
      validate_ovh_secret_readiness
      validate_ovh_provider_identity
    fi
    validate_schemas "${backend}"
  done

  printf 'All Composition unit tests passed.\n'
}

main
