#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import io
import runpy
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
GATE_PATH = REPO_ROOT / "scripts" / "project-coverage-gate.py"


def load_gate_module():
    spec = importlib.util.spec_from_file_location("project_coverage_gate", GATE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {GATE_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ProjectCoverageGateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.gate = load_gate_module()

    def test_delivery_runner_reaches_portable_product_suites(self) -> None:
        script = (REPO_ROOT / "scripts/vityo.py").read_text(encoding="utf-8")
        for suite in (
            "daemon-core",
            "workspace-transactions",
            "developer-loop",
            "agent-client-protocol",
            "mcp-host",
            "ide-security",
            "agent-workbench",
            "quality-runtime",
            "recovery-isolation",
        ):
            self.assertIn(f'"{suite}"', script)
        self.assertIn('"native-desktop"', script)
        self.assertIn('"macos-native-ui"', script)

    def test_native_integration_is_reachable_on_each_host_matrix(self) -> None:
        workflow = (
            REPO_ROOT / ".github/workflows/local-ci-gate.yml"
        ).read_text(encoding="utf-8")

        self.assertEqual(workflow.count("scripts/vityo.py deliver --mode ci --platform"), 3)
        self.assertIn("runs-on: ubuntu-latest", workflow)
        self.assertIn("runs-on: windows-latest", workflow)
        self.assertIn("runs-on: macos-latest", workflow)
        self.assertIn("actions-rust-lang/setup-rust-toolchain@ecabd13d1c56bd1345c230e542e9144811ad706f", workflow)
        delivery_source = (REPO_ROOT / "scripts/vityo.py").read_text(encoding="utf-8")
        self.assertIn('"--suite", "native-desktop"', delivery_source)
        self.assertIn('"--suite", "macos-native-ui"', delivery_source)
        self.assertNotIn("--vityo-delivery-smoke", workflow)

    def test_event_refs_are_resolved_for_every_declared_event(self) -> None:
        workflow = (
            REPO_ROOT / ".github/workflows/local-ci-gate.yml"
        ).read_text(encoding="utf-8")
        refs_script = "scripts/resolve-ci-refs.py"

        self.assertEqual(workflow.count(refs_script), 3)
        for event_name in (
            "schedule",
            "pull_request",
            "push",
            "merge_group",
            "workflow_dispatch",
        ):
            self.assertIn(f"  {event_name}:", workflow.split("jobs:", 1)[0])

        for path in ("repo-hygiene.yml",):
            source = (REPO_ROOT / ".github/workflows" / path).read_text(
                encoding="utf-8"
            )
            self.assertIn(refs_script, source)
            self.assertNotIn("github.event.before", source)

    def test_ci_installs_coverage_and_uploads_reports(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/local-ci-gate.yml").read_text(encoding="utf-8")

        self.assertIn('"$PYTHON_BIN" -m pip install coverage', workflow)
        self.assertIn("python -m pip install coverage", workflow)
        self.assertIn("vityo-coverage-reports", workflow)
        self.assertIn("vityo-coverage-reports-linux", workflow)
        self.assertIn("vityo-coverage-reports-windows", workflow)
        self.assertIn("vityo-coverage-reports-macos", workflow)
        self.assertIn("vityo-nightly/.coverage", workflow)
        self.assertIn("vityo-nightly/products/vityo_app/coverage/lcov.info", workflow)

    def test_local_ci_gate_runs_real_platform_delivery_gates(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/local-ci-gate.yml").read_text(encoding="utf-8")
        delivery_source = (REPO_ROOT / "scripts/vityo.py").read_text(encoding="utf-8")

        self.assertIn("runs-on: ubuntu-latest", workflow)
        self.assertIn("runs-on: windows-latest", workflow)
        self.assertIn("runs-on: macos-latest", workflow)
        self.assertEqual(workflow.count("scripts/vityo.py deliver --mode ci --platform"), 3)
        self.assertNotIn("--styio-bin", workflow)
        self.assertNotIn("--pafio-bin", workflow)
        self.assertEqual(workflow.count("--install-root"), 3)
        self.assertNotIn("--vityo-delivery-smoke", workflow)
        for value in ("VITYO_CHROME_PATH:", "CHROME_EXECUTABLE:", "PYTHON_BIN:"):
            self.assertIn(value, workflow)
        self.assertIn('"linux": ("build", "linux", "--release")', delivery_source)
        self.assertIn('"windows": ("build", "windows", "--release")', delivery_source)
        self.assertIn('"macos": ("build", "macos", "--release")', delivery_source)

    def test_project_coverage_workflow_runs_gate_and_uploads_lcov(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/project-coverage-gate.yml").read_text(encoding="utf-8")
        delivery_source = (REPO_ROOT / "scripts/vityo.py").read_text(encoding="utf-8")

        self.assertIn("name: project-coverage-gate", workflow)
        self.assertIn('VITYO_FLUTTER_VERSION: "3.41.7"', workflow)
        self.assertIn("python3 -m pip install coverage", workflow)
        self.assertIn("flutter pub get", workflow)
        self.assertIn("sudo apt-get install -y pkg-config libssl-dev", workflow)
        self.assertIn('RUST_COVERAGE_CLI_VERSION = "0.9.0"', delivery_source)
        self.assertIn("llvm-tools-preview", delivery_source)
        self.assertIn("cargo-llvm-cov", delivery_source)
        self.assertIn("python3 scripts/vityo.py test --scope coverage", workflow)
        self.assertIn("python3 scripts/vityo.py coverage --scope coverage", workflow)
        self.assertIn("vityo-project-coverage", workflow)
        self.assertIn("products/vityo_app/coverage/lcov.info", workflow)
        self.assertIn("build/evidence/rust-coverage", workflow)

    def test_parse_lcov_sums_records_and_rejects_invalid_reports(self) -> None:
        with tempfile.TemporaryDirectory(prefix="project-coverage-", dir=REPO_ROOT) as tmp_name:
            root = Path(tmp_name)
            report = root / "lcov.info"
            report.write_text(
                "SF:a.dart\nLF:10\nLH:9\nend_of_record\n"
                "SF:b.dart\nLF:20\nLH:20\nend_of_record\n",
                encoding="utf-8",
            )
            coverage = self.gate.parse_lcov(report)
            self.assertEqual((coverage.found, coverage.hit), (30, 29))
            self.assertAlmostEqual(coverage.percent, 96.6666666667)

            for content, message in (
                ("LF:not-int\nLH:0\n", "invalid LF counter"),
                ("LF:1\nLH:not-int\n", "invalid LH counter"),
                ("SF:a.dart\n", "no line data"),
                ("LF:1\nLH:2\n", "more hit lines than found lines"),
            ):
                report.write_text(content, encoding="utf-8")
                with self.subTest(message=message):
                    with self.assertRaisesRegex(RuntimeError, message):
                        self.gate.parse_lcov(report)

            with self.assertRaisesRegex(RuntimeError, "lcov report is missing"):
                self.gate.parse_lcov(root / "missing.info")

    def test_run_python_gate_uses_current_interpreter_and_threshold(self) -> None:
        with mock.patch.object(self.gate, "run_command", return_value=0) as run_command:
            self.assertEqual(self.gate.run_python_gate(96), 0)

        command = run_command.call_args.args[0]
        self.assertEqual(command, [sys.executable, str(self.gate.PYTHON_COVERAGE_GATE), "--fail-under", "96"])
        self.assertEqual(run_command.call_args.kwargs["cwd"], self.gate.ROOT)

    def test_run_command_returns_subprocess_exit_code(self) -> None:
        with mock.patch.object(self.gate.subprocess, "run") as run:
            run.return_value.returncode = 17
            self.assertEqual(
                self.gate.run_command(["coverage", "report"], cwd=REPO_ROOT),
                17,
            )

        run.assert_called_once_with(["coverage", "report"], cwd=REPO_ROOT, check=False)

    def test_run_rust_coverage_gate_runs_agent_and_daemon_once_per_phase(self) -> None:
        with mock.patch.object(self.gate, "run_command", return_value=0) as run_command:
            self.assertEqual(
                self.gate.run_rust_coverage_gate(
                    collect=True,
                    report=True,
                    output_dir=Path("build/evidence/rust-coverage"),
                    agent_receipt=Path("build/evidence/agent.json"),
                ),
                0,
            )

        commands = [call.args[0] for call in run_command.call_args_list]
        self.assertEqual(len(commands), 4)
        self.assertEqual(commands[0][commands[0].index("--suite") + 1], "full")
        self.assertIn("--coverage", commands[0])
        self.assertEqual(commands[1][commands[1].index("--product") + 1], "vityod")
        self.assertIn("--collect-only", commands[1])
        self.assertEqual(commands[2][commands[2].index("--suite") + 1], "coverage-report")
        self.assertEqual(commands[3][commands[3].index("--product") + 1], "vityod")
        self.assertIn("--report-only", commands[3])
        self.assertTrue(all("build/evidence/rust-coverage" in command for command in commands))
        self.assertIn("build/evidence/agent.json", commands[0])

    def test_rust_coverage_gate_stops_after_agent_or_daemon_failure(self) -> None:
        for failures, expected_count in (([7], 1), ([0, 8], 2)):
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
                        failures[-1],
                    )
                self.assertEqual(run_command.call_count, expected_count)

    def test_resolve_flutter_binary_uses_path_or_explicit_file(self) -> None:
        with tempfile.TemporaryDirectory(prefix="project-coverage-", dir=REPO_ROOT) as tmp_name:
            explicit = Path(tmp_name) / "flutter"
            explicit.write_text("#!/bin/sh\n", encoding="utf-8")

            with mock.patch.object(self.gate.shutil, "which", return_value="/bin/flutter"):
                self.assertEqual(self.gate.resolve_flutter_binary(None), "/bin/flutter")
                self.assertEqual(self.gate.resolve_flutter_binary("flutter"), "/bin/flutter")

            with mock.patch.object(self.gate.shutil, "which", return_value=None):
                self.assertEqual(self.gate.resolve_flutter_binary(str(explicit)), str(explicit))
                self.assertIsNone(self.gate.resolve_flutter_binary(str(explicit) + "-missing"))

    def test_resolve_lcov_path_uses_default_absolute_or_repo_relative_path(self) -> None:
        original_root = self.gate.ROOT
        try:
            self.gate.ROOT = REPO_ROOT
            app_dir = REPO_ROOT / "products/vityo_app"
            explicit = REPO_ROOT / "out/flutter.lcov.info"

            self.assertEqual(
                self.gate.resolve_lcov_path(
                    app_dir=app_dir,
                    flutter_coverage_path=None,
                ),
                app_dir / "coverage/lcov.info",
            )
            self.assertEqual(
                self.gate.resolve_lcov_path(
                    app_dir=app_dir,
                    flutter_coverage_path=explicit,
                ),
                explicit,
            )
            self.assertEqual(
                self.gate.resolve_lcov_path(
                    app_dir=app_dir,
                    flutter_coverage_path=Path("artifacts/flutter.lcov.info"),
                ),
                REPO_ROOT / "artifacts/flutter.lcov.info",
            )
        finally:
            self.gate.ROOT = original_root

    def test_run_flutter_gate_reports_missing_tool_and_missing_app(self) -> None:
        with mock.patch.object(self.gate, "resolve_flutter_binary", return_value=None):
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                self.assertEqual(
                    self.gate.run_flutter_gate(
                        fail_under=95,
                        flutter_dir=Path("products/vityo_app"),
                        flutter_bin=None,
                    ),
                    2,
                )
        self.assertIn("flutter is required", stderr.getvalue())

        with mock.patch.object(self.gate, "resolve_flutter_binary", return_value="/bin/flutter"):
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                self.assertEqual(
                    self.gate.run_flutter_gate(
                        fail_under=95,
                        flutter_dir=Path("missing/app"),
                        flutter_bin=None,
                    ),
                    2,
                )
        self.assertIn("Flutter app directory is missing", stderr.getvalue())

    def test_run_flutter_gate_runs_tests_parses_lcov_and_applies_threshold(self) -> None:
        with tempfile.TemporaryDirectory(prefix="project-coverage-", dir=REPO_ROOT) as tmp_name:
            root = Path(tmp_name)
            app = root / "app"
            (app / "coverage").mkdir(parents=True)
            vityod_manifest = app / "native/vityod/Cargo.toml"
            vityod_manifest.parent.mkdir(parents=True)
            vityod_manifest.write_text("[workspace]\n", encoding="utf-8")
            # The packaged-Agent handshake needs the Coding Agent built first,
            # so the collection path resolves this manifest too.
            agent_manifest = root / "products/vityo_coding_agent/Cargo.toml"
            agent_manifest.parent.mkdir(parents=True)
            agent_manifest.write_text("[package]\n", encoding="utf-8")
            original_root = self.gate.ROOT
            self.gate.ROOT = root
            try:
                with mock.patch.object(self.gate, "resolve_flutter_binary", return_value="/bin/flutter"):
                    with mock.patch.object(self.gate, "run_command", return_value=7):
                        self.assertEqual(
                            self.gate.run_flutter_gate(
                                fail_under=95,
                                flutter_dir=Path("app"),
                                flutter_bin=None,
                                use_existing_report=False,
                            ),
                            7,
                        )

                    with mock.patch.object(self.gate, "run_command", return_value=0):
                        stderr = io.StringIO()
                        with redirect_stderr(stderr):
                            self.assertEqual(
                                self.gate.run_flutter_gate(
                                    fail_under=95,
                                    flutter_dir=Path("app"),
                                    flutter_bin=None,
                                    use_existing_report=False,
                                ),
                                2,
                            )
                        self.assertIn("lcov report is missing", stderr.getvalue())

                    (app / "coverage/lcov.info").write_text("LF:100\nLH:94\n", encoding="utf-8")
                    with mock.patch.object(self.gate, "run_command", return_value=0):
                        stdout = io.StringIO()
                        with redirect_stdout(stdout):
                            self.assertEqual(
                                self.gate.run_flutter_gate(
                                    fail_under=95,
                                    flutter_dir=Path("app"),
                                    flutter_bin=None,
                                    use_existing_report=False,
                                ),
                                1,
                            )
                        self.assertIn("94.00%", stdout.getvalue())

                    (app / "coverage/lcov.info").write_text("LF:100\nLH:95\n", encoding="utf-8")
                    with mock.patch.object(self.gate, "run_command", return_value=0) as run_command:
                        stdout = io.StringIO()
                        with redirect_stdout(stdout):
                            self.assertEqual(
                                self.gate.run_flutter_gate(
                                    fail_under=95,
                                    flutter_dir=Path("app"),
                                    flutter_bin="/bin/flutter",
                                    use_existing_report=False,
                                ),
                                0,
                            )
                    self.assertEqual(
                        run_command.call_args_list[0],
                        mock.call(
                            [
                                "cargo",
                                "build",
                                "--locked",
                                "--manifest-path",
                                str(vityod_manifest),
                                "-p",
                                "vityod",
                            ],
                            cwd=root,
                        ),
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
                    self.assertIn("95.00%", stdout.getvalue())

                    with mock.patch.object(self.gate, "resolve_flutter_binary", return_value=None):
                        with mock.patch.object(self.gate, "run_command") as run_command:
                            stdout = io.StringIO()
                            with redirect_stdout(stdout):
                                self.assertEqual(
                                    self.gate.run_flutter_gate(
                                        fail_under=95,
                                        flutter_dir=Path("app"),
                                        flutter_bin=None,
                                        use_existing_report=True,
                                    ),
                                    0,
                                )
                    run_command.assert_not_called()
                    self.assertIn("95.00%", stdout.getvalue())
            finally:
                self.gate.ROOT = original_root

    def test_run_flutter_gate_can_parse_explicit_lcov_without_app_directory(self) -> None:
        with tempfile.TemporaryDirectory(prefix="project-coverage-", dir=REPO_ROOT) as tmp_name:
            root = Path(tmp_name)
            report = root / "flutter.lcov.info"
            report.write_text("LF:100\nLH:96\n", encoding="utf-8")
            original_root = self.gate.ROOT
            self.gate.ROOT = root
            try:
                with mock.patch.object(self.gate, "resolve_flutter_binary", return_value=None):
                    with mock.patch.object(self.gate, "run_command") as run_command:
                        stdout = io.StringIO()
                        with redirect_stdout(stdout):
                            self.assertEqual(
                                self.gate.run_flutter_gate(
                                    fail_under=95,
                                    flutter_dir=Path("missing/app"),
                                    flutter_bin=None,
                                    use_existing_report=True,
                                    flutter_coverage_path=Path("flutter.lcov.info"),
                                ),
                                0,
                            )
            finally:
                self.gate.ROOT = original_root

        run_command.assert_not_called()
        self.assertIn("96.00%", stdout.getvalue())

    def test_main_dispatches_scopes_and_short_circuits_failures(self) -> None:
        with mock.patch.object(self.gate, "run_python_gate", return_value=0) as python_gate:
            with mock.patch.object(self.gate, "run_flutter_gate", return_value=0) as flutter_gate:
                with mock.patch.object(self.gate, "run_rust_coverage_gate", return_value=0) as rust_gate:
                    self.assertEqual(self.gate.main(["--fail-under", "96"]), 0)
        python_gate.assert_called_once_with(96, collect=True, report=True)
        flutter_gate.assert_called_once()
        self.assertEqual(flutter_gate.call_args.kwargs["fail_under"], 96)
        self.assertFalse(flutter_gate.call_args.kwargs["use_existing_report"])
        rust_gate.assert_called_once_with(
            collect=True,
            report=True,
            output_dir=Path("build/evidence/rust-coverage"),
            agent_receipt=Path("build/evidence/vityo-coding-agent-full.json"),
        )

        with mock.patch.object(self.gate, "run_python_gate", return_value=5) as python_gate:
            with mock.patch.object(self.gate, "run_flutter_gate", return_value=0) as flutter_gate:
                with mock.patch.object(self.gate, "run_rust_coverage_gate", return_value=0) as rust_gate:
                    self.assertEqual(self.gate.main([]), 5)
        python_gate.assert_called_once_with(95, collect=True, report=True)
        flutter_gate.assert_not_called()
        rust_gate.assert_not_called()

        with mock.patch.object(self.gate, "run_python_gate", return_value=0) as python_gate:
            with mock.patch.object(self.gate, "run_flutter_gate", return_value=4) as flutter_gate:
                with mock.patch.object(self.gate, "run_rust_coverage_gate", return_value=0) as rust_gate:
                    self.assertEqual(
                        self.gate.main(
                            [
                                "--skip-python",
                                "--flutter-fail-under",
                                "97",
                                "--flutter-dir",
                                "app",
                                "--flutter-bin",
                                "/bin/flutter",
                                "--use-existing-flutter-coverage",
                            ]
                        ),
                        4,
                    )
        python_gate.assert_not_called()
        flutter_gate.assert_called_once()
        rust_gate.assert_not_called()
        self.assertEqual(flutter_gate.call_args.kwargs["fail_under"], 97)
        self.assertEqual(flutter_gate.call_args.kwargs["flutter_dir"], Path("app"))
        self.assertEqual(flutter_gate.call_args.kwargs["flutter_bin"], "/bin/flutter")
        self.assertTrue(flutter_gate.call_args.kwargs["use_existing_report"])
        self.assertIsNone(flutter_gate.call_args.kwargs["flutter_coverage_path"])

        with mock.patch.object(self.gate, "run_python_gate", return_value=0) as python_gate:
            with mock.patch.object(self.gate, "run_flutter_gate", return_value=0) as flutter_gate:
                with mock.patch.object(self.gate, "run_rust_coverage_gate", return_value=0) as rust_gate:
                    self.assertEqual(
                        self.gate.main(
                            [
                                "--skip-python",
                                "--use-existing-flutter-coverage",
                                "--flutter-coverage-path",
                                "artifacts/flutter.lcov.info",
                            ]
                        ),
                        0,
                    )
        python_gate.assert_not_called()
        flutter_gate.assert_called_once()
        rust_gate.assert_called_once()
        self.assertEqual(
            flutter_gate.call_args.kwargs["flutter_coverage_path"],
            Path("artifacts/flutter.lcov.info"),
        )

        with mock.patch.object(self.gate, "run_python_gate", return_value=0) as python_gate:
            with mock.patch.object(self.gate, "run_flutter_gate", return_value=0) as flutter_gate:
                with mock.patch.object(self.gate, "run_rust_coverage_gate", return_value=0) as rust_gate:
                    self.assertEqual(self.gate.main(["--skip-flutter", "--python-fail-under", "98"]), 0)
        python_gate.assert_called_once_with(98, collect=True, report=True)
        flutter_gate.assert_not_called()
        rust_gate.assert_called_once()

        with mock.patch.object(self.gate, "run_python_gate", return_value=0), mock.patch.object(
            self.gate, "run_flutter_gate", return_value=0
        ), mock.patch.object(self.gate, "run_rust_coverage_gate", return_value=0) as rust_gate:
            self.assertEqual(self.gate.main(["--skip-python", "--skip-flutter"]), 0)
        rust_gate.assert_called_once()

    def test_script_entrypoint_exits_with_main_result(self) -> None:
        with mock.patch.object(sys, "argv", [str(GATE_PATH), "--unknown-option"]):
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                with self.assertRaises(SystemExit) as raised:
                    runpy.run_path(str(GATE_PATH), run_name="__main__")

        self.assertEqual(raised.exception.code, 2)
        self.assertIn("unrecognized arguments", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
