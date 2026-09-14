#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.bash
source "${INTEGRATION_DIR}/lib.bash"

if [[ "${1:-}" == ovh ]]; then
  if (($# != 2)) || [[ "$2" != --with-capability-one ]]; then
    printf 'Usage: %s ovh --with-capability-one\n' "$0" >&2
    exit 1
  fi
  "${INTEGRATION_DIR}/deploy-ovh-probe.bash"
  "${INTEGRATION_DIR}/capability-one.bash" ovh
  exit
fi

backend="$(selected_backend "${1:-}" "$0")"
mode="${2:-}"
if (($# > 2)) || [[ -n "${mode}" && "${mode}" != --with-capability-one ]]; then
  printf 'Usage: %s <minio|aws|otc> [--with-capability-one]\n' "$0" >&2
  exit 1
fi
if [[ "${mode}" == --with-capability-one && "${backend}" != minio ]]; then
  printf 'The capability-one story currently has a MinIO adapter only.\n' >&2
  exit 1
fi

"${INTEGRATION_DIR}/deploy-providers.bash" "${backend}"
"${INTEGRATION_DIR}/deploy-storages.bash" "${backend}"
"${INTEGRATION_DIR}/verify.bash" "${backend}"
if [[ "${mode}" == --with-capability-one ]]; then
  "${INTEGRATION_DIR}/capability-one.bash" "${backend}"
fi
