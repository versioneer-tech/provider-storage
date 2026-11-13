# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

import json

from crossplane.function import request, response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import rollover_suffixes, to_dict

ENVIRONMENT_KEY = "apiextensions.crossplane.io/environment"
API_VERSION = "cloud.ovh.m.edixos.io/v1alpha1"


def managed(rsp, key, kind, name, namespace, for_provider, **spec_fields):
    rsp.desired.resources[key].resource.update(
        {
            "apiVersion": API_VERSION,
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": namespace,
                "annotations": {"crossplane.io/composition-resource-name": key},
            },
            "spec": {
                "forProvider": for_provider,
                "providerConfigRef": {"name": "provider-ovh", "kind": "ProviderConfig"},
                **spec_fields,
            },
        }
    )


def policy_statements(bucket, permission, effect):
    bucket_arn = f"arn:aws:s3:::{bucket}"
    object_arn = f"{bucket_arn}/*"
    if effect == "Deny":
        return [
            {"Effect": "Deny", "Action": ["s3:*"], "Resource": [bucket_arn, object_arn]}
        ]
    bucket_actions = [
        "s3:GetBucketAcl",
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads",
    ]
    object_actions = ["s3:ListMultipartUploadParts"]
    if permission in ("ReadOnly", "ReadWrite"):
        object_actions.extend(
            ["s3:GetObject", "s3:GetObjectAcl", "s3:GetObjectAttributes"]
        )
    if permission in ("WriteOnly", "ReadWrite"):
        object_actions.extend(
            ["s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
        )
    return [
        {
            "Effect": "Allow",
            "Action": sorted(bucket_actions + object_actions),
            "Resource": [bucket_arn, object_arn],
        }
    ]


def grant_from_peer(peer, bucket, grantee):
    peer_spec = peer.get("spec") or {}
    if not any(
        (item.get("bucketName") or "").strip() == bucket
        for item in (peer_spec.get("buckets") or [])
    ):
        return None
    for grant in peer_spec.get("bucketAccessGrants") or []:
        if (grant.get("bucketName") or "").strip() == bucket and (
            grant.get("grantee") or ""
        ).strip() == grantee:
            return (grant.get("permission") or "None").strip()
    return "None"


def ready_user_id(observed, key):
    item = observed.get(key)
    if item is None or not getattr(item, "resource", None):
        return None
    data = to_dict(item.resource)
    ready = any(
        condition.get("type") == "Ready" and condition.get("status") == "True"
        for condition in ((data.get("status") or {}).get("conditions") or [])
    )
    value = ((data.get("status") or {}).get("atProvider") or {}).get("id")
    if not ready or not isinstance(value, str) or not value.isdecimal():
        return None
    number = int(value)
    return number if 0 < number <= 9007199254740991 else None


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    metadata = xr.get("metadata") or {}
    spec = xr.get("spec") or {}
    namespace = metadata.get("namespace") or "default"
    principal = (spec.get("principal") or metadata.get("name") or "").strip()
    identity = (spec.get("providerIdentity") or principal).strip()
    context = to_dict(req.context)
    storage_env = (context.get(ENVIRONMENT_KEY) or {}).get("storage") or {}
    project = (storage_env.get("serviceName") or "").strip()
    s3_region = (storage_env.get("region") or "").strip().lower()
    if not principal or not project or not s3_region:
        return
    region_name = s3_region.upper()

    response.require_resources(
        rsp,
        name="peer-storages",
        api_version="pkg.internal/v1beta1",
        kind="Storage",
        namespace=namespace,
        match_labels={"storages.pkg.internal/discoverable": "true"},
    )
    peers = request.get_required_resources(req, "peer-storages") or []
    observed = req.observed.resources
    owner_key = f"owner-{principal}"
    managed(
        rsp,
        owner_key,
        "User",
        f"{identity}-owner",
        namespace,
        {
            "description": f"Stable owner for {identity}",
            "roleNames": ["objectstore_operator"],
            "serviceName": project,
        },
        managementPolicies=["Observe", "Create", "Update", "LateInitialize"],
    )

    numeric_owner = ready_user_id(observed, owner_key)
    own_buckets = sorted(
        {
            (item.get("bucketName") or "").strip()
            for item in (spec.get("buckets") or [])
            if (item.get("bucketName") or "").strip()
        }
    )
    for bucket in own_buckets:
        if numeric_owner is None:
            continue
        key = f"bucket-{bucket}"
        managed(
            rsp,
            key,
            "ProjectStorage",
            bucket,
            namespace,
            {
                "serviceName": project,
                "name": bucket,
                "regionName": region_name,
                "ownerId": numeric_owner,
                "hideObjects": True,
            },
        )

    requested = sorted(
        {
            (item.get("bucketName") or "").strip()
            for item in (spec.get("bucketAccessRequests") or [])
            if (item.get("bucketName") or "").strip()
        }
    )
    statements = [
        {"Effect": "Deny", "Action": ["s3:ListAllMyBuckets"], "Resource": ["*"]}
    ]
    for bucket in own_buckets:
        statements.extend(policy_statements(bucket, "ReadWrite", "Allow"))
    for bucket in requested:
        if bucket in own_buckets:
            continue
        matches = []
        for peer in peers:
            peer_meta = peer.get("metadata") or {}
            if (peer_meta.get("namespace") or namespace) != namespace or peer_meta.get(
                "name"
            ) == metadata.get("name"):
                continue
            grant = grant_from_peer(peer, bucket, principal)
            if grant is not None:
                matches.append(grant)
        permission = matches[0] if len(matches) == 1 else "None"
        if permission in ("ReadOnly", "WriteOnly", "ReadWrite"):
            statements.extend(policy_statements(bucket, permission, "Allow"))
        else:
            statements.extend(policy_statements(bucket, "None", "Deny"))
    policy = json.dumps(
        {"Statement": statements}, separators=(",", ":"), sort_keys=True
    )

    suffixes = rollover_suffixes(spec)
    current = f"{principal}{suffixes[0]}"
    current_dependent_name = None
    for suffix in suffixes:
        generation = f"{principal}{suffix}"
        user_key = f"user-{generation}"
        user_name = f"{identity}{suffix}"
        managed(
            rsp,
            user_key,
            "User",
            user_name,
            namespace,
            {
                "description": f"Credential generation for {identity}{suffix}",
                "roleNames": ["objectstore_operator"],
                "serviceName": project,
            },
        )
        numeric_user = ready_user_id(observed, user_key)
        if numeric_user is None:
            continue
        dependent_name = f"{generation}-u{numeric_user}"
        managed(
            rsp,
            f"credentials-{dependent_name}",
            "S3Credentials",
            dependent_name,
            namespace,
            {
                "serviceName": project,
                "userId": str(numeric_user),
            },
            writeConnectionSecretToRef={"name": f"{dependent_name}-credentials"},
        )
        managed(
            rsp,
            f"policy-{dependent_name}",
            "S3Policy",
            dependent_name,
            namespace,
            {
                "serviceName": project,
                "policy": policy,
                "userId": str(numeric_user),
            },
        )
        if generation == current:
            current_dependent_name = dependent_name

    if current_dependent_name is not None:
        observer_key = f"observe-secret-{current_dependent_name}"
        rsp.desired.resources[observer_key].ready = fnv1.READY_FALSE
        rsp.desired.resources[observer_key].resource.update(
            {
                "apiVersion": "kubernetes.m.crossplane.io/v1alpha1",
                "kind": "Object",
                "metadata": {
                    "name": observer_key,
                    "namespace": namespace,
                    "annotations": {
                        "crossplane.io/composition-resource-name": observer_key
                    },
                },
                "spec": {
                    "managementPolicies": ["Observe"],
                    "forProvider": {
                        "manifest": {
                            "apiVersion": "v1",
                            "kind": "Secret",
                            "metadata": {
                                "name": f"{current_dependent_name}-credentials",
                                "namespace": namespace,
                            },
                        }
                    },
                    "providerConfigRef": {
                        "name": "provider-kubernetes",
                        "kind": "ProviderConfig",
                    },
                },
            }
        )
