#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.bash
source "${INTEGRATION_DIR}/lib.bash"

backend="$(selected_backend "${1:-}" "$0")"
if [[ "${backend}" == cloudferro ]]; then
  cloudferro_it2_enabled || :
fi

"${INTEGRATION_DIR}/deploy-providers.bash" "${backend}"
"${INTEGRATION_DIR}/deploy-storages.bash" "${backend}"
"${INTEGRATION_DIR}/verify.bash" "${backend}"
