# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

import json

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import to_dict

ENVIRONMENT_KEY = "apiextensions.crossplane.io/environment"


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    meta = xr.get("metadata", {}) or {}
    spec = xr.get("spec", {}) or {}
    ctx = to_dict(req.context)
    env = ctx.get(ENVIRONMENT_KEY) or {}
    storage_env = env.get("storage") or {}
    iam_env = storage_env.get("iam") or {}
    policy_path = (iam_env.get("policyPath") or "/provider-storage/managed/").strip()
    ns = meta.get("namespace") or "default"
    for b in spec.get("buckets") or []:
        bucket = (b.get("bucketName") or "").strip()
        if not bucket:
            continue
        polname = f"provider-storage.{bucket}"
        policy_doc = {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Action": ["s3:*"],
                    "Resource": [f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"],
                }
            ],
        }
        key = f"policy-{bucket}"
        rsp.desired.resources[key].resource.update(
            {
                "apiVersion": "iam.aws.m.upbound.io/v1beta1",
                "kind": "Policy",
                "metadata": {
                    "name": polname,
                    "namespace": ns,
                    "annotations": {"crossplane.io/composition-resource-name": key},
                },
                "spec": {
                    "forProvider": {
                        "path": policy_path,
                        "policy": json.dumps(policy_doc, indent=2),
                    },
                    "providerConfigRef": {
                        "name": "provider-aws",
                        "kind": "ProviderConfig",
                    },
                },
            }
        )
