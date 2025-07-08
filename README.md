# provider-storage

# Testing PRs in vClusters

Whenever a new PR against `main` is created, a new vCluster is automatically provisioned and configured with Github Actions. The vCluster is named `pr-<pr-number>-provider-storage` and the version of the installed Configuration Package corresponds to the files present in the PR and is also named `pr-<pr-number>-provider-storage`.

The secret with the `kubeconfig` of the vCluster is also named `pr-<pr-number>-provider-storage` and can be found in the namespace with the same name.

In order to use the vCluster with the installed Configuration Package there still a few things you need to install yourself:

1. **MinIO instance(s)** - It was an intentional decision not to install a MinIO instance by default to best mimic an actual deployment where it is expected that the underlying infrastructure (which could also be outside the cluster) is provisioned independently.
1. **ProviderConfig** - Since we don't assume any standard configuration, the `ProviderConfig` for the `provider-minio` provider needs to be supplied as well as the corresponding connection secret.
