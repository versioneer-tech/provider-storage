# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

import re

from crossplane.function import response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import (
    credential_suffixes,
    storage_provider_config_name,
    to_dict,
)

ENVIRONMENT_KEY = "apiextensions.crossplane.io/environment"


def managed(
    rsp,
    key,
    api_version,
    kind,
    name,
    namespace,
    provider_config_name,
    for_provider,
    **fields,
):
    rsp.desired.resources[key].resource.update(
        {
            "apiVersion": api_version,
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": namespace,
                "annotations": {"crossplane.io/composition-resource-name": key},
            },
            "spec": {
                "forProvider": for_provider,
                "providerConfigRef": {
                    "name": provider_config_name,
                    "kind": "ProviderConfig",
                },
                **fields,
            },
        }
    )


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    metadata = xr.get("metadata") or {}
    spec = xr.get("spec") or {}
    namespace = metadata.get("namespace") or "default"
    principal = (spec.get("principal") or metadata.get("name") or "").strip()
    env = (to_dict(req.context).get(ENVIRONMENT_KEY) or {}).get("storage") or {}
    project_id = (env.get("projectId") or "").strip()
    provider_config_name = storage_provider_config_name(req)
    region = (env.get("region") or "").strip()
    s3_region = (env.get("s3Region") or "").strip()
    if (
        not principal
        or not re.fullmatch(r"[0-9a-f]{32}", project_id)
        or not provider_config_name
        or not region
        or not s3_region
    ):
        response.fatal(
            rsp,
            "CloudFerro environment must define a valid projectId, providerConfigName, region, and s3Region.",
        )
        return
    selected_provider = (
        ((spec.get("crossplane") or {}).get("compositionSelector") or {}).get(
            "matchLabels"
        )
        or {}
    ).get("provider")
    if selected_provider != "cloudferro":
        response.fatal(rsp, "CloudFerro Storage must select provider cloudferro.")
        return

    own_buckets = sorted(
        {
            (b.get("bucketName") or "").strip()
            for b in (spec.get("buckets") or [])
            if (b.get("bucketName") or "").strip()
        }
    )
    for bucket in own_buckets:
        managed(
            rsp,
            f"bucket-{bucket}",
            "objectstorage.openstack.m.crossplane.io/v1alpha1",
            "ContainerV1",
            bucket,
            namespace,
            provider_config_name,
            {
                "name": bucket,
                "region": region,
                "forceDestroy": False,
            },
        )

    for suffix in credential_suffixes(req):
        generation = f"{principal}{suffix}"
        managed(
            rsp,
            f"credentials-{generation}",
            "identity.openstack.m.crossplane.io/v1alpha1",
            "EC2CredentialV3",
            generation,
            namespace,
            provider_config_name,
            {
                "region": region,
            },
            writeConnectionSecretToRef={"name": f"{generation}-credentials"},
        )
