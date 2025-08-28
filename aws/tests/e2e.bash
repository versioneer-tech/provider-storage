#!/bin/bash

# Add helm repositories for Crossplane
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update

# Install Crossplane
helm install crossplane \
--namespace crossplane-system \
--create-namespace crossplane-stable/crossplane \
--version 2.0.2 \
--set provider.defaultActivations={} \
--set args={"--enable-operations"} \
--wait

# Install the MRAP to reduce stress on the control plane
kubectl apply -f - << EOF
apiVersion: apiextensions.crossplane.io/v1alpha1
kind: ManagedResourceActivationPolicy
metadata:
  name: storage-aws
spec:
  activate:
  - buckets.s3.aws.upbound.io
  - accesskeys.iam.aws.upbound.io
  - policies.iam.aws.upbound.io
  - users.iam.aws.upbound.io
  - userpolicyattachments.iam.aws.upbound.io
  - objects.kubernetes.crossplane.io
EOF

# Install the storage-aws configuration package
kubectl apply -f - << EOF
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: storage-aws
spec:
  package: ghcr.io/versioneer-tech/provider-storage/aws:${PR_SLUG}
EOF

# Wait for the configuration and providers to be healthy
kubectl wait --for=condition=Healthy configuration.pkg.crossplane.io/storage-aws --timeout=15m
kubectl wait --for=condition=Healthy providers.pkg.crossplane.io --all --timeout=15m

# Configure the connection secret for provider-aws-s3 and provider-aws-iam
kubectl apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: storage-aws
  namespace: crossplane-system
stringData:
  credentials: |
    [default]
    aws_access_key_id = ${AWS_ACCESS_KEY_ID}
    aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF

# Apply the ProviderConfig for provider-aws-s3 and provider-aws-iam
kubectl apply -f - << EOF
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: storage-aws
spec:
  credentials:
    source: Secret
    secretRef:
      name: storage-aws
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
  - iam.aws.upbound.io
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
