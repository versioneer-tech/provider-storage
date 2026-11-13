# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

"""Check response cache durations in the installed function runtimes."""

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
with grpc.insecure_channel('localhost:9443') as channel:
    grpc.channel_ready_future(channel).result(timeout=30)
    stub = fnv1_grpc.FunctionRunnerServiceStub(channel)
    for case in data:
        for xr in ({}, case['xr']):
            for step in case['pipeline']:
                req = fnv1.RunFunctionRequest()
                req.observed.composite.resource.update(xr)
                req.context.update({'apiextensions.crossplane.io/environment': {
                    'storage': {'region': 'RegionOne', 's3Region': 'RegionOne',
                                'endpoint': 'https://s3.example.test'},
                }})
                req.input.update(step['input'])
                if step['input']['kind'] == 'Script':
                    namespace = {}
                    exec(compile(step['input']['script'], step['step'], 'exec'), namespace)
                    rsp = response.to(req)
                    namespace['compose'](req, rsp)
                else:
                    rsp = stub.RunFunction(req, timeout=10)
                assert (rsp.meta.ttl.seconds, rsp.meta.ttl.nanos) == (case['seconds'], 0), (
                    case['backend'], step['step'], rsp.meta.ttl)
"""


class ResponseTTLTests(unittest.TestCase):
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
                {path.parent.name for path in Path(directory).glob("*/composition.yaml")},
                {"minio", "aws", "otc", "ovh", "cloudferro"},
            )

    def test_durations_reject_invalid_or_overflowing_values(self):
        for value in ("0s", "-1m", "1.5s", "5", "1d", "999999999999h", None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                BUILDER["response_ttl_seconds"](value)

    def test_setting_and_override_reach_every_function_response(self):
        cases = []
        with tempfile.TemporaryDirectory(prefix="test-storage-ttl-") as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "composition", root / "composition")
            (root / "composition/settings.yaml").write_text("responseTTL: 5m\n")
            for backend in BACKENDS:
                fixture = (
                    ROOT / "cloudferro/tests/fixtures/001-buckets.yaml"
                    if backend == "cloudferro"
                    else ROOT / "examples/base/002-buckets.yaml"
                )
                for ttl in (None, "5m", "90s"):
                    composition = yaml.safe_load(
                        BUILDER["build"](
                            backend,
                            root=ROOT if ttl is None else root,
                            response_ttl="90s" if ttl == "90s" else None,
                        )
                    )
                    settings = yaml.safe_load(
                        (ROOT / "composition/settings.yaml").read_text()
                    )
                    cases.append(
                        {
                            "backend": backend,
                            "pipeline": composition["spec"]["pipeline"],
                            "xr": yaml.safe_load(fixture.read_text()),
                            "seconds": BUILDER["response_ttl_seconds"](
                                ttl or settings["responseTTL"]
                            ),
                        }
                    )
        functions = list(
            yaml.safe_load_all((ROOT / "minio/dependencies/functions.yaml").read_text())
        )
        images = {
            function["metadata"]["name"]: function["spec"]["package"]
            for function in functions
        }
        name = "test-storage-ttl-" + uuid.uuid4().hex[:12]
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
        try:
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
                input=json.dumps(cases),
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            subprocess.run(
                ["docker", "rm", "--force", name], check=True, capture_output=True
            )


if __name__ == "__main__":
    unittest.main()
