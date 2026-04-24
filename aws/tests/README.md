### Unit Testing

You can unit-test your Crossplane v2 Composition locally with `crossplane render`, feeding it observed and required resources to validate the pipeline without touching a live cluster. The loop below renders actual outputs and compares them to golden files with `dyff`, which is easy to drop into CI to catch regressions early.

```sh
for file in examples/base/00*-buckets.yaml; do
  name="$(basename "$file")"
  idx="${name#00}"
  idx="${idx%-buckets.yaml}"

  crossplane render "$file" aws/composition.yaml aws/dependencies/functions.yaml \
    -x \
    > "aws/tests/00${idx}-buckets.yaml"

  dyff between \
    "aws/tests/00${idx}-buckets.yaml" \
    "aws/tests/expected/00${idx}-buckets.yaml" \
    -s

  obs="aws/tests/observed/00${idx}-buckets.yaml"
  req="aws/tests/required/00${idx}x-buckets.yaml"
  if [[ -f "$obs" || -f "$req" ]]; then
    render_args=()
    if [[ -f "$obs" ]]; then
      render_args+=(--observed-resources "$obs")
    fi
    if [[ -f "$req" ]]; then
      render_args+=(--required-resources "$req")
    fi

    crossplane render "$file" aws/composition.yaml aws/dependencies/functions.yaml \
      "${render_args[@]}" \
      -x \
      > "aws/tests/00${idx}x-buckets.yaml"

    dyff between \
      "aws/tests/00${idx}x-buckets.yaml" \
      "aws/tests/expected/00${idx}x-buckets.yaml" \
      -s
  fi
done
```
