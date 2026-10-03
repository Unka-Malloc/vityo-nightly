#!/usr/bin/env python3
"""Phase-selection and failure-propagation tests for scripts/project-coverage-gate.py."""

from __future__ import annotations

import importlib.util
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
GATE_PATH = REPO_ROOT / "scripts" / "project-coverage-gate.py"


def load_gate_module():
    spec = importlib.util.spec_from_file_location("project_coverage_gate_phases", GATE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {GATE_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ProjectCoverageGatePhaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.gate = load_gate_module()

    def test_run_python_gate_selects_the_requested_phase(self) -> None:
        for collect, report, flag in (
            (True, False, "--collect-only"),
            (False, True, "--report-only"),
        ):
            with self.subTest(collect=collect, report=report):
                with mock.patch.object(self.gate, "run_command", return_value=0) as run_command:
                    self.assertEqual(
                        self.gate.run_python_gate(96, collect=collect, report=report),
                        0,
                    )
                self.assertEqual(
                    run_command.call_args.args[0],
                    [
                        sys.executable,
                        str(self.gate.PYTHON_COVERAGE_GATE),
                        "--fail-under",
                        "96",
                        flag,
                    ],
                )
                self.assertEqual(run_command.call_args.kwargs["cwd"], self.gate.ROOT)

    def test_run_python_gate_rejects_a_phase_selection_that_does_nothing(self) -> None:
        stderr = io.StringIO()
        with mock.patch.object(self.gate, "run_command") as run_command:
            with redirect_stderr(stderr):
                self.assertEqual(
                    self.gate.run_python_gate(95, collect=False, report=False),
                    2,
                )

        run_command.assert_not_called()
        self.assertIn("Python coverage collection or reporting must be selected", stderr.getvalue())

    def test_run_rust_coverage_gate_rejects_a_phase_selection_that_does_nothing(self) -> None:
        stderr = io.StringIO()
        with mock.patch.object(self.gate, "run_command") as run_command:
            with redirect_stderr(stderr):
                self.assertEqual(
                    self.gate.run_rust_coverage_gate(
                        collect=False,
                        report=False,
                        output_dir=Path("build/evidence/rust-coverage"),
                        agent_receipt=Path("build/evidence/agent.json"),
                    ),
                    2,
                )

        run_command.assert_not_called()
        self.assertIn("Rust coverage collection or reporting must be selected", stderr.getvalue())

    def test_run_rust_coverage_gate_report_only_runs_the_two_reporters(self) -> None:
        with mock.patch.object(self.gate, "run_command", return_value=0) as run_command:
            self.assertEqual(
                self.gate.run_rust_coverage_gate(
                    collect=False,
                    report=True,
                    output_dir=Path("build/evidence/rust-coverage"),
                    agent_receipt=Path("build/evidence/agent.json"),
                ),
                0,
            )

        commands = [call.args[0] for call in run_command.call_args_list]
        self.assertEqual(len(commands), 2)
        self.assertEqual(commands[0][commands[0].index("--suite") + 1], "coverage-report")
        self.assertIn("--report-only", commands[1])
        self.assertEqual(commands[1][commands[1].index("--product") + 1], "vityod")

    def test_run_rust_coverage_gate_stops_when_the_report_phase_fails(self) -> None:
        for failures, expected in (([0, 0, 9], 9), ([0, 0, 0, 10], 10)):
            with self.subTest(failures=failures):
                with mock.patch.object(
                    self.gate, "run_command", side_effect=failures
                ) as run_command:
                    self.assertEqual(
                        self.gate.run_rust_coverage_gate(
                            collect=True,
                            report=True,
                            output_dir=Path("build/evidence/rust-coverage"),
                            agent_receipt=Path("build/evidence/agent.json"),
                        ),
                        expected,
                    )
                self.assertEqual(run_command.call_count, len(failures))

    def test_run_flutter_gate_requires_the_vityod_manifest_before_building(self) -> None:
        with tempfile.TemporaryDirectory(prefix="project-coverage-phases-") as tmp_name:
            root = Path(tmp_name)
            (root / "app").mkdir()
            with mock.patch.object(self.gate, "ROOT", root):
                with mock.patch.object(
                    self.gate, "resolve_flutter_binary", return_value="/bin/flutter"
                ):
                    with mock.patch.object(self.gate, "run_command") as run_command:
                        stderr = io.StringIO()
                        with redirect_stderr(stderr):
                            self.assertEqual(
                                self.gate.run_flutter_gate(
                                    fail_under=95,
                                    flutter_dir=Path("app"),
                                    flutter_bin=None,
                                ),
                                2,
                            )

        run_command.assert_not_called()
        self.assertIn("vityod Cargo manifest is missing", stderr.getvalue())
        self.assertIn("native/vityod/Cargo.toml", stderr.getvalue())

    def test_run_flutter_gate_propagates_a_failing_flutter_test_run(self) -> None:
        with tempfile.TemporaryDirectory(prefix="project-coverage-phases-") as tmp_name:
            root = Path(tmp_name)
            app = root / "app"
            manifest = app / "native/vityod/Cargo.toml"
            manifest.parent.mkdir(parents=True)
            manifest.write_text("[workspace]\n", encoding="utf-8")
            # Collection also builds the Coding Agent for the packaged handshake.
            agent_manifest = root / "products/vityo_coding_agent/Cargo.toml"
            agent_manifest.parent.mkdir(parents=True)
            agent_manifest.write_text("[package]\n", encoding="utf-8")
            with mock.patch.object(self.gate, "ROOT", root):
                with mock.patch.object(
                    self.gate, "resolve_flutter_binary", return_value="/bin/flutter"
                ):
                    with mock.patch.object(
                        self.gate, "run_command", side_effect=[0, 0, 11]
                    ) as run_command:
                        self.assertEqual(
                            self.gate.run_flutter_gate(
                                fail_under=95,
                                flutter_dir=Path("app"),
                                flutter_bin=None,
                            ),
                            11,
                        )

        self.assertEqual(
            run_command.call_args_list[1],
            mock.call(
                [
                    "cargo",
                    "build",
                    "--locked",
                    "--manifest-path",
                    str(agent_manifest),
                    "--bin",
                    "vityo-coding-agent",
                ],
                cwd=root,
            ),
        )
        self.assertEqual(
            run_command.call_args_list[2],
            mock.call(["/bin/flutter", "test", "--coverage"], cwd=app),
        )
        self.assertEqual(len(run_command.call_args_list), 3)

    def test_run_flutter_gate_skips_reporting_when_only_collection_was_requested(self) -> None:
        with tempfile.TemporaryDirectory(prefix="project-coverage-phases-") as tmp_name:
            root = Path(tmp_name)
            app = root / "app"
            manifest = app / "native/vityod/Cargo.toml"
            manifest.parent.mkdir(parents=True)
            manifest.write_text("[workspace]\n", encoding="utf-8")
            # Collection also builds the Coding Agent for the packaged handshake.
            agent_manifest = root / "products/vityo_coding_agent/Cargo.toml"
            agent_manifest.parent.mkdir(parents=True)
            agent_manifest.write_text("[package]\n", encoding="utf-8")
            with mock.patch.object(self.gate, "ROOT", root):
                with mock.patch.object(
                    self.gate, "resolve_flutter_binary", return_value="/bin/flutter"
                ):
                    with mock.patch.object(self.gate, "run_command", return_value=0):
                        with mock.patch.object(self.gate, "parse_lcov") as parse_lcov:
                            self.assertEqual(
                                self.gate.run_flutter_gate(
                                    fail_under=95,
                                    flutter_dir=Path("app"),
                                    flutter_bin=None,
                                    collect=True,
                                    report=False,
                                ),
                                0,
                            )

        parse_lcov.assert_not_called()

    def test_main_propagates_a_failing_rust_coverage_gate(self) -> None:
        with mock.patch.object(self.gate, "run_python_gate", return_value=0):
            with mock.patch.object(self.gate, "run_flutter_gate", return_value=0):
                with mock.patch.object(
                    self.gate, "run_rust_coverage_gate", return_value=12
                ) as rust_gate:
                    self.assertEqual(self.gate.main([]), 12)

        rust_gate.assert_called_once_with(
            collect=True,
            report=True,
            output_dir=self.gate.DEFAULT_RUST_COVERAGE_DIR,
            agent_receipt=self.gate.DEFAULT_AGENT_RECEIPT,
        )


if __name__ == "__main__":
    unittest.main()
