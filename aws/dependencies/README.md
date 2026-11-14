# AWS dependencies

These manifests configure the providers used by the `storage-aws`
Composition.

See [Cloud IAM bootstrap](../../docs/how-to-guides/cloud-iam-bootstrap.md#aws)
for script installation, controller permissions, and authentication modes.

## IAM bootstrap

AWS supports two controller authentication modes:

- `assume-role` uses an existing workload identity.
- `static-user` creates a static controller credential user.

Set `CROSSPLANE_AWS_AUTH_MODE`, `CROSSPLANE_AWS_ACCOUNT_ID`, and any optional
resource prefix or IAM names. For `assume-role`, also set
`CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN`. Then run:

```bash
bootstrap-iam.sh aws configure
bootstrap-iam.sh aws show
bootstrap-iam.sh aws apply
bootstrap-iam.sh aws verify
```

For `static-user`, keep the local credential file private and outside Git.

## Deployment

Both authentication modes use the controller runtime role. In
[`03-providerConfigs.yaml`](03-providerConfigs.yaml), uncomment
`assumeRoleChain` and set the role ARN printed by `bootstrap-iam.sh aws apply`.

Then configure the base controller identity:

- For `assume-role`, replace the Secret credentials block with the source for
  the existing workload identity, such as `IRSA` or `PodIdentity`. This mode
  does not use `aws-provider-creds`.
- For `static-user`, keep the Secret credentials block. Replace
  `<storage-namespace>` with the namespace where `render-secrets` created
  `aws-provider-creds`.

For `static-user`, set `CROSSPLANE_AWS_NAMESPACE` to that namespace and
create the controller Secret:

```bash
bootstrap-iam.sh aws render-secrets |
  kubectl --context storage-cluster apply --server-side -f -
```

Replace `storage-cluster` with the deployment context. The ProviderConfig's
Secret reference must use `aws-provider-creds`, the selected namespace, and
the `credentials` key. IAM `apply` prepares cloud resources only.

Set the AWS region in
[`04-environmentConfigs.yaml`](04-environmentConfigs.yaml).

Apply [`03-providerConfigs.yaml`](03-providerConfigs.yaml) in every namespace
that contains an AWS `Storage` resource. Apply the remaining manifests in the
order given in the
[installation guide](../../docs/how-to-guides/installation.md#1-install-backend-dependencies).
