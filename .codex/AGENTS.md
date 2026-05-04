---
agent: codex
type: crossplane-composition
disclaimer: never ever change this frontmatter header - only edit content below
---

## Explicit Permission First

- Do not commit or push to any git repository unless the user explicitly asks for it.
- Do not connect to or operate on any Kubernetes cluster unless the user explicitly asks for it.
- If the user provides a new general repo rule or policy, ask whether it should be added to `.codex/AGENTS.md`.
- Record durable repo-specific learnings in `.codex/LOGBOOK.md`.

This repo develops Crossplane v2 XRDs and Compositions for storage provisioning.

Primary repo surfaces:
- `xrd.yaml`
- `minio/composition.yaml`
- `aws/composition.yaml`
- `otc/composition.yaml`
- `<provider>/dependencies/`
- `examples/base/`

Current live-cluster focus is MinIO integration on `config-k`. Treat AWS and OTC as local/unit-test targets unless the user explicitly asks for live-cluster work there.

Validation order:
1. local validation
2. cluster integration
3. Flux source-of-truth follow-through

Default delivery rule:
- Treat local validation as mandatory before cluster work.
- Try every new feature, fix, or behavior change against MinIO first.
- A MinIO-first cycle means: local validation, live integration validation on `config-k`, and matching Flux source-of-truth update.
- Only after MinIO is clean and integrated should follow-up provider work start.
- After MinIO is integrated, explicitly ask whether AWS and OTC should be adapted too, then update their compositions and run their unit tests as needed.

## Preflight

Start every full validation cycle with:

```bash
docker ps
```

Rules:
- If Docker is unavailable, stop immediately.
- Report that the Docker daemon must be started before any render, fixture update, or validation.
- Continue only after Docker is confirmed running.

## Required Tooling

- Docker
- `crossplane`
- `dyff`
- `kubectl`
- `pre-commit`
- `git`

## Local Validation

Local validation must pass before cluster work.

Changes to these files require test updates:
- `xrd.yaml`
- `minio/composition.yaml`
- `aws/composition.yaml`
- `otc/composition.yaml`

Rules:
- Update `examples/base/` first when shared API or behavior changes.
- Use `examples/base/00*-buckets.yaml` as the shared example suite.
- For changes that affect behavior, always run the full MinIO local validation cycle first.
- Render only affected providers unless the change is shared.
- Compare rendered output with `dyff`.
- Update only affected fixtures under `<provider>/tests/expected/`.
- Re-run until all diffs are resolved.
- End every local change cycle with `pre-commit run --all-files`.

Documentation rules:
- If `xrd.yaml` changes, update `.codex/LOGBOOK.md` with compact repo-specific learnings about schema or behavior changes.
- If user-facing behavior, prerequisites, installation flow, or usage expectations change, update `README.md` and docs in `docs/how-to-guides/*`, at minimum `installation.md`.
- Keep `.codex/LOGBOOK.md` as durable repo knowledge, not a step-by-step activity log.

Canonical loop for one provider:

```bash
for file in examples/base/00*-buckets.yaml; do
  name="$(basename "$file")"
  idx="${name#00}"
  idx="${idx%-buckets.yaml}"

  crossplane render "$file" minio/composition.yaml minio/dependencies/functions.yaml \
    -x \
    > "minio/tests/00${idx}-buckets.yaml"

  dyff between \
    "minio/tests/00${idx}-buckets.yaml" \
    "minio/tests/expected/00${idx}-buckets.yaml" \
    -s

  obs="minio/tests/observed/00${idx}-buckets.yaml"
  if [[ -f "$obs" ]]; then
    crossplane render "$file" minio/composition.yaml minio/dependencies/functions.yaml \
      --observed-resources "$obs" \
      -x \
      > "minio/tests/00${idx}x-buckets.yaml"

    dyff between \
      "minio/tests/00${idx}x-buckets.yaml" \
      "minio/tests/expected/00${idx}x-buckets.yaml" \
      -s
  fi
done
```

Swap `minio` for `aws` or `otc` as needed.

If a `dyff` change is intended, copy the rendered file to the matching expected fixture and rerun until clean.

## Cluster Integration on `config-k`

Run cluster tests only after local validation is green.

Requirements:
- Cluster: `config-k`
- Kubeconfig: `~/.kube/config-k`
- Required context: `k`
- Current live-cluster focus: MinIO-backed `Storage` claims

Before cluster work:

```bash
KUBECONFIG=~/.kube/config-k kubectl config current-context
```

Rules:
- Use `KUBECONFIG=~/.kube/config-k kubectl ...`.
- If the context is not `k`, do not continue.
- Inspect first; do not jump straight to delete/recreate.
- Prefer validating the real MinIO-backed `Storage` claims and namespaces already used by the cluster unless the user asks for a different target.
- Run integration at least once after local validation passes, then keep iterating until it succeeds or there is enough evidence to explain the blocker.
- If `examples/base/` behavior changes, update the corresponding live example manifests in Flux too.
- If reconciliation is clearly wedged and a clean rebuild is necessary, pause and ask before deleting or recreating live resources.

Integration procedure:
1. Treat the relevant `examples/base/00*-buckets.yaml` scenario as the source-of-truth shape for live verification.
2. Verify that the live `Storage` claim matches the intended spec from the current repo and local fixtures.
3. If cluster definitions are stale, apply the changed cluster resources first, at minimum:
   - `xrd.yaml`
   - the affected `<provider>/composition.yaml`
   - the affected `<provider>/dependencies/rbac.yaml` when RBAC-relevant resources changed
4. Wait for Crossplane reconciliation, then inspect:
   - `Storage` status
   - composed resources
   - generated connection `Secret`
   - provider-specific backing resources
5. For MinIO, verify bucket, policy, user, access attachment, observer resources, and generated credentials as applicable to the scenario.
6. If anything is unready, inspect resource status, events, and relevant logs before changing manifests.
7. Do not treat missing observer resources as an automatic failure unless the current scenario requires them to exist.

## Flux Guardrails

The cluster is Flux-managed.

Rules:
- Do not fight Flux reconciliation.
- For direct cluster-side testing:
  1. add the temporary disable annotation
  2. apply the live change
  3. verify
  4. remove the annotation again
- Do not leave disable annotations behind.
- Mirror live-tested changes into the local Flux checkout instead of relying on long-lived drift.
- Assume sibling repos live at `~/github/<github-org|github-user>/<github-repo>`.
- Expected local Flux checkout: `~/github/versioneer-inc/flux-k`.
- `.codex/LOGBOOK.md` is for durable repo learnings, not a step-by-step activity log.

Disable reconciliation on one object:

```bash
KUBECONFIG=~/.kube/config-k kubectl annotate <kind> <name> \
  kustomize.toolkit.fluxcd.io/reconcile=disabled --overwrite
```

Remove the annotation afterward:

```bash
KUBECONFIG=~/.kube/config-k kubectl annotate <kind> <name> \
  kustomize.toolkit.fluxcd.io/reconcile-
```

## Guardrails

- Treat XRD schema fields as API.
- Keep compositions deterministic and idempotent.
- Avoid unrelated fixture churn.
- Update only affected expected files.
- Prefer source-of-truth fixes over ad hoc live edits.
- Do not update Flux-managed resources in-place and walk away; carry the matching change into the local `flux-k` checkout.
- Keep `.codex/AGENTS.md` as the runbook and `.codex/LOGBOOK.md` as the durable knowledge base.
