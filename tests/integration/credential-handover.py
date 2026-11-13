#!/usr/bin/env python3
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

"""Check MinIO consumer Secret continuity during a generation change."""

import json
import subprocess
import time
from datetime import datetime, timezone

CONTEXT = "kind-provider-storage-it"
NAMESPACE = "provider-storage-it"
STORAGE = "storage-minio-it2"
PRINCIPAL = "provider-storage-minio-it2"


def kube(*arguments):
    result = subprocess.run(
        [
            "kubectl",
            "--context",
            CONTEXT,
            "--namespace",
            NAMESPACE,
            "--request-timeout=15s",
            *arguments,
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout) if result.stdout.strip() else None


def wait_for_credentials(uid, source_name):
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        secret = kube("get", "secret", PRINCIPAL, "--ignore-not-found", "-o", "json")
        if secret is None:
            raise RuntimeError("The consumer Secret disappeared during handover.")
        if secret["metadata"]["uid"] != uid:
            raise RuntimeError("The consumer Secret was recreated during handover.")
        data = secret.get("data") or {}
        source = kube("get", "secret", source_name, "--ignore-not-found", "-o", "json")
        native = (source or {}).get("data") or {}
        keys = ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY")
        if all(native.get(key) and data.get(key) == native[key] for key in keys):
            return
        time.sleep(2)
    raise RuntimeError("Replacement consumer credentials did not become available.")


def set_rollover(config):
    kube(
        "patch",
        "storage.pkg.internal",
        STORAGE,
        "--type=merge",
        "-p",
        json.dumps({"spec": {"credentialsRollover": config}}),
        "-o",
        "json",
    )


def main():
    storage = kube("get", "storage.pkg.internal", STORAGE, "-o", "json")
    original = storage["spec"].get("credentialsRollover") or {
        "interval": "none",
        "maxToKeep": 1,
    }
    if original["interval"] != "none":
        raise RuntimeError("The MinIO handover fixture must start without rollover.")
    secret = kube("get", "secret", PRINCIPAL, "-o", "json")
    uid = secret["metadata"]["uid"]
    original_source = f"{PRINCIPAL}-credentials"
    wait_for_credentials(uid, original_source)
    generation = datetime.now(timezone.utc).strftime("%Y%m%d")
    try:
        set_rollover({"interval": "daily", "maxToKeep": 2})
        wait_for_credentials(uid, f"{PRINCIPAL}-{generation}")
        print("MinIO consumer Secret kept its UID through credential replacement.")
    finally:
        set_rollover(original)
        wait_for_credentials(uid, original_source)
    print("MinIO credential rollover settings restored; the consumer Secret is intact.")


if __name__ == "__main__":
    main()
