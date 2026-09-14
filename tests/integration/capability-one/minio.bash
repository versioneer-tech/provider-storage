#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

story_environment=storage-minio
story_rclone_provider=Minio

story_bucket() {
  printf '%s-%s\n' "${story_prefix}" "$1"
}

story_identity() {
  printf '%s-%s\n' "${story_prefix}" "$1"
}

story_bucket_exists() {
  kube get bucket.minio.crossplane.io/"$1" >/dev/null 2>&1
}

story_setup() {
  kube create namespace "${story_namespace}"
  cat <<EOF | kube apply -f -
apiVersion: kubernetes.m.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: provider-kubernetes
  namespace: ${story_namespace}
spec:
  credentials:
    source: InjectedIdentity
EOF
  kube wait provider.pkg.crossplane.io/provider-minio \
    --for=condition=Healthy --timeout=5m
  kube get environmentconfig.apiextensions.crossplane.io/${story_environment} \
    >/dev/null
  kube get composition.apiextensions.crossplane.io/storage-minio >/dev/null
}
