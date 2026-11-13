# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

import base64
from datetime import datetime, timedelta

from crossplane.function.proto.v1 import run_function_pb2 as fnv1
from google.protobuf import json_format


def retain_resources(req, rsp, keys):
    # Omitted resources are deleted, so keep the last output during handover.
    for key in keys:
        observed = req.observed.resources.get(key)
        if observed is None:
            continue
        body = to_dict(observed.resource)
        if not body.get("spec"):
            continue
        metadata = body.get("metadata") or {}
        rsp.desired.resources[key].resource.update(
            {
                "apiVersion": body["apiVersion"],
                "kind": body["kind"],
                "metadata": {
                    field: metadata[field]
                    for field in ("name", "namespace")
                    if field in metadata
                }
                | {"annotations": {"crossplane.io/composition-resource-name": key}},
                "spec": body["spec"],
            }
        )
        rsp.desired.resources[key].ready = fnv1.READY_FALSE


def _bucket_grants_access(storage: dict, bucket: str, grantee: str) -> bool | None:
    spec = storage.get("spec") or {}
    owns_bucket = any(
        (b.get("bucketName") or "").strip() == bucket
        for b in (spec.get("buckets") or [])
    )
    if not owns_bucket:
        return None

    decision = None
    for grant in spec.get("bucketAccessGrants") or []:
        grant_bucket = (grant.get("bucketName") or "").strip()
        grant_grantee = (grant.get("grantee") or "").strip()
        permission = (grant.get("permission") or "").strip().lower()
        if grant_bucket != bucket or grant_grantee != grantee:
            continue
        if permission == "none":
            return False
        if permission in ("readonly", "writeonly", "readwrite"):
            decision = True
    return decision


def rollover_suffixes(spec, now: datetime) -> list[str]:
    cfg = spec.get("credentialsRollover") or {}
    interval = cfg.get("interval", "none")
    # The XRD validates the range; protobuf Struct stores numbers as floats.
    max_to_keep = int(cfg.get("maxToKeep", 1))
    out = []
    if interval == "daily":
        for i in range(max_to_keep):
            d = (now - timedelta(days=i)).date()
            out.append(d.strftime("%Y%m%d"))
    elif interval == "weekly":
        for i in range(max_to_keep):
            d = (now - timedelta(weeks=i)).date()
            iso = d.isocalendar()
            out.append(f"{iso.year}w{iso.week:02d}")
    elif interval == "monthly":
        for i in range(max_to_keep):
            y = now.year
            m = now.month - i
            while m <= 0:
                y -= 1
                m += 12
            out.append(f"{y}{m:02d}")
    elif interval == "quarterly":
        for i in range(max_to_keep):
            q_total = now.year * 4 + (now.month - 1) // 3 - i
            y = q_total // 4
            q = (q_total % 4) + 1
            out.append(f"{y}q{q}")
    elif interval == "yearly":
        for i in range(max_to_keep):
            out.append(str(now.year - i))
    else:
        return [""]
    return ["-" + s for s in out]


def dig(d, *keys):
    cur = d
    for k in keys:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(k)
    return cur


def extract_ids(obj_dict):
    s = obj_dict.get("status") or {}
    ap = s.get("atProvider") or {}
    u = dig(ap, "manifest", "status", "atProvider") or {}
    if u.get("id"):
        return u.get("id"), u.get("domainId")
    u = dig(ap, "manifest", "status") or {}
    if u and u.get("id"):
        return u.get("id"), u.get("domainId")
    if ap.get("id"):
        return ap.get("id"), ap.get("domainId")
    return None, None


def credential_suffixes(req):
    return to_dict(req.context)["storages.pkg.internal/credential-generations"]


def credential_time(req):
    return datetime.fromisoformat(
        to_dict(req.context)["storages.pkg.internal/credential-time"]
    )


def kubernetes_object(key, namespace, manifest, *, name=None, **spec_fields):
    return {
        "apiVersion": "kubernetes.m.crossplane.io/v1alpha1",
        "kind": "Object",
        "metadata": {
            "name": key if name is None else name,
            "namespace": namespace,
            "annotations": {"crossplane.io/composition-resource-name": key},
        },
        "spec": {
            "forProvider": {"manifest": manifest},
            "providerConfigRef": {
                "name": "provider-kubernetes",
                "kind": "ProviderConfig",
            },
            **spec_fields,
        },
    }


def publish_consumer_secret(rsp, principal, namespace, data):
    key = f"secret-{principal}"
    rsp.desired.resources[key].ClearField("ready")
    rsp.desired.resources[key].resource.update(
        kubernetes_object(
            key,
            namespace,
            {
                "apiVersion": "v1",
                "kind": "Secret",
                "metadata": {"name": principal, "namespace": namespace},
                "type": "Opaque",
                "data": data,
            },
        )
    )


def ready_user_id(observed, key):
    item = observed.get(key)
    if item is None:
        return None
    status = to_dict(item.resource).get("status") or {}
    ready = any(
        condition.get("type") == "Ready" and condition.get("status") == "True"
        for condition in status.get("conditions") or []
    )
    value = (status.get("atProvider") or {}).get("id")
    if not ready or not isinstance(value, str) or not value.isdecimal():
        return None
    number = int(value)
    return number if 0 < number <= 9007199254740991 else None


def encoded(value):
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def decoded(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        return base64.b64decode(value, validate=True).decode("utf-8")
    except (ValueError, UnicodeError):
        return None


def to_dict(value):
    if value is None:
        return {}
    if isinstance(value, dict):
        return value
    return json_format.MessageToDict(value, preserving_proto_field_name=True)
