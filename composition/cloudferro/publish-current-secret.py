# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

from crossplane.function import request, response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1

from composition.helpers import current_suffix, decoded, encoded, to_dict

ENVIRONMENT_KEY = "apiextensions.crossplane.io/environment"


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = to_dict(req.observed.composite.resource)
    metadata = xr.get("metadata") or {}
    spec = xr.get("spec") or {}
    namespace = metadata.get("namespace") or "default"
    principal = (spec.get("principal") or metadata.get("name") or "").strip()
    generation = f"{principal}{current_suffix(spec)}"
    env = (to_dict(req.context).get(ENVIRONMENT_KEY) or {}).get("storage") or {}
    endpoint = (env.get("endpoint") or "").strip()
    region = (env.get("s3Region") or "").strip()
    if not principal or not endpoint or not region:
        return
    secret_key = f"credential-secret-{principal}"
    response.require_resources(
        rsp,
        name=secret_key,
        api_version="v1",
        kind="Secret",
        namespace=namespace,
        match_name=f"{generation}-credentials",
    )
    credential = req.observed.resources.get(f"credentials-{generation}")
    secret = request.get_required_resource(req, secret_key)
    if credential is None or secret is None:
        return
    credential_data = to_dict(credential.resource)
    access = ((credential_data.get("status") or {}).get("atProvider") or {}).get(
        "access"
    )
    secret_data = secret.get("data") or {}
    if not isinstance(access, str) or not access or not isinstance(secret_data, dict):
        return
    source_secret = decoded(
        secret_data.get("attribute.secret") or secret_data.get("secret")
    )
    if not source_secret:
        return
    data = {
        "AWS_ACCESS_KEY_ID": encoded(access),
        "AWS_SECRET_ACCESS_KEY": encoded(source_secret),
        "AWS_ENDPOINT_URL": encoded(endpoint),
        "AWS_REGION": encoded(region),
        "AWS_S3_FORCE_PATH_STYLE": encoded("true"),
    }
    key = f"secret-{principal}"
    rsp.desired.resources[key].resource.update(
        {
            "apiVersion": "kubernetes.m.crossplane.io/v1alpha1",
            "kind": "Object",
            "metadata": {
                "name": key,
                "namespace": namespace,
                "annotations": {"crossplane.io/composition-resource-name": key},
            },
            "spec": {
                "forProvider": {
                    "manifest": {
                        "apiVersion": "v1",
                        "kind": "Secret",
                        "metadata": {"name": principal, "namespace": namespace},
                        "type": "Opaque",
                        "data": data,
                    }
                },
                "providerConfigRef": {
                    "name": "provider-kubernetes",
                    "kind": "ProviderConfig",
                },
            },
        }
    )
    provider_secret = f"{principal}-cloudferro-aws"
    credentials = "\n".join(
        [
            "[default]",
            f"aws_access_key_id={access}",
            f"aws_secret_access_key={source_secret}",
            "",
        ]
    )
    secret_key = f"aws-provider-secret-{principal}"
    rsp.desired.resources[secret_key].resource.update(
        {
            "apiVersion": "kubernetes.m.crossplane.io/v1alpha1",
            "kind": "Object",
            "metadata": {
                "name": secret_key,
                "namespace": namespace,
                "annotations": {"crossplane.io/composition-resource-name": secret_key},
            },
            "spec": {
                "forProvider": {
                    "manifest": {
                        "apiVersion": "v1",
                        "kind": "Secret",
                        "metadata": {"name": provider_secret, "namespace": namespace},
                        "type": "Opaque",
                        "data": {"credentials": encoded(credentials)},
                    }
                },
                "providerConfigRef": {
                    "name": "provider-kubernetes",
                    "kind": "ProviderConfig",
                },
            },
        }
    )
    provider_key = f"aws-provider-config-{principal}"
    provider_name = f"cloudferro-s3-{principal}"
    rsp.desired.resources[provider_key].resource.update(
        {
            "apiVersion": "kubernetes.m.crossplane.io/v1alpha1",
            "kind": "Object",
            "metadata": {
                "name": provider_name,
                "namespace": namespace,
                "annotations": {
                    "crossplane.io/composition-resource-name": provider_key
                },
            },
            "spec": {
                "forProvider": {
                    "manifest": {
                        "apiVersion": "aws.m.upbound.io/v1beta1",
                        "kind": "ProviderConfig",
                        "metadata": {"name": provider_name, "namespace": namespace},
                        "spec": {
                            "credentials": {
                                "source": "Secret",
                                "secretRef": {
                                    "name": provider_secret,
                                    "namespace": namespace,
                                    "key": "credentials",
                                },
                            },
                            "endpoint": {
                                "url": {"type": "Static", "static": endpoint},
                                "services": ["s3"],
                                "source": "Custom",
                                "hostnameImmutable": True,
                                "signingName": "s3",
                                "signingRegion": region,
                            },
                            "s3_use_path_style": True,
                            "skip_credentials_validation": True,
                            "skip_metadata_api_check": True,
                            "skip_region_validation": True,
                            "skip_requesting_account_id": True,
                        },
                    }
                },
                "readiness": {"policy": "SuccessfulCreate"},
                "providerConfigRef": {
                    "name": "provider-kubernetes",
                    "kind": "ProviderConfig",
                },
            },
        }
    )
    usage_key = f"usage-aws-provider-{principal}"
    rsp.desired.resources[usage_key].ready = fnv1.READY_TRUE
    rsp.desired.resources[usage_key].resource.update(
        {
            "apiVersion": "protection.crossplane.io/v1beta1",
            "kind": "Usage",
            "metadata": {
                "name": usage_key,
                "namespace": namespace,
                "annotations": {"crossplane.io/composition-resource-name": usage_key},
            },
            "spec": {
                "replayDeletion": True,
                "of": {
                    "apiVersion": "kubernetes.m.crossplane.io/v1alpha1",
                    "kind": "Object",
                    "resourceRef": {"name": secret_key},
                },
                "by": {
                    "apiVersion": "kubernetes.m.crossplane.io/v1alpha1",
                    "kind": "Object",
                    "resourceRef": {"name": provider_name},
                },
            },
        }
    )
