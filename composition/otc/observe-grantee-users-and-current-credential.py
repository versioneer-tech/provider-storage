# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from crossplane.function import request, resource, response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import (
    credential_suffixes,
    credential_time,
    kubernetes_object,
    rollover_suffixes,
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
    current_user_name = f"{principal}{suffixes[0] if suffixes else ''}"
    current_secret_name = (
        current_user_name if suffixes and suffixes[0] else f"{principal}-credentials"
    )

    key = f"observe-secret-{principal}"
    rsp.desired.resources[key].resource.update(
        kubernetes_object(
            key,
            ns,
            {
                "apiVersion": "v1",
                "kind": "Secret",
                "metadata": {"name": current_secret_name, "namespace": ns},
            },
            managementPolicies=["Observe"],
        )
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
            grantee_users.update({gr: [("", gr)] for gr in grantees})
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
                peer_suffixes = rollover_suffixes(peer_spec, credential_time(req))
                grantee_users[gr] = [
                    (suffix, f"provider-storage-managed-{peer_identity}{suffix}")
                    for suffix in peer_suffixes
                ]

    observers = {}
    for gr in grantees:
        observers[gr] = []
        for suffix, user_name in grantee_users[gr]:
            key = f"observe-user-{gr}{suffix}"
            observers[gr].append(key)
            rsp.desired.resources[key].resource.update(
                kubernetes_object(
                    key,
                    ns,
                    {
                        "apiVersion": "identity.opentelekomcloud.crossplane.io/v1alpha1",
                        "kind": "UserV3",
                        "metadata": {"name": user_name},
                    },
                    managementPolicies=["Observe"],
                )
            )
    rsp.context.MergeFrom(
        resource.dict_to_struct({"storages.pkg.internal/otc-grantee-users": observers})
    )
