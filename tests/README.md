# Tests

The unit suite checks Composition output and local helpers. It uses Docker
for function calls and renders, and needs no Kubernetes cluster.

## Select checks

Run this from the repository root. Use the pull request base commit when it
is known, or the target branch:

```bash
python3 scripts/ci-checks.py --base main
```

[GitHub Actions](../.github/workflows/pr.yaml) defines the required checks.
Without `--head`, the comparison includes committed, staged, unstaged, and
untracked changes. Use `--head` to compare two commits. Missing refs and empty
comparisons select full checks. Manual CI runs use the full suite.

For `docs_only=true`, run:

```bash
python3 -m pip install -r docs/requirements.txt pre-commit
python3 tests/ci-checks.py
mkdocs build --strict --site-dir /tmp/provider-storage-docs
pre-commit run --all-files
git diff --check
```

For `docs_only=false`, also run the full unit suite and the applicable
[integration tests](integration/README.md). CI runs the MinIO integration;
cloud integrations need operator bootstrap and credentials.

Release tags require a full successful Tests run on the same `main` commit.
If its push changed only documentation, run Tests manually on `main` before
publishing.

## Unit suite

Install Docker, the Crossplane CLI, dyff, yq, jq, Python, and pre-commit.
Start Docker, then build and test:

```bash
python3 -m pip install -r scripts/requirements.txt
python3 scripts/build-composition.py
docker ps
tests/unit.bash
```

The suite checks all five backends. Pass backend names, such as
`tests/unit.bash minio aws`, to investigate a failure. Run all backends before
completion.

| Check | Purpose |
| --- | --- |
| Build and function checks | Generated files match source; response cache settings reach all steps. |
| Render comparisons | Bucket, access, credential, and lifecycle resources match expected output. |
| Readiness and policies | Incomplete credentials do not produce a consumer Secret; `None` grants add no allow. |
| Credential transitions | The desired Secret remains during handover; OTC policies include retained identities and omit expired identities. |
| Generation and lifecycle bounds | One generation time reaches all steps; cleanup Jobs have a deadline and finite retries. |
| CloudFerro | Project binding, credential publication, and deletion dependencies. |
| IAM helpers | Controller Secret formats and AWS permission scope. |
| Integration inputs | Owner, requester, and grants match the live access checks. |
| Schemas | Rendered resources conform to their provider schemas. |

Function checks share one container with the pinned SDK. Render and schema
checks do not prove cloud enforcement, credential revocation, or tenant
isolation. Use the integration suite for S3 access checks.

## Fixtures

Shared inputs are in `examples/base/`. CloudFerro has project-specific inputs
in `cloudferro/tests/fixtures/`. Backend `tests/required/` and `tests/observed/`
files supply peer resources and provider state. Expected renders are in
`<backend>/tests/expected/`.

Review render differences and update only fixtures affected by an intended
behavior change. Credential generation dates are normalized before comparison.
Crossplane packages and schemas use `~/.cache/provider-storage/crossplane`;
`PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR` can select another absolute path.
