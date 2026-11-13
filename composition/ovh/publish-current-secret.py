# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import (
    credential_suffixes,
    decoded,
    encoded,
    publish_consumer_secret,
    ready_user_id,
    retain_resources,
    to_dict,
)

ENVIRONMENT_KEY = "apiextensions.crossplane.io/environment"


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    metadata = xr.get("metadata") or {}
    spec = xr.get("spec") or {}
    namespace = metadata.get("namespace") or "default"
    principal = (spec.get("principal") or metadata.get("name") or "").strip()
    retain_resources(req, rsp, [f"secret-{principal}"])
    generation = f"{principal}{credential_suffixes(req)[0]}"
    context = to_dict(req.context)
    storage_env = (context.get(ENVIRONMENT_KEY) or {}).get("storage") or {}
    endpoint = (storage_env.get("endpoint") or "").strip()
    region = (storage_env.get("region") or "").strip()
    force_path_style = storage_env.get("force_path_style")
    if not principal or not endpoint or not region or force_path_style in (None, ""):
        return
    observed = req.observed.resources
    user_id = ready_user_id(observed, f"user-{generation}")
    if not user_id:
        return
    dependent_name = f"{generation}-u{user_id}"
    observer_key = f"observe-secret-{dependent_name}"
    rsp.desired.resources[observer_key].ready = fnv1.READY_FALSE
    credential = observed.get(f"credentials-{dependent_name}")
    secret = observed.get(observer_key)
    if credential is None or secret is None:
        return
    credential_data = to_dict(credential.resource)
    access_key = ((credential_data.get("status") or {}).get("atProvider") or {}).get(
        "accessKeyId"
    )
    secret_data = (
        ((to_dict(secret.resource).get("status") or {}).get("atProvider") or {}).get(
            "manifest"
        )
        or {}
    ).get("data") or {}
    if (
        not isinstance(access_key, str)
        or not access_key
        or not isinstance(secret_data, dict)
    ):
        return
    source_access = decoded(secret_data.get("access_key_id"))
    source_secret = decoded(secret_data.get("attribute.secret_access_key"))
    if source_access != access_key or not source_secret:
        return
    data = {
        "AWS_ACCESS_KEY_ID": encoded(access_key),
        "AWS_SECRET_ACCESS_KEY": encoded(source_secret),
        "AWS_ENDPOINT_URL": encoded(endpoint),
        "AWS_REGION": encoded(region),
        "AWS_S3_FORCE_PATH_STYLE": encoded(str(force_path_style).lower()),
    }
    publish_consumer_secret(rsp, principal, namespace, data)
    rsp.desired.resources[observer_key].ready = fnv1.READY_TRUE
