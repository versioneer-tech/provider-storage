#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.bash
source "${INTEGRATION_DIR}/lib.bash"

require_command docker
require_command kind
require_command kubectl

if kind_cluster_exists; then
  if ! kube cluster-info >/dev/null 2>&1; then
    kind export kubeconfig --name "${KIND_CLUSTER_NAME}"
  fi
  printf 'Reusing kind cluster %s with context %s.\n' \
    "${KIND_CLUSTER_NAME}" "${KUBECTL_CONTEXT}"
  kube cluster-info
  exit 0
fi

log "Creating ephemeral kind cluster ${KIND_CLUSTER_NAME}"
kind create cluster \
  --name "${KIND_CLUSTER_NAME}" \
  --config "${MANIFEST_DIR}/kind.yaml" \
  --wait 5m
kube cluster-info

printf 'Remove this test cluster when the validation cycle is complete:\n'
printf 'kind delete cluster --name %s\n' "${KIND_CLUSTER_NAME}"
