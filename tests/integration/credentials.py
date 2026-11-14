#!/usr/bin/env python3
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

"""Check credential publication, protection, and deletion in MinIO."""

import argparse
import base64
import json
import subprocess
import time
from datetime import datetime, timezone

NAMESPACE = "provider-storage-it"
PRINCIPALS = [f"provider-storage-minio-{suffix}" for suffix in ("it", "it2")]
REQUESTER_STORAGE = "storage-minio-it2"
REQUESTER_PRINCIPAL = PRINCIPALS[1]


def kube(*arguments, text=False, namespace=NAMESPACE):
    result = subprocess.run(
        [
            "kubectl",
            "--context",
            "kind-provider-storage-it",
            "--namespace",
            namespace,
            "--request-timeout=15s",
            *arguments,
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    if text:
        return result.stdout
    return json.loads(result.stdout) if result.stdout.strip() else None


def secret(name):
    return kube(
        "get",
        "secret",
        name,
        "--ignore-not-found",
        "-o",
        "json",
    )


def verify():
    values = set()
    for principal in PRINCIPALS:
        resource = secret(principal)
        owners = resource["metadata"].get("ownerReferences") or []
        if not any(
            owner["kind"] == "Storage" and owner.get("controller") for owner in owners
        ):
            raise RuntimeError("The consumer Secret is not owned by its Storage.")
        value = resource.get("data", {}).get("AWS_SECRET_ACCESS_KEY")
        if value:
            values.add(value)
            values.add(base64.b64decode(value).decode())
    if not values:
        raise RuntimeError(
            "No test credentials were available for the protection check."
        )
    objects = kube(
        "get",
        "objects.kubernetes.m.crossplane.io",
        "-l",
        "crossplane.io/composite in (storage-minio-it,storage-minio-it2)",
        "-o",
        "json",
    )
    body = json.dumps(objects)
    if any(value in body for value in values):
        raise RuntimeError("A test credential is stored in an Object resource.")
    pods = kube(
        "get",
        "pods",
        "-l",
        "runtime=provider-minio",
        "-o",
        "json",
        namespace="crossplane",
    )
    if not pods["items"]:
        raise RuntimeError("The MinIO provider runtime configuration is not active.")
    for pod in pods["items"]:
        runtime = next(
            item
            for item in pod["spec"]["containers"]
            if item["name"] == "package-runtime"
        )
        if runtime.get("args") != ["--log-level=-1", "operator"]:
            raise RuntimeError("The MinIO provider log threshold is unsafe.")
        logs = kube(
            "logs",
            pod["metadata"]["name"],
            "-c",
            "package-runtime",
            text=True,
            namespace="crossplane",
        )
        if "user client created, everything went fine" in logs or any(
            value in logs for value in values
        ):
            raise RuntimeError("The MinIO provider logged a test credential.")
    print("Consumer Secrets are owned by their Storage resources.")
    print("No test credentials found in Objects or current MinIO provider logs.")
    verify_deletion()


def verify_deletion():
    name = "storage-minio-disposable"
    principal = "provider-storage-minio-disposable"
    fixture = {
        "apiVersion": "pkg.internal/v1beta1",
        "kind": "Storage",
        "metadata": {
            "name": name,
            "namespace": NAMESPACE,
            "annotations": {"storages.pkg.internal/environment": "storage-minio"},
        },
        "spec": {
            "principal": principal,
            "providerIdentity": "it-delete",
            "buckets": [],
            "crossplane": {"compositionRef": {"name": "storage-minio"}},
        },
    }
    subprocess.run(
        ["kubectl", "--context", "kind-provider-storage-it", "create", "-f", "-"],
        input=json.dumps(fixture),
        text=True,
        capture_output=True,
        check=True,
    )
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        data = (secret(principal) or {}).get("data") or {}
        if data.get("AWS_ACCESS_KEY_ID") and data.get("AWS_SECRET_ACCESS_KEY"):
            break
        time.sleep(2)
    else:
        raise RuntimeError("The disposable Storage did not publish credentials.")
    kube(
        "delete",
        "storage.pkg.internal",
        name,
        "--wait=false",
        text=True,
    )
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        user = kube(
            "get",
            "users.minio.crossplane.io",
            "provider-storage-managed-it-delete",
            "--ignore-not-found",
            "-o",
            "json",
        )
        storage = kube(
            "get", "storage.pkg.internal", name, "--ignore-not-found", "-o", "json"
        )
        if (
            secret(principal) is None
            and secret(f"{principal}-credentials") is None
            and user is None
            and storage is None
        ):
            print(
                "Deleting a disposable Storage removed its consumer Secret and MinIO User."
            )
            return
        time.sleep(2)
    raise RuntimeError(
        "Disposable Storage deletion left credentials or a managed User."
    )


def wait_for_credentials(uid, source_name):
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        secret = kube(
            "get", "secret", REQUESTER_PRINCIPAL, "--ignore-not-found", "-o", "json"
        )
        if secret is None:
            raise RuntimeError("The consumer Secret disappeared during rollover.")
        if secret["metadata"]["uid"] != uid:
            raise RuntimeError("The consumer Secret was recreated during rollover.")
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
        REQUESTER_STORAGE,
        "--type=merge",
        "-p",
        json.dumps({"spec": {"credentialsRollover": config}}),
        "-o",
        "json",
    )


def verify_rollover():
    storage = kube("get", "storage.pkg.internal", REQUESTER_STORAGE, "-o", "json")
    original = storage["spec"].get("credentialsRollover") or {
        "interval": "none",
        "maxToKeep": 1,
    }
    if original["interval"] != "none":
        raise RuntimeError("The MinIO rollover fixture must start without rollover.")
    secret = kube("get", "secret", REQUESTER_PRINCIPAL, "-o", "json")
    uid = secret["metadata"]["uid"]
    original_source = f"{REQUESTER_PRINCIPAL}-credentials"
    wait_for_credentials(uid, original_source)
    generation = datetime.now(timezone.utc).strftime("%Y%m%d")
    try:
        set_rollover({"interval": "daily", "maxToKeep": 2})
        wait_for_credentials(uid, f"{REQUESTER_PRINCIPAL}-{generation}")
        print("MinIO consumer Secret kept its UID through credential replacement.")
    finally:
        set_rollover(original)
        wait_for_credentials(uid, original_source)
    print("MinIO credential rollover settings restored; the consumer Secret is intact.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    actions = {"rollover": verify_rollover, "verify": verify}
    parser.add_argument("check", choices=actions)
    actions[parser.parse_args().check]()
