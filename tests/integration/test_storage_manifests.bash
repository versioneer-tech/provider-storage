#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.bash
source "${INTEGRATION_DIR}/lib.bash"

if (($#)); then
  BACKENDS=("$@")
else
  BACKENDS=(minio aws otc ovh cloudferro)
fi

assert_scenario() {
  local backend="$1" content="$2" bucket_a="$3" bucket_b="$4"
  local bucket_c="$5" bucket_d="$6" bucket_it2_a="$7"
  local storage="storage-${backend}-it"
  local storage_it2="storage-${backend}-it2"
  local principal="provider-storage-${backend}-it"
  local principal_it2="provider-storage-${backend}-it2"
  local environment="storage-${backend}"

  if ! env \
    XYZ_BACKEND="${backend}" \
    XYZ_BUCKET_A="${bucket_a}" \
    XYZ_BUCKET_B="${bucket_b}" \
    XYZ_BUCKET_C="${bucket_c}" \
    XYZ_BUCKET_D="${bucket_d}" \
    XYZ_BUCKET_IT2_A="${bucket_it2_a}" \
    XYZ_ENVIRONMENT="${environment}" \
    XYZ_PRINCIPAL="${principal}" \
    XYZ_PRINCIPAL_IT2="${principal_it2}" \
    XYZ_STORAGE="${storage}" \
    XYZ_STORAGE_IT2="${storage_it2}" \
    yq eval-all -e '
      [.] | (({
        "resources": map({
          "name": .metadata.name,
          "namespace": .metadata.namespace,
          "environment":
            .metadata.annotations."storages.pkg.internal/environment",
          "backend": .metadata.labels."storages.pkg.internal/backend",
          "selector":
            .spec.crossplane.compositionSelector.matchLabels.provider,
          "principal": .spec.principal,
          "providerIdentity": .spec.providerIdentity,
          "buckets": [.spec.buckets[].bucketName],
          "grants": [(.spec.bucketAccessGrants // [])[] | {
            "bucketName": .bucketName,
            "grantee": .grantee,
            "permission": .permission
          }],
          "requests": [(.spec.bucketAccessRequests // [])[] | {
            "bucketName": .bucketName,
            "reason": .reason
          }]
        })
      } | to_json) == ({
        "resources": [
          {
            "name": strenv(XYZ_STORAGE),
            "namespace": "provider-storage-it",
            "environment": strenv(XYZ_ENVIRONMENT),
            "backend": strenv(XYZ_BACKEND),
            "selector": strenv(XYZ_BACKEND),
            "principal": strenv(XYZ_PRINCIPAL),
            "providerIdentity": "it",
            "buckets": [
              strenv(XYZ_BUCKET_A),
              strenv(XYZ_BUCKET_B),
              strenv(XYZ_BUCKET_C),
              strenv(XYZ_BUCKET_D)
            ],
            "grants": [
              {
                "bucketName": strenv(XYZ_BUCKET_B),
                "grantee": strenv(XYZ_PRINCIPAL_IT2),
                "permission": "ReadOnly"
              },
              {
                "bucketName": strenv(XYZ_BUCKET_C),
                "grantee": strenv(XYZ_PRINCIPAL_IT2),
                "permission": "None"
              }
            ],
            "requests": []
          },
          {
            "name": strenv(XYZ_STORAGE_IT2),
            "namespace": "provider-storage-it",
            "environment": strenv(XYZ_ENVIRONMENT),
            "backend": strenv(XYZ_BACKEND),
            "selector": strenv(XYZ_BACKEND),
            "principal": strenv(XYZ_PRINCIPAL_IT2),
            "providerIdentity": "it2",
            "buckets": [strenv(XYZ_BUCKET_IT2_A)],
            "grants": [],
            "requests": [
              {
                "bucketName": strenv(XYZ_BUCKET_B),
                "reason": "Integration ReadOnly check"
              },
              {
                "bucketName": strenv(XYZ_BUCKET_C),
                "reason": "Integration denied ReadWrite check"
              },
              {
                "bucketName": strenv(XYZ_BUCKET_D),
                "reason": "Integration pending ReadOnly check"
              }
            ]
          }
        ]
      } | to_json))
    ' - >/dev/null <<<"${content}"; then
    printf 'Integration Storage manifest contract failed for %s.\n' \
      "${backend}" >&2
    return 1
  fi
}

validate_backend_manifest() {
  local backend="$1" content

  case "${backend}" in
    minio)
      content="$(<"${MANIFEST_DIR}/storages/minio.yaml")"
      assert_scenario minio "${content}" \
        minio-default-it-a minio-default-it-b minio-default-it-c \
        minio-default-it-d minio-default-it2-a
      ;;
    aws)
      content="$(render_template "${MANIFEST_DIR}/storages/aws.yaml" \
        AWS_BUCKET_A aws-example-it-a \
        AWS_BUCKET_B aws-example-it-b \
        AWS_BUCKET_C aws-example-it-c \
        AWS_BUCKET_D aws-example-it-d \
        AWS_BUCKET_IT2_A aws-example-it2-a)"
      assert_scenario aws "${content}" \
        aws-example-it-a aws-example-it-b aws-example-it-c \
        aws-example-it-d aws-example-it2-a
      ;;
    otc)
      content="$(render_template "${MANIFEST_DIR}/storages/otc.yaml" \
        OTC_BUCKET_A otc-example-it-a \
        OTC_BUCKET_B otc-example-it-b \
        OTC_BUCKET_C otc-example-it-c \
        OTC_BUCKET_D otc-example-it-d \
        OTC_BUCKET_IT2_A otc-example-it2-a)"
      assert_scenario otc "${content}" \
        otc-example-it-a otc-example-it-b otc-example-it-c \
        otc-example-it-d otc-example-it2-a
      ;;
    ovh)
      content="$(render_template "${MANIFEST_DIR}/storages/ovh.yaml" \
        OVH_PROJECT_PREFIX 0123456789ab)"
      assert_scenario ovh "${content}" \
        ovh-0123456789ab-it-a ovh-0123456789ab-it-b \
        ovh-0123456789ab-it-c ovh-0123456789ab-it-d \
        ovh-0123456789ab-it2-a
      ;;
    cloudferro)
      content="$(render_template "${MANIFEST_DIR}/storages/cloudferro.yaml" \
        CLOUDFERRO_PROJECT_ID 0123456789abcdef0123456789abcdef \
        CLOUDFERRO_PROJECT_PREFIX 0123456789ab \
        CLOUDFERRO_IT2_PROJECT_ID fedcba9876543210fedcba9876543210 \
        CLOUDFERRO_IT2_PROJECT_PREFIX fedcba987654)"
      assert_scenario cloudferro "${content}" \
        cloudferro-0123456789ab-it-a \
        cloudferro-0123456789ab-it-b \
        cloudferro-0123456789ab-it-c \
        cloudferro-0123456789ab-it-d \
        cloudferro-fedcba987654-it2-a
      ;;
    *)
      selected_backend "${backend}" "$0" >/dev/null
      ;;
  esac
}

main() {
  require_command yq

  local backend
  for backend in "${BACKENDS[@]}"; do
    validate_backend_manifest "${backend}"
  done

  printf 'Integration Storage manifest contracts passed.\n'
}

main
