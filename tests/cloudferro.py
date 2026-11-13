# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

"""Check project binding, credential publication, and deletion dependencies."""

import base64
import json
import sys
import unittest
from pathlib import Path

import yaml

BASE, READY, SECOND = [
    list(yaml.safe_load_all(Path(path).read_text())) for path in sys.argv[1:]
]
sys.argv[1:] = []
FIRST_PROJECT = "0123456789abcdef0123456789abcdef"
SECOND_PROJECT = "fedcba9876543210fedcba9876543210"


def resources(documents, kind):
    return [resource for resource in documents if resource["kind"] == kind]


def manifests(documents):
    return {
        resource["metadata"]["name"]: resource["spec"]["forProvider"]["manifest"]
        for resource in resources(documents, "Object")
    }


class CloudFerroTests(unittest.TestCase):
    def test_buckets_and_credentials_use_the_selected_project(self):
        for documents, principal, project, peer_project, buckets, count in (
            (BASE, "s-joe", FIRST_PROJECT, SECOND_PROJECT, ["s-joe"], 1),
            (
                SECOND,
                "s-jeff",
                SECOND_PROJECT,
                FIRST_PROJECT,
                ["s-jeff", "s-jeff-shared"],
                2,
            ),
        ):
            with self.subTest(principal=principal):
                (config,) = resources(documents, "ProviderConfig")
                self.assertEqual(
                    config["spec"]["credentials"]["secretRef"],
                    {
                        "key": "config",
                        "name": f"cloudferro-project-{project}",
                        "namespace": "default",
                    },
                )
                self.assertEqual(
                    sorted(
                        bucket["metadata"]["name"]
                        for bucket in resources(documents, "ContainerV1")
                    ),
                    buckets,
                )
                self.assertEqual(len(resources(documents, "EC2CredentialV3")), count)
                for resource in resources(documents, "ContainerV1") + resources(
                    documents, "EC2CredentialV3"
                ):
                    self.assertEqual(
                        resource["spec"]["providerConfigRef"]["name"],
                        config["metadata"]["name"],
                    )
                policies = resources(documents, "BucketPolicy")
                self.assertEqual(len(policies), 1)
                for policy in policies:
                    statements = json.loads(policy["spec"]["forProvider"]["policy"])[
                        "Statement"
                    ]
                    self.assertTrue(statements)
                    self.assertEqual(
                        {item["Principal"]["AWS"] for item in statements},
                        {f"arn:aws:iam::{peer_project}:root"},
                    )
                self.assertFalse(
                    any(
                        resource.get("spec", {}).get("managementPolicies")
                        for resource in documents
                    )
                )

    def test_credentials_are_published_only_after_the_provider_returns_them(self):
        self.assertEqual(manifests(BASE), {})
        secret = manifests(READY)["secret-s-joe"]
        self.assertEqual(secret["metadata"]["name"], "s-joe")
        self.assertEqual((secret["kind"], secret["type"]), ("Secret", "Opaque"))
        self.assertEqual(
            {
                key: base64.b64decode(value).decode()
                for key, value in secret["data"].items()
            },
            {
                "AWS_ACCESS_KEY_ID": "EXAMPLEACCESSKEY",
                "AWS_SECRET_ACCESS_KEY": "EXAMPLESECRETKEY",
                "AWS_ENDPOINT_URL": "https://s3.example.cloudferro.test",
                "AWS_REGION": "RegionOne",
                "AWS_S3_FORCE_PATH_STYLE": "true",
            },
        )

    def test_bucket_policy_dependencies_keep_credentials_until_deletion(self):
        dependencies = {
            (usage["spec"]["of"]["kind"], usage["spec"]["of"]["resourceRef"]["name"])
            for usage in resources(READY, "Usage")
            if usage["spec"]["by"]["kind"] == "BucketPolicy"
            and usage["spec"]["by"]["resourceRef"]["name"] == "bucketpolicy-s-joe"
            and usage["spec"]["replayDeletion"]
        }
        self.assertEqual(
            dependencies,
            {("EC2CredentialV3", "s-joe"), ("Object", "cloudferro-s3-s-joe")},
        )
        credential_use = next(
            usage
            for usage in resources(READY, "Usage")
            if usage["metadata"]["name"] == "usage-aws-provider-s-joe"
        )
        self.assertEqual(
            credential_use["spec"]["of"]["resourceRef"]["name"],
            "aws-provider-secret-s-joe",
        )
        self.assertEqual(
            credential_use["spec"]["by"]["resourceRef"]["name"], "cloudferro-s3-s-joe"
        )

    def test_lifecycle_jobs_use_the_s3_region(self):
        objects = list(manifests(SECOND).values())
        self.assertEqual(
            sorted(obj["kind"] for obj in objects), ["ConfigMap", "CronJob"]
        )
        cron = next(obj for obj in objects if obj["kind"] == "CronJob")
        containers = cron["spec"]["jobTemplate"]["spec"]["template"]["spec"][
            "containers"
        ]
        self.assertEqual(len(containers), 2)
        self.assertEqual(
            {
                entry["value"]
                for container in containers
                for entry in container["env"]
                if entry["name"] == "RCLONE_CONFIG_STORAGE_REGION"
            },
            {"RegionOne"},
        )


if __name__ == "__main__":
    unittest.main()
