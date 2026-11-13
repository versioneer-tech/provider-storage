# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

"""Keep the integration inputs consistent with the access checks."""

import sys
import unittest
from pathlib import Path

import yaml

BACKENDS = sys.argv[1:] or ("minio", "aws", "otc", "ovh", "cloudferro")
sys.argv[1:] = []
MANIFESTS = Path(__file__).parent / "manifests/storages"


class StorageScenarioTests(unittest.TestCase):
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
                        metadata["labels"]["storages.pkg.internal/backend"], backend
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


if __name__ == "__main__":
    unittest.main()
