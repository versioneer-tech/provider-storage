#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.bash
source "${INTEGRATION_DIR}/lib.bash"

: "${CROSSPLANE_OVH_PROJECT_ID:?Set the project ID used by ovh/dependencies/iam.sh.}"
if [[ ! ${CROSSPLANE_OVH_PROJECT_ID} =~ ^[0-9a-f]{32}$ ]]; then
  printf 'CROSSPLANE_OVH_PROJECT_ID must be a 32-character lowercase hexadecimal ID.\n' >&2
  exit 1
fi

require_cluster
project_prefix=${CROSSPLANE_OVH_PROJECT_ID:0:12}
owner_name="xyz-ovh-owner-${project_prefix}"
credentials_name="xyz-ovh-s3-${project_prefix}"
connection_name="${credentials_name}-connection"

kube wait "user.cloud.ovh.m.edixos.io/${owner_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  --for=condition=Ready --timeout=30s

apply_template "${MANIFEST_DIR}/ovh-probe/s3-credentials.yaml" \
  OVH_CREDENTIALS_NAME "${credentials_name}" \
  OVH_CONNECTION_NAME "${connection_name}" \
  OVH_OWNER_NAME "${owner_name}" \
  OVH_PROJECT_ID "${CROSSPLANE_OVH_PROJECT_ID}"
kube wait "s3credentials.cloud.ovh.m.edixos.io/${credentials_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  --for=condition=Ready --timeout=5m

access_key_id=$(kube get "s3credentials.cloud.ovh.m.edixos.io/${credentials_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  -o jsonpath='{.status.atProvider.accessKeyId}')
[[ -n $access_key_id ]] || {
  printf 'The S3 credential is Ready but has no observed access key ID.\n' >&2
  exit 1
}

kube wait "secret/${connection_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  --for=create --timeout=1m
connection_keys=$(kube get "secret/${connection_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  -o go-template='{{range $key, $value := .data}}{{$key}}{{"\n"}}{{end}}' | sort)
[[ $connection_keys == $'access_key_id\nattribute.secret_access_key' ]] || {
  printf 'The S3 connection Secret does not have the expected key names.\n' >&2
  exit 1
}
connection_values_present=$(kube get "secret/${connection_name}" \
  --namespace "${INTEGRATION_NAMESPACE}" \
  -o go-template='{{if and (index .data "access_key_id") (index .data "attribute.secret_access_key")}}yes{{end}}')
[[ $connection_values_present == yes ]] || {
  printf 'The S3 connection Secret has an empty required value.\n' >&2
  exit 1
}
printf 'OVHcloud S3 credential is Ready with an observed access key ID and expected connection Secret key names.\n'
