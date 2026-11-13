# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import (
    dig,
    encoded,
    publish_consumer_secret,
    retain_resources,
    to_dict,
)

ENVIRONMENT_KEY = "apiextensions.crossplane.io/environment"


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    metadata = xr.get("metadata") or {}
    spec = xr.get("spec") or {}
    principal = (spec.get("principal") or metadata.get("name") or "").strip()
    if not principal:
        return
    retain_resources(req, rsp, [f"secret-{principal}"])

    backend = req.input["backend"]
    observer_key = f"observe-secret-{principal}"
    observer = req.observed.resources.get(observer_key)
    data = (
        dig(to_dict(observer.resource), "status", "atProvider", "manifest", "data")
        if observer is not None
        else None
    )
    if not isinstance(data, dict):
        data = {}
    access = data.get("AWS_ACCESS_KEY_ID")
    secret = data.get("AWS_SECRET_ACCESS_KEY")
    if backend == "aws":
        access = access or data.get("username")
        secret = secret or data.get("password") or data.get("attribute.secret")
    elif backend == "otc":
        access = access or data.get("attribute.access") or data.get("access")
        secret = secret or data.get("attribute.secret") or data.get("secret")
    if not access or not secret:
        if backend == "aws":
            rsp.desired.resources[observer_key].ready = fnv1.READY_FALSE
        return

    settings = (to_dict(req.context).get(ENVIRONMENT_KEY) or {}).get("storage") or {}
    endpoint = (settings.get("endpoint") or "").strip()
    region = settings.get("region") or ""
    if backend != "minio":
        region = (
            region
            or spec.get("region")
            or {"aws": "eu-central-1", "otc": "eu-nl"}[backend]
        )
    region = region.strip()
    if backend == "otc" and not endpoint:
        endpoint = f"https://obs.{region}.otc.t-systems.com"
    data = {"AWS_ACCESS_KEY_ID": access, "AWS_SECRET_ACCESS_KEY": secret}
    if endpoint:
        data["AWS_ENDPOINT_URL"] = encoded(endpoint)
    if region:
        data["AWS_REGION"] = encoded(region)
    force_path_style = settings.get("force_path_style")
    if force_path_style not in (None, ""):
        data["AWS_S3_FORCE_PATH_STYLE"] = encoded(str(force_path_style))
    publish_consumer_secret(
        rsp, principal, metadata.get("namespace") or "default", data
    )
