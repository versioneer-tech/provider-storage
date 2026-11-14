# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import storage_provider_config_name, to_dict

ENVIRONMENT_KEY = "apiextensions.crossplane.io/environment"


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    meta = xr.get("metadata", {}) or {}
    spec = xr.get("spec", {}) or {}
    ctx = to_dict(req.context)
    env = ctx.get(ENVIRONMENT_KEY) or {}
    storage_env = env.get("storage") or {}
    ns = meta.get("namespace") or "default"
    region = (storage_env.get("region") or spec.get("region") or "eu-central-1").strip()
    for b in spec.get("buckets") or []:
        bucket = (b.get("bucketName") or "").strip()
        if not bucket:
            continue
        key = f"bucket-{bucket}"
        rsp.desired.resources[key].resource.update(
            {
                "apiVersion": "s3.aws.m.upbound.io/v1beta1",
                "kind": "Bucket",
                "metadata": {
                    "name": bucket,
                    "namespace": ns,
                    "annotations": {"crossplane.io/composition-resource-name": key},
                },
                "spec": {
                    "forProvider": {"region": region},
                    "providerConfigRef": {
                        "name": storage_provider_config_name(req, "provider-aws"),
                        "kind": "ProviderConfig",
                    },
                },
            }
        )
