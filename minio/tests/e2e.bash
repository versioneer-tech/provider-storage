#!/bin/bash

# Add helm repositories for MinIO and Crossplane
helm repo add minio-operator https://operator.min.io
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update

# Install Crossplane
helm install crossplane \
--namespace crossplane-system \
--create-namespace crossplane-stable/crossplane \
--version 2.0.2 \
--set provider.defaultActivations={} \
--wait

# Install the MinIO operator
helm install \
  --namespace minio-operator \
  --create-namespace \
  operator minio-operator/operator \
  --wait

# Install the MinIO tenant
cat > values.yaml << EOF
tenant:
  pools:
    - servers: 1
      name: pool-0
      volumesPerServer: 1
      size: 1Gi
  certificate:
    requestAutoCert: false
EOF

helm install \
  --values values.yaml \
  --namespace minio-tenant \
  --create-namespace \
  minio-tenant minio-operator/tenant \
  --wait

# Install the MRAP to reduce stress on the control plane
kubectl apply -f - << EOF
apiVersion: apiextensions.crossplane.io/v1alpha1
kind: ManagedResourceActivationPolicy
metadata:
  name: storage-aws
spec:
  activate:
  - buckets.minio.crossplane.io
  - policies.minio.crossplane.io
  - users.minio.crossplane.io
  - objects.kubernetes.crossplane.io
EOF

# Install the storage-minio configuration package
kubectl apply -f - << EOF
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-minio
spec:
  package: ghcr.io/chrstphfrtz/testeroni-meloni/test:test-minio
EOF

# Wait for the configuration and providers to be healthy
kubectl wait --for=condition=Healthy configuration.pkg.crossplane.io/storage-minio --timeout=15m
kubectl wait --for=condition=Healthy providers.pkg.crossplane.io --all --timeout=15m

# Configure the connection secret for provider-minio
kubectl apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: storage-minio
  namespace: minio-tenant
stringData:
  AWS_ACCESS_KEY_ID: minio
  AWS_SECRET_ACCESS_KEY: minio123
EOF

# Apply the ProviderConfig for provider-minio
kubectl apply -f - << EOF
apiVersion: minio.crossplane.io/v1
kind: ProviderConfig
metadata:
  name: storage-minio
  namespace: crossplane-system
spec:
  credentials:
    apiSecretRef:
      name: storage-minio
      namespace: minio-tenant
    source: InjectedIdentity
  minioURL: "http://myminio-hl.minio-tenant.svc.cluster.local:9000/"
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
  - minio.crossplane.io
  resources:
  - policies
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
  package: xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.18.0
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
