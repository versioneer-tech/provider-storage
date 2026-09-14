#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.bash
source "${INTEGRATION_DIR}/lib.bash"

if (($# != 2)) || [[ "$1" != minio && "$1" != ovh ]] ||
  [[ ! "$2" =~ ^xyz-story-(minio|ovh)-[0-9]+(-[0-9]+)?$ ]] ||
  [[ "$2" != xyz-story-"$1"-* ]]; then
  printf 'Usage: %s <minio|ovh> <matching-xyz-story-run-namespace>\n' "$0" >&2
  exit 1
fi
backend="$1"
story_namespace="$2"
require_cluster
require_command jq

if ! kube get namespace/"${story_namespace}" >/dev/null 2>&1; then
  printf 'Story namespace %s does not exist.\n' "${story_namespace}" >&2
  exit 1
fi

if [[ "${backend}" == ovh ]]; then
  # shellcheck source=capability-one/cleanup-ovh.bash
  source "${INTEGRATION_DIR}/capability-one/cleanup-ovh.bash"
  cleanup_ovh
  exit
fi
if ! kube get storages.pkg.internal -n "${story_namespace}" -o json |
  jq -e 'all(.items[];
    .metadata.labels["storages.pkg.internal/capability-one"] == "true")' >/dev/null; then
  printf 'Namespace %s contains a Storage outside the capability-1 story.\n' \
    "${story_namespace}" >&2
  exit 1
fi

delete_story_objects() {
  local bucket="$1"
  kube exec -n minio deployment/default -- sh -c '
    set -eu
    export MC_HOST_story="http://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@localhost:9000"
    mc rm --recursive --force "story/$1/story/" >/dev/null
    remaining="$(mc ls --recursive "story/$1")"
    if [ -n "$remaining" ]; then
      printf "Bucket still contains objects outside the story prefix.\n" >&2
      exit 1
    fi
  ' story-cleanup "${bucket}" >/dev/null
  printf 'Emptied story bucket %s\n' "${bucket}"
}

while IFS= read -r bucket; do
  [[ -z "${bucket}" ]] || delete_story_objects "${bucket}"
done < <(
  kube get storages.pkg.internal -n "${story_namespace}" \
    -l storages.pkg.internal/capability-one=true -o json |
    jq -r '.items[] | .spec.buckets[]?.bucketName'
)

log "Deleting story claims before the namespaced ProviderConfig"
kube delete storages.pkg.internal -n "${story_namespace}" \
  -l storages.pkg.internal/capability-one=true --wait=false

deadline=$((SECONDS + 600))
while [[ "$(kube get objects.kubernetes.m.crossplane.io \
  -n "${story_namespace}" -o name | wc -l)" != 0 ]]; do
  if ((SECONDS >= deadline)); then
    printf 'Composed Objects did not finish deleting in %s.\n' \
      "${story_namespace}" >&2
    exit 1
  fi
  sleep 5
done

kube delete providerconfig.kubernetes.m.crossplane.io/provider-kubernetes \
  -n "${story_namespace}" --ignore-not-found
kube delete namespace/"${story_namespace}" --wait=true --timeout=5m
printf 'Removed story namespace %s.\n' "${story_namespace}"
