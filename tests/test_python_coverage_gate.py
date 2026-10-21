#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import io
import runpy
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
GATE_PATH = REPO_ROOT / "scripts" / "python-coverage-gate.py"


def load_gate_module():
    spec = importlib.util.spec_from_file_location("python_coverage_gate", GATE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {GATE_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class PythonCoverageGateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.gate = load_gate_module()

    def test_coverage_available_checks_module_version(self) -> None:
        with mock.patch.object(self.gate.subprocess, "run") as run:
            run.return_value.returncode = 0
            self.assertTrue(self.gate.coverage_available())
            run.return_value.returncode = 1
            self.assertFalse(self.gate.coverage_available())

        command = run.call_args.args[0]
        self.assertEqual(command[:3], [sys.executable, "-m", "coverage"])

    def test_run_gate_reports_missing_coverage_dependency(self) -> None:
        with mock.patch.object(self.gate, "coverage_available", return_value=False):
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                code = self.gate.run_gate(95)

        self.assertEqual(code, 2)
        self.assertIn("coverage.py is required", stderr.getvalue())

    def test_run_command_returns_subprocess_exit_code(self) -> None:
        with mock.patch.object(self.gate.subprocess, "run") as run:
            run.return_value.returncode = 13
            self.assertEqual(self.gate.run_command(["coverage", "erase"]), 13)

        run.assert_called_once_with(["coverage", "erase"], cwd=self.gate.ROOT, check=False)

    def test_run_gate_runs_erase_test_and_report_commands(self) -> None:
        commands: list[list[str]] = []

        def fake_run(command: list[str]) -> int:
            commands.append(command)
            return 0

        with mock.patch.object(self.gate, "coverage_available", return_value=True):
            with mock.patch.object(self.gate, "run_command", side_effect=fake_run):
                self.assertEqual(self.gate.run_gate(97), 0)

        self.assertEqual(commands[0], [sys.executable, "-m", "coverage", "erase"])
        self.assertEqual(
            len(commands),
            2
            + len(self.gate.UNIT_TEST_DISCOVERY)
            + len(self.gate.STANDALONE_TEST_SCRIPTS),
        )
        for index, (start_directory, pattern) in enumerate(self.gate.UNIT_TEST_DISCOVERY):
            discovery = commands[index + 1]
            self.assertIn("unittest", discovery)
            self.assertEqual(
                discovery[-7:],
                [
                    "-m",
                    "unittest",
                    "discover",
                    "--start-directory",
                    start_directory,
                    "--pattern",
                    pattern,
                ],
            )
            self.assertEqual("--append" in discovery, index > 0)
        report = commands[-1]
        self.assertEqual(report[-2:], ["--fail-under", "97"])
        standalone_commands = commands[1 + len(self.gate.UNIT_TEST_DISCOVERY) : -1]
        for script, command in zip(
            self.gate.STANDALONE_TEST_SCRIPTS,
            standalone_commands,
            strict=True,
        ):
            self.assertEqual(command[-1], script)
            self.assertIn("--append", command)

    def test_standalone_acceptance_scripts_map_to_existing_files(self) -> None:
        for script in self.gate.STANDALONE_TEST_SCRIPTS:
            with self.subTest(script=script):
                self.assertTrue((REPO_ROOT / script).is_file())

    def test_unittest_discovery_executes_a_new_test_under_the_supported_root(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-test-discovery-") as tmp_name:
            test_root = Path(tmp_name)
            (test_root / "test_new_feature.py").write_text(
                "import unittest\n"
                "class NewFeatureTest(unittest.TestCase):\n"
                "    def test_discovered(self):\n"
                "        self.assertTrue(True)\n",
                encoding="utf-8",
            )
            command = [
                sys.executable,
                "-m",
                "unittest",
                "discover",
                "--start-directory",
                str(test_root),
                "--pattern",
                self.gate.UNIT_TEST_DISCOVERY[0][1],
            ]
            completed = subprocess.run(
                command,
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("Ran 1 test", completed.stderr)

    def test_run_gate_stops_on_first_failing_command(self) -> None:
        with mock.patch.object(self.gate, "coverage_available", return_value=True):
            with mock.patch.object(self.gate, "run_command", side_effect=[0, 4, 0]) as run:
                self.assertEqual(self.gate.run_gate(95), 4)

        self.assertEqual(run.call_count, 2)

    def test_main_uses_fail_under_argument(self) -> None:
        with mock.patch.object(self.gate, "run_gate", return_value=0) as run_gate:
            self.assertEqual(self.gate.main(["--fail-under", "96"]), 0)

        run_gate.assert_called_once_with(96, collect=True, report=True)

    def test_script_entrypoint_exits_with_main_result(self) -> None:
        with mock.patch.object(sys, "argv", [str(GATE_PATH), "--fail-under", "99"]):
            with mock.patch("subprocess.run") as run:
                run.return_value.returncode = 0
                with self.assertRaises(SystemExit) as raised:
                    runpy.run_path(str(GATE_PATH), run_name="__main__")

        self.assertEqual(raised.exception.code, 0)


if __name__ == "__main__":
    unittest.main()
