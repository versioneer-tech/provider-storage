#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

integration_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
mkdir -p "${test_dir}/bin"

cat >"${test_dir}/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"${test_dir}/bin/kind" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'get clusters') printf 'provider-storage-it\n' ;;
  *) exit 1 ;;
esac
EOF

cat >"${test_dir}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${TEST_CALLS_FILE}"
[[ "$1" == --context && "$2" == kind-provider-storage-it ]]
shift 2
case "$1" in
  cluster-info) ;;
  apply) ;;
  get) exit 1 ;;
  *) exit 1 ;;
esac
EOF

chmod +x "${test_dir}/bin/docker" "${test_dir}/bin/kind" \
  "${test_dir}/bin/kubectl"

export PATH="${test_dir}/bin:${PATH}"
export TEST_CALLS_FILE="${test_dir}/calls"

bash "${integration_dir}/create-cluster.bash" >"${test_dir}/cluster.out"
grep -Fq -- "--context kind-provider-storage-it apply -f ${integration_dir}/manifests/namespaces.yaml" \
  "${TEST_CALLS_FILE}"

: >"${TEST_CALLS_FILE}"
if CROSSPLANE_CLOUDFERRO_PROJECT_ID=0123456789abcdef0123456789abcdef \
  CROSSPLANE_CLOUDFERRO_IT2_PROJECT_ID=fedcba9876543210fedcba9876543210 \
  bash "${integration_dir}/deploy-providers.bash" cloudferro \
    >"${test_dir}/cloudferro.out" 2>&1; then
  printf 'CloudFerro provider deployment accepted missing project Secrets.\n' >&2
  exit 1
fi
grep -Fq 'Apply the manifests printed by cloudferro/dependencies/iam.sh render-secrets.' \
  "${test_dir}/cloudferro.out"
! grep -Fq ' apply ' "${TEST_CALLS_FILE}"

printf 'Integration setup contract passed.\n'
