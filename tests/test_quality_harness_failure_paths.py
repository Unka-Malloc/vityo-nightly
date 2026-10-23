#!/usr/bin/env python3
"""Failure-path, guard, and routing behaviour for the vityo quality entry point.

Every runner, tool lookup, and subprocess call is injected here, so no test in
this module starts Flutter, Dart, Cargo, or a real repository quality lane.
"""

from __future__ import annotations

import importlib.util
import io
import json
import runpy
import sys
import tempfile
import unittest
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "vityo_quality.py"
SCRIPTS_DIR = str(SCRIPT_PATH.parent)


def load_quality_module():
    spec = importlib.util.spec_from_file_location(
        "vityo_quality_edge_cases",
        SCRIPT_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class VityoQualityFailurePathTest(unittest.TestCase):
    def setUp(self) -> None:
        saved = list(sys.path)
        sys.path[:] = [
            entry
            for entry in sys.path
            if not entry or Path(entry).resolve() != Path(SCRIPTS_DIR).resolve()
        ]
        try:
            self.quality = load_quality_module()
            self.assertIn(SCRIPTS_DIR, sys.path)
        finally:
            sys.path[:] = saved

    def _patch_runners(
        self,
        stack: ExitStack,
        *,
        raising: str | None = None,
    ) -> dict[str, mock.MagicMock]:
        runners: dict[str, mock.MagicMock] = {}
        for entry in self.quality.FULL_IDE_PLAN:
            if entry.requirement == raising:
                patcher = mock.patch.object(
                    self.quality,
                    entry.runner_name,
                    side_effect=RuntimeError("synthetic runner failure"),
                )
            else:
                patcher = mock.patch.object(
                    self.quality,
                    entry.runner_name,
                    return_value=0,
                )
            runners[entry.requirement] = stack.enter_context(patcher)
        return runners

    def test_formal_ide_run_treats_a_raising_runner_as_a_failed_suite(self) -> None:
        with tempfile.TemporaryDirectory(prefix="quality-runner-") as name:
            report_path = Path(name) / "nested" / "ide-full.json"
            with ExitStack() as stack:
                stack.enter_context(
                    mock.patch.object(
                        self.quality,
                        "_preflight_ide_full",
                        return_value={"ready": True, "platform": "linux"},
                    )
                )
                runners = self._patch_runners(stack, raising="REQ-IDE-002")
                result = self.quality.ide_full(
                    plan_only=False,
                    preflight=False,
                    report_path=report_path,
                )
            report = json.loads(report_path.read_text(encoding="utf-8"))

        self.assertEqual(result, 1)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["failure_code"], "suite_failed")
        self.assertEqual(report["requirements"]["REQ-IDE-002"]["status"], "failed")
        self.assertEqual(
            report["requirements"]["REQ-IDE-002"]["failure_code"],
            "suite_failed",
        )
        self.assertEqual(report["requirements"]["REQ-IDE-001"]["status"], "passed")
        for runner in runners.values():
            runner.assert_called_once()

    def test_formal_ide_run_records_not_run_when_plan_validation_fails(self) -> None:
        cases = (
            (
                self.quality.ValidationReportError(
                    "invalid_requirement_mapping",
                    "synthetic mapping failure",
                ),
                "invalid_requirement_mapping",
            ),
            (RuntimeError("synthetic harness failure"), "validation_harness_failed"),
        )
        for error, expected_code in cases:
            with self.subTest(failure_code=expected_code):
                with tempfile.TemporaryDirectory(prefix="quality-plan-") as name:
                    report_path = Path(name) / "ide-full.json"
                    with ExitStack() as stack:
                        stack.enter_context(
                            mock.patch.object(
                                self.quality,
                                "_preflight_ide_full",
                                return_value={"ready": True, "platform": "linux"},
                            )
                        )
                        # The first call validates the canonical plan for the
                        # plan_only/preflight gate; the second one runs inside
                        # the formal harness and must fail closed there.
                        stack.enter_context(
                            mock.patch.object(
                                self.quality,
                                "validate_full_suite_plan",
                                side_effect=[None, error],
                            )
                        )
                        runners = self._patch_runners(stack)
                        result = self.quality.ide_full(
                            plan_only=False,
                            preflight=False,
                            report_path=report_path,
                        )
                    report = json.loads(report_path.read_text(encoding="utf-8"))

                self.assertEqual(result, 1)
                self.assertEqual(report["status"], "failed")
                self.assertEqual(report["failure_code"], expected_code)
                self.assertEqual(len(report["requirements"]), 8)
                self.assertEqual(
                    {item["status"] for item in report["requirements"].values()},
                    {"not-run"},
                )
                self.assertEqual(
                    {
                        item["failure_code"]
                        for item in report["requirements"].values()
                    },
                    {expected_code},
                )
                for runner in runners.values():
                    runner.assert_not_called()

    def test_preflight_marks_an_unsupported_host_after_tools_pass(self) -> None:
        with mock.patch.object(
            self.quality.shutil,
            "which",
            return_value="/tools/fixture",
        ), mock.patch.object(
            self.quality,
            "_host_platform",
            return_value="plan9",
        ):
            report = self.quality._preflight_ide_full()

        self.assertFalse(report["ready"])
        self.assertEqual(report["failure_code"], "unsupported_host")
        self.assertEqual(
            report["checks"],
            [
                {"name": "requirement_mapping", "status": "passed"},
                {"name": "tools", "status": "passed"},
                {
                    "name": "host",
                    "status": "failed",
                    "failure_code": "unsupported_host",
                },
            ],
        )
        self.assertEqual(len(report["requirements"]), 8)

    def test_preflight_falls_back_to_the_canonical_plan_when_mapping_fails(self) -> None:
        failure = self.quality.ValidationReportError(
            "invalid_requirement_mapping",
            "synthetic mapping failure",
        )
        with mock.patch.object(
            self.quality,
            "full_suite_plan",
            side_effect=failure,
        ), mock.patch.object(
            self.quality.shutil,
            "which",
            return_value="/tools/fixture",
        ), mock.patch.object(
            self.quality,
            "_host_platform",
            return_value="linux",
        ):
            report = self.quality._preflight_ide_full()

        self.assertFalse(report["ready"])
        self.assertEqual(report["failure_code"], "invalid_requirement_mapping")
        self.assertEqual(
            [entry["requirement"] for entry in report["requirements"]],
            [f"REQ-IDE-{index:03d}" for index in range(1, 9)],
        )
        self.assertEqual(
            [entry["runner"] for entry in report["requirements"]],
            [entry.runner_name for entry in self.quality.FULL_IDE_PLAN],
        )
        self.assertEqual(
            report["checks"][0],
            {
                "name": "requirement_mapping",
                "status": "failed",
                "failure_code": "invalid_requirement_mapping",
            },
        )

    def test_plan_only_and_preflight_are_mutually_exclusive(self) -> None:
        with self.assertRaisesRegex(ValueError, "mutually exclusive"):
            self.quality.ide_full(
                plan_only=True,
                preflight=True,
                report_path=Path("unused.json"),
            )

    def test_ide_quality_stops_at_the_first_failing_command(self) -> None:
        run_calls: list[list[str]] = []

        def fake_run(command, cwd=None, environment=None):
            run_calls.append(list(command))
            return 9

        with mock.patch.object(
            self.quality,
            "daemon_core",
            return_value=0,
        ) as daemon, mock.patch.object(
            self.quality,
            "tool",
            side_effect=lambda name: f"/tools/{name}",
        ), mock.patch.object(
            self.quality,
            "run",
            side_effect=fake_run,
        ):
            code = self.quality.ide_quality()

        self.assertEqual(code, 9)
        daemon.assert_called_once()
        self.assertEqual(
            run_calls,
            [
                [
                    "/tools/flutter",
                    "test",
                    "--no-pub",
                    "-d",
                    self.quality._host_platform(),
                    "integration_test/vityod_reconnect_test.dart",
                ]
            ],
        )

    def test_rust_coverage_phase_is_rejected_before_touching_the_gate(self) -> None:
        with self.assertRaisesRegex(ValueError, "collect-only or report-only"):
            self.quality.agent_rust_coverage_command("collect")

    def test_rust_coverage_command_requires_a_source_mapping_per_requirement(
        self,
    ) -> None:
        unmapped = self.quality.AgentSuiteEntry(
            "REQ-AGENT-001",
            "stdio-runtime",
            ("--test", "agent_stdio"),
            (),
        )
        with mock.patch.object(self.quality, "FULL_AGENT_PLAN", (unmapped,)):
            with self.assertRaises(self.quality.ValidationReportError) as error:
                self.quality.agent_rust_coverage_command("collect-only")

        self.assertEqual(error.exception.code, "rust_coverage_mapping_missing")
        self.assertIn("REQ-AGENT-001", str(error.exception))

    def test_rust_coverage_report_delegates_and_propagates_failure(self) -> None:
        with mock.patch.object(self.quality, "run", return_value=4) as run:
            code = self.quality.agent_rust_coverage_report(
                output_dir="build/evidence/custom"
            )

        self.assertEqual(code, 4)
        run.assert_called_once()
        command = run.call_args.args[0]
        self.assertEqual(
            command[:2],
            [sys.executable, "scripts/rust-coverage-gate.py"],
        )
        self.assertEqual(command[command.index("--product") + 1], "coding-agent")
        self.assertIn("--report-only", command)
        self.assertNotIn("--collect-only", command)
        self.assertEqual(
            command[command.index("--output-dir") + 1],
            "build/evidence/custom",
        )
        self.assertEqual(
            command.count("--require-module"),
            sum(len(entry.rust_source_roots) for entry in self.quality.FULL_AGENT_PLAN),
        )

    def test_coding_agent_full_marks_failure_when_the_runner_cannot_start(self) -> None:
        with tempfile.TemporaryDirectory(prefix="quality-agent-") as name:
            receipt = Path(name) / "vityo-coding-agent-full.json"
            with mock.patch.object(
                self.quality,
                "agent_cargo_test_command",
                return_value=["cargo", "test", "--workspace", "--all-targets"],
            ), mock.patch.object(
                self.quality,
                "run",
                side_effect=RuntimeError("synthetic launch failure"),
            ), redirect_stdout(io.StringIO()):
                code = self.quality.coding_agent_full(receipt_path=receipt)
            payload = json.loads(receipt.read_text(encoding="utf-8"))

        self.assertEqual(code, 1)
        self.assertEqual(payload["status"], "failed")
        self.assertEqual(payload["failure_code"], "suite_failed")
        self.assertEqual(payload["schema_version"], 1)
        self.assertEqual(payload["product"], "vityo_coding_agent")
        self.assertEqual(len(payload["requirements"]), 9)
        self.assertEqual(
            {item["status"] for item in payload["requirements"].values()},
            {"failed"},
        )
        self.assertEqual(
            {item["failure_code"] for item in payload["requirements"].values()},
            {"workspace_validation_failed"},
        )
        self.assertNotIn("rust_coverage", payload)
        self.assertEqual(
            payload["requirements"]["REQ-AGENT-001"]["runner"],
            "cargo test --workspace --all-targets",
        )

    def test_coding_agent_full_reports_receipt_write_failure_without_details(self) -> None:
        stdout = io.StringIO()
        with mock.patch.object(
            self.quality,
            "agent_cargo_test_command",
            return_value=["cargo", "test"],
        ), mock.patch.object(
            self.quality,
            "run",
            return_value=0,
        ), mock.patch.object(
            self.quality,
            "write_report_atomic",
            side_effect=OSError("private fixture detail"),
        ), redirect_stdout(stdout):
            code = self.quality.coding_agent_full(receipt_path=Path("unused.json"))

        self.assertEqual(code, 1)
        self.assertEqual(
            json.loads(stdout.getvalue()),
            {
                "schema_version": 1,
                "product": "vityo_coding_agent",
                "suite": "full",
                "status": "failed",
                "failure_code": "report_write_failed",
            },
        )
        self.assertNotIn("private fixture detail", stdout.getvalue())

    def test_main_rejects_incompatible_flag_combinations(self) -> None:
        cases = (
            (
                ["--product", "ide", "--suite", "full", "--plan-only", "--preflight"],
                "mutually exclusive",
            ),
            (
                ["--product", "coding-agent", "--suite", "full", "--plan-only"],
                "plan-only is supported only for ide/full",
            ),
            (
                ["--product", "coding-agent", "--suite", "full", "--preflight"],
                "preflight is supported only for ide/full",
            ),
            (
                ["--product", "ide", "--suite", "full", "--coverage"],
                "coverage is supported only for coding-agent/full",
            ),
        )
        for argv, message in cases:
            with self.subTest(argv=argv):
                stderr = io.StringIO()
                with mock.patch.object(
                    sys,
                    "argv",
                    [str(SCRIPT_PATH), *argv],
                ), redirect_stderr(stderr), self.assertRaises(SystemExit) as exit_error:
                    self.quality.main()
                self.assertEqual(exit_error.exception.code, 2)
                self.assertIn(message, stderr.getvalue())

    def test_module_entrypoint_exits_with_a_usage_error_without_arguments(self) -> None:
        stderr = io.StringIO()
        with mock.patch.object(
            sys,
            "argv",
            [str(SCRIPT_PATH)],
        ), redirect_stderr(stderr), redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as exit_error:
                runpy.run_path(str(SCRIPT_PATH), run_name="__main__")

        self.assertEqual(exit_error.exception.code, 2)
        self.assertIn("--product", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
