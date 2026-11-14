# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import (
    credential_suffixes,
    encoded,
    publish_consumer_secret,
    require_secret,
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
    publish_consumer_secret(req, rsp, principal, metadata.get("namespace") or "default")

    backend = req.input["backend"]
    suffix = credential_suffixes(req)[0]
    generation = f"{principal}{suffix}"
    source_name = generation if suffix else f"{principal}-credentials"
    source = require_secret(
        req,
        rsp,
        f"credential-secret-{principal}",
        source_name,
        metadata.get("namespace") or "default",
    )
    data = source.get("data") or {}
    access = data.get("AWS_ACCESS_KEY_ID")
    secret = data.get("AWS_SECRET_ACCESS_KEY")
    if backend == "aws":
        access = access or data.get("username")
        secret = secret or data.get("password") or data.get("attribute.secret")
    elif backend == "otc":
        access = access or data.get("attribute.access") or data.get("access")
        secret = secret or data.get("attribute.secret") or data.get("secret")
    if not access or not secret:
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
        req, rsp, principal, metadata.get("namespace") or "default", data
    )
