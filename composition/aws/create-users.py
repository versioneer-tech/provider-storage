# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import (
    credential_suffixes,
    storage_provider_config_name,
    to_dict,
)

ENVIRONMENT_KEY = "apiextensions.crossplane.io/environment"


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    meta = xr.get("metadata", {}) or {}
    spec = xr.get("spec", {}) or {}
    ctx = to_dict(req.context)
    env = ctx.get(ENVIRONMENT_KEY) or {}
    storage_env = env.get("storage") or {}
    iam_env = storage_env.get("iam") or {}
    user_path = (iam_env.get("userPath") or "/provider-storage/managed/").strip()
    ns = meta.get("namespace") or "default"
    principal = (spec.get("principal") or meta.get("name") or "<principal>").strip()
    provider_identity = (spec.get("providerIdentity") or principal).strip()
    suffixes = credential_suffixes(req)

    for suf in suffixes:
        user_name = f"{provider_identity}{suf}"
        resource_name = f"{principal}{suf}"
        key = f"user-{resource_name}"
        rsp.desired.resources[key].resource.update(
            {
                "apiVersion": "iam.aws.m.upbound.io/v1beta1",
                "kind": "User",
                "metadata": {
                    "name": user_name,
                    "namespace": ns,
                    "annotations": {"crossplane.io/composition-resource-name": key},
                },
                "spec": {
                    "forProvider": {"path": user_path},
                    "providerConfigRef": {
                        "name": storage_provider_config_name(req, "provider-aws"),
                        "kind": "ProviderConfig",
                    },
                },
            }
        )
