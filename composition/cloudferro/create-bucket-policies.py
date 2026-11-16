# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

import json
import re

from crossplane.function import request, response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import credential_suffixes, to_dict


def statements(bucket, project_id, permission):
    principal = {"AWS": f"arn:aws:iam::{project_id}:root"}
    bucket_actions = [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads",
    ]
    object_actions = ["s3:ListMultipartUploadParts"]
    if permission in ("ReadOnly", "ReadWrite"):
        object_actions.append("s3:GetObject")
    if permission in ("WriteOnly", "ReadWrite"):
        object_actions.extend(
            ["s3:AbortMultipartUpload", "s3:DeleteObject", "s3:PutObject"]
        )
    return [
        {
            "Effect": "Allow",
            "Principal": principal,
            "Action": sorted(bucket_actions),
            "Resource": f"arn:aws:s3:::{bucket}",
        },
        {
            "Effect": "Allow",
            "Principal": principal,
            "Action": sorted(object_actions),
            "Resource": f"arn:aws:s3:::{bucket}/*",
        },
    ]


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    metadata = xr.get("metadata") or {}
    spec = xr.get("spec") or {}
    namespace = metadata.get("namespace") or "default"
    principal = (spec.get("principal") or metadata.get("name") or "").strip()
    generation = f"{principal}{credential_suffixes(req)[0]}"
    own_buckets = {
        (item.get("bucketName") or "").strip()
        for item in (spec.get("buckets") or [])
        if (item.get("bucketName") or "").strip()
    }
    active = [
        grant
        for grant in (spec.get("bucketAccessGrants") or [])
        if (grant.get("bucketName") or "").strip() in own_buckets
        and (grant.get("grantee") or "").strip()
        and (grant.get("permission") or "None")
        in ("ReadOnly", "WriteOnly", "ReadWrite")
    ]
    if not principal or not active:
        return

    response.require_resources(
        rsp,
        name="cloudferro-grantee-storages",
        api_version="pkg.internal/v1beta1",
        kind="Storage",
        namespace=namespace,
        match_labels={"storages.pkg.internal/discoverable": "true"},
    )
    peer_storages = (
        request.get_required_resources(req, "cloudferro-grantee-storages") or []
    )
    if not peer_storages:
        return

    environments = {}
    for grantee in sorted({(grant.get("grantee") or "").strip() for grant in active}):
        matches = [
            peer
            for peer in peer_storages
            if ((peer.get("spec") or {}).get("principal") or "").strip() == grantee
        ]
        if not matches:
            return
        if len(matches) != 1:
            response.fatal(
                rsp,
                f"CloudFerro grantee principal {grantee} must identify one discoverable Storage.",
            )
            return
        peer = matches[0]
        peer_metadata = peer.get("metadata") or {}
        peer_spec = peer.get("spec") or {}
        peer_provider = (
            ((peer_spec.get("crossplane") or {}).get("compositionSelector") or {}).get(
                "matchLabels"
            )
            or {}
        ).get("provider")
        if peer_provider != "cloudferro":
            response.fatal(
                rsp,
                f"CloudFerro grantee principal {grantee} does not use the cloudferro backend.",
            )
            return
        environments[grantee] = [
            name
            for name in (
                "default",
                ((peer_spec.get("crossplane") or {}).get("compositionRef") or {}).get(
                    "name", "storage-cloudferro"
                ),
                peer_spec.get("environmentName"),
                peer_metadata["name"],
            )
            if name
        ]

    configs = {}
    pending = False
    for env_name in sorted({name for names in environments.values() for name in names}):
        key = f"cloudferro-grantee-environment-{env_name}"
        response.require_resources(
            rsp,
            name=key,
            api_version="apiextensions.crossplane.io/v1beta1",
            kind="EnvironmentConfig",
            match_name=env_name,
        )
        if key not in req.required_resources:
            pending = True
            continue
        environment = request.get_required_resource(req, key) or {}
        configs[env_name] = (environment.get("data") or {}).get("storage") or {}
    if pending:
        return

    projects = {}
    for grantee, names in environments.items():
        project_id = ""
        for name in names:
            if "projectId" in configs[name]:
                project_id = (configs[name]["projectId"] or "").strip()
        if not re.fullmatch(r"[0-9a-f]{32}", project_id):
            response.fatal(
                rsp,
                f"CloudFerro grantee {grantee} must have a valid environment projectId.",
            )
            return
        projects[grantee] = project_id

    by_bucket = {}
    for grant in active:
        bucket = (grant.get("bucketName") or "").strip()
        grantee = (grant.get("grantee") or "").strip()
        permission = (grant.get("permission") or "None").strip()
        by_bucket.setdefault(bucket, []).extend(
            statements(bucket, projects[grantee], permission)
        )

    for bucket, bucket_statements in sorted(by_bucket.items()):
        key = f"bucketpolicy-{bucket}"
        policy = {"Version": "2012-10-17", "Statement": bucket_statements}
        rsp.desired.resources[key].resource.update(
            {
                "apiVersion": "s3.aws.m.upbound.io/v1beta1",
                "kind": "BucketPolicy",
                "metadata": {
                    "name": key,
                    "namespace": namespace,
                    "annotations": {"crossplane.io/composition-resource-name": key},
                },
                "spec": {
                    "forProvider": {
                        "bucket": bucket,
                        "region": "us-east-1",
                        "policy": json.dumps(
                            policy, separators=(",", ":"), sort_keys=True
                        ),
                    },
                    "providerConfigRef": {
                        "name": f"cloudferro-s3-{principal}",
                        "kind": "ProviderConfig",
                    },
                },
            }
        )
        usage_key = f"usage-{key}"
        rsp.desired.resources[usage_key].ready = fnv1.READY_TRUE
        rsp.desired.resources[usage_key].resource.update(
            {
                "apiVersion": "protection.crossplane.io/v1beta1",
                "kind": "Usage",
                "metadata": {
                    "name": usage_key,
                    "namespace": namespace,
                    "annotations": {
                        "crossplane.io/composition-resource-name": usage_key
                    },
                },
                "spec": {
                    "replayDeletion": True,
                    "of": {
                        "apiVersion": "kubernetes.m.crossplane.io/v1alpha1",
                        "kind": "Object",
                        "resourceRef": {"name": f"cloudferro-s3-{principal}"},
                    },
                    "by": {
                        "apiVersion": "s3.aws.m.upbound.io/v1beta1",
                        "kind": "BucketPolicy",
                        "resourceRef": {"name": key},
                    },
                },
            }
        )
        credential_usage_key = f"usage-credential-{key}"
        rsp.desired.resources[credential_usage_key].ready = fnv1.READY_TRUE
        rsp.desired.resources[credential_usage_key].resource.update(
            {
                "apiVersion": "protection.crossplane.io/v1beta1",
                "kind": "Usage",
                "metadata": {
                    "name": credential_usage_key,
                    "namespace": namespace,
                    "annotations": {
                        "crossplane.io/composition-resource-name": credential_usage_key
                    },
                },
                "spec": {
                    "replayDeletion": True,
                    "of": {
                        "apiVersion": "identity.openstack.m.crossplane.io/v1alpha1",
                        "kind": "EC2CredentialV3",
                        "resourceRef": {"name": generation},
                    },
                    "by": {
                        "apiVersion": "s3.aws.m.upbound.io/v1beta1",
                        "kind": "BucketPolicy",
                        "resourceRef": {"name": key},
                    },
                },
            }
        )
