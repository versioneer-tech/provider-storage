# provider-storage

# Testing PRs in vClusters

Whenever a new PR against `main` is created, a new vCluster is automatically provisioned and configured with Github Actions. The vCluster is named `pr-<pr-number>-provider-storage` and the version of the installed Configuration Package corresponds to the files present in the PR and is also named `pr-<pr-number>-provider-storage`.

The secret with the `kubeconfig` of the vCluster is also named `pr-<pr-number>-provider-storage` and can be found in the namespace with the same name.

In order to use the vCluster with the installed Configuration Package you need to do the following:

1. Copy the `kubeconfig` of the vCluster with `kubectl get secret vc-pr-6-provider-storage -n pr-6-provider-storage -o jsonpath='{.data.config}' | base64 -d > kubeconfig.yaml`
1. Export the file for `kubectl` to use `export KUBECONFIG=<path-to-kubeconfig.yaml>`
1. Forward the port of the vCluster service in the background `kubectl port-forward service/pr-6-provider-storage 8443:443 -n pr-6-provider-storage &`
1. Install a `ProviderConfig` as described [here](https://marketplace.upbound.io/providers/vshn/provider-minio/v0.4.4/resources/minio.crossplane.io/ProviderConfig/v1) to the `crossplane-system` namespace.
1. Happy testing!

After the PR has been merged or closed, the vCluster is automatically deleted.
