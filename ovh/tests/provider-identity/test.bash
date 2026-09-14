#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
output="$(mktemp)"
trap 'rm -f "${output}"' EXIT

crossplane render \
  "${ROOT}/ovh/tests/provider-identity/input.yaml" \
  "${ROOT}/ovh/composition.yaml" \
  "${ROOT}/ovh/dependencies/functions.yaml" \
  --required-resources "${ROOT}/ovh/tests/required/environment.yaml" \
  -x >"${output}"

grep -Fxq '  name: xyz-ovh-identity-joe-owner' "${output}"
grep -Fxq '  name: xyz-ovh-identity-joe' "${output}"
[[ "$(grep -Fxc '      name: xyz-ovh-identity-joe' "${output}")" == 2 ]]
grep -Fxq '        name: s-joe-credentials' "${output}"
grep -Fxq '  name: s-joe' "${output}"
printf 'OVHcloud providerIdentity names are distinct from the consumer Secret.\n'
