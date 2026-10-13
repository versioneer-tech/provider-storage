#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

integration_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
mkdir -p "${test_dir}/bin"
project_id=0123456789abcdef0123456789abcdef
project_two_id=fedcba9876543210fedcba9876543210

cat >"${test_dir}/bin/kind" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'get clusters' ]]
printf 'provider-storage-it\n'
EOF

cat >"${test_dir}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --context && "$2" == kind-provider-storage-it ]]
shift 2
case "$1" in
  cluster-info) ;;
  get) ;;
  apply)
    [[ "$2" == -f && "$3" == - ]]
    cat >>"${TEST_APPLIED_FILE}"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${test_dir}/bin/kind" "${test_dir}/bin/kubectl"

export PATH="${test_dir}/bin:${PATH}"
export CROSSPLANE_CLOUDFERRO_PROJECT_ID="${project_id}"
export CROSSPLANE_CLOUDFERRO_IT2_PROJECT_ID="${project_two_id}"
export TEST_APPLIED_FILE="${test_dir}/applied.yaml"

bash "${integration_dir}/deploy-storages.bash" cloudferro >"${test_dir}/default.out"
awk '$1 == "name:" && $2 ~ /^storage-cloudferro-it/ { print $2 }' \
  "${TEST_APPLIED_FILE}" >"${test_dir}/names"
diff -u <(printf 'storage-cloudferro-it\nstorage-cloudferro-it2\n') \
  "${test_dir}/names"
grep -Fq "bucketName: cloudferro-${project_id:0:12}-it-a" "${TEST_APPLIED_FILE}"
grep -Fq "bucketName: cloudferro-${project_id:0:12}-it-b" "${TEST_APPLIED_FILE}"
grep -Fq "bucketName: cloudferro-${project_id:0:12}-it-c" "${TEST_APPLIED_FILE}"
grep -Fq "bucketName: cloudferro-${project_id:0:12}-it-d" "${TEST_APPLIED_FILE}"
grep -Fq 'principal: provider-storage-cloudferro-it2' "${TEST_APPLIED_FILE}"
grep -Fq "bucketName: cloudferro-${project_two_id:0:12}-it2-a" "${TEST_APPLIED_FILE}"
grep -Fq "storages.pkg.internal/cloudferro-project-id: ${project_id}" "${TEST_APPLIED_FILE}"
grep -Fq "storages.pkg.internal/cloudferro-project-id: ${project_two_id}" "${TEST_APPLIED_FILE}"
[[ $(grep -Fc 'storages.pkg.internal/backend: cloudferro' "${TEST_APPLIED_FILE}") == 2 ]]
grep -Fq 'grantee: provider-storage-cloudferro-it2' "${TEST_APPLIED_FILE}"
grep -Fq 'permission: ReadOnly' "${TEST_APPLIED_FILE}"
grep -Fq 'permission: None' "${TEST_APPLIED_FILE}"

: >"${TEST_APPLIED_FILE}"
if CROSSPLANE_CLOUDFERRO_IT2_PROJECT_ID=invalid \
  bash "${integration_dir}/deploy-storages.bash" cloudferro \
    >"${test_dir}/invalid.out" 2>&1; then
  printf 'An invalid CloudFerro second project ID was accepted.\n' >&2
  exit 1
fi
grep -Fq 'CROSSPLANE_CLOUDFERRO_IT2_PROJECT_ID must be a 32-character lowercase hexadecimal ID.' \
  "${test_dir}/invalid.out"
[[ ! -s "${TEST_APPLIED_FILE}" ]]

: >"${TEST_APPLIED_FILE}"
if CROSSPLANE_CLOUDFERRO_IT2_PROJECT_ID="${project_id}" \
  bash "${integration_dir}/deploy-storages.bash" cloudferro \
    >"${test_dir}/same-project.out" 2>&1; then
  printf 'CloudFerro integration accepted one project for both Storages.\n' >&2
  exit 1
fi
grep -Fq 'CloudFerro integration Storages must use different project IDs.' \
  "${test_dir}/same-project.out"
[[ ! -s "${TEST_APPLIED_FILE}" ]]

printf 'CloudFerro integration Storage selection passed.\n'
