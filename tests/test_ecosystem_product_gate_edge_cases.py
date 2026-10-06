#!/usr/bin/env python3
"""Edge-case behaviour for the ecosystem product gate.

Covers the failure-classification, marker-parsing, privacy-projection, and
process-supervision paths that the happy-path suite never reaches. No test
starts Flutter, Styio, or Pafio: process boundaries are injected.
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import runpy
import sys
import tempfile
import unittest
from contextlib import ExitStack, redirect_stdout
from pathlib import Path, PureWindowsPath
from types import SimpleNamespace
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
GATE_PATH = REPO_ROOT / "scripts" / "ecosystem-product-gate.py"


def load_gate_module():
    spec = importlib.util.spec_from_file_location(
        "ecosystem_product_gate_edge_cases",
        GATE_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {GATE_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class EcosystemProductGateEdgeCaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.gate = load_gate_module()

    def _revision_step(self, name: str) -> dict[str, object]:
        return {
            "name": name,
            "status": "succeeded",
            "workspace_revision": 1,
            "source_sha256": self.gate.EXPECTED_SOURCE_DIGEST,
        }

    def _scenario(self) -> dict[str, object]:
        owner = "pafio-current+styio-files-v1"
        check, test, run = "c" * 64, "d" * 64, "e" * 64
        return {
            "schema_version": 1,
            "scenario": self.gate.SCENARIO,
            "evidence_kind": "real-pinned-matrix",
            "ok": True,
            "workspace_revision": 1,
            "source_sha256": self.gate.EXPECTED_SOURCE_DIGEST,
            "preflight": {
                "metadata_contract": "metadata-v1",
                "sync_status": "succeeded",
                "compiler_tool": "styio",
                "compile_plan_contract": 1,
                "runtime_events_contract": 1,
                "runtime_event_stream": True,
                "package": "vityo/product-gate",
                "bin_target": "product-gate",
                "test_target": "product-gate-test",
            },
            "steps": [
                self._revision_step("edit"),
                {
                    **self._revision_step("check"),
                    "owner_contract": owner,
                    "session_id_sha256": check,
                },
                {
                    **self._revision_step("test"),
                    "owner_contract": owner,
                    "session_id_sha256": test,
                },
                {
                    **self._revision_step("run"),
                    "owner_contract": owner,
                    "session_id_sha256": run,
                },
                {
                    **self._revision_step("observe"),
                    "session_id_sha256": run,
                    "eventKind": "log.emitted",
                    "observation_sha256": self.gate.EXPECTED_OBSERVATION_DIGEST,
                },
            ],
        }

    def _contracts(self) -> list[dict[str, object]]:
        values = (
            ("missing-styio", "blocked", "styio_missing"),
            (
                "incompatible-machine-contract",
                "blocked",
                "styio_machine_contract_incompatible",
            ),
            ("compiler-execution-failure", "failed", "compiler_execution_failed"),
        )
        return [
            {
                "schema_version": 1,
                "scenario": self.gate.SCENARIO,
                "evidence_kind": "deterministic-contract",
                "case": case,
                "accepted": True,
                "outcome": outcome,
                "error_category": category,
                "success_observation": False,
            }
            for case, outcome, category in values
        ]

    def _marker_output(self) -> bytes:
        lines = [
            self.gate.PRODUCT_MARKER + json.dumps(self._scenario()).encode("utf-8")
        ]
        lines.extend(
            self.gate.CONTRACT_MARKER + json.dumps(contract).encode("utf-8")
            for contract in self._contracts()
        )
        return b"\n".join(lines) + b"\n"

    def test_host_platform_maps_every_supported_platform(self) -> None:
        for raw, expected in (
            ("darwin", "macos"),
            ("win32", "windows"),
            ("linux", "linux"),
            ("freebsd", "linux"),
        ):
            with self.subTest(host=raw), mock.patch.object(
                self.gate.sys,
                "platform",
                raw,
            ):
                self.assertEqual(self.gate.host_platform(), expected)

    def test_workspace_creation_requires_pafio_new_to_write_the_manifest(self) -> None:
        with tempfile.TemporaryDirectory(prefix="product-gate-") as name:
            root = Path(name)
            with mock.patch.object(
                self.gate.subprocess,
                "run",
                return_value=SimpleNamespace(returncode=0, stdout="", stderr=""),
            ) as run:
                with self.assertRaisesRegex(ValueError, "did not create pafio.toml"):
                    self.gate.write_product_workspace(
                        root / "workspace",
                        pafio_bin=root / "pafio",
                    )
            command = run.call_args.args[0]

        self.assertEqual(command[1:3], ["new", "vityo/product-gate"])
        self.assertEqual(command[3], str(root / "workspace"))

    def test_bounded_process_requires_captured_streams(self) -> None:
        process = SimpleNamespace(stdout=None, stderr=None)
        with mock.patch.object(
            self.gate.subprocess,
            "Popen",
            return_value=process,
        ):
            with self.assertRaisesRegex(OSError, "streams are unavailable"):
                self.gate.run_bounded_process(
                    ["flutter", "test"],
                    cwd=REPO_ROOT,
                    env={},
                )

    def test_terminate_process_reaps_without_killing_after_a_clean_exit(self) -> None:
        calls: list[tuple[str, object]] = []

        class CleanProcess:
            def terminate(self) -> None:
                calls.append(("terminate", None))

            def wait(self, timeout=None):
                calls.append(("wait", timeout))
                return 0

            def kill(self) -> None:
                raise AssertionError("kill must not be called after a clean exit")

        self.gate._terminate_process(CleanProcess())
        self.assertEqual(
            calls,
            [("terminate", None), ("wait", self.gate.TERMINATION_GRACE_SECONDS)],
        )

    def test_terminate_process_escalates_to_kill_after_the_grace_period(self) -> None:
        calls: list[tuple[str, object]] = []
        timeout_error = self.gate.subprocess.TimeoutExpired

        class StubbornProcess:
            def terminate(self) -> None:
                calls.append(("terminate", None))

            def wait(self, timeout=None):
                calls.append(("wait", timeout))
                if timeout is not None:
                    raise timeout_error(cmd="synthetic", timeout=timeout)
                return -9

            def kill(self) -> None:
                calls.append(("kill", None))

        self.gate._terminate_process(StubbornProcess())
        self.assertEqual(
            calls,
            [
                ("terminate", None),
                ("wait", self.gate.TERMINATION_GRACE_SECONDS),
                ("kill", None),
                ("wait", None),
            ],
        )

    def test_bounded_process_terminates_a_streaming_child_over_the_limit(self) -> None:
        with mock.patch.object(self.gate, "OUTER_STREAM_LIMIT", 64):
            result = self.gate.run_bounded_process(
                [
                    sys.executable,
                    "-c",
                    "import sys, time; sys.stdout.write('x' * 100000); "
                    "sys.stdout.flush(); time.sleep(30)",
                ],
                cwd=REPO_ROOT,
                env=dict(os.environ),
            )

        self.assertEqual(result.failure_category, "product_output_limit_exceeded")
        self.assertLessEqual(len(result.stdout), 65)

    def test_marker_lines_are_strict_about_payload_shape(self) -> None:
        products, contracts = self.gate.parse_product_reports(
            b"unrelated runner noise\n"
            + self.gate.PRODUCT_MARKER
            + b'{"schema_version": 1}\n'
            + b"Shell: another unrelated line\n"
        )
        self.assertEqual(products, [{"schema_version": 1}])
        self.assertEqual(contracts, [])

        with self.assertRaisesRegex(ValueError, "byte limit"):
            self.gate.parse_product_reports(self.gate.PRODUCT_MARKER + b"   \n")
        with self.assertRaisesRegex(ValueError, "one JSON object"):
            self.gate.parse_product_reports(self.gate.PRODUCT_MARKER + b"[1]\n")

    def test_scenario_requires_five_steps_and_distinct_sessions(self) -> None:
        self.gate.validate_product_reports([self._scenario()], self._contracts())

        short = self._scenario()
        short["steps"] = short["steps"][:4]
        with self.assertRaisesRegex(ValueError, "exactly five steps"):
            self.gate.validate_product_reports([short], self._contracts())

        repeated = self._scenario()
        repeated["steps"][2]["session_id_sha256"] = repeated["steps"][1][
            "session_id_sha256"
        ]
        with self.assertRaisesRegex(ValueError, "distinct"):
            self.gate.validate_product_reports([repeated], self._contracts())

    def test_privacy_projection_rejects_forbidden_fields_and_absolute_paths(
        self,
    ) -> None:
        for forbidden in (
            "stdout",
            "stderr",
            "source_text",
            "receipt_path",
            "runtime_events",
            "timestamp",
            "environment",
            "executable",
            "machine_identity",
            "token",
            "client_secret",
            "db_password",
        ):
            with self.subTest(forbidden=forbidden), self.assertRaisesRegex(
                ValueError,
                "forbidden evidence field",
            ):
                self.gate._validate_privacy({forbidden: "synthetic"})

        with self.assertRaisesRegex(ValueError, r"report\.steps"):
            self.gate._validate_privacy({"steps": [{"token": "synthetic"}]})

        limit = "x" * self.gate.PROJECTED_STRING_LIMIT
        self.gate._validate_privacy({"note": limit})
        with self.assertRaisesRegex(ValueError, "projected string limit"):
            self.gate._validate_privacy({"note": limit + "x"})
        with self.assertRaisesRegex(ValueError, "absolute path"):
            self.gate._validate_privacy({"note": "/private/synthetic/workspace"})
        # Model Windows' native Path semantics even when this suite runs on a
        # POSIX host; a POSIX-rooted path still needs to be rejected there.
        with mock.patch.object(self.gate, "Path", PureWindowsPath):
            with self.assertRaisesRegex(ValueError, "absolute path"):
                self.gate._validate_privacy(
                    {"note": "/private/synthetic/workspace"}
                )
        with self.assertRaisesRegex(ValueError, "absolute path"):
            self.gate._validate_privacy({"note": "C:\\Users\\synthetic\\workspace"})
        self.gate._validate_privacy({"note": "src/main.styio"})
        self.gate._validate_privacy({"note": ["src/main.styio"]})

    def test_validation_helpers_reject_wrong_container_types(self) -> None:
        self.assertEqual(
            self.gate._object({"preflight": 1}, "preflight"),
            {"preflight": 1},
        )
        with self.assertRaisesRegex(ValueError, "must be a JSON object"):
            self.gate._object(["preflight"], "preflight")
        with self.assertRaisesRegex(ValueError, "must be a JSON object"):
            self.gate._object({1: "non-string key"}, "preflight")

        self.assertEqual(self.gate._array(["step"], "steps"), ["step"])
        with self.assertRaisesRegex(ValueError, "must be a JSON array"):
            self.gate._array({"steps": []}, "steps")

        wrong_preflight = self._scenario()
        wrong_preflight["preflight"] = ["metadata-v1"]
        with self.assertRaisesRegex(ValueError, "must be a JSON object"):
            self.gate.validate_product_reports(
                [wrong_preflight],
                self._contracts(),
            )

        wrong_steps = self._scenario()
        wrong_steps["steps"] = {"step": "edit"}
        with self.assertRaisesRegex(ValueError, "must be a JSON array"):
            self.gate.validate_product_reports([wrong_steps], self._contracts())

    def test_marker_json_constants_are_rejected(self) -> None:
        for constant in (b"NaN", b"Infinity", b"-Infinity"):
            with self.subTest(constant=constant), self.assertRaisesRegex(
                ValueError,
                "invalid JSON constant",
            ):
                self.gate.parse_product_reports(
                    self.gate.PRODUCT_MARKER + b'{"value": ' + constant + b"}"
                )

    def test_main_classifies_unexpected_environment_failures(self) -> None:
        with tempfile.TemporaryDirectory(prefix="product-gate-") as name:
            root = Path(name)
            styio = root / "styio"
            pafio = root / "pafio"
            styio.write_bytes(b"synthetic binary")
            pafio.write_bytes(b"synthetic binary")
            cases = (
                (
                    mock.patch.object(
                        self.gate,
                        "build_product_environment",
                        side_effect=ValueError("synthetic environment failure"),
                    ),
                ),
                (
                    mock.patch.object(
                        self.gate,
                        "build_product_environment",
                        return_value={},
                    ),
                    mock.patch.object(
                        self.gate,
                        "run_bounded_process",
                        side_effect=OSError("synthetic process failure"),
                    ),
                ),
            )
            for patchers in cases:
                with self.subTest(patchers=len(patchers)):
                    output = io.StringIO()
                    with ExitStack() as stack:
                        for patcher in patchers:
                            stack.enter_context(patcher)
                        stack.enter_context(redirect_stdout(output))
                        code = self.gate.main(
                            [
                                "--platform",
                                "linux",
                                "--styio-bin",
                                str(styio),
                                "--pafio-bin",
                                str(pafio),
                                "--require-real-matrix",
                                "--json",
                            ]
                        )
                    payload = json.loads(output.getvalue())

                    self.assertEqual(code, 1)
                    self.assertEqual(
                        payload["failure_category"],
                        "product_report_invalid",
                    )
                    self.assertFalse(payload["skipped"])
                    self.assertTrue(payload["required"])
                    self.assertFalse(payload["ok"])
                    self.assertEqual(payload["report"]["scenario_count"], 0)
                    self.assertEqual(payload["report"]["contract_case_count"], 0)
                    self.assertEqual(
                        payload["steps"][0],
                        {"name": "product-process", "ok": False},
                    )
                    self.assertNotIn("synthetic", output.getvalue())

    def test_human_summary_reports_pass_and_fail_status(self) -> None:
        with tempfile.TemporaryDirectory(prefix="product-gate-") as name:
            root = Path(name)
            styio = root / "styio"
            pafio = root / "pafio"
            styio.write_bytes(b"synthetic binary")
            pafio.write_bytes(b"synthetic binary")
            cases = (
                (
                    self.gate.ProcessResult(0, self._marker_output(), b""),
                    0,
                    f"[PASS] {self.gate.GATE_ID} (linux)",
                ),
                (
                    self.gate.ProcessResult(0, b"", b""),
                    1,
                    f"[FAIL] {self.gate.GATE_ID} (linux)",
                ),
            )
            for process, expected_code, expected_line in cases:
                with self.subTest(expected_line=expected_line):
                    output = io.StringIO()
                    with mock.patch.object(
                        self.gate,
                        "build_product_environment",
                        return_value={},
                    ), mock.patch.object(
                        self.gate,
                        "run_bounded_process",
                        return_value=process,
                    ), redirect_stdout(output):
                        code = self.gate.main(
                            [
                                "--platform",
                                "linux",
                                "--styio-bin",
                                str(styio),
                                "--pafio-bin",
                                str(pafio),
                                "--require-real-matrix",
                            ]
                        )

                    self.assertEqual(code, expected_code)
                    self.assertEqual(output.getvalue().strip(), expected_line)

    def test_module_entrypoint_skips_locally_with_a_human_summary(self) -> None:
        output = io.StringIO()
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(
            sys,
            "argv",
            ["ecosystem-product-gate.py"],
        ), redirect_stdout(output):
            with self.assertRaises(SystemExit) as exit_error:
                runpy.run_path(str(GATE_PATH), run_name="__main__")

        self.assertEqual(exit_error.exception.code, 0)
        self.assertEqual(
            output.getvalue().strip(),
            f"[FAIL] {self.gate.GATE_ID} ({self.gate.host_platform()})",
        )


if __name__ == "__main__":
    unittest.main()
