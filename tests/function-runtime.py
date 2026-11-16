# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

"""Check cache durations and Composition behavior in the function runtimes."""

import json
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
BUILDER = runpy.run_path(str(ROOT / "scripts/build-composition.py"))
BACKENDS = sys.argv[1:] or BUILDER["BACKENDS"]
sys.argv[1:] = []
RUNTIME = """
import json
import sys

import grpc
from crossplane.function import response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1
from crossplane.function.proto.v1 import run_function_pb2_grpc as fnv1_grpc

data = json.load(sys.stdin)
pipelines = {}
with grpc.insecure_channel('localhost:9443') as channel, grpc.insecure_channel('localhost:9444') as environment_channel:
    grpc.channel_ready_future(channel).result(timeout=30)
    grpc.channel_ready_future(environment_channel).result(timeout=30)
    stub = fnv1_grpc.FunctionRunnerServiceStub(channel)
    environment_stub = fnv1_grpc.FunctionRunnerServiceStub(environment_channel)
    for case in data['cases']:
        pipelines.setdefault(case['backend'], case['pipeline'])
        for xr in ({}, case['xr']):
            for step in case['pipeline']:
                req = fnv1.RunFunctionRequest()
                req.observed.composite.resource.update(xr)
                req.context.update({'apiextensions.crossplane.io/environment': {
                    'storage': {'region': 'RegionOne', 's3Region': 'RegionOne',
                    'endpoint': 'https://s3.example.test',
                    'projectId': '0123456789abcdef0123456789abcdef',
                    'providerConfigName': 'test-project-provider'},
                }, 'storages.pkg.internal/credential-time': '2026-11-13T12:00:00+00:00',
                   'storages.pkg.internal/credential-generations': ['']})
                req.input.update(step['input'])
                if step['input']['kind'] == 'Script':
                    namespace = {}
                    exec(compile(step['input']['script'], step['step'], 'exec'), namespace)
                    rsp = response.to(req)
                    namespace['compose'](req, rsp)
                else:
                    runner = environment_stub if step['step'] == 'environmentConfigs' else stub
                    rsp = runner.RunFunction(req, timeout=10)
                assert (rsp.meta.ttl.seconds, rsp.meta.ttl.nanos) == (case['seconds'], 0), (
                    case['backend'], step['step'], rsp.meta.ttl)
    scope = {}
    exec(compile(data['checks'], 'tests/composition-behavior.py', 'exec'), scope)
    raise SystemExit(scope['run_tests'](pipelines, environment_stub))
"""


class FunctionRuntimeTests(unittest.TestCase):
    def test_build_without_backend_arguments_writes_all_compositions(self):
        with tempfile.TemporaryDirectory(prefix="test-storage-build-") as directory:
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts/build-composition.py"),
                    "--output-dir",
                    directory,
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                {
                    path.parent.name
                    for path in Path(directory).glob("*/composition.yaml")
                },
                {"minio", "aws", "otc", "ovh", "cloudferro"},
            )

    def test_durations_reject_invalid_or_overflowing_values(self):
        for value in ("0s", "-1m", "1.5s", "5", "1d", "999999999999h", None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                BUILDER["response_ttl_seconds"](value)

    def test_function_responses_and_cache_settings(self):
        cases = []
        with tempfile.TemporaryDirectory(prefix="test-storage-ttl-") as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "composition", root / "composition")
            (root / "composition/settings.yaml").write_text("responseTTL: 5m\n")
            builds = [(backend, ROOT, None, 60) for backend in BACKENDS]
            # File and command overrides use the same builder for every backend.
            # Expected seconds must not depend on the parser under test.
            builds.extend(
                [(BACKENDS[0], root, None, 300), (BACKENDS[0], root, "90s", 90)]
            )
            for backend, source_root, override, seconds in builds:
                fixture = (
                    ROOT / "cloudferro/tests/fixtures/001-buckets.yaml"
                    if backend == "cloudferro"
                    else ROOT / "examples/base/002-buckets.yaml"
                )
                composition = yaml.safe_load(
                    BUILDER["build"](backend, root=source_root, response_ttl=override)
                )
                cases.append(
                    {
                        "backend": backend,
                        "pipeline": composition["spec"]["pipeline"],
                        "xr": yaml.safe_load(fixture.read_text()),
                        "seconds": seconds,
                    }
                )
        functions = list(
            yaml.safe_load_all((ROOT / "minio/dependencies/functions.yaml").read_text())
        )
        images = {
            function["metadata"]["name"]: function["spec"]["package"]
            for function in functions
        }
        name = "test-storage-functions-" + uuid.uuid4().hex[:12]
        subprocess.run(
            [
                "docker",
                "run",
                "--detach",
                "--rm",
                "--network",
                "none",
                "--name",
                name,
                images["crossplane-contrib-function-auto-ready"],
                "--insecure",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        environment_name = name + "-environment"
        try:
            subprocess.run(
                [
                    "docker",
                    "run",
                    "--detach",
                    "--rm",
                    "--network",
                    f"container:{name}",
                    "--name",
                    environment_name,
                    images["function-environment-configs"],
                    "--insecure",
                    "--address=:9444",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            result = subprocess.run(
                [
                    "docker",
                    "run",
                    "--rm",
                    "-i",
                    "--network",
                    f"container:{name}",
                    "--entrypoint",
                    "/venv/fn/bin/python",
                    images["crossplane-contrib-function-python"],
                    "-c",
                    RUNTIME,
                ],
                input=json.dumps(
                    {
                        "cases": cases,
                        "checks": (ROOT / "tests/composition-behavior.py").read_text(),
                    }
                ),
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            print(result.stderr, end="")
        finally:
            subprocess.run(
                ["docker", "rm", "--force", environment_name, name],
                check=True,
                capture_output=True,
            )


if __name__ == "__main__":
    unittest.main()
