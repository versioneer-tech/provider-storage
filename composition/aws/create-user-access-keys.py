# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from datetime import datetime, timezone

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import _get_rollover, _suffixes, to_dict


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    meta = xr.get("metadata", {}) or {}
    spec = xr.get("spec", {}) or {}
    ns = meta.get("namespace") or "default"
    principal = (spec.get("principal") or meta.get("name") or "<principal>").strip()
    provider_identity = (spec.get("providerIdentity") or principal).strip()

    interval, max_to_keep = _get_rollover(spec)
    now = datetime.now(timezone.utc)
    suffixes = _suffixes(now, interval, max_to_keep)

    for suf in suffixes:
        user_name = f"{provider_identity}{suf}"
        resource_name = f"{principal}{suf}"
        connection_secret_name = resource_name if suf else f"{principal}-credentials"
        key = f"access-key-{resource_name}"
        rsp.desired.resources[key].resource.update(
            {
                "apiVersion": "iam.aws.m.upbound.io/v1beta1",
                "kind": "AccessKey",
                "metadata": {
                    "name": resource_name,
                    "namespace": ns,
                    "annotations": {"crossplane.io/composition-resource-name": key},
                },
                "spec": {
                    "forProvider": {"userRef": {"name": user_name}},
                    "providerConfigRef": {
                        "name": "provider-aws",
                        "kind": "ProviderConfig",
                    },
                    "writeConnectionSecretToRef": {"name": connection_secret_name},
                },
            }
        )
