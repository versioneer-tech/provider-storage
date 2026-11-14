# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import (
    credential_suffixes,
    extract_ids,
    kubernetes_object,
    storage_provider_config_name,
    to_dict,
)


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    meta = xr.get("metadata", {}) or {}
    spec = xr.get("spec", {}) or {}
    ns = meta.get("namespace") or "default"
    principal = (spec.get("principal") or meta.get("name") or "").strip()
    if not principal:
        return

    suffixes = credential_suffixes(req)

    observed = req.observed.resources

    for suf in suffixes:
        user_name = f"{principal}{suf}"
        connection_secret_name = user_name if suf else f"{principal}-credentials"
        wrapper = observed.get(f"user-{user_name}")
        user_id = None
        if wrapper is not None:
            od = to_dict(wrapper.resource)
            user_id, _ = extract_ids(od)
        if not user_id:
            continue

        key = f"access-key-{user_name}"
        rsp.desired.resources[key].resource.update(
            kubernetes_object(
                key,
                ns,
                {
                    "apiVersion": "identity.opentelekomcloud.crossplane.io/v1alpha1",
                    "kind": "CredentialV3",
                    "metadata": {"name": f"aksk-{user_name}"},
                    "spec": {
                        "forProvider": {"userId": user_id},
                        "providerConfigRef": {
                            "name": storage_provider_config_name(req, "provider-otc")
                        },
                        "writeConnectionSecretToRef": {
                            "name": connection_secret_name,
                            "namespace": ns,
                        },
                    },
                },
                readiness={"policy": "DeriveFromObject"},
            )
        )
