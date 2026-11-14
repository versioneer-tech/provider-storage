# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

"""Validate native resources and pass extension resources to Crossplane."""

import sys
from pathlib import Path

import kubernetes_validate
import yaml

source, target = map(Path, sys.argv[1:])
extensions = []
count = 0
for resource in yaml.safe_load_all(source.read_text()):
    group = resource["apiVersion"].split("/")[0]
    if group in ("v1", "apps", "batch"):
        kubernetes_validate.validate(resource, "1.34.0", strict=True)
        count += 1
    else:
        extensions.append(resource)
target.write_text(yaml.safe_dump_all(extensions, sort_keys=False))
print(f"Validated {count} native Kubernetes resources.")
