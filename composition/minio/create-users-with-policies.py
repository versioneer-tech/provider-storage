# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from crossplane.function import request, response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import (
    _bucket_grants_access,
    credential_suffixes,
    kubernetes_object,
    to_dict,
)


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    meta = xr.get("metadata", {}) or {}
    spec = xr.get("spec", {}) or {}
    ns = meta.get("namespace") or "default"

    principal = (
        spec.get("principal") or meta.get("name") or "<principal-missing>"
    ).strip()
    provider_identity = (spec.get("providerIdentity") or principal).strip()
    # Peer Storage objects are loaded by a shared label so request resolution can inspect grants.
    response.require_resources(
        rsp,
        name="peer-storages",
        api_version="pkg.internal/v1beta1",
        kind="Storage",
        namespace=ns,
        match_labels={"storages.pkg.internal/discoverable": "true"},
    )
    peer_storages = request.get_required_resources(req, "peer-storages") or []

    policies = []
    for b in spec.get("buckets") or []:
        bucket = (b.get("bucketName") or "").strip()
        if bucket:
            policies.append(f"provider-storage.{bucket}")

    for r in spec.get("bucketAccessRequests") or []:
        bucket = (r.get("bucketName") or "").strip()
        if not bucket:
            continue
        granted = None
        for peer in peer_storages:
            peer_meta = peer.get("metadata") or {}
            if (peer_meta.get("namespace") or ns) != ns:
                continue
            if (peer_meta.get("name") or "") == meta.get("name"):
                continue
            granted = _bucket_grants_access(peer, bucket, principal)
            if granted is not None:
                break
        if granted:
            policies.append(f"provider-storage.{principal}.{bucket}")

    suffixes = credential_suffixes(req)

    for suf in suffixes:
        user_name = f"provider-storage-managed-{provider_identity}{suf}"
        resource_name = f"{principal}{suf}"
        connection_secret_name = resource_name if suf else f"{principal}-credentials"
        key = f"user-{resource_name}"
        rsp.desired.resources[key].resource.update(
            kubernetes_object(
                key,
                ns,
                {
                    "apiVersion": "minio.crossplane.io/v1",
                    "kind": "User",
                    "metadata": {"name": user_name},
                    "spec": {
                        "forProvider": {"userName": user_name, "policies": policies},
                        "providerConfigRef": {"name": "provider-minio"},
                        "writeConnectionSecretToRef": {
                            "name": connection_secret_name,
                            "namespace": ns,
                        },
                    },
                },
            )
        )

    current_user_name = f"{principal}{suffixes[0] if suffixes else ''}"
    current_secret_name = (
        current_user_name if suffixes and suffixes[0] else f"{principal}-credentials"
    )
    obs_key = f"observe-secret-{principal}"
    rsp.desired.resources[obs_key].ready = fnv1.READY_TRUE
    rsp.desired.resources[obs_key].resource.update(
        kubernetes_object(
            obs_key,
            ns,
            {
                "apiVersion": "v1",
                "kind": "Secret",
                "metadata": {"name": current_secret_name, "namespace": ns},
            },
            managementPolicies=["Observe"],
        )
    )
