#!/bin/bash

# Add helm repositories for Crossplane
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update

# Install Crossplane
helm install crossplane \
--namespace crossplane-system \
--create-namespace crossplane-stable/crossplane \
--version 2.0.2 \
--wait

# Install the storage-scaleway configuration package
kubectl apply -f - << EOF
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-scaleway
spec:
  package: ghcr.io/chrstphfrtz/testeroni-meloni/test:test
EOF

# Wait for the configuration and providers to be healthy
kubectl wait --for=condition=Healthy configuration.pkg.crossplane.io/storage-scaleway --timeout=15m
kubectl wait --for=condition=Healthy providers.pkg.crossplane.io --all --timeout=15m

# Configure the connection secret for provider-scaleway
kubectl apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: storage-scaleway
  namespace: crossplane-system
type: Opaque
stringData:
  credentials: |
    {
      "access_key": "${SCALEWAY_ACCESS_KEY_ID}",
      "secret_key": "${SCALEWAY_SECRET_ACCESS_KEY}",
      "organization_id": "${SCALEWAY_ORGANIZATION_ID}",
      "region": "fr-par",
      "zone": "fr-par-1"
    }
EOF

# Apply the ProviderConfig for provider-scaleway
kubectl apply -f - << EOF
apiVersion: scaleway.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: storage-scaleway
spec:
  credentials:
    source: Secret
    secretRef:
      name: storage-scaleway
      namespace: crossplane-system
      key: credentials
EOF

# Create RBAC for provider-kubernetes
kubectl apply -f - << EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: storage-kubernetes
rules:
- apiGroups:
  - kubernetes.crossplane.io
  resources:
  - objects
  - objects/status
  - observedobjectcollections
  - observedobjectcollections/status
  - providerconfigs
  - providerconfigs/status
  - providerconfigusages
  - providerconfigusages/status
  verbs:
  - get
  - list
  - watch
  - update
  - patch
  - create
- apiGroups:
  - kubernetes.crossplane.io
  resources:
  - '*/finalizers'
  verbs:
  - update
- apiGroups:
  - coordination.k8s.io
  resources:
  - secrets
  - configmaps
  - events
  - leases
  verbs:
  - '*'
- apiGroups:
  - ""
  resources:
  - secrets
  verbs:
  - watch
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: storage-kubernetes
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: storage-kubernetes
subjects:
- kind: ServiceAccount
  name: storage-kubernetes
  namespace: crossplane-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: storage-kubernetes
  namespace: crossplane-system
EOF

# Apply Provider, ProviderConfig and DeploymentRuntimeConfig for provider-kubernetes
kubectl apply -f - << EOF
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: crossplane-contrib-provider-kubernetes
spec:
  package: xpkg.crossplane.io/crossplane-contrib/provider-kubernetes:v0.18.0
  runtimeConfigRef:
    apiVersion: pkg.crossplane.io/v1beta1
    kind: DeploymentRuntimeConfig
    name: storage-kubernetes
---
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata:
  name: storage-kubernetes
spec:
  serviceAccountTemplate:
    metadata:
      name: storage-kubernetes
---
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: storage-kubernetes
spec:
  credentials:
    source: InjectedIdentity
EOF

# Create namespaces for claims in examples/buckets.yaml
kubectl create ns alice
kubectl create ns bob
