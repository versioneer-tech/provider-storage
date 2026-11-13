# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from crossplane.function import request, response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import _bucket_grants_access, credential_suffixes, to_dict


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    meta = xr.get("metadata", {}) or {}
    spec = xr.get("spec", {}) or {}
    ns = meta.get("namespace") or "default"
    principal = (spec.get("principal") or meta.get("name") or "<principal>").strip()
    provider_identity = (spec.get("providerIdentity") or principal).strip()
    # Peer Storage objects are loaded by a discoverable label so request resolution can inspect grants.
    response.require_resources(
        rsp,
        name="peer-storages",
        api_version="pkg.internal/v1beta1",
        kind="Storage",
        namespace=ns,
        match_labels={"storages.pkg.internal/discoverable": "true"},
    )
    peer_storages = request.get_required_resources(req, "peer-storages") or []
    suffixes = credential_suffixes(req)
    user_names = (
        [f"{provider_identity}{suf}" for suf in suffixes]
        if suffixes
        else [provider_identity]
    )

    for user_name in user_names:
        for b in spec.get("buckets") or []:
            bucket = (b.get("bucketName") or "").strip()
            if not bucket:
                continue
            polname = f"provider-storage.{bucket}"
            key = f"upa-own-{user_name}-{bucket}"
            rsp.desired.resources[key].resource.update(
                {
                    "apiVersion": "iam.aws.m.upbound.io/v1beta1",
                    "kind": "UserPolicyAttachment",
                    "metadata": {
                        "name": f"{user_name}.{bucket}.own",
                        "namespace": ns,
                        "annotations": {"crossplane.io/composition-resource-name": key},
                    },
                    "spec": {
                        "forProvider": {
                            "userRef": {"name": user_name},
                            "policyArnRef": {"name": polname},
                        },
                        "providerConfigRef": {
                            "name": "provider-aws",
                            "kind": "ProviderConfig",
                        },
                    },
                }
            )

        for r in spec.get("bucketAccessRequests") or []:
            bucket = (r.get("bucketName") or "").strip()
            if not bucket:
                continue
            polname = f"provider-storage.{principal}.{bucket}"
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
            if not granted:
                continue
            key = f"upa-req-{user_name}-{bucket}"
            rsp.desired.resources[key].resource.update(
                {
                    "apiVersion": "iam.aws.m.upbound.io/v1beta1",
                    "kind": "UserPolicyAttachment",
                    "metadata": {
                        "name": f"{user_name}.{bucket}.req",
                        "namespace": ns,
                        "annotations": {"crossplane.io/composition-resource-name": key},
                    },
                    "spec": {
                        "forProvider": {
                            "userRef": {"name": user_name},
                            "policyArnRef": {"name": polname},
                        },
                        "providerConfigRef": {
                            "name": "provider-aws",
                            "kind": "ProviderConfig",
                        },
                    },
                }
            )
