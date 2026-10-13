# AWS dependencies

These manifests configure the providers used by the `storage-aws`
Composition.

Dedicated provider controllers in the cluster reconcile resources created by
the Composition. Give each `ProviderConfig` only the permissions it needs. Do
not use unrestricted administrator credentials. Read the
[AWS cloud IAM bootstrap guide](../../docs/how-to-guides/cloud-iam-bootstrap.md#aws)
for the permission model and safety details.

## IAM bootstrap

AWS supports two controller authentication modes:

- `assume-role` uses an existing workload identity.
- `static-user` creates a static controller credential user.

Set `CROSSPLANE_AWS_AUTH_MODE`, `CROSSPLANE_AWS_ACCOUNT_ID`, and any optional
resource prefix or IAM names. For `assume-role`, also set
`CROSSPLANE_AWS_TRUST_PRINCIPAL_ARN`. Then run:

```bash
aws/dependencies/iam.sh status
aws/dependencies/iam.sh apply
aws/dependencies/iam.sh verify
```

For `static-user`, keep the local credential file private and outside Git.

## Deployment

Both authentication modes use the controller runtime role. In
[`03-providerConfigs.yaml`](03-providerConfigs.yaml), uncomment
`assumeRoleChain` and set the role ARN printed by `iam.sh apply`.

Then configure the base controller identity:

- For `assume-role`, replace the Secret credentials block with the source for
  the existing workload identity, such as `IRSA` or `PodIdentity`. This mode
  does not use `aws-provider-creds`.
- For `static-user`, keep the Secret credentials block. Replace
  `<storage-namespace>` with the namespace where `render-secrets` created
  `aws-provider-creds`.

For `static-user`, set `CROSSPLANE_AWS_NAMESPACE` to that namespace and
create the controller Secret before you apply the `ProviderConfig`:

```bash
aws/dependencies/iam.sh render-secrets |
  kubectl apply -f -
```

Set the AWS region in
[`04-environmentConfigs.yaml`](04-environmentConfigs.yaml).

Apply [`03-providerConfigs.yaml`](03-providerConfigs.yaml) in every namespace
that contains an AWS `Storage` resource. The other dependency manifests are
cluster-scoped. Apply the numbered manifests in order, then apply
[`functions.yaml`](functions.yaml) and [`rbac.yaml`](rbac.yaml). Wait for all
provider and function revisions to become ready.
