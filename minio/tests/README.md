### Unit Testing

You can unit-test your Crossplane v2 Composition locally with `crossplane render`, feeding it observed and required resources to validate the pipeline without touching a live cluster. The loop below renders actual outputs and compares them to golden files with `dyff`, which is easy to drop into CI to catch regressions early.

```sh
for file in examples/base/00*-buckets.yaml; do
  i=$(basename "$file" | sed -E 's/^00(.+)-buckets\.yaml$/\1/')

  crossplane render "$file" minio/composition.yaml minio/dependencies/functions.yaml \
    --observed-resources "minio/tests/observed/00${i}-buckets.yaml" \
    -x \
    > "minio/tests/00${i}-buckets.yaml"

    dyff between \
    "minio/tests/00${i}-buckets.yaml" \
    "minio/tests/expected/00${i}-buckets.yaml" \
    -s
done
```