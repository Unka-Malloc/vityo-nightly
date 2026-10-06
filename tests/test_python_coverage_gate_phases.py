#!/usr/bin/env python3
"""Phase-selection and reporting tests for scripts/python-coverage-gate.py."""

from __future__ import annotations

import importlib.util
import io
import sys
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
GATE_PATH = REPO_ROOT / "scripts" / "python-coverage-gate.py"


def load_gate_module():
    spec = importlib.util.spec_from_file_location("python_coverage_gate_phases", GATE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {GATE_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class PythonCoverageGatePhaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.gate = load_gate_module()

    def test_collect_coverage_omits_the_declared_infrastructure_scripts(self) -> None:
        commands: list[list[str]] = []

        def fake_run(command: list[str]) -> int:
            commands.append(command)
            return 0

        with mock.patch.object(self.gate, "coverage_available", return_value=True):
            with mock.patch.object(self.gate, "run_command", side_effect=fake_run):
                self.assertEqual(self.gate.collect_coverage(), 0)

        self.assertEqual(commands[0], [sys.executable, "-m", "coverage", "erase"])
        self.assertTrue(self.gate.COVERAGE_OMIT)
        for command in commands[1:]:
            self.assertIn("--source", command)
            self.assertEqual(
                command[command.index("--source") + 1],
                self.gate.SOURCE_SCOPE,
            )
            self.assertEqual(
                command[command.index("--omit") + 1],
                ",".join(self.gate.COVERAGE_OMIT),
            )

    def test_empty_omit_list_keeps_run_and_report_commands_free_of_omit(self) -> None:
        commands: list[list[str]] = []

        def fake_run(command: list[str]) -> int:
            commands.append(command)
            return 0

        with mock.patch.object(self.gate, "COVERAGE_OMIT", []):
            with mock.patch.object(self.gate, "coverage_available", return_value=True):
                with mock.patch.object(self.gate, "run_command", side_effect=fake_run):
                    self.assertEqual(self.gate.collect_coverage(), 0)
                    self.assertEqual(self.gate.report_coverage(94), 0)

        for command in commands:
            self.assertNotIn("--omit", command)
        self.assertEqual(commands[0], [sys.executable, "-m", "coverage", "erase"])
        self.assertEqual(
            commands[-1][:4],
            [sys.executable, "-m", "coverage", "report"],
        )

    def test_report_coverage_requires_coverage_to_be_installed(self) -> None:
        stderr = io.StringIO()
        with mock.patch.object(self.gate, "coverage_available", return_value=False):
            with mock.patch.object(self.gate, "run_command") as run_command:
                with redirect_stderr(stderr):
                    self.assertEqual(self.gate.report_coverage(95), 2)

        run_command.assert_not_called()
        self.assertIn("coverage.py is required", stderr.getvalue())

    def test_report_coverage_forwards_scope_threshold_and_exit_code(self) -> None:
        with mock.patch.object(self.gate, "coverage_available", return_value=True):
            with mock.patch.object(self.gate, "run_command", return_value=3) as run_command:
                self.assertEqual(self.gate.report_coverage(93), 3)

        command = run_command.call_args.args[0]
        self.assertEqual(command[:4], [sys.executable, "-m", "coverage", "report"])
        self.assertEqual(
            command[command.index("--include") + 1],
            self.gate.REPORT_INCLUDE,
        )
        self.assertEqual(command[-2:], ["--fail-under", "93"])
        run_command.assert_called_once_with(command)

    def test_run_gate_rejects_a_phase_selection_that_does_nothing(self) -> None:
        stderr = io.StringIO()
        with mock.patch.object(self.gate, "collect_coverage") as collect:
            with mock.patch.object(self.gate, "report_coverage") as report:
                with redirect_stderr(stderr):
                    self.assertEqual(
                        self.gate.run_gate(95, collect=False, report=False),
                        2,
                    )

        collect.assert_not_called()
        report.assert_not_called()
        self.assertIn("collection or reporting must be selected", stderr.getvalue())

    def test_run_gate_can_collect_without_evaluating_the_threshold(self) -> None:
        with mock.patch.object(self.gate, "collect_coverage", return_value=0) as collect:
            with mock.patch.object(self.gate, "report_coverage") as report:
                self.assertEqual(self.gate.run_gate(95, collect=True, report=False), 0)

        collect.assert_called_once_with()
        report.assert_not_called()

    def test_run_gate_can_report_without_collecting(self) -> None:
        with mock.patch.object(self.gate, "collect_coverage") as collect:
            with mock.patch.object(self.gate, "report_coverage", return_value=4) as report:
                self.assertEqual(self.gate.run_gate(96, collect=False, report=True), 4)

        collect.assert_not_called()
        report.assert_called_once_with(96)

    def test_run_gate_stops_before_reporting_when_collection_fails(self) -> None:
        with mock.patch.object(self.gate, "collect_coverage", return_value=9) as collect:
            with mock.patch.object(self.gate, "report_coverage") as report:
                self.assertEqual(self.gate.run_gate(95, collect=True, report=True), 9)

        collect.assert_called_once_with()
        report.assert_not_called()

    def test_main_phase_flags_select_collection_or_reporting(self) -> None:
        with mock.patch.object(self.gate, "run_gate", return_value=0) as run_gate:
            self.assertEqual(self.gate.main(["--collect-only"]), 0)
        run_gate.assert_called_once_with(
            self.gate.DEFAULT_FAIL_UNDER,
            collect=True,
            report=False,
        )

        with mock.patch.object(self.gate, "run_gate", return_value=1) as run_gate:
            self.assertEqual(self.gate.main(["--report-only", "--fail-under", "90"]), 1)
        run_gate.assert_called_once_with(90, collect=False, report=True)

        with mock.patch.object(self.gate, "run_gate", return_value=0) as run_gate:
            self.assertEqual(self.gate.main([]), 0)
        run_gate.assert_called_once_with(95, collect=True, report=True)


if __name__ == "__main__":
    unittest.main()
