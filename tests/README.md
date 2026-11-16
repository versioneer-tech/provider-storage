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
CI uses Crossplane CLI 2.4.1. Renders and schema checks target Crossplane
2.4.3 and use the provider and function packages in each backend's dependency
manifests. See the [dependency baseline](../docs/how-to-guides/installation.md#dependency-baseline).
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
| [Build and function runtime](function-runtime.py) | Generated files match source; response cache settings reach every pipeline; environment layers merge in order and allow missing configs. |
| [Credential and lifecycle behavior](composition-behavior.py) | Secrets stay available during rollover; policies retain the correct identities; cleanup Jobs have finite limits. |
| [Render and schema checks](unit.bash) | Bucket, access, credential, and lifecycle resources match expected output and provider schemas. |
| [CloudFerro](cloudferro.py) | External project ProviderConfig selection, cross-project grants, AWS profile wiring, and deletion dependencies. |
| [IAM bootstrap](bootstrap-iam.py) | Configuration, provider Secret formats, permission scope, credential reuse, and rotation recovery. |
| [Access checks](integration/access-checks.py) | Owner and requester inputs match the access matrix; only the requested operation's AccessDenied satisfies a negative probe. |

Function checks use the pinned SDK and function containers. Render and schema
checks do not prove cloud enforcement, credential revocation, or tenant
isolation. Use the integration suite for S3 access checks.
Bootstrap checks copy the script to a temporary directory and use test
credentials with local cloud commands. They need no cloud login or cluster.
Native resources use Kubernetes schemas. Extension resources use the
Crossplane validator with missing schemas treated as errors.

## Fixtures

Shared inputs are in `examples/base/`. CloudFerro has project-specific inputs
in `cloudferro/tests/fixtures/`. Backend `tests/required/` and `tests/observed/`
files supply peer resources and provider state. Use the same scenario filename
in each directory. Expected renders are in `<backend>/tests/expected/`;
`expected/with-dependencies/` contains the render with supplied state.

| Shared scenario | Purpose |
| --- | --- |
| `001-buckets.yaml` | One bucket, a ReadWrite grant, and a request to another owner. |
| `002-buckets.yaml` | Weekly credentials, ReadOnly sharing, and lifecycle rules. |
| `003-buckets.yaml` | Credentials and an access request without an owned bucket. |
| `004-buckets.yaml` | Daily credentials, several requests, and an unresolved owner. |

Review render differences and update only fixtures affected by an intended
behavior change. Credential generation dates are normalized before comparison.
Crossplane packages and schemas use `~/.cache/provider-storage/crossplane`;
`PROVIDER_STORAGE_CROSSPLANE_CACHE_DIR` can select another absolute path.
