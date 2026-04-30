#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

: "${KIND_CLUSTER_NAME:=storage-minio}"
: "${CREATE_KIND_CLUSTER:=auto}"
: "${DELETE_KIND_CLUSTER:=false}"
: "${CROSSPLANE_NAMESPACE:=crossplane}"
: "${CROSSPLANE_VERSION:=2.0.2}"
: "${MINIO_NAMESPACE:=minio}"
: "${WORKSPACE_NAMESPACE:=workspace}"
: "${PR_SLUG:=dev}"
: "${GITHUB_REPOSITORY_OWNER:=versioneer-tech}"
: "${GITHUB_REPOSITORY:=versioneer-tech/provider-storage}"
: "${INSTALL_CONFIGURATION_PACKAGE:=auto}"
: "${APPLY_EXAMPLES:=true}"
: "${RUN_SETUP:=true}"
: "${RUN_EXAMPLE_TESTS:=${APPLY_EXAMPLES}}"
: "${RUN_LIFECYCLE_TEST:=${VERIFY_LIFECYCLE:-true}}"
: "${VERIFY_MINIO:=true}"
: "${VERIFY_OBJECT_ROUNDTRIP:=true}"
: "${VERIFY_LIFECYCLE:=true}"
: "${MINIO_IMAGE:=minio/minio:RELEASE.2025-04-22T22-12-26Z}"
: "${MINIO_MC_IMAGE:=minio/mc:latest}"
: "${RCLONE_IMAGE:=rclone/rclone:1.69}"
: "${LIFECYCLE_TEST_NAME:=lifecycle-test}"
: "${LIFECYCLE_WAIT_SECONDS:=75}"

PACKAGE_WAS_SET="${PACKAGE+x}"
ORG="${GITHUB_REPOSITORY_OWNER,,}"
REPO="${GITHUB_REPOSITORY#*/}"
REPO="${REPO,,}"
: "${PACKAGE:=ghcr.io/${ORG}/${REPO}/minio:${PR_SLUG}}"

created_kind_cluster=false
KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-}"

log() {
  printf '\n==> %s\n' "$*"
}

