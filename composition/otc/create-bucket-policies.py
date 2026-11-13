# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

import json
from collections import defaultdict

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import extract_ids, to_dict


def grant_statements(bucket, principal_str, perm):
    p = (perm or "").strip().lower()
    if p == "readwrite":
        bucket_actions = ["ListBucket"]
        object_actions = ["GetObject", "PutObject", "DeleteObject"]
    elif p == "readonly":
        bucket_actions = ["ListBucket"]
        object_actions = ["GetObject"]
    elif p == "writeonly":
        bucket_actions = ["ListBucket"]
        object_actions = ["PutObject", "DeleteObject"]
    else:
        bucket_actions = []
        object_actions = []
    stmts = []
    if bucket_actions:
        stmts.append(
            {
                "Effect": "Allow",
                "Action": bucket_actions,
                "Resource": [f"{bucket}"],
                "Principal": {"ID": [principal_str]},
            }
        )
    if object_actions:
        stmts.append(
            {
                "Effect": "Allow",
                "Action": object_actions,
                "Resource": [f"{bucket}/*"],
                "Principal": {"ID": [principal_str]},
            }
        )
    return stmts


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    meta = xr.get("metadata", {}) or {}
    spec = xr.get("spec", {}) or {}
    ns = meta.get("namespace") or "default"
    principal = (spec.get("principal") or meta.get("name") or "").strip()
    if not principal:
        return

    observed = getattr(req.observed, "resources", {}) or {}

    owner_ids = {}
    for k, v in (observed or {}).items():
        if not k.startswith("user-"):
            continue
        if not getattr(v, "resource", None):
            continue
        uname = k.replace("user-", "", 1)
        od = to_dict(v.resource)
        uid, udom = extract_ids(od)
        if uid:
            owner_ids[uname] = (uid, udom)

    grantee_ids = {}
    for k, v in (observed or {}).items():
        if not k.startswith("observe-user-"):
            continue
        if not getattr(v, "resource", None):
            continue
        gr_name = k.replace("observe-user-", "", 1)
        od = to_dict(v.resource)
        gid, gdom = extract_ids(od)
        if gid:
            grantee_ids[gr_name] = (gid, gdom)

    by_bucket = defaultdict(set)

    for b in spec.get("buckets") or []:
        bucket = (b.get("bucketName") or "").strip()
        if not bucket:
            continue
        by_bucket[bucket].add(("_OWNER_", "readwrite"))

    for g in spec.get("bucketAccessGrants") or []:
        bucket = (g.get("bucketName") or "").strip()
        gr = (g.get("grantee") or "").strip()
        perm = (g.get("permission") or "").strip()
        if not bucket or not gr or not perm:
            continue
        ids = grantee_ids.get(gr)
        if not ids:
            continue
        gid, gdom = ids
        principal_str = f"domain/{gdom}:user/{gid}" if gdom else f"user/{gid}"
        by_bucket[bucket].add((principal_str, perm))

    for bucket, items in by_bucket.items():
        statements = []
        for principal_str, perm in sorted(items):
            if principal_str == "_OWNER_":
                owner_user_name = None
                candidates = [k for k in owner_ids.keys() if k.startswith(principal)]
                if candidates:
                    owner_user_name = sorted(candidates)[0]
                if not owner_user_name:
                    continue
                uid, udom = owner_ids[owner_user_name]
                owner_principal = f"domain/{udom}:user/{uid}" if udom else f"user/{uid}"
                statements.extend(grant_statements(bucket, owner_principal, perm))
            else:
                statements.extend(grant_statements(bucket, principal_str, perm))

        policy = {"Version": "2012-10-17", "Statement": statements}
        key = f"bucketpolicy-{bucket}"
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
                            "apiVersion": "obs.opentelekomcloud.crossplane.io/v1alpha1",
                            "kind": "BucketPolicy",
                            "metadata": {"name": f"bucketpolicy-{bucket}"},
                            "spec": {
                                "forProvider": {
                                    "bucket": bucket,
                                    "policy": json.dumps(policy, indent=2),
                                },
                                "providerConfigRef": {"name": "provider-otc"},
                            },
                        }
                    },
                    "readiness": {"policy": "DeriveFromObject"},
                    "providerConfigRef": {
                        "name": "provider-kubernetes",
                        "kind": "ProviderConfig",
                    },
                },
            }
        )
