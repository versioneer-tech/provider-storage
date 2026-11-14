# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

import json

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import storage_provider_config_name, to_dict

ENVIRONMENT_KEY = "apiextensions.crossplane.io/environment"


def _policy_for(bucket, perm):
    p = (perm or "").strip().lower()
    if p == "readwrite":
        stmts = [
            {
                "Effect": "Allow",
                "Action": [
                    "s3:ListBucket",
                    "s3:GetObject",
                    "s3:PutObject",
                    "s3:DeleteObject",
                ],
                "Resource": [f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"],
            }
        ]
    elif p == "readonly":
        stmts = [
            {
                "Effect": "Allow",
                "Action": ["s3:ListBucket"],
                "Resource": [f"arn:aws:s3:::{bucket}"],
            },
            {
                "Effect": "Allow",
                "Action": ["s3:GetObject"],
                "Resource": [f"arn:aws:s3:::{bucket}/*"],
            },
        ]
    elif p == "writeonly":
        stmts = [
            {
                "Effect": "Allow",
                "Action": ["s3:ListBucket"],
                "Resource": [f"arn:aws:s3:::{bucket}"],
            },
            {
                "Effect": "Allow",
                "Action": ["s3:PutObject", "s3:DeleteObject"],
                "Resource": [f"arn:aws:s3:::{bucket}/*"],
            },
        ]
    else:
        stmts = []
    return {"Version": "2012-10-17", "Statement": stmts}


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
    for g in spec.get("bucketAccessGrants") or []:
        bucket = (g.get("bucketName") or "").strip()
        grantee = (g.get("grantee") or "").strip()
        perm = (g.get("permission") or "").strip()
        if not bucket or not grantee or not perm:
            continue
        policy_doc = _policy_for(bucket, perm)
        if not policy_doc["Statement"]:
            continue
        pname = f"provider-storage.{grantee}.{bucket}"
        key = f"policy-{grantee}-{bucket}"
        rsp.desired.resources[key].resource.update(
            {
                "apiVersion": "iam.aws.m.upbound.io/v1beta1",
                "kind": "Policy",
                "metadata": {
                    "name": pname,
                    "namespace": ns,
                    "annotations": {"crossplane.io/composition-resource-name": key},
                },
                "spec": {
                    "forProvider": {
                        "path": policy_path,
                        "policy": json.dumps(policy_doc, indent=2),
                    },
                    "providerConfigRef": {
                        "name": storage_provider_config_name(req, "provider-aws"),
                        "kind": "ProviderConfig",
                    },
                },
            }
        )
