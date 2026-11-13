# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from datetime import datetime, timezone

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import _get_rollover, _suffixes, to_dict

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
    interval, max_to_keep = _get_rollover(spec)
    now = datetime.now(timezone.utc)
    suffixes = _suffixes(now, interval, max_to_keep)

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
                        "name": "provider-aws",
                        "kind": "ProviderConfig",
                    },
                },
            }
        )

    current_user_name = f"{principal}{suffixes[0] if suffixes else ''}"
    current_secret_name = (
        current_user_name if suffixes and suffixes[0] else f"{principal}-credentials"
    )
    obs_key = f"observe-secret-{principal}"
    rsp.desired.resources[obs_key].resource.update(
        {
            "apiVersion": "kubernetes.m.crossplane.io/v1alpha1",
            "kind": "Object",
            "metadata": {
                "name": obs_key,
                "namespace": ns,
                "annotations": {"crossplane.io/composition-resource-name": obs_key},
            },
            "spec": {
                "managementPolicies": ["Observe"],
                "forProvider": {
                    "manifest": {
                        "apiVersion": "v1",
                        "kind": "Secret",
                        "metadata": {"name": current_secret_name, "namespace": ns},
                    }
                },
                "providerConfigRef": {
                    "name": "provider-kubernetes",
                    "kind": "ProviderConfig",
                },
            },
        }
    )
