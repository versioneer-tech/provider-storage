# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

import json

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import to_dict


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    meta = xr.get("metadata", {}) or {}
    spec = xr.get("spec", {}) or {}
    ns = meta.get("namespace") or "default"

    for b in spec.get("buckets") or []:
        bucket = (b.get("bucketName") or "").strip()
        if not bucket:
            continue
        polname = f"provider-storage.{bucket}"
        key = f"policy-full-{bucket}"
        raw = json.dumps(
            {
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Allow",
                        "Action": ["s3:*"],
                        "Resource": [
                            f"arn:aws:s3:::{bucket}",
                            f"arn:aws:s3:::{bucket}/*",
                        ],
                    }
                ],
            },
            indent=2,
        )

        rsp.desired.resources[key].resource.update(
            {
                "apiVersion": "kubernetes.m.crossplane.io/v1alpha1",
                "kind": "Object",
                "metadata": {
                    "name": key,
                    "namespace": ns,
                    "annotations": {"crossplane.io/composition-resource-name": key},
                },
                "spec": {
                    "forProvider": {
                        "manifest": {
                            "apiVersion": "minio.crossplane.io/v1",
                            "kind": "Policy",
                            "metadata": {"name": polname},
                            "spec": {
                                "forProvider": {"rawPolicy": raw},
                                "providerConfigRef": {"name": "provider-minio"},
                            },
                        }
                    },
                    "providerConfigRef": {
                        "name": "provider-kubernetes",
                        "kind": "ProviderConfig",
                    },
                },
            }
        )
