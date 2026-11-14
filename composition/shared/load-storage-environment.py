# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from datetime import datetime, timezone

from crossplane.function import request, resource, response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import rollover_suffixes, storage_environment_name, to_dict

ENVIRONMENT_KEY = "apiextensions.crossplane.io/environment"


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    meta = xr.get("metadata", {}) or {}
    context = to_dict(req.context)
    time_key = "storages.pkg.internal/credential-time"
    generations_key = "storages.pkg.internal/credential-generations"
    timestamp = context.get(time_key) or datetime.now(timezone.utc).isoformat()
    suffixes = context.get(generations_key) or rollover_suffixes(
        xr.get("spec") or {}, datetime.fromisoformat(timestamp)
    )
    rsp.context.MergeFrom(
        resource.dict_to_struct({time_key: timestamp, generations_key: suffixes})
    )
    env_name = storage_environment_name(
        meta, to_dict(req.input)["environmentConfigName"]
    )

    response.require_resources(
        rsp,
        name="storage-environment",
        api_version="apiextensions.crossplane.io/v1beta1",
        kind="EnvironmentConfig",
        match_name=env_name,
    )

    environment = request.get_required_resource(req, "storage-environment") or {}
    environment_data = environment.get("data") or {}
    rsp.context.MergeFrom(resource.dict_to_struct({ENVIRONMENT_KEY: environment_data}))
