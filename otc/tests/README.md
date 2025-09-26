### Unit Testing

You can unit-test your Crossplane v2 Composition locally with `crossplane render`, feeding it observed and required resources to validate the pipeline without touching a live cluster. The loop below renders actual outputs and compares them to golden files with `dyff`, which is easy to drop into CI to catch regressions early.

```sh
for file in examples/base/00*-buckets.yaml; do
  name="$(basename "$file")"
  idx="${name#00}"
  idx="${idx%-buckets.yaml}"

  crossplane render "$file" otc/composition.yaml otc/dependencies/functions.yaml \
    -x \
    > "otc/tests/00${idx}-buckets.yaml"

  dyff between \
    "otc/tests/00${idx}-buckets.yaml" \
    "otc/tests/expected/00${idx}-buckets.yaml" \
    -s

  obs="otc/tests/observed/00${idx}-buckets.yaml"
  if [[ -f "$obs" ]]; then
    crossplane render "$file" otc/composition.yaml otc/dependencies/functions.yaml \
      --observed-resources "$obs" \
      -x \
      > "otc/tests/00${idx}x-buckets.yaml"

    dyff between \
      "otc/tests/00${idx}x-buckets.yaml" \
      "otc/tests/expected/00${idx}x-buckets.yaml" \
      -s
  fi
done
```