### Unit Testing

You can unit-test your Crossplane v2 Composition locally with `crossplane render`, feeding it observed and required resources to validate the pipeline without touching a live cluster. The loop below renders actual outputs and compares them to golden files with `dyff`, which is easy to drop into CI to catch regressions early.

```sh
for file in tests/00*-buckets.yaml; do
  i=$(basename "$file" | sed -E 's/^00(.+)-buckets\.yaml$/\1/')

  crossplane render "$file" aws/composition.yaml aws/dependencies/functions.yaml \
    --observed-resources "aws/tests/observed/00${i}-buckets.yaml" \
    -x \
    > "aws/tests/00${i}-buckets.yaml"

    dyff between \
    "aws/tests/00${i}-buckets.yaml" \
    "aws/tests/expected/00${i}-buckets.yaml" \
    -s
done
```