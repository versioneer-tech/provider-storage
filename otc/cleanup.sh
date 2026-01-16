#!/usr/bin/env bash
set -euo pipefail

CRDS=(
  userv3.identity.opentelekomcloud.crossplane.io
  credentialv3.identity.opentelekomcloud.crossplane.io
  bucket.obs.opentelekomcloud.crossplane.io
  bucketpolicy.obs.opentelekomcloud.crossplane.io
)

# Step 1: strip finalizers
for crd in "${CRDS[@]}"; do
  echo "Stripping finalizers from resources of CRD: $crd"
  for res in $(kubectl get "$crd" -o name 2>/dev/null || true); do
    echo "  Patching $res"
    kubectl patch "$res" --type merge -p '{"metadata":{"finalizers":[]}}' || true
  done
done

# Step 2: delete all instances
for crd in "${CRDS[@]}"; do
  echo "Deleting all instances of CRD: $crd"
  kubectl delete "$crd" --all --ignore-not-found || true
done

# Step 3: delete CRDs themselves
for crd in "${CRDS[@]}"; do
  echo "Deleting CRD: $crd"
  kubectl delete crd "$crd" --ignore-not-found || true
done
kubectl delete providers.pkg.crossplane.io provider-otc || true
kubectl delete DeploymentRuntimeConfig provider-otc || true
kubectl delete ManagedResourceActivationPolicy provider-otc || true
kubectl delete providerconfigs.opentelekomcloud.crossplane.io provider-otc || true
