# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

"""Check integration access scenarios and authorization-denial classification."""

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import yaml

BACKENDS = sys.argv[1:] or ("minio", "aws", "otc", "ovh", "cloudferro")
sys.argv[1:] = []
MANIFESTS = Path(__file__).parent / "manifests/storages"


class AccessScenarioTests(unittest.TestCase):
    def test_owner_and_requester_match_the_access_matrix(self):
        for backend in BACKENDS:
            with self.subTest(backend=backend):
                prefix = {
                    "minio": "minio-default",
                    "aws": "aws-example",
                    "otc": "otc-example",
                }.get(backend, f"{backend}-0123456789ab")
                second_prefix = (
                    "cloudferro-fedcba987654" if backend == "cloudferro" else prefix
                )
                buckets = [f"{prefix}-it-{letter}" for letter in "abcd"]
                second_bucket = f"{second_prefix}-it2-a"
                values = {
                    f"{backend.upper()}_BUCKET_{letter.upper()}": bucket
                    for letter, bucket in zip("abcd", buckets)
                }
                values.update(
                    {
                        f"{backend.upper()}_BUCKET_IT2_A": second_bucket,
                        "OVH_PROJECT_PREFIX": "0123456789ab",
                        "CLOUDFERRO_PROJECT_ID": "0123456789abcdef0123456789abcdef",
                        "CLOUDFERRO_PROJECT_PREFIX": "0123456789ab",
                        "CLOUDFERRO_IT2_PROJECT_ID": "fedcba9876543210fedcba9876543210",
                        "CLOUDFERRO_IT2_PROJECT_PREFIX": "fedcba987654",
                    }
                )
                content = (MANIFESTS / f"{backend}.yaml").read_text()
                for key, value in values.items():
                    content = content.replace(f"__{key}__", value)
                resources = list(yaml.safe_load_all(content))
                self.assertEqual(len(resources), 2)
                owner, requester = resources
                for resource, role, owned in (
                    (owner, "it", buckets),
                    (requester, "it2", [second_bucket]),
                ):
                    metadata, spec = resource["metadata"], resource["spec"]
                    self.assertEqual(
                        (resource["apiVersion"], resource["kind"]),
                        ("pkg.internal/v1beta1", "Storage"),
                    )
                    self.assertEqual(metadata["name"], f"storage-{backend}-{role}")
                    self.assertEqual(metadata["namespace"], "provider-storage-it")
                    self.assertEqual(
                        metadata["annotations"]["storages.pkg.internal/environment"],
                        f"storage-{backend}",
                    )
                    self.assertEqual(
                        spec["crossplane"]["compositionSelector"]["matchLabels"][
                            "provider"
                        ],
                        backend,
                    )
                    self.assertEqual(
                        spec["principal"], f"provider-storage-{backend}-{role}"
                    )
                    self.assertEqual(spec["providerIdentity"], role)
                    self.assertEqual(
                        [bucket["bucketName"] for bucket in spec["buckets"]], owned
                    )
                self.assertEqual(
                    [
                        (grant["bucketName"], grant["grantee"], grant["permission"])
                        for grant in owner["spec"]["bucketAccessGrants"]
                    ],
                    [
                        (buckets[1], f"provider-storage-{backend}-it2", "ReadOnly"),
                        (buckets[2], f"provider-storage-{backend}-it2", "None"),
                    ],
                )
                self.assertEqual(
                    [
                        request["bucketName"]
                        for request in requester["spec"]["bucketAccessRequests"]
                    ],
                    buckets[1:],
                )
                self.assertFalse(owner["spec"].get("bucketAccessRequests"))
                self.assertFalse(requester["spec"].get("bucketAccessGrants"))


class S3DenialTests(unittest.TestCase):
    def test_only_authorization_denial_satisfies_negative_probes(self):
        manifest = yaml.safe_load((MANIFESTS.parent / "jobs/access.yaml").read_text())
        script = manifest["spec"]["template"]["spec"]["containers"][0]["command"][-1]

        class ClientError(Exception):
            def __init__(self, operation, code="AccessDenied", status=403, message=None):
                self.operation_name = operation
                self.response = {
                    "Error": {"Code": code, "Message": message},
                    "ResponseMetadata": {"HTTPStatusCode": status},
                }

        operations = {
            "list_objects_v2": "ListObjectsV2", "get_object": "GetObject",
            "put_object": "PutObject", "delete_object": "DeleteObject",
        }
        environment = {
            "TEST_PHASE": "deny",
            "AWS_ACCESS_KEY_ID": "test-access",
            "AWS_SECRET_ACCESS_KEY": "test-secret",
            "AWS_REGION": "test-region",
        }
        for method, operation in operations.items():
            cases = [
                ("empty message", ClientError(operation), True),
                ("message", ClientError(operation, message="denied"), True),
                ("success", None, False),
                ("network", ConnectionError("test-secret"), False),
                ("wrong operation", ClientError("HeadObject"), False),
                ("wrong status", ClientError(operation, status=500), False),
            ]
            cases.extend(
                (code, ClientError(operation, code=code), False)
                for code in (
                    "InvalidAccessKeyId", "SignatureDoesNotMatch", "ExpiredToken",
                    "NoSuchKey", "NoSuchBucket",
                )
            )
            for name, error, expected in cases:
                client = SimpleNamespace(**{
                    method: Mock(side_effect=ClientError(operation))
                    for method, operation in operations.items()
                })
                getattr(client, method).side_effect = error
                modules = {
                    "os": SimpleNamespace(environ=environment, getenv=environment.get),
                    "boto3": SimpleNamespace(client=lambda *args, **kwargs: client),
                    "botocore.config": SimpleNamespace(Config=lambda **kwargs: None),
                    "botocore.exceptions": SimpleNamespace(ClientError=ClientError),
                }
                with self.subTest(operation=operation, error=name), patch.dict(sys.modules, modules):
                    if expected:
                        exec(script, {})
                    else:
                        with self.assertRaises(SystemExit) as failure:
                            exec(script, {})
                        self.assertNotIn("test-secret", str(failure.exception))


if __name__ == "__main__":
    unittest.main()
