# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from datetime import datetime, timezone

from crossplane.function import request, response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import _get_rollover, _suffixes, to_dict


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    meta = xr.get("metadata", {}) or {}
    spec = xr.get("spec", {}) or {}
    ns = meta.get("namespace") or "default"
    principal = (spec.get("principal") or meta.get("name") or "").strip()
    if not principal:
        return

    interval, max_to_keep = _get_rollover(spec)
    now = datetime.now(timezone.utc)
    suffixes = _suffixes(now, interval, max_to_keep)
    current_user_name = f"{principal}{suffixes[0] if suffixes else ''}"
    current_secret_name = (
        current_user_name if suffixes and suffixes[0] else f"{principal}-credentials"
    )

    key = f"observe-secret-{principal}"
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

    grantees = []
    for g in spec.get("bucketAccessGrants") or []:
        gr = (g.get("grantee") or "").strip()
        if gr and gr not in grantees:
            grantees.append(gr)

    grantee_users = {}
    if grantees:
        response.require_resources(
            rsp,
            name="grantee-storages",
            api_version="pkg.internal/v1beta1",
            kind="Storage",
            namespace=ns,
            match_labels={"storages.pkg.internal/discoverable": "true"},
        )
        peers = request.get_required_resources(req, "grantee-storages") or []
        if not peers:
            grantee_users.update({gr: gr for gr in grantees})
        else:
            for gr in grantees:
                matches = [
                    peer
                    for peer in peers
                    if ((peer.get("spec") or {}).get("principal") or "").strip() == gr
                ]
                if not matches:
                    return
                if len(matches) != 1:
                    response.fatal(
                        rsp,
                        f"OTC grantee principal {gr} must identify one discoverable Storage.",
                    )
                    return
                peer_spec = matches[0].get("spec") or {}
                peer_identity = (peer_spec.get("providerIdentity") or gr).strip()
                peer_interval, peer_max_to_keep = _get_rollover(peer_spec)
                peer_suffixes = _suffixes(now, peer_interval, peer_max_to_keep)
                peer_suffix = peer_suffixes[0] if peer_suffixes else ""
                grantee_users[gr] = (
                    f"provider-storage-managed-{peer_identity}{peer_suffix}"
                )

    for gr in grantees:
        key = f"observe-user-{gr}"
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
                    "managementPolicies": ["Observe"],
                    "forProvider": {
                        "manifest": {
                            "apiVersion": "identity.opentelekomcloud.crossplane.io/v1alpha1",
                            "kind": "UserV3",
                            "metadata": {"name": grantee_users[gr]},
                        }
                    },
                    "providerConfigRef": {
                        "name": "provider-kubernetes",
                        "kind": "ProviderConfig",
                    },
                },
            }
        )
