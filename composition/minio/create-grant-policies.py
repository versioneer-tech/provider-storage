# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

import json

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import to_dict


def _raw_policy(bucket, perm):
    p = (perm or "").strip().lower()
    if p == "readwrite":
        stmt = [
            {
                "Effect": "Allow",
                "Action": [
                    "s3:GetBucketLocation",
                    "s3:ListBucket",
                    "s3:GetObject",
                    "s3:PutObject",
                    "s3:DeleteObject",
                ],
                "Resource": [f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"],
            }
        ]
    elif p == "readonly":
        stmt = [
            {
                "Effect": "Allow",
                "Action": ["s3:GetBucketLocation", "s3:ListBucket"],
                "Resource": [f"arn:aws:s3:::{bucket}"],
            },
            {
                "Effect": "Allow",
                "Action": ["s3:GetObject"],
                "Resource": [f"arn:aws:s3:::{bucket}/*"],
            },
        ]
    elif p == "writeonly":
        stmt = [
            {
                "Effect": "Allow",
                "Action": ["s3:GetBucketLocation", "s3:ListBucket"],
                "Resource": [f"arn:aws:s3:::{bucket}"],
            },
            {
                "Effect": "Allow",
                "Action": ["s3:PutObject", "s3:DeleteObject"],
                "Resource": [f"arn:aws:s3:::{bucket}/*"],
            },
        ]
    elif p == "none":
        stmt = []
    else:
        stmt = []
    return json.dumps({"Version": "2012-10-17", "Statement": stmt}, indent=2)


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    meta = xr.get("metadata", {}) or {}
    spec = xr.get("spec", {}) or {}
    ns = meta.get("namespace") or "default"

    for grant in spec.get("bucketAccessGrants") or []:
        bucket = (grant.get("bucketName") or "").strip()
        grantee = (grant.get("grantee") or "").strip()
        perm = (grant.get("permission") or "").strip()
        if not bucket or not grantee or not perm:
            continue

        raw = _raw_policy(bucket, perm)
        polname = f"provider-storage.{grantee}.{bucket}"
        key = f"policy-{grantee}-{bucket}"
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
