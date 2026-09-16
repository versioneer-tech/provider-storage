#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

integration_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.bash
source "${integration_dir}/lib.bash"

verify_scenario() {
  local backend="$1" content="$2" bucket_a="$3" bucket_b="$4" bucket_it2_a="$5"
  [[ "$(grep -c '^kind: Storage$' <<<"${content}")" == 2 ]]
  grep -Fxq "  name: storage-${backend}-it" <<<"${content}"
  grep -Fxq "  name: storage-${backend}-it2" <<<"${content}"
  grep -Fxq "  principal: provider-storage-${backend}-it2" <<<"${content}"
  grep -Fq "bucketName: ${bucket_a}" <<<"${content}"
  [[ "$(grep -Fc "bucketName: ${bucket_b}" <<<"${content}")" == 3 ]]
  grep -Fq "bucketName: ${bucket_it2_a}" <<<"${content}"
  grep -Fq "grantee: provider-storage-${backend}-it2" <<<"${content}"
  grep -Fq 'permission: ReadOnly' <<<"${content}"
}

minio_content="$(<"${MANIFEST_DIR}/storages/minio.yaml")"
verify_scenario minio "${minio_content}" \
  minio-default-it-a minio-default-it-b minio-default-it2-a

aws_content="$(render_template "${MANIFEST_DIR}/storages/aws.yaml" \
  AWS_BUCKET_A aws-example-it-a \
  AWS_BUCKET_B aws-example-it-b \
  AWS_BUCKET_IT2_A aws-example-it2-a)"
verify_scenario aws "${aws_content}" \
  aws-example-it-a aws-example-it-b aws-example-it2-a

otc_content="$(render_template "${MANIFEST_DIR}/storages/otc.yaml" \
  OTC_BUCKET_A otc-example-it-a \
  OTC_BUCKET_B otc-example-it-b \
  OTC_BUCKET_IT2_A otc-example-it2-a)"
verify_scenario otc "${otc_content}" \
  otc-example-it-a otc-example-it-b otc-example-it2-a

ovh_content="$(render_template "${MANIFEST_DIR}/storages/ovh.yaml" \
  OVH_PROJECT_PREFIX 0123456789ab)"
verify_scenario ovh "${ovh_content}" \
  ovh-0123456789ab-it-a ovh-0123456789ab-it-b ovh-0123456789ab-it2-a

cloudferro_content="$(render_template "${MANIFEST_DIR}/storages/cloudferro.yaml" \
  CLOUDFERRO_SLOT cloudferro-0001 \
  CLOUDFERRO_PROJECT_PREFIX 0123456789ab \
  CLOUDFERRO_IT2_SLOT cloudferro-0002 \
  CLOUDFERRO_IT2_PROJECT_PREFIX fedcba987654)"
verify_scenario cloudferro "${cloudferro_content}" \
  cloudferro-0123456789ab-it-a \
  cloudferro-0123456789ab-it-b \
  cloudferro-fedcba987654-it2-a

printf 'Integration Storage manifests are aligned.\n'
