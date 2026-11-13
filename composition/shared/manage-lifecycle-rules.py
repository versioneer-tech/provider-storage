# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

import shlex
from datetime import datetime

from crossplane.function import response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import (
    kubernetes_object,
    to_dict,
)

ENVIRONMENT_KEY = "apiextensions.crossplane.io/environment"


def _normalize_target(target: str) -> str | None:
    value = (target or "").strip()
    if not value:
        return None
    if value == "*":
        return ""
    if "*" in value[:-1]:
        return None
    if value.endswith("*"):
        value = value[:-1]
    return value.lstrip("/")


def _normalize_after(value: str) -> str:
    rel = (value or "").strip()
    if rel.startswith("+"):
        rel = rel[1:]
    if not rel:
        return rel
    unit = rel[-1]
    if unit in ("S", "s", "M", "m", "H", "h", "D", "d", "W", "w"):
        return rel[:-1] + unit.lower()
    return rel


def _parse_at_epoch(value: str) -> int | None:
    timestamp = (value or "").strip()
    if not timestamp:
        return None
    if timestamp.endswith("Z"):
        timestamp = timestamp[:-1] + "+00:00"
    try:
        return int(datetime.fromisoformat(timestamp).timestamp())
    except ValueError:
        return None


def _build_script(bucket: str, rule: dict) -> str:
    mode = (rule.get("mode") or "").strip()
    target = _normalize_target(rule.get("target") or "")
    remote_path = bucket if not target else f"{bucket}/{target}"
    remote = shlex.quote(f"storage:{remote_path}")
    target_display = target or "*"

    min_age = (rule.get("minAge") or "").strip()
    at = (rule.get("at") or "").strip()
    if min_age:
        min_age = _normalize_after(min_age)
        action = "lsf" if mode == "Notify" else "delete"
        recursive = " --recursive" if mode == "Notify" else ""
        return (
            "\n".join(
                [
                    "#!/bin/sh",
                    "set -eu",
                    f"exec rclone {action} {remote}{recursive} --min-age {shlex.quote(min_age)} --fast-list --s3-no-check-bucket",
                ]
            )
            + "\n"
        )

    at_epoch = _parse_at_epoch(at)
    if at_epoch is None:
        return (
            "\n".join(
                [
                    "#!/bin/sh",
                    "set -eu",
                    f"echo {shlex.quote(f'Invalid lifecycle timestamp for {bucket}/{target_display}; skipping.')}",
                ]
            )
            + "\n"
        )
    return (
        "\n".join(
            [
                "#!/bin/sh",
                "set -eu",
                'now="$(date -u +%s)"',
                f'cutoff="{at_epoch}"',
                'if [ "$now" -lt "$cutoff" ]; then',
                "  exit 0",
                "fi",
                f"exec rclone {'lsf' if mode == 'Notify' else 'delete'} {remote}{' --recursive' if mode == 'Notify' else ''} --fast-list --s3-no-check-bucket",
            ]
        )
        + "\n"
    )


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    meta = xr.get("metadata", {}) or {}
    spec = xr.get("spec", {}) or {}
    ctx = to_dict(req.context)
    env = ctx.get(ENVIRONMENT_KEY) or {}
    storage_env = env.get("storage") or {}
    ns = meta.get("namespace") or "default"
    principal = (
        spec.get("principal") or meta.get("name") or "<principal-missing>"
    ).strip()

    rules = []
    for bucket_cfg in spec.get("buckets") or []:
        bucket = (bucket_cfg.get("bucketName") or "").strip()
        if not bucket:
            continue
        for index, rule in enumerate(bucket_cfg.get("lifecycleRules") or [], start=1):
            target = _normalize_target(rule.get("target") or "")
            if target is None:
                continue
            rules.append(
                {
                    "bucket": bucket,
                    "index": index,
                    "target": target,
                    "mode": (rule.get("mode") or "").strip(),
                    "minAge": (rule.get("minAge") or "").strip(),
                    "at": (rule.get("at") or "").strip(),
                }
            )

    if not rules:
        return

    backend = req.input["backend"]
    storage_type = (storage_env.get("type") or "").strip() or "s3"
    providers = {"minio": "Minio", "aws": "AWS"}
    storage_provider = (storage_env.get("provider") or "").strip() or providers.get(
        backend, "Other"
    )
    regions = {"aws": "eu-central-1", "otc": "eu-nl", "ovh": "de"}
    if backend == "cloudferro":
        storage_region = (storage_env.get("s3Region") or "").strip()
    elif backend == "minio":
        storage_region = (storage_env.get("region") or "").strip()
    else:
        storage_region = (
            storage_env.get("region") or spec.get("region") or regions[backend]
        ).strip()
    endpoint = (storage_env.get("endpoint") or "").strip()
    if backend == "minio" and not endpoint:
        endpoint = "http://default-hl.minio:9000"
    elif backend == "otc" and not endpoint and storage_region:
        endpoint = f"https://obs.{storage_region}.otc.t-systems.com"
    elif backend == "ovh" and not endpoint and storage_region:
        endpoint = f"https://s3.{storage_region}.io.cloud.ovh.net"
    elif backend == "cloudferro" and (not endpoint or not storage_region):
        return
    lifecycle = storage_env.get("lifecycle") or {}
    schedule = (lifecycle.get("schedule") or "").strip() or "17 2 * * *"
    deadline = lifecycle.get("activeDeadlineSeconds", 3600)
    retries = lifecycle.get("backoffLimit", 2)
    for field, value, minimum, maximum in (
        ("activeDeadlineSeconds", deadline, 1, 86400),
        ("backoffLimit", retries, 0, 10),
    ):
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not minimum <= value <= maximum
            or int(value) != value
        ):
            response.fatal(
                rsp,
                f"storage.lifecycle.{field} must be an integer from {minimum} through {maximum}.",
            )
            return
    force_path_style = storage_env.get("force_path_style")
    if backend == "minio" and force_path_style in (None, ""):
        force_path_style = "true"
    if force_path_style not in (None, ""):
        force_path_style = str(force_path_style)
    image = "rclone/rclone:1.75.1"
    for package in env.get("packages") or []:
        if (package.get("name") or "").strip() != "rclone":
            continue
        for file_entry in package.get("files") or []:
            image_url = (((file_entry.get("image") or {}).get("url")) or "").strip()
            if image_url:
                image = image_url
                break
        break

    scripts = {}
    containers = []
    for idx, rule in enumerate(rules, start=1):
        key = f"rule-{idx:02d}.sh"
        display_target = rule["target"] or "*"
        scripts[key] = _build_script(rule["bucket"], rule)
        container_env = [
            {"name": "HOME", "value": "/tmp"},
            {"name": "RCLONE_CONFIG", "value": "/dev/null"},
            {"name": "RCLONE_CONFIG_STORAGE_TYPE", "value": storage_type},
            {"name": "RCLONE_CONFIG_STORAGE_PROVIDER", "value": storage_provider},
        ]
        if endpoint:
            container_env.append(
                {"name": "RCLONE_CONFIG_STORAGE_ENDPOINT", "value": endpoint}
            )
        if force_path_style not in (None, ""):
            container_env.append(
                {
                    "name": "RCLONE_CONFIG_STORAGE_FORCE_PATH_STYLE",
                    "value": force_path_style,
                }
            )
        if storage_region and backend != "minio":
            container_env.append(
                {"name": "RCLONE_CONFIG_STORAGE_REGION", "value": storage_region}
            )
        container_env.extend(
            [
                {
                    "name": "RCLONE_CONFIG_STORAGE_ACCESS_KEY_ID",
                    "valueFrom": {
                        "secretKeyRef": {"name": principal, "key": "AWS_ACCESS_KEY_ID"}
                    },
                },
                {
                    "name": "RCLONE_CONFIG_STORAGE_SECRET_ACCESS_KEY",
                    "valueFrom": {
                        "secretKeyRef": {
                            "name": principal,
                            "key": "AWS_SECRET_ACCESS_KEY",
                        }
                    },
                },
                {"name": "STORAGE_LIFECYCLE_BUCKET", "value": rule["bucket"]},
                {"name": "STORAGE_LIFECYCLE_TARGET", "value": display_target},
            ]
        )
        if storage_region and backend == "minio":
            container_env.append(
                {"name": "RCLONE_CONFIG_STORAGE_REGION", "value": storage_region}
            )
        containers.append(
            {
                "name": f"lifecycle-{idx:02d}",
                "image": image,
                "imagePullPolicy": "IfNotPresent",
                "command": ["/bin/sh", "/opt/lifecycle/run.sh"],
                "securityContext": {
                    "allowPrivilegeEscalation": False,
                    "capabilities": {"drop": ["ALL"]},
                    "readOnlyRootFilesystem": True,
                },
                "env": container_env,
                "volumeMounts": [
                    {
                        "name": "lifecycle-scripts",
                        "mountPath": "/opt/lifecycle/run.sh",
                        "subPath": key,
                        "readOnly": True,
                    },
                    {"name": "scratch", "mountPath": "/tmp"},
                ],
                "resources": {
                    "requests": {"cpu": "50m", "memory": "64Mi"},
                    "limits": {"cpu": "250m", "memory": "256Mi"},
                },
            }
        )

    config_key = f"lifecycle-config-{principal}"
    config_name = f"{principal}-lifecycle"
    rsp.desired.resources[config_key].resource.update(
        kubernetes_object(
            config_key,
            ns,
            {
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {"name": config_name, "namespace": ns},
                "data": scripts,
            },
        )
    )

    cron_key = f"lifecycle-cron-{principal}"
    cron_name = f"{principal}-lifecycle"
    rsp.desired.resources[cron_key].resource.update(
        kubernetes_object(
            cron_key,
            ns,
            {
                "apiVersion": "batch/v1",
                "kind": "CronJob",
                "metadata": {
                    "name": cron_name,
                    "namespace": ns,
                    "labels": {
                        "app.kubernetes.io/name": "storage-lifecycle",
                        "storages.pkg.internal/principal": principal,
                    },
                },
                "spec": {
                    "schedule": schedule,
                    "concurrencyPolicy": "Forbid",
                    "successfulJobsHistoryLimit": 1,
                    "failedJobsHistoryLimit": 1,
                    "jobTemplate": {
                        "spec": {
                            "activeDeadlineSeconds": int(deadline),
                            "backoffLimit": int(retries),
                            "template": {
                                "spec": {
                                    "automountServiceAccountToken": False,
                                    "restartPolicy": "Never",
                                    "securityContext": {
                                        "runAsNonRoot": True,
                                        "runAsUser": 1000,
                                        "runAsGroup": 1000,
                                        "fsGroup": 1000,
                                        "seccompProfile": {"type": "RuntimeDefault"},
                                    },
                                    "containers": containers,
                                    "volumes": [
                                        {
                                            "name": "lifecycle-scripts",
                                            "configMap": {
                                                "name": config_name,
                                                "defaultMode": 493,
                                            },
                                        },
                                        {"name": "scratch", "emptyDir": {}},
                                    ],
                                }
                            },
                        }
                    },
                },
            },
        )
    )
