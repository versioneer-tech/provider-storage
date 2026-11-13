# Composition source

Each backend has a `pipeline.yaml` and Python step files. Shared steps and
helpers are in `shared/` and `helpers.py`.

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
