# Composition source

Each backend has a `pipeline.yaml` and Python step files. Shared steps and
helpers are in `shared/` and `helpers.py`.
The shared environment step records the UTC time and credential generations
in the pipeline context. Later steps use that context instead of reading the
clock again.
The environment annotation takes precedence over the label, then defaults
to the backend package name, such as `storage-aws`. Backend resources use
`storage.providerConfigName` from that environment. AWS, MinIO, OTC, and
OVHcloud retain their default provider names
when it is unset or blank. CloudFerro requires a project provider name.
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

`settings.yaml` sets `responseTTL` for all steps. Use a positive whole number
of seconds (`30s`), minutes (`5m`), or hours (`1h`). The default is `60s`.
A longer cache duration can delay time-based credential rollover. Rebuild
after changing the setting. Use `--response-ttl` with a separate
`--output-dir` for a temporary build.

Run the [unit suite](../tests/README.md) after source changes.
