# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

def normalized:
  {
    name: .metadata.name,
    spec: (
      .spec
      | del(.providerIdentity, .crossplane, .credentialsRollover)
      | .buckets = ((.buckets // []) | map(
          del(.lifecycleRules)
          | .bucketName |= sub("^s-"; $prefix + "-")
          | .discoverable = (.discoverable // false)
        ))
      | .bucketAccessRequests = ((.bucketAccessRequests // []) | map(
          .bucketName |= sub("^s-"; $prefix + "-")
        ))
      | .bucketAccessGrants = ((.bucketAccessGrants // []) | map(
          .bucketName |= sub("^s-"; $prefix + "-")
        ))
    )
  };

(if type == "array" then . else .items end)
| map(normalized)
| sort_by(.name)
