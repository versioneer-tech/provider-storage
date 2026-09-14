#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
umask 077

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${INTEGRATION_DIR}/../.." && pwd)"

if (($# != 3)) || [[ "$1" != minio && "$1" != ovh ]]; then
  printf 'Usage: %s <minio|ovh> <sanitized-capture-dir> <candidate-output-dir>\n' "$0" >&2
  exit 1
fi
backend="$1"
capture_dir="$2"
output_dir="$3"
for command in jq yq crossplane; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "${command}" >&2
    exit 1
  fi
done
capture_path() {
  local step="$1"
  local matches=("${capture_dir}/t${step}-"*)
  if ((${#matches[@]} != 1)) || [[ ! -d "${matches[0]}" ]]; then
    printf 'Expected one capture directory for T%s.\n' "${step}" >&2
    exit 1
  fi
  printf '%s\n' "${matches[0]}"
}
if [[ ! -f "$(capture_path 10)/claims.json" ]]; then
  printf 'The capture is incomplete: T10 is missing.\n' >&2
  exit 1
fi
for observed_file in "${capture_dir}"/t*/observed-*.json; do
  if ! jq -e 'all(.[];
    (.status.atProvider.manifest.data // {}) as $data |
    ($data | keys | all(.[];
      . == "AWS_ACCESS_KEY_ID" or . == "AWS_SECRET_ACCESS_KEY" or
      . == "access_key_id" or . == "attribute.secret_access_key")) and
    ($data | to_entries | all(.[];
      ((.key == "AWS_ACCESS_KEY_ID" or .key == "access_key_id") and
        .value == "RVhBTVBMRUFDQ0VTU0tFWQ==") or
      ((.key == "AWS_SECRET_ACCESS_KEY" or .key == "attribute.secret_access_key") and
        .value == "RVhBTVBMRVNFQ1JFVEtFWQ=="))) and
    (if .kind == "S3Credentials" then
      .status.atProvider.accessKeyId == "EXAMPLEACCESSKEY"
    else true end))' \
    "${observed_file}" >/dev/null; then
    printf 'Capture has unreviewed credential data: %s\n' "${observed_file}" >&2
    exit 1
  fi
done
if [[ -e "${output_dir}" ]]; then
  printf 'Candidate output already exists: %s\n' "${output_dir}" >&2
  exit 1
fi
mkdir -m 700 -p "${output_dir}"
composition="${REPO_ROOT}/${backend}/composition.yaml"
if [[ "${backend}" == ovh ]]; then
  composition="${output_dir}/composition-ovh-capability-one.yaml"
  yq eval '.metadata.name = "storage-ovh-capability-one" |
    .metadata.labels.provider = "ovh-capability-one"' \
    "${REPO_ROOT}/ovh/composition.yaml" >"${composition}"
fi

fixture_header() {
  printf '# Copyright %s, EOX (https://eox.at) and Versioneer (https://versioneer.at)\n' \
    "$(date -u +%Y)"
  printf '%s\n\n' '# SPDX-License-Identifier: Apache-2.0'
}

# A grant edit changes both the owner and requester's rendered resources.
cases=(
  01:s-joe:create-bucket_s-joe
  02:s-jeff:create-buckets_s-jeff-and-s-jeff-shared
  03:s-joe:request-access_s-jeff-shared
  04:s-jeff:grant-readwrite_s-joe
  04:s-joe:receive-readwrite_s-jeff-shared
  05:s-jeff:change-grant-readonly_s-joe
  05:s-joe:receive-readonly_s-jeff-shared
  06:s-jeff:request-access_s-joe
  07:s-joe:grant-readwrite_s-jeff
  07:s-jeff:receive-readwrite_s-joe
  08:s-jane:request-access_s-john
  09:s-john:create-bucket-and-requests_s-john
  09:s-jane:observe-bucket_s-john
  10:s-john:grant-readwrite_s-jane
  10:s-jane:receive-readwrite_s-john
)

for case in "${cases[@]}"; do
  IFS=: read -r step principal action <<<"${case}"
  previous="$(printf '%02d' "$((10#${step} - 1))")"
  current="$(capture_path "${step}")"
  prior="$(capture_path "${previous}")"
  candidate="${output_dir}/t${step}-${principal}_${action}"
  mkdir -m 700 "${candidate}"
  {
    fixture_header
    yq -P -p=json -o=yaml "${current}/input-${principal}.json"
  } >"${candidate}/input.yaml"
  {
    fixture_header
    jq -c -s '
      .[0] as $environment | .[1] as $claims |
      ([$environment] + $claims)[]
    ' "${current}/environment.json" "${current}/claims.json" |
      while IFS= read -r document; do
        printf '%s\n' '---'
        printf '%s\n' "${document}" | yq -P -p=json -o=yaml
      done
  } >"${candidate}/required.yaml"

  render_args=(--required-resources "${candidate}/required.yaml")
  if [[ -f "${prior}/observed-${principal}.json" ]] &&
    jq -e 'length > 0' "${prior}/observed-${principal}.json" >/dev/null; then
    {
      fixture_header
      jq -c '.[]' "${prior}/observed-${principal}.json" |
        while IFS= read -r document; do
          printf '%s\n' '---'
          printf '%s\n' "${document}" | yq -P -p=json -o=yaml
        done
    } >"${candidate}/observed.yaml"
    render_args+=(--observed-resources "${candidate}/observed.yaml")
  fi

  {
    fixture_header
    crossplane render \
      "${candidate}/input.yaml" \
      "${composition}" \
      "${REPO_ROOT}/${backend}/dependencies/functions.yaml" \
      "${render_args[@]}" -x
  } >"${candidate}/expected.yaml"
  printf 'Prepared %s\n' "${candidate##*/}"
done

printf 'Review candidate fixtures in %s before copying them into the repository.\n' \
  "${output_dir}"
