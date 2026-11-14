# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import (
    credential_suffixes,
    kubernetes_object,
    storage_provider_config_name,
    to_dict,
)


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    meta = xr.get("metadata", {}) or {}
    spec = xr.get("spec", {}) or {}
    principal = (spec.get("principal") or meta.get("name") or "").strip()
    provider_identity = (spec.get("providerIdentity") or principal).strip()
    ns = meta.get("namespace") or "default"
    if not principal:
        return

    suffixes = credential_suffixes(req)

    for suf in suffixes:
        user_name = f"provider-storage-managed-{provider_identity}{suf}"
        resource_name = f"{principal}{suf}"
        key = f"user-{resource_name}"
        rsp.desired.resources[key].resource.update(
            kubernetes_object(
                key,
                ns,
                {
                    "apiVersion": "identity.opentelekomcloud.crossplane.io/v1alpha1",
                    "kind": "UserV3",
                    "metadata": {"name": user_name},
                    "spec": {
                        "forProvider": {
                            "name": user_name,
                            "enabled": True,
                            "accessType": "programmatic",
                        },
                        "providerConfigRef": {
                            "name": storage_provider_config_name(req, "provider-otc")
                        },
                    },
                },
                readiness={"policy": "DeriveFromObject"},
            )
        )
