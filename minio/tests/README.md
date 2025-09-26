### Unit Testing

You can unit-test your Crossplane v2 Composition locally with `crossplane render`, feeding it observed and required resources to validate the pipeline without touching a live cluster. The loop below renders actual outputs and compares them to golden files with `dyff`, which is easy to drop into CI to catch regressions early.

```sh
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