# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import _b64, to_dict

ENVIRONMENT_KEY = "apiextensions.crossplane.io/environment"


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

    observed_resources = getattr(req.observed, "resources", {}) or {}
    obs_key = f"observe-secret-{principal}"
    oc = observed_resources.get(obs_key)

    if not oc or not getattr(oc, "resource", None):
        return

    od = to_dict(oc.resource)
    st = od.get("status") or {}
    manifest = (st.get("atProvider") or {}).get("manifest") or {}
    data = manifest.get("data") or {}
    if not isinstance(data, dict) or not data:
        return

    access_key = data.get("AWS_ACCESS_KEY_ID")
    secret_key = data.get("AWS_SECRET_ACCESS_KEY")
    if not access_key or not secret_key:
        return
    secret_data = {
        "AWS_ACCESS_KEY_ID": access_key,
        "AWS_SECRET_ACCESS_KEY": secret_key,
    }

    endpoint = (storage_env.get("endpoint") or "").strip()
    region = (storage_env.get("region") or "").strip()
    force_path_style = storage_env.get("force_path_style")
    if endpoint:
        secret_data["AWS_ENDPOINT_URL"] = _b64(endpoint)
    if region:
        secret_data["AWS_REGION"] = _b64(region)
    if force_path_style not in (None, ""):
        secret_data["AWS_S3_FORCE_PATH_STYLE"] = _b64(force_path_style)

    key = f"secret-{principal}"
    secret_name = f"{principal}"
    rsp.desired.resources[key].resource.update(
        {
            "apiVersion": "kubernetes.m.crossplane.io/v1alpha1",
            "kind": "Object",
            "metadata": {
                "name": key,
                "namespace": ns,
                "annotations": {
                    "crossplane.io/composition-resource-name": key,
                },
            },
            "spec": {
                "forProvider": {
                    "manifest": {
                        "apiVersion": "v1",
                        "kind": "Secret",
                        "metadata": {
                            "name": secret_name,
                            "namespace": ns,
                        },
                        "type": "Opaque",
                        "data": secret_data,
                    }
                },
                "providerConfigRef": {
                    "name": "provider-kubernetes",
                    "kind": "ProviderConfig",
                },
            },
        }
    )
