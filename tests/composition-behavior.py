# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

"""Check credential rollover, access policies, and lifecycle bounds."""

import base64
import json
import unittest
from datetime import datetime, timezone
from unittest.mock import Mock


def encoded(value):
    return base64.b64encode(value.encode()).decode()


def run_tests(pipelines):
    from crossplane.function import response
    from crossplane.function.proto.v1 import run_function_pb2 as fnv1
    from google.protobuf.json_format import MessageToDict

    principal = "test-consumer"
    secret_key = f"native-secret-{principal}"
    old_data = {
        "AWS_ACCESS_KEY_ID": encoded("test-old-access"),
        "AWS_SECRET_ACCESS_KEY": encoded("test-old-secret"),
        "AWS_ENDPOINT_URL": encoded("https://old.example.test"),
    }
    old_secret = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {
            "name": principal,
            "namespace": "test-space",
            "uid": "test-stable-uid",
            "resourceVersion": "1",
        },
        "type": "Opaque",
        "data": old_data,
    }

    def request(backend, phase="missing", previous=None):
        req = fnv1.RunFunctionRequest()
        req.observed.composite.resource.update(
            {
                "metadata": {"name": "test-storage", "namespace": "test-space"},
                "spec": {"principal": principal, "buckets": []},
            }
        )
        req.context.update(
            {
                "apiextensions.crossplane.io/environment": {
                    "storage": {
                        "endpoint": "https://new.example.test",
                        "region": "RegionOne",
                        "s3Region": "RegionOne",
                        "force_path_style": "true",
                    }
                },
                "storages.pkg.internal/credential-time": "2026-11-13T12:00:00+00:00",
                "storages.pkg.internal/credential-generations": [""],
            }
        )
        for key, body in (previous or {}).items():
            req.observed.resources[key].resource.update(body)
        if phase == "missing":
            return req
        data = {"AWS_ACCESS_KEY_ID": encoded("test-new-access")}
        if phase == "ready":
            data["AWS_SECRET_ACCESS_KEY"] = encoded("test-new-secret")
        if backend == "ovh":
            req.observed.resources[f"user-{principal}"].resource.update(
                {
                    "status": {
                        "atProvider": {"id": "12"},
                        "conditions": [{"type": "Ready", "status": "True"}],
                    }
                }
            )
            req.observed.resources[f"credentials-{principal}-u12"].resource.update(
                {"status": {"atProvider": {"accessKeyId": "test-new-access"}}}
            )
            data = {"access_key_id": data["AWS_ACCESS_KEY_ID"]} | (
                {"attribute.secret_access_key": data["AWS_SECRET_ACCESS_KEY"]}
                if phase == "ready"
                else {}
            )

        elif backend == "cloudferro":
            req.observed.resources[f"credentials-{principal}"].resource.update(
                {"status": {"atProvider": {"access": "test-new-access"}}}
            )
            req.required_resources[
                f"credential-secret-{principal}"
            ].items.add().resource.update(
                {
                    "data": {"attribute.secret": encoded("test-new-secret")}
                    if phase == "ready"
                    else {}
                }
            )
            return req
        data["provider_token"] = encoded("test-unused-token")
        req.required_resources[
            f"credential-secret-{principal}"
        ].items.add().resource.update({"data": data})
        return req

    def compose(backend, step_name, req, clock=None):
        step = next(step for step in pipelines[backend] if step["step"] == step_name)
        script = step["input"]["script"]
        req.input.update(step["input"])
        scope = {}
        exec(compile(script, backend, "exec"), scope)
        if clock is not None:
            scope["datetime"] = clock
        rsp = response.to(req)
        scope["compose"](req, rsp)
        return rsp

    def publish(backend, req):
        return compose(backend, "publish-current-secret", req)

    def lifecycle_request(backend, config):
        req = request(backend)
        req.observed.composite.resource["spec"].update(
            {
                "buckets": [
                    {
                        "bucketName": "test-bucket",
                        "lifecycleRules": [
                            {"target": "tmp/*", "mode": "Delete", "minAge": "1h"}
                        ],
                    }
                ]
            }
        )
        req.context["apiextensions.crossplane.io/environment"]["storage"].update(
            {"lifecycle": config}
        )
        return req

    def body(rsp, key=secret_key):
        return MessageToDict(rsp.desired.resources[key].resource)

    class CompositionTests(unittest.TestCase):
        def test_environment_defaults_to_backend_package_and_accepts_overrides(self):
            key = "storages.pkg.internal/environment"
            for backend in pipelines:
                default = f"storage-{backend}"
                for metadata, expected in (
                    ({}, default),
                    ({"annotations": {key: "  "}}, default),
                    (
                        {"labels": {key: "test-label-environment"}},
                        "test-label-environment",
                    ),
                    (
                        {
                            "annotations": {key: "test-annotation-environment"},
                            "labels": {key: "test-label-environment"},
                        },
                        "test-annotation-environment",
                    ),
                ):
                    with self.subTest(backend=backend, metadata=metadata):
                        req = request(backend)
                        req.observed.composite.resource["metadata"].update(metadata)
                        environment = {"storage": {"region": "test-region"}}
                        req.required_resources[
                            "storage-environment"
                        ].items.add().resource.update({"data": environment})
                        rsp = compose(backend, "load-storage-environment", req)
                        self.assertEqual(
                            rsp.requirements.resources[
                                "storage-environment"
                            ].match_name,
                            expected,
                        )
                        self.assertEqual(
                            MessageToDict(rsp.context)[
                                "apiextensions.crossplane.io/environment"
                            ],
                            environment,
                        )

        def test_backend_resources_use_selected_provider_config_or_existing_default(
            self,
        ):
            kinds = {
                "aws": {
                    "Bucket",
                    "User",
                    "AccessKey",
                    "Policy",
                    "UserPolicyAttachment",
                },
                "minio": {"Bucket", "User", "Policy"},
                "otc": {"Bucket", "UserV3", "CredentialV3", "BucketPolicy"},
                "ovh": {"User", "ProjectStorage", "S3Credentials", "S3Policy"},
            }
            for backend in pipelines.keys() & kinds.keys():
                for selected in (None, "", "  ", " test-project-provider "):
                    with self.subTest(backend=backend, selected=selected):
                        req = request(backend)
                        req.context["apiextensions.crossplane.io/environment"][
                            "storage"
                        ].update({"serviceName": "test-project"})
                        if selected is not None:
                            req.context["apiextensions.crossplane.io/environment"][
                                "storage"
                            ].update({"providerConfigName": selected})
                        req.observed.composite.resource["spec"].update(
                            {
                                "buckets": [{"bucketName": "test-bucket"}],
                                "bucketAccessGrants": [
                                    {
                                        "bucketName": "test-bucket",
                                        "grantee": "test-reader",
                                        "permission": "ReadOnly",
                                    }
                                ],
                            }
                        )
                        for key in (f"owner-{principal}", f"user-{principal}"):
                            req.observed.resources[key].resource.update(
                                {
                                    "status": {
                                        "atProvider": {
                                            "id": "12",
                                            "domainId": "test-domain",
                                        },
                                        "conditions": [
                                            {"type": "Ready", "status": "True"}
                                        ],
                                    }
                                }
                            )
                        for step in pipelines[backend][1:]:
                            if step["input"]["kind"] != "Script":
                                continue
                            rsp = compose(backend, step["step"], req)
                            req.desired.CopyFrom(rsp.desired)
                            req.context.CopyFrom(rsp.context)
                        checked = set()
                        for value in req.desired.resources.values():
                            item = MessageToDict(value.resource)
                            if item["kind"] == "Object":
                                self.assertEqual(
                                    item["spec"]["providerConfigRef"]["name"],
                                    "provider-kubernetes",
                                )
                                item = item["spec"]["forProvider"]["manifest"]
                            ref = (item.get("spec") or {}).get("providerConfigRef")
                            if ref is not None:
                                self.assertEqual(
                                    ref["name"],
                                    selected.strip()
                                    if selected and selected.strip()
                                    else f"provider-{backend}",
                                )
                                checked.add(item["kind"])
                        self.assertTrue(kinds[backend].issubset(checked), checked)

        @unittest.skipUnless("cloudferro" in pipelines, "CloudFerro was not selected")
        def test_cloudferro_rejects_incomplete_project_environments(self):
            valid = {
                "projectId": "0123456789abcdef0123456789abcdef",
                "providerConfigName": "test-project-provider",
                "region": "RegionOne",
                "s3Region": "RegionOne",
            }
            for change in (
                {"projectId": ""},
                {"projectId": "invalid-project"},
                {"providerConfigName": ""},
            ):
                with self.subTest(change=change):
                    req = request("cloudferro")
                    req.observed.composite.resource["spec"].update(
                        {
                            "buckets": [{"bucketName": "test-bucket"}],
                            "crossplane": {
                                "compositionSelector": {
                                    "matchLabels": {"provider": "cloudferro"}
                                }
                            },
                        }
                    )
                    req.context["apiextensions.crossplane.io/environment"].update(
                        {"storage": valid | change}
                    )
                    rsp = compose("cloudferro", "create-project-resources", req)
                    self.assertFalse(rsp.desired.resources)
                    self.assertTrue(
                        any(
                            result.severity == fnv1.SEVERITY_FATAL
                            for result in rsp.results
                        )
                    )

        @unittest.skipUnless("cloudferro" in pipelines, "CloudFerro was not selected")
        def test_cloudferro_grants_resolve_all_peer_environments(self):
            req = request("cloudferro")
            req.observed.composite.resource["spec"].update(
                {
                    "buckets": [{"bucketName": "test-bucket"}],
                    "bucketAccessGrants": [
                        {
                            "bucketName": "test-bucket",
                            "grantee": grantee,
                            "permission": "ReadOnly",
                        }
                        for grantee in (
                            "test-reader-one", "test-reader-two", "test-reader-default"
                        )
                    ],
                }
            )
            for grantee, selector in (
                ("test-reader-default", {}),
                (
                    "test-reader-one",
                    {"labels": {"storages.pkg.internal/environment": "test-env-one"}},
                ),
                (
                    "test-reader-two",
                    {
                        "annotations": {
                            "storages.pkg.internal/environment": "test-env-two"
                        },
                        "labels": {
                            "storages.pkg.internal/environment": "test-unused-env"
                        },
                    },
                ),
            ):
                req.required_resources[
                    "cloudferro-grantee-storages"
                ].items.add().resource.update(
                    {
                        "metadata": {"name": grantee, **selector},
                        "spec": {
                            "principal": grantee,
                            "crossplane": {
                                "compositionSelector": {
                                    "matchLabels": {"provider": "cloudferro"}
                                }
                            },
                        },
                    }
                )
            pending = compose("cloudferro", "create-bucket-policies", req)
            self.assertNotIn("bucketpolicy-test-bucket", pending.desired.resources)
            self.assertEqual(
                {
                    item.match_name
                    for item in pending.requirements.resources.values()
                    if item.kind == "EnvironmentConfig"
                },
                {"test-env-one", "test-env-two", "storage-cloudferro"},
            )
            projects = (
                "0123456789abcdef0123456789abcdef",
                "fedcba9876543210fedcba9876543210",
                "00112233445566778899aabbccddeeff",
            )
            for name, project in zip(
                ("test-env-one", "test-env-two", "storage-cloudferro"), projects
            ):
                req.required_resources[
                    f"cloudferro-grantee-environment-{name}"
                ].items.add().resource.update(
                    {"data": {"storage": {"projectId": project}}}
                )
            ready = compose("cloudferro", "create-bucket-policies", req)
            policy = json.loads(
                body(ready, "bucketpolicy-test-bucket")["spec"]["forProvider"]["policy"]
            )
            self.assertEqual(
                {item["Principal"]["AWS"] for item in policy["Statement"]},
                {f"arn:aws:iam::{project}:root" for project in projects},
            )
            req.required_resources["cloudferro-grantee-environment-test-env-one"].items[
                0
            ].resource.update({"data": {"storage": {"projectId": "invalid-project"}}})
            invalid = compose("cloudferro", "create-bucket-policies", req)
            self.assertNotIn("bucketpolicy-test-bucket", invalid.desired.resources)
            self.assertTrue(
                any(
                    result.severity == fnv1.SEVERITY_FATAL for result in invalid.results
                )
            )

        def test_ovh_publication_uses_the_resource_steps_numeric_user_id(self):
            if "ovh" not in pipelines:
                self.skipTest("OVHcloud pipeline not selected")
            for user_id, publishable in (
                ("0012", True),
                ("0", False),
                ("9007199254740992", False),
            ):
                with self.subTest(user_id=user_id):
                    req = request("ovh", "ready")
                    req.observed.resources[f"user-{principal}"].resource["status"][
                        "atProvider"
                    ]["id"] = user_id
                    rsp = publish("ovh", req)
                    self.assertEqual(secret_key in rsp.desired.resources, publishable)

        def test_initial_incomplete_credentials_publish_no_secret(self):
            for backend in pipelines:
                for phase in ("missing", "partial"):
                    with self.subTest(backend=backend, phase=phase):
                        rsp = publish(backend, request(backend, phase))
                        self.assertNotIn(secret_key, rsp.desired.resources)

        def test_existing_secret_stays_desired_until_replacement_is_complete(self):
            for backend in pipelines:
                for phase in ("missing", "partial"):
                    with self.subTest(backend=backend, phase=phase):
                        rsp = publish(
                            backend, request(backend, phase, {secret_key: old_secret})
                        )
                        self.assertEqual(body(rsp)["data"], old_secret["data"])
                        self.assertNotIn("uid", body(rsp)["metadata"])
                        self.assertNotIn("status", body(rsp))
                        self.assertEqual(
                            rsp.desired.resources[secret_key].ready, fnv1.READY_FALSE
                        )

        def test_complete_replacement_updates_only_consumer_keys(self):
            for backend in pipelines:
                with self.subTest(backend=backend):
                    rsp = publish(
                        backend, request(backend, "ready", {secret_key: old_secret})
                    )
                    self.assertEqual(
                        body(rsp)["data"],
                        {
                            "AWS_ACCESS_KEY_ID": encoded("test-new-access"),
                            "AWS_SECRET_ACCESS_KEY": encoded("test-new-secret"),
                            "AWS_ENDPOINT_URL": encoded("https://new.example.test"),
                            "AWS_REGION": encoded("RegionOne"),
                            "AWS_S3_FORCE_PATH_STYLE": encoded("true"),
                        },
                    )
                    self.assertNotEqual(
                        rsp.desired.resources[secret_key].ready, fnv1.READY_FALSE
                    )

        def test_published_credentials_are_only_in_native_secrets(self):
            for backend in pipelines:
                with self.subTest(backend=backend):
                    rsp = publish(backend, request(backend, "ready"))
                    self.assertEqual(body(rsp)["kind"], "Secret")
                    self.assertEqual(body(rsp)["apiVersion"], "v1")
                    for item in rsp.desired.resources.values():
                        resource = MessageToDict(item.resource)
                        if resource["kind"] != "Secret":
                            manifest = (
                                resource.get("spec", {})
                                .get("forProvider", {})
                                .get("manifest", {})
                            )
                            self.assertNotEqual(manifest.get("kind"), "Secret")
                            text = json.dumps(resource)
                            self.assertNotIn(encoded("test-new-secret"), text)
                            self.assertNotIn("test-new-secret", text)

        @unittest.skipUnless("cloudferro" in pipelines, "CloudFerro was not selected")
        def test_cloudferro_keeps_policy_dependencies_during_rollover(self):
            initial = publish("cloudferro", request("cloudferro", "ready"))
            previous = {
                key: MessageToDict(value.resource)
                for key, value in initial.desired.resources.items()
            }
            pending = publish("cloudferro", request("cloudferro", previous=previous))
            self.assertEqual(set(pending.desired.resources), set(previous))
            for key, resource in previous.items():
                field = "data" if resource["kind"] == "Secret" else "spec"
                self.assertEqual(body(pending, key)[field], resource[field])

        @unittest.skipUnless("otc" in pipelines, "OTC was not selected")
        def test_otc_policy_includes_retained_ids_and_omits_expired_or_revoked_ids(
            self,
        ):
            req = request("otc")
            xr = MessageToDict(req.observed.composite.resource)
            xr["spec"].update(
                credentialsRollover={"interval": "daily", "maxToKeep": 2},
                buckets=[{"bucketName": "test-bucket"}],
                bucketAccessGrants=[
                    {
                        "bucketName": "test-bucket",
                        "grantee": "test-reader",
                        "permission": "ReadOnly",
                    }
                ],
            )
            req.observed.composite.resource.update(xr)
            peer = {
                "metadata": {"name": "test-reader-storage", "namespace": "test-space"},
                "spec": {
                    "principal": "test-reader",
                    "providerIdentity": "test-short-reader",
                    "credentialsRollover": {"interval": "daily", "maxToKeep": 2},
                },
            }

            def prepare():
                req.desired.Clear()
                del req.context["storages.pkg.internal/credential-generations"]
                req.required_resources["grantee-storages"].Clear()
                req.required_resources["grantee-storages"].items.add().resource.update(
                    peer
                )
                for step in (
                    "load-storage-environment",
                    "create-users",
                    "observe-grantee-users",
                ):
                    rsp = compose("otc", step, req)
                    req.desired.CopyFrom(rsp.desired)
                    req.context.CopyFrom(rsp.context)

            prepare()
            expected = set()
            for prefix, role in (("user-", "owner"), ("observe-user-", "reader")):
                keys = sorted(
                    key for key in req.desired.resources if key.startswith(prefix)
                )
                self.assertEqual(len(keys), 2)
                for index, key in enumerate(keys):
                    identity = f"test-{role}-{index}"
                    req.observed.resources[key].resource.update(
                        {
                            "status": {
                                "atProvider": {
                                    "id": identity,
                                    "domainId": "test-domain",
                                }
                            }
                        }
                    )
                    expected.add(f"domain/test-domain:user/{identity}")
                    if role == "reader":
                        manifest = MessageToDict(req.desired.resources[key].resource)[
                            "spec"
                        ]["forProvider"]["manifest"]
                        self.assertTrue(
                            manifest["metadata"]["name"].startswith(
                                "provider-storage-managed-test-short-reader-"
                            )
                        )

            def allowed_ids():
                rsp = compose("otc", "create-bucket-policies", req)
                policy = json.loads(
                    body(rsp, "bucketpolicy-test-bucket")["spec"]["forProvider"][
                        "manifest"
                    ]["spec"]["forProvider"]["policy"]
                )
                for statement in policy["Statement"]:
                    if any(
                        "reader" in identity
                        for identity in statement["Principal"]["ID"]
                    ):
                        self.assertFalse(
                            {"PutObject", "DeleteObject"} & set(statement["Action"])
                        )
                return {
                    identity
                    for statement in policy["Statement"]
                    for identity in statement["Principal"]["ID"]
                }

            self.assertEqual(allowed_ids(), expected)
            xr["spec"]["credentialsRollover"]["maxToKeep"] = 1
            peer["spec"]["credentialsRollover"]["maxToKeep"] = 1
            req.observed.composite.resource.update(xr)
            prepare()
            self.assertEqual(
                allowed_ids(),
                {
                    "domain/test-domain:user/test-owner-1",
                    "domain/test-domain:user/test-reader-1",
                },
            )
            for grants in (
                [dict(xr["spec"]["bucketAccessGrants"][0], permission="None")],
                [],
            ):
                xr["spec"]["bucketAccessGrants"] = grants
                req.observed.composite.resource.update(xr)
                prepare()
                self.assertEqual(
                    allowed_ids(), {"domain/test-domain:user/test-owner-1"}
                )

        def test_generation_time_stays_fixed_across_a_period_boundary(self):
            for backend in pipelines:
                with self.subTest(backend=backend):
                    req = request(backend)
                    req.context.Clear()
                    req.observed.composite.resource["spec"].update(
                        {
                            "credentialsRollover": {
                                "interval": "daily",
                                "maxToKeep": 2,
                            },
                            "crossplane": {
                                "compositionSelector": {
                                    "matchLabels": {"provider": backend}
                                }
                            },
                        }
                    )
                    req.required_resources[
                        "storage-environment"
                    ].items.add().resource.update(
                        {
                            "data": {
                                "storage": {
                                    "endpoint": "https://s3.example.test",
                                    "region": "RegionOne",
                                    "s3Region": "RegionOne",
                                    "serviceName": "test-project",
                                    "projectId": "0123456789abcdef0123456789abcdef",
                                    "providerConfigName": "test-project-provider",
                                    "force_path_style": "true",
                                }
                            }
                        }
                    )
                    clock = Mock(wraps=datetime)
                    clock.now.side_effect = [
                        datetime(2026, 12, 31, 23, 59, 59, tzinfo=timezone.utc),
                        datetime(2027, 1, 1, tzinfo=timezone.utc),
                    ]
                    clock.fromisoformat.side_effect = datetime.fromisoformat
                    for _ in range(2):
                        rsp = compose(backend, "load-storage-environment", req, clock)
                        req.context.CopyFrom(rsp.context)
                    for step in pipelines[backend][1:]:
                        if step["input"]["kind"] != "Script":
                            continue
                        rsp = compose(backend, step["step"], req)
                        req.desired.CopyFrom(rsp.desired)
                        req.context.CopyFrom(rsp.context)
                    names = " ".join(req.desired.resources)
                    self.assertIn("20261231", names)
                    self.assertIn("20261230", names)
                    self.assertNotIn("20270101", names)

        def test_generation_intervals_cross_calendar_boundaries(self):
            expected = {
                "daily": ["-20270101", "-20261231"],
                "weekly": ["-2026w53", "-2026w52"],
                "monthly": ["-202701", "-202612"],
                "quarterly": ["-2027q1", "-2026q4"],
                "yearly": ["-2027", "-2026"],
                "none": [""],
            }
            for interval, suffixes in expected.items():
                with self.subTest(interval=interval):
                    backend = next(iter(pipelines))
                    req = request(backend)
                    req.context.Clear()
                    req.observed.composite.resource["spec"].update(
                        {
                            "credentialsRollover": {
                                "interval": interval,
                                "maxToKeep": 1 if interval == "none" else 2,
                            }
                        }
                    )
                    clock = Mock(wraps=datetime)
                    clock.now.return_value = datetime(2027, 1, 1, tzinfo=timezone.utc)
                    clock.fromisoformat.side_effect = datetime.fromisoformat
                    rsp = compose(backend, "load-storage-environment", req, clock)
                    self.assertEqual(
                        MessageToDict(rsp.context)[
                            "storages.pkg.internal/credential-generations"
                        ],
                        suffixes,
                    )

        def test_lifecycle_has_a_deadline_and_finite_retries(self):
            for backend in pipelines:
                for config, deadline, retries in (
                    ({}, 3600, 2),
                    ({"activeDeadlineSeconds": 120, "backoffLimit": 0}, 120, 0),
                ):
                    with self.subTest(backend=backend, config=config):
                        req = lifecycle_request(backend, config)
                        rsp = compose(backend, "manage-lifecycle-rules", req)
                        job = body(rsp, f"lifecycle-cron-{principal}")["spec"][
                            "forProvider"
                        ]["manifest"]["spec"]
                        self.assertEqual(job["concurrencyPolicy"], "Forbid")
                        self.assertEqual(
                            job["jobTemplate"]["spec"]["activeDeadlineSeconds"],
                            deadline,
                        )
                        self.assertEqual(
                            job["jobTemplate"]["spec"]["backoffLimit"], retries
                        )
                        self.assertEqual(
                            job["jobTemplate"]["spec"]["template"]["spec"][
                                "restartPolicy"
                            ],
                            "Never",
                        )

        def test_invalid_lifecycle_bounds_fail_without_creating_jobs(self):
            for field, values in (
                ("activeDeadlineSeconds", (0, -1, 86401, 1.5, True, "60")),
                ("backoffLimit", (-1, 11, 1.5, True, "2")),
            ):
                for value in values:
                    with self.subTest(field=field, value=value):
                        backend = next(iter(pipelines))
                        req = lifecycle_request(backend, {field: value})
                        rsp = compose(backend, "manage-lifecycle-rules", req)
                        self.assertTrue(
                            any(
                                result.severity == fnv1.SEVERITY_FATAL
                                for result in rsp.results
                            )
                        )
                        self.assertNotIn(
                            f"lifecycle-cron-{principal}", rsp.desired.resources
                        )

    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(CompositionTests)
    )
    return 0 if result.wasSuccessful() else 1