kubectl() {
  if [[ -n "${KUBECTL_CONTEXT}" ]]; then
    command kubectl --context "${KUBECTL_CONTEXT}" "$@"
  else
    command kubectl "$@"
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

current_cluster_ready() {
  kubectl cluster-info >/dev/null 2>&1
}

kind_cluster_exists() {
  kind get clusters 2>/dev/null | grep -Fxq "${KIND_CLUSTER_NAME}"
}

ensure_kind_cluster() {
  require_command kubectl
  require_command helm

  if [[ "${CREATE_KIND_CLUSTER}" == "false" ]]; then
    if current_cluster_ready; then
      KUBECTL_CONTEXT="$(command kubectl config current-context)"
      log "Using existing Kubernetes context ${KUBECTL_CONTEXT}"
      return
    fi

    printf 'No usable Kubernetes context and CREATE_KIND_CLUSTER=false.\n' >&2
    exit 1
  fi

  require_command docker
  require_command kind

  if kind_cluster_exists; then
    log "Using existing kind cluster ${KIND_CLUSTER_NAME}"
    kind export kubeconfig --name "${KIND_CLUSTER_NAME}"
    KUBECTL_CONTEXT="kind-${KIND_CLUSTER_NAME}"
    return
  fi

  if [[ "${CREATE_KIND_CLUSTER}" == "auto" || "${CREATE_KIND_CLUSTER}" == "true" ]]; then
    log "Creating kind cluster ${KIND_CLUSTER_NAME}"
    kind create cluster --name "${KIND_CLUSTER_NAME}"
    kind export kubeconfig --name "${KIND_CLUSTER_NAME}"
    KUBECTL_CONTEXT="kind-${KIND_CLUSTER_NAME}"
    created_kind_cluster=true
    return
  fi

  printf 'CREATE_KIND_CLUSTER must be auto, true, or false.\n' >&2
  exit 1
}

cleanup() {
  if [[ "${DELETE_KIND_CLUSTER}" == "true" && "${created_kind_cluster}" == "true" ]]; then
    log "Deleting kind cluster ${KIND_CLUSTER_NAME}"
    kind delete cluster --name "${KIND_CLUSTER_NAME}"
  fi
}
trap cleanup EXIT

apply_namespace() {
  kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f -
}

show_core_state() {
  log "Kubernetes core state"
  echo "+ kubectl get pods --all-namespaces"
  kubectl get pods --all-namespaces || true
  echo "+ kubectl get providers,functions"
  kubectl get providers.pkg.crossplane.io,functions.pkg.crossplane.io || true
  echo "+ kubectl get providerconfigs and EnvironmentConfig"
  kubectl get providerconfigs.minio.crossplane.io || true
  kubectl get providerconfigs.kubernetes.m.crossplane.io --all-namespaces || true
  kubectl get environmentconfigs.apiextensions.crossplane.io || true
}

show_storage_state() {
  log "Storage resources and composed MinIO state"
  echo "+ kubectl get storages.pkg.internal -n ${WORKSPACE_NAMESPACE}"
  kubectl get storages.pkg.internal --namespace "${WORKSPACE_NAMESPACE}" || true
  echo "+ kubectl get objects.kubernetes.m.crossplane.io -n ${WORKSPACE_NAMESPACE}"
  kubectl get objects.kubernetes.m.crossplane.io --namespace "${WORKSPACE_NAMESPACE}" || true
  echo "+ kubectl get buckets/users/policies -n ${WORKSPACE_NAMESPACE}"
  kubectl get buckets.minio.crossplane.io,users.minio.crossplane.io,policies.minio.crossplane.io \
    --namespace "${WORKSPACE_NAMESPACE}" || true
  echo "+ kubectl get generated Secrets -n ${WORKSPACE_NAMESPACE}"
  kubectl get secrets --namespace "${WORKSPACE_NAMESPACE}" || true
}

install_crossplane() {
  log "Installing Crossplane ${CROSSPLANE_VERSION}"
  apply_namespace "${CROSSPLANE_NAMESPACE}"

  helm repo add crossplane-stable https://charts.crossplane.io/stable --force-update
  helm repo update crossplane-stable
  helm upgrade --install crossplane crossplane-stable/crossplane \
    --namespace "${CROSSPLANE_NAMESPACE}" \
    --version "${CROSSPLANE_VERSION}" \
    --set 'provider.defaultActivations={}' \
    --wait \
    --timeout 10m

  kubectl rollout status deployment/crossplane \
    --namespace "${CROSSPLANE_NAMESPACE}" \
    --timeout=5m
}

install_minio() {
  log "Installing local MinIO"
  apply_namespace "${MINIO_NAMESPACE}"

  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: default-env-configuration
  namespace: ${MINIO_NAMESPACE}
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: minioadmin
  AWS_SECRET_ACCESS_KEY: minioadmin
  accesskey: minioadmin
  secretkey: minioadmin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: default
  namespace: ${MINIO_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: minio-e2e
  template:
    metadata:
      labels:
        app.kubernetes.io/name: minio-e2e
    spec:
      containers:
        - name: minio
          image: ${MINIO_IMAGE}
          args:
            - server
            - /data
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: default-env-configuration
                  key: accesskey
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: default-env-configuration
                  key: secretkey
          ports:
            - name: api
              containerPort: 9000
          readinessProbe:
            httpGet:
              path: /minio/health/ready
              port: api
            initialDelaySeconds: 5
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: default-hl
  namespace: ${MINIO_NAMESPACE}
spec:
  selector:
    app.kubernetes.io/name: minio-e2e
  ports:
    - name: api
      port: 9000
      targetPort: api
EOF

  kubectl rollout status deployment/default \
    --namespace "${MINIO_NAMESPACE}" \
    --timeout=5m
}

install_minio_dependencies() {
  log "Installing MinIO Crossplane dependencies"
  kubectl apply -f minio/dependencies/00-mrap.yaml
  kubectl apply -f minio/dependencies/01-deploymentRuntimeConfigs.yaml
  kubectl apply -f minio/dependencies/02-providers.yaml
  kubectl apply -f minio/dependencies/functions.yaml
  kubectl apply -f minio/dependencies/rbac.yaml

  kubectl wait provider.pkg.crossplane.io/provider-minio \
    --for=condition=Healthy \
    --timeout=10m
  kubectl wait provider.pkg.crossplane.io/provider-kubernetes \
    --for=condition=Healthy \
    --timeout=10m
  kubectl wait function.pkg.crossplane.io/crossplane-contrib-function-python \
    --for=condition=Healthy \
    --timeout=10m
  kubectl wait function.pkg.crossplane.io/crossplane-contrib-function-auto-ready \
    --for=condition=Healthy \
    --timeout=10m

  kubectl apply -f minio/dependencies/03-providerConfigs.yaml
  kubectl apply -f minio/dependencies/04-environmentConfigs.yaml
}

install_storage_api() {
  if [[ "${INSTALL_CONFIGURATION_PACKAGE}" == "auto" ]]; then
    if [[ -n "${PACKAGE_WAS_SET}" || "${PR_SLUG}" != "dev" ]]; then
      INSTALL_CONFIGURATION_PACKAGE=true
    else
      INSTALL_CONFIGURATION_PACKAGE=false
    fi
  fi

  if [[ "${INSTALL_CONFIGURATION_PACKAGE}" == "true" ]]; then
    log "Installing MinIO configuration package ${PACKAGE}"
    kubectl apply -f - <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-minio
spec:
  package: ${PACKAGE}
  skipDependencyResolution: true
EOF

    kubectl wait configuration.pkg.crossplane.io/storage-minio \
      --for=condition=Healthy \
      --timeout=10m
  elif [[ "${INSTALL_CONFIGURATION_PACKAGE}" == "false" ]]; then
    log "Installing local XRD and MinIO composition"
    kubectl apply -f xrd.yaml
    kubectl wait crd/storages.pkg.internal \
      --for=condition=Established \
      --timeout=2m
    kubectl apply -f minio/composition.yaml
  else
    printf 'INSTALL_CONFIGURATION_PACKAGE must be auto, true, or false.\n' >&2
    exit 1
  fi
}

ensure_workspace_provider_config() {
  log "Ensuring workspace namespace and provider-kubernetes ProviderConfig"
  apply_namespace "${WORKSPACE_NAMESPACE}"
  kubectl apply -f - <<EOF
apiVersion: kubernetes.m.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: provider-kubernetes
  namespace: ${WORKSPACE_NAMESPACE}
spec:
  credentials:
    source: InjectedIdentity
EOF
}

apply_examples() {
  log "Applying MinIO examples"
  ensure_workspace_provider_config
  echo "+ kubectl apply -k examples/overlays/minio"
  kubectl apply -k examples/overlays/minio
}

wait_for_storage() {
  log "Waiting for Storage examples to become ready"
  local storage
  for storage in s-joe s-jeff s-jane s-john; do
    echo "+ kubectl wait storage.pkg.internal/${storage} -n ${WORKSPACE_NAMESPACE} --for=condition=Ready --timeout=15m"
    kubectl wait "storage.pkg.internal/${storage}" \
      --namespace "${WORKSPACE_NAMESPACE}" \
      --for=condition=Ready \
      --timeout=15m
  done
  show_storage_state
}

mc_job() {
  local name="minio-mc-$(date +%s)-${RANDOM}"
  local script
  script="echo '+ mc alias set local http://default-hl.${MINIO_NAMESPACE}:9000 minioadmin minioadmin'
mc alias set local http://default-hl.${MINIO_NAMESPACE}:9000 minioadmin minioadmin >/dev/null
$*"

  echo "+ kubectl run ${name} -n ${MINIO_NAMESPACE} --image ${MINIO_MC_IMAGE} --restart=Never"
  kubectl run "${name}" \
    --namespace "${MINIO_NAMESPACE}" \
    --image "${MINIO_MC_IMAGE}" \
    --restart=Never \
    --command -- /bin/sh -ec "${script}"

  echo "+ kubectl wait pod/${name} -n ${MINIO_NAMESPACE} --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m"
  if ! kubectl wait "pod/${name}" \
    --namespace "${MINIO_NAMESPACE}" \
    --for=jsonpath='{.status.phase}'=Succeeded \
    --timeout=5m; then
    echo "+ kubectl logs pod/${name} -n ${MINIO_NAMESPACE}"
    kubectl logs "pod/${name}" --namespace "${MINIO_NAMESPACE}" || true
    echo "+ kubectl describe pod/${name} -n ${MINIO_NAMESPACE}"
    kubectl describe "pod/${name}" --namespace "${MINIO_NAMESPACE}" || true
    exit 1
  fi

  echo "+ kubectl logs pod/${name} -n ${MINIO_NAMESPACE}"
  kubectl logs "pod/${name}" --namespace "${MINIO_NAMESPACE}"
  echo "+ kubectl delete pod/${name} -n ${MINIO_NAMESPACE} --wait=false"
  kubectl delete "pod/${name}" --namespace "${MINIO_NAMESPACE}" --wait=false
}

verify_minio_state() {
  [[ "${VERIFY_MINIO}" == "true" ]] || return

  log "Verifying buckets, users, and policies in MinIO"
  local today current_week previous_week year month quarter jane_current
  today="$(date -u +%Y%m%d)"
  current_week="$(date -u +%Gw%V)"
  previous_week="$(date -u -d '7 days ago' +%Gw%V)"
  year="$(date -u +%Y)"
  month="$(date -u +%-m)"
  quarter=$(((month + 2) / 3))
  jane_current="s-jane-${year}q${quarter}"

  mc_job "
for bucket in s-joe s-jeff s-jeff-shared s-john; do
  echo \"+ mc stat local/\${bucket}\"
  mc stat \"local/\${bucket}\" >/dev/null
  echo \"bucket \${bucket} exists\"
done

for user in s-joe-1 s-jeff-${previous_week} s-jeff-${current_week} ${jane_current} s-john-${today}; do
  echo \"+ mc admin user info local \${user}\"
  mc admin user info local \"\${user}\" >/dev/null
  echo \"user \${user} exists\"
done

for policy in s-joe.s-joe s-jeff.s-joe s-jeff.s-jeff s-jeff.s-jeff-shared s-joe.s-jeff-shared s-jane.s-john s-john.s-john; do
  echo \"+ mc admin policy info local \${policy}\"
  mc admin policy info local \"\${policy}\" >/dev/null
  echo \"policy \${policy} exists\"
done
"
}

wait_for_resource() {
  local resource="$1"
  local namespace="$2"
  local timeout_seconds="$3"
  local waited=0

  echo "+ kubectl get ${resource} -n ${namespace}"
  until kubectl get "${resource}" --namespace "${namespace}" >/dev/null 2>&1; do
    if (( waited >= timeout_seconds )); then
      printf 'Timed out waiting for %s in namespace %s\n' "${resource}" "${namespace}" >&2
      exit 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  kubectl get "${resource}" --namespace "${namespace}"
}

wait_for_job() {
  local name="$1"

  echo "+ kubectl get job/${name} -n ${WORKSPACE_NAMESPACE}"
  kubectl get "job/${name}" --namespace "${WORKSPACE_NAMESPACE}" || true
  echo "+ kubectl wait job/${name} -n ${WORKSPACE_NAMESPACE} --for=condition=Complete --timeout=180s"
  if ! kubectl wait "job/${name}" \
    --namespace "${WORKSPACE_NAMESPACE}" \
    --for=condition=Complete \
    --timeout=180s; then
    echo "+ kubectl logs job/${name} -n ${WORKSPACE_NAMESPACE} --all-containers=true"
    kubectl logs "job/${name}" --namespace "${WORKSPACE_NAMESPACE}" --all-containers=true || true
    echo "+ kubectl describe job/${name} -n ${WORKSPACE_NAMESPACE}"
    kubectl describe "job/${name}" --namespace "${WORKSPACE_NAMESPACE}" || true
    exit 1
  fi

  echo "+ kubectl get pods -n ${WORKSPACE_NAMESPACE} --selector=job-name=${name}"
  kubectl get pods --namespace "${WORKSPACE_NAMESPACE}" --selector="job-name=${name}" || true
  echo "+ kubectl logs job/${name} -n ${WORKSPACE_NAMESPACE} --all-containers=true"
  kubectl logs "job/${name}" --namespace "${WORKSPACE_NAMESPACE}" --all-containers=true
}

cleanup_roundtrip_jobs() {
  kubectl delete job s-joe-roundtrip \
    --namespace "${WORKSPACE_NAMESPACE}" \
    --ignore-not-found \
    --wait=false
}

verify_secret_has_key() {
  local secret_name="$1"
  local key="$2"
  local value

  value="$(kubectl get "secret/${secret_name}" \
    --namespace "${WORKSPACE_NAMESPACE}" \
    -o "jsonpath={.data.${key}}" 2>/dev/null || true)"
  if [[ -z "${value}" ]]; then
    printf 'Secret %s is missing key %s\n' "${secret_name}" "${key}" >&2
    exit 1
  fi
}

verify_generated_secrets_and_roundtrip() {
  [[ "${VERIFY_OBJECT_ROUNDTRIP}" == "true" ]] || return

  log "Verifying generated Secrets and principal object roundtrip"
  local secret_name
  for secret_name in s-joe s-jeff s-jane s-john; do
    wait_for_resource "secret/${secret_name}" "${WORKSPACE_NAMESPACE}" 180
    echo "+ kubectl get secret/${secret_name} -n ${WORKSPACE_NAMESPACE}"
    kubectl get "secret/${secret_name}" --namespace "${WORKSPACE_NAMESPACE}"
    verify_secret_has_key "${secret_name}" AWS_ACCESS_KEY_ID
    verify_secret_has_key "${secret_name}" AWS_SECRET_ACCESS_KEY
    echo "secret ${secret_name} has AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
  done

  cleanup_roundtrip_jobs
  echo "+ kubectl apply -f - # Job/s-joe-roundtrip"
  kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: s-joe-roundtrip
  namespace: ${WORKSPACE_NAMESPACE}
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      automountServiceAccountToken: false
      restartPolicy: Never
      containers:
        - name: roundtrip
          image: ${RCLONE_IMAGE}
          imagePullPolicy: IfNotPresent
          env:
            - name: RCLONE_CONFIG_STORAGE_TYPE
              value: s3
            - name: RCLONE_CONFIG_STORAGE_PROVIDER
              value: Minio
            - name: RCLONE_CONFIG_STORAGE_ENDPOINT
              value: http://default-hl.${MINIO_NAMESPACE}:9000
            - name: RCLONE_CONFIG_STORAGE_FORCE_PATH_STYLE
              value: "true"
            - name: RCLONE_CONFIG_STORAGE_REGION
              value: us-east-1
            - name: RCLONE_CONFIG_STORAGE_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: s-joe
                  key: AWS_ACCESS_KEY_ID
            - name: RCLONE_CONFIG_STORAGE_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: s-joe
                  key: AWS_SECRET_ACCESS_KEY
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              object=e2e/roundtrip.txt
              echo "writing test object to storage:s-joe/\${object}"
              printf 'provider-storage e2e roundtrip\n' >/tmp/upload.txt
              echo "+ rclone copyto /tmp/upload.txt storage:s-joe/\${object} --s3-no-check-bucket"
              rclone copyto /tmp/upload.txt "storage:s-joe/\${object}" --s3-no-check-bucket

              echo "listing e2e prefix after upload"
              echo "+ rclone lsf storage:s-joe/e2e/ --s3-no-check-bucket | sort"
              rclone lsf storage:s-joe/e2e/ --s3-no-check-bucket | sort

              echo "downloading test object from storage:s-joe/\${object}"
              echo "+ rclone copyto storage:s-joe/\${object} /tmp/download.txt --s3-no-check-bucket"
              rclone copyto "storage:s-joe/\${object}" /tmp/download.txt --s3-no-check-bucket
              echo "+ cmp /tmp/upload.txt /tmp/download.txt"
              cmp /tmp/upload.txt /tmp/download.txt

              echo "downloaded object content:"
              echo "+ cat /tmp/download.txt"
              cat /tmp/download.txt

              echo "removing roundtrip object"
              echo "+ rclone deletefile storage:s-joe/\${object} --s3-no-check-bucket"
              rclone deletefile "storage:s-joe/\${object}" --s3-no-check-bucket
EOF

  wait_for_job s-joe-roundtrip
  show_storage_state
  cleanup_roundtrip_jobs
}

cleanup_lifecycle_jobs() {
  kubectl delete job \
    "${LIFECYCLE_TEST_NAME}-seed" \
    "${LIFECYCLE_TEST_NAME}-cleanup-1" \
    "${LIFECYCLE_TEST_NAME}-verify" \
    --namespace "${WORKSPACE_NAMESPACE}" \
    --ignore-not-found \
    --wait=false
}

reset_lifecycle_storage() {
  cleanup_lifecycle_jobs
  log "Emptying lifecycle test bucket before reset"
  mc_job "
echo '+ mc rm --recursive --force local/${LIFECYCLE_TEST_NAME}'
mc rm --recursive --force local/${LIFECYCLE_TEST_NAME} || true
"
  echo "+ kubectl delete storage.pkg.internal/${LIFECYCLE_TEST_NAME} -n ${WORKSPACE_NAMESPACE} --ignore-not-found --wait=true --timeout=300s"
  kubectl delete "storage.pkg.internal/${LIFECYCLE_TEST_NAME}" \
    --namespace "${WORKSPACE_NAMESPACE}" \
    --ignore-not-found \
    --wait=true \
    --timeout=300s
}

verify_lifecycle_cleanup() {
  [[ "${VERIFY_LIFECYCLE}" == "true" ]] || return

  log "Verifying lifecycle cleanup CronJob"
  ensure_workspace_provider_config
  reset_lifecycle_storage

  echo "+ kubectl apply -f - # Storage/${LIFECYCLE_TEST_NAME}"
  kubectl apply -f - <<EOF
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: ${LIFECYCLE_TEST_NAME}
  namespace: ${WORKSPACE_NAMESPACE}
  annotations:
    storages.pkg.internal/environment: storage
spec:
  principal: ${LIFECYCLE_TEST_NAME}
  buckets:
    - bucketName: ${LIFECYCLE_TEST_NAME}
      lifecycleRules:
        - target: tmp/*
          mode: Delete
          minAge: 1m
  crossplane:
    compositionSelector:
      matchLabels:
        provider: minio
EOF

  echo "+ kubectl wait storage.pkg.internal/${LIFECYCLE_TEST_NAME} -n ${WORKSPACE_NAMESPACE} --for=condition=Ready --timeout=300s"
  kubectl wait "storage.pkg.internal/${LIFECYCLE_TEST_NAME}" \
    --namespace "${WORKSPACE_NAMESPACE}" \
    --for=condition=Ready \
    --timeout=300s
  show_storage_state

  wait_for_resource "configmap/${LIFECYCLE_TEST_NAME}-lifecycle" "${WORKSPACE_NAMESPACE}" 120
  wait_for_resource "cronjob/${LIFECYCLE_TEST_NAME}-lifecycle" "${WORKSPACE_NAMESPACE}" 120

  log "Generated lifecycle resources"
  echo "+ kubectl get configmap/${LIFECYCLE_TEST_NAME}-lifecycle -n ${WORKSPACE_NAMESPACE} -o yaml"
  kubectl get "configmap/${LIFECYCLE_TEST_NAME}-lifecycle" --namespace "${WORKSPACE_NAMESPACE}" -o yaml
  echo "+ kubectl get cronjob/${LIFECYCLE_TEST_NAME}-lifecycle -n ${WORKSPACE_NAMESPACE} -o yaml"
  kubectl get "cronjob/${LIFECYCLE_TEST_NAME}-lifecycle" --namespace "${WORKSPACE_NAMESPACE}" -o yaml

  local generated_script expected_script
  generated_script="$(kubectl get "configmap/${LIFECYCLE_TEST_NAME}-lifecycle" \
    --namespace "${WORKSPACE_NAMESPACE}" \
    -o jsonpath='{.data.rule-01\.sh}')"
  expected_script="#!/bin/sh
set -eu
exec rclone delete storage:${LIFECYCLE_TEST_NAME}/tmp/ --min-age 1m --fast-list --s3-no-check-bucket"
  if [[ "${generated_script}" != "${expected_script}" ]]; then
    printf 'Unexpected lifecycle script:\n%s\n' "${generated_script}" >&2
    exit 1
  fi

  echo "+ kubectl apply -f - # Job/${LIFECYCLE_TEST_NAME}-seed"
  kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${LIFECYCLE_TEST_NAME}-seed
  namespace: ${WORKSPACE_NAMESPACE}
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      automountServiceAccountToken: false
      restartPolicy: Never
      containers:
        - name: seed
          image: ${RCLONE_IMAGE}
          imagePullPolicy: IfNotPresent
          env:
            - name: RCLONE_CONFIG_STORAGE_TYPE
              value: s3
            - name: RCLONE_CONFIG_STORAGE_PROVIDER
              value: Minio
            - name: RCLONE_CONFIG_STORAGE_ENDPOINT
              value: http://default-hl.${MINIO_NAMESPACE}:9000
            - name: RCLONE_CONFIG_STORAGE_FORCE_PATH_STYLE
              value: "true"
            - name: RCLONE_CONFIG_STORAGE_REGION
              value: us-east-1
            - name: RCLONE_CONFIG_STORAGE_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: ${LIFECYCLE_TEST_NAME}
                  key: AWS_ACCESS_KEY_ID
            - name: RCLONE_CONFIG_STORAGE_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: ${LIFECYCLE_TEST_NAME}
                  key: AWS_SECRET_ACCESS_KEY
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              expected='data/
              data/keep.txt
              root-keep.txt
              tmp/
              tmp/delete-me.txt'
              echo "+ rclone delete storage:${LIFECYCLE_TEST_NAME} --s3-no-check-bucket"
              rclone delete storage:${LIFECYCLE_TEST_NAME} --s3-no-check-bucket || true
              printf 'delete after one minute\n' >/tmp/delete-me.txt
              printf 'keep at bucket root\n' >/tmp/root-keep.txt
              printf 'keep below data\n' >/tmp/data-keep.txt
              echo "+ rclone copyto /tmp/delete-me.txt storage:${LIFECYCLE_TEST_NAME}/tmp/delete-me.txt --s3-no-check-bucket"
              rclone copyto /tmp/delete-me.txt storage:${LIFECYCLE_TEST_NAME}/tmp/delete-me.txt --s3-no-check-bucket
              echo "+ rclone copyto /tmp/root-keep.txt storage:${LIFECYCLE_TEST_NAME}/root-keep.txt --s3-no-check-bucket"
              rclone copyto /tmp/root-keep.txt storage:${LIFECYCLE_TEST_NAME}/root-keep.txt --s3-no-check-bucket
              echo "+ rclone copyto /tmp/data-keep.txt storage:${LIFECYCLE_TEST_NAME}/data/keep.txt --s3-no-check-bucket"
              rclone copyto /tmp/data-keep.txt storage:${LIFECYCLE_TEST_NAME}/data/keep.txt --s3-no-check-bucket
              echo "+ rclone lsf -R storage:${LIFECYCLE_TEST_NAME} --s3-no-check-bucket | sort"
              listing="\$(rclone lsf -R storage:${LIFECYCLE_TEST_NAME} --s3-no-check-bucket | sort)"
              printf '%s\n' "\${listing}"
              if [ "\${listing}" != "\${expected}" ]; then
                echo "unexpected pre-cleanup listing" >&2
                exit 1
              fi
EOF

  wait_for_job "${LIFECYCLE_TEST_NAME}-seed"

  log "Waiting ${LIFECYCLE_WAIT_SECONDS}s for lifecycle minAge"
  sleep "${LIFECYCLE_WAIT_SECONDS}"

  echo "+ kubectl delete job/${LIFECYCLE_TEST_NAME}-cleanup-1 -n ${WORKSPACE_NAMESPACE} --ignore-not-found --wait=false"
  kubectl delete "job/${LIFECYCLE_TEST_NAME}-cleanup-1" \
    --namespace "${WORKSPACE_NAMESPACE}" \
    --ignore-not-found \
    --wait=false
  echo "+ kubectl create job ${LIFECYCLE_TEST_NAME}-cleanup-1 -n ${WORKSPACE_NAMESPACE} --from=cronjob/${LIFECYCLE_TEST_NAME}-lifecycle"
  kubectl create job "${LIFECYCLE_TEST_NAME}-cleanup-1" \
    --namespace "${WORKSPACE_NAMESPACE}" \
    --from="cronjob/${LIFECYCLE_TEST_NAME}-lifecycle"
  wait_for_job "${LIFECYCLE_TEST_NAME}-cleanup-1"

  echo "+ kubectl apply -f - # Job/${LIFECYCLE_TEST_NAME}-verify"
  kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${LIFECYCLE_TEST_NAME}-verify
  namespace: ${WORKSPACE_NAMESPACE}
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      automountServiceAccountToken: false
      restartPolicy: Never
      containers:
        - name: verify
          image: ${RCLONE_IMAGE}
          imagePullPolicy: IfNotPresent
          env:
            - name: RCLONE_CONFIG_STORAGE_TYPE
              value: s3
            - name: RCLONE_CONFIG_STORAGE_PROVIDER
              value: Minio
            - name: RCLONE_CONFIG_STORAGE_ENDPOINT
              value: http://default-hl.${MINIO_NAMESPACE}:9000
            - name: RCLONE_CONFIG_STORAGE_FORCE_PATH_STYLE
              value: "true"
            - name: RCLONE_CONFIG_STORAGE_REGION
              value: us-east-1
            - name: RCLONE_CONFIG_STORAGE_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: ${LIFECYCLE_TEST_NAME}
                  key: AWS_ACCESS_KEY_ID
            - name: RCLONE_CONFIG_STORAGE_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: ${LIFECYCLE_TEST_NAME}
                  key: AWS_SECRET_ACCESS_KEY
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              expected='data/
              data/keep.txt
              root-keep.txt'
              echo "+ rclone lsf -R storage:${LIFECYCLE_TEST_NAME} --s3-no-check-bucket | sort"
              listing="\$(rclone lsf -R storage:${LIFECYCLE_TEST_NAME} --s3-no-check-bucket | sort)"
              echo "+ rclone lsf -R storage:${LIFECYCLE_TEST_NAME}/tmp/ --s3-no-check-bucket | sort"
              tmp_listing="\$(rclone lsf -R storage:${LIFECYCLE_TEST_NAME}/tmp/ --s3-no-check-bucket | sort)"
              echo "all objects:"
              printf '%s\n' "\${listing}"
              echo "tmp objects:"
              printf '%s\n' "\${tmp_listing}"
              if [ "\${listing}" != "\${expected}" ]; then
                echo "unexpected post-cleanup listing" >&2
                exit 1
              fi
              if [ -n "\${tmp_listing}" ]; then
                echo "tmp prefix still contains objects" >&2
                exit 1
              fi
EOF

  wait_for_job "${LIFECYCLE_TEST_NAME}-verify"
  show_storage_state
  cleanup_lifecycle_jobs
}

debug_cluster_state() {
  log "Cluster state"
  show_core_state
  show_storage_state
}

setup_stack() {
  log "Running setup phase"
  ensure_kind_cluster
  install_crossplane
  install_minio
  install_minio_dependencies
  install_storage_api
  show_core_state
}

run_example_tests() {
  log "Running example Storage e2e phase"
  apply_examples
  show_storage_state
  wait_for_storage
  verify_minio_state
  verify_generated_secrets_and_roundtrip
}

run_lifecycle_tests() {
  log "Running lifecycle e2e phase"
  verify_lifecycle_cleanup
}

main() {
  trap debug_cluster_state ERR

  if [[ "${RUN_SETUP}" == "true" ]]; then
    setup_stack
  fi
  if [[ "${RUN_EXAMPLE_TESTS}" == "true" ]]; then
    run_example_tests
  fi
  if [[ "${RUN_LIFECYCLE_TEST}" == "true" ]]; then
    run_lifecycle_tests
  fi

  log "MinIO e2e completed"
}

main "$@"
