# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import (
    kubernetes_object,
    to_dict,
)


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    meta = xr.get("metadata", {}) or {}
    spec = xr.get("spec", {}) or {}
    ns = meta.get("namespace") or "default"

    for b in spec.get("buckets") or []:
        bucket = (b.get("bucketName") or "").strip()
        if not bucket:
            continue
        discoverable = str(bool(b.get("discoverable", False))).lower()
        key = f"bucket-{bucket}"
        rsp.desired.resources[key].resource.update(
            kubernetes_object(
                key,
                ns,
                {
                    "apiVersion": "minio.crossplane.io/v1",
                    "kind": "Bucket",
                    "metadata": {
                        "name": bucket,
                        "annotations": {
                            "storages.pkg.internal/discoverable": discoverable
                        },
                    },
                    "spec": {"providerConfigRef": {"name": "provider-minio"}},
                },
            )
        )
