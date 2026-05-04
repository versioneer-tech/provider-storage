# Repo Learnings

- On the current `~/.kube/config-k`, `kubectl config current-context` returns `k`.
- The live Flux source is `ssh://git@github.com/versioneer-inc/flux-k.git` on `refs/heads/main`.
- The expected local Flux checkout is `~/github/versioneer-inc/flux-k`.
- For temporary direct testing of a Flux-managed object, disable reconciliation on that object first with `kustomize.toolkit.fluxcd.io/reconcile=disabled`, and remove the annotation again after the source-of-truth change is integrated.
- MinIO request-policy observer resources like `observe-s-john-s-jane` are needed for access attachment logic, but missing foreign policies can represent valid pending or denied states and should not block overall XR readiness.
- On `2026-04-16`, `workspace/s-john` on `storage-minio-61287bd` was `Ready=False` only because of `observe-s-john-s-jane`, `observe-s-john-s-jeff`, and `observe-s-john-s-joe`.
- The MinIO readiness fix is to keep request observers in the composition while marking them non-blocking for XR readiness.
- That fix was validated live: all `Storage` claims became `READY=True`, and `workspace/s-john` moved to `storage-minio-d162b1f`.
