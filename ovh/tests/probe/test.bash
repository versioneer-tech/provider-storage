#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

probe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "$probe_dir/../../.." && pwd)
work_dir=$(mktemp -d /tmp/xyz-ovh-probe.XXXXXXXX)
trap 'rm -rf -- "$work_dir"' EXIT

for tool in docker crossplane yq; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Missing required probe tool: %s\n' "$tool" >&2
    exit 1
  }
done
docker ps >/dev/null

crossplane render "$probe_dir/input.yaml" "$probe_dir/composition.yaml" \
  "$probe_dir/functions.yaml" -x >"$work_dir/pending.yaml"
crossplane render "$probe_dir/input.yaml" "$probe_dir/composition.yaml" \
  "$probe_dir/functions.yaml" --observed-resources "$probe_dir/observed.yaml" -x \
  >"$work_dir/ready.yaml"

yq ea -e '[select(.kind == "ProjectStorage")] | length == 0' \
  "$work_dir/pending.yaml" >/dev/null
yq ea -e '[select(.kind == "ProjectStorage" and
  .spec.forProvider.ownerId == 12345 and
  .spec.forProvider.regionName == "DE" and
  .spec.forProvider.hideObjects == true and
  (.spec.managementPolicies | contains(["Observe", "Create", "Update", "LateInitialize"])) and
  (.spec.managementPolicies | contains(["Delete"]) | not))] | length == 1' \
  "$work_dir/ready.yaml" >/dev/null
yq ea -e '[select(.kind == "User" and
  .spec.forProvider.serviceName == "00000000000000000000000000000000" and
  (.spec.forProvider.roleNames | contains(["objectstore_operator"])))] | length == 2' \
  "$work_dir/ready.yaml" >/dev/null
yq ea -e '[select(.kind == "S3Credentials" and
  .spec.forProvider.userIdRef.name == "xyz-ovh-writer" and
  .spec.writeConnectionSecretToRef.name == "xyz-ovh-writer-connection")] | length == 1' \
  "$work_dir/ready.yaml" >/dev/null
yq ea -e '[select(.kind == "S3Policy" and
  .spec.forProvider.userIdRef.name == "xyz-ovh-writer" and
  (.spec.forProvider.policy | from_json | .Statement[0].Effect == "Allow"))] | length == 1' \
  "$work_dir/ready.yaml" >/dev/null

extensions="$repo_dir/xrd.yaml,$probe_dir/provider.yaml"
for resources in "$work_dir/pending.yaml" "$work_dir/ready.yaml" \
  "$probe_dir/provider-config.yaml" "$probe_dir/observed.yaml"; do
  crossplane beta validate "$extensions" "$resources" \
    --cache-dir "$work_dir/cache" \
    --crossplane-image xpkg.crossplane.io/crossplane/crossplane:v2.0.2 \
    --error-on-missing-schemas --skip-success-results
done

printf 'OVHcloud direct-resource render and schema probe passed.\n'
