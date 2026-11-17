# Composition source

Each backend has a `pipeline.yaml` and Python step files. Shared steps and
helpers are in `shared/` and `helpers.py`.
Environment setup is in the
[installation guide](../docs/how-to-guides/installation.md#environment-settings).
The shared credential step records the UTC time and credential generations
in the pipeline context. Later steps use that context instead of reading the
clock again.
AWS, MinIO, and OTC share the current-Secret step. OVHcloud and CloudFerro
resolve their provider-specific credential sources, then use the same consumer
Secret writer.
The writer composes native Secrets and reads connection Secrets through
required resources.
`kubernetes_object` builds the common provider-kubernetes envelope. Keep the
native manifest and provider-specific settings in each backend step.

Build all deployable Compositions from the repository root:

```bash
python3 -m pip install -r scripts/requirements.txt
python3 scripts/build-composition.py
```

The build embeds the steps and their imported helpers in
`<backend>/composition.yaml`. Include source and generated files in the same change.
Do not edit generated files. Check them with:

```bash
python3 scripts/build-composition.py --check
```

`settings.yaml` sets the Python `responseTTL` default to `1m` and the
`environmentConfigsTTL` and `autoReadyTTL` values to `10m`. Operators can
override the Python TTL through
[environment settings](../docs/how-to-guides/installation.md#environment-settings).
Rebuild after changing the build settings. Use `--response-ttl` with a separate
`--output-dir` to override the Python default for a temporary build.

Run the [unit suite](../tests/README.md) after source changes.
