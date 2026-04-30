#!/usr/bin/env bash
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

: "${CROSSPLANE_NAMESPACE:=crossplane}"
: "${PR_SLUG:=dev}"
: "${GITHUB_REPOSITORY_OWNER:=versioneer-tech}"
: "${GITHUB_REPOSITORY:=versioneer-tech/provider-storage}"

ORG="${GITHUB_REPOSITORY_OWNER,,}"
REPO="${GITHUB_REPOSITORY#*/}"
REPO="${REPO,,}"
PACKAGE="ghcr.io/${ORG}/${REPO}/minio:${PR_SLUG}"

kubectl create namespace "${CROSSPLANE_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace workspace --dry-run=client -o yaml | kubectl apply -f -

helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm upgrade --install crossplane crossplane-stable/crossplane \
  --namespace "${CROSSPLANE_NAMESPACE}" \
  --version 2.0.2 \
  --set provider.defaultActivations={}

kubectl rollout status deployment/crossplane \
  --namespace "${CROSSPLANE_NAMESPACE}" \
  --timeout=5m

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: default-env-configuration
  namespace: minio
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
  namespace: minio
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
          image: minio/minio:RELEASE.2025-04-22T22-12-26Z
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
  namespace: minio
spec:
  selector:
    app.kubernetes.io/name: minio-e2e
  ports:
    - name: api
      port: 9000
      targetPort: api
EOF

kubectl rollout status deployment/default --namespace minio --timeout=5m

kubectl apply -f minio/dependencies/00-mrap.yaml
kubectl apply -f minio/dependencies/01-deploymentRuntimeConfigs.yaml
kubectl apply -f minio/dependencies/02-providers.yaml
kubectl apply -f minio/dependencies/functions.yaml
kubectl apply -f minio/dependencies/rbac.yaml
kubectl apply -f minio/dependencies/03-providerConfigs.yaml
kubectl apply -f minio/dependencies/04-environmentConfigs.yaml

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
