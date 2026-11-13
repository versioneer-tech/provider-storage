# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from datetime import datetime, timezone

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import _get_rollover, _suffixes, to_dict


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    meta = xr.get("metadata", {}) or {}
    spec = xr.get("spec", {}) or {}
    principal = (spec.get("principal") or meta.get("name") or "").strip()
    provider_identity = (spec.get("providerIdentity") or principal).strip()
    ns = meta.get("namespace") or "default"
    if not principal:
        return

    interval, max_to_keep = _get_rollover(spec)
    now = datetime.now(timezone.utc)
    suffixes = _suffixes(now, interval, max_to_keep)

    for suf in suffixes:
        user_name = f"provider-storage-managed-{provider_identity}{suf}"
        resource_name = f"{principal}{suf}"
        key = f"user-{resource_name}"
        rsp.desired.resources[key].resource.update(
            {
                "apiVersion": "kubernetes.m.crossplane.io/v1alpha1",
                "kind": "Object",
                "metadata": {
                    "name": key,
                    "namespace": ns,
                    "annotations": {"crossplane.io/composition-resource-name": key},
                },
                "spec": {
                    "forProvider": {
                        "manifest": {
                            "apiVersion": "identity.opentelekomcloud.crossplane.io/v1alpha1",
                            "kind": "UserV3",
                            "metadata": {"name": user_name},
                            "spec": {
                                "forProvider": {
                                    "name": user_name,
                                    "enabled": True,
                                    "accessType": "programmatic",
                                },
                                "providerConfigRef": {"name": "provider-otc"},
                            },
                        }
                    },
                    "readiness": {"policy": "DeriveFromObject"},
                    "providerConfigRef": {
                        "name": "provider-kubernetes",
                        "kind": "ProviderConfig",
                    },
                },
            }
        )
