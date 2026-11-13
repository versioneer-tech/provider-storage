# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

import base64
from datetime import datetime, timedelta, timezone

from google.protobuf import json_format


def _get_rollover(spec: dict) -> tuple[str, int]:
    cfg = spec.get("credentialsRollover") or {}
    interval = (cfg.get("interval") or "none").strip().lower()
    max_to_keep = cfg.get("maxToKeep")
    if max_to_keep is None:
        max_to_keep = 1
    try:
        max_to_keep = int(max_to_keep)
    except Exception:
        max_to_keep = 1
    if max_to_keep < 1:
        max_to_keep = 1
    if max_to_keep > 10:
        max_to_keep = 10
    return interval, max_to_keep


def _quarter(dt: datetime) -> int:
    return ((dt.month - 1) // 3) + 1


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


def _b64(value):
    return base64.b64encode(str(value).encode("utf-8")).decode("utf-8")


def _suffixes(now: datetime, interval: str, max_to_keep: int) -> list[str]:
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
            q_total = (now.year * 4 + (_quarter(now) - 1)) - i
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


def current_suffix(spec):
    interval = (
        ((spec.get("credentialsRollover") or {}).get("interval") or "none")
        .strip()
        .lower()
    )
    now = datetime.now(timezone.utc)
    if interval == "daily":
        return "-" + now.strftime("%Y%m%d")
    if interval == "weekly":
        week = now.isocalendar()
        return f"-{week.year}w{week.week:02d}"
    if interval == "monthly":
        return "-" + now.strftime("%Y%m")
    if interval == "quarterly":
        return f"-{now.year}q{(now.month - 1) // 3 + 1}"
    if interval == "yearly":
        return "-" + str(now.year)
    return ""


def encoded(value):
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def decoded(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        return base64.b64decode(value, validate=True).decode("utf-8")
    except (ValueError, UnicodeError):
        return None


def rollover_suffixes(spec):
    config = spec.get("credentialsRollover") or {}
    interval = (config.get("interval") or "none").strip().lower()
    count = max(1, min(10, int(config.get("maxToKeep") or 1)))
    now = datetime.now(timezone.utc)
    if interval == "daily":
        dates = [(now - timedelta(days=i)).strftime("%Y%m%d") for i in range(count)]
    elif interval == "weekly":
        dates = []
        for i in range(count):
            week = (now - timedelta(weeks=i)).isocalendar()
            dates.append(f"{week.year}w{week.week:02d}")
    elif interval == "monthly":
        dates = [
            f"{(now.year * 12 + now.month - 1 - i) // 12}{((now.year * 12 + now.month - 1 - i) % 12) + 1:02d}"
            for i in range(count)
        ]
    elif interval == "quarterly":
        quarter = now.year * 4 + (now.month - 1) // 3
        dates = [
            f"{(quarter - i) // 4}q{((quarter - i) % 4) + 1}" for i in range(count)
        ]
    elif interval == "yearly":
        dates = [str(now.year - i) for i in range(count)]
    else:
        return [""]
    return ["-" + date for date in dates]


def to_dict(value):
    if value is None:
        return {}
    if isinstance(value, dict):
        return value
    return json_format.MessageToDict(value, preserving_proto_field_name=True)
