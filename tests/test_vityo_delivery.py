from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "vityo.py"


def load_delivery():
    spec = importlib.util.spec_from_file_location("vityo_delivery_test_target", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class VityoDeliveryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.delivery = load_delivery()

    def test_shared_coverage_command_carries_distinct_rust_reports_and_receipt(self) -> None:
        options = self.delivery.DeliveryOptions(
            evidence_dir=Path("build/custom-evidence"),
            flutter_dir=Path("products/custom-app"),
        )
        command = self.delivery._project_coverage_command(options, collect_only=True)

        self.assertEqual(command[1:3], ("scripts/project-coverage-gate.py", "--python-fail-under"))
        self.assertIn("--collect-only", command)
        self.assertEqual(
            Path(command[command.index("--flutter-dir") + 1]),
            Path("products/custom-app"),
        )
        self.assertEqual(
            command[command.index("--rust-coverage-dir") + 1],
            "build/custom-evidence/rust-coverage",
        )
        self.assertEqual(
            command[command.index("--agent-receipt") + 1],
            "build/custom-evidence/vityo-coding-agent-full.json",
        )

    def test_stage_builds_current_agent_and_daemon_before_ide_suites(self) -> None:
        options = self.delivery.DeliveryOptions(platform="macos")
        commands: list[tuple[str, ...]] = []

        def runner(argv, _cwd, _environment):
            commands.append(tuple(argv))
            return 0

        with mock.patch.dict(
            os.environ,
            {"CI": "", "GITHUB_ACTIONS": "", "VITYO_PRODUCT_GATE": ""},
            clear=False,
        ), mock.patch.object(self.delivery, "resolve_pinned_cli", return_value=Path("/pinned/styio")), mock.patch.object(
            self.delivery, "require_rust_toolchain", return_value=True
        ), mock.patch.object(
            self.delivery, "ensure_rust_coverage_tools", return_value=True
        ) as coverage_tools, mock.patch.object(
            self.delivery.shutil, "which", return_value="/tools/flutter"
        ), mock.patch.object(
            self.delivery, "_project_coverage_command", return_value=("python3", "project-coverage-gate.py", "--collect-only")
        ), mock.patch.object(
            self.delivery, "_run_language_fixture_gate",
            side_effect=lambda _options: runner(("language-fixtures",), None, None),
        ), mock.patch.object(
            self.delivery, "run_command", return_value=0
        ):
            self.assertEqual(self.delivery.run_test_stage(options, runner=runner), 0)

        coverage_runs = [command for command in commands if command[:2] == ("python3", "project-coverage-gate.py")]
        self.assertEqual(coverage_runs, [("python3", "project-coverage-gate.py", "--collect-only")])
        suite_runs = [command for command in commands if "--suite" in command]
        self.assertEqual(
            {command[command.index("--suite") + 1] for command in suite_runs},
            set(self.delivery.PORTABLE_IDE_SUITES),
        )
        self.assertEqual(len(suite_runs), 9)
        agent_build = (
            "cargo",
            "build",
            "--locked",
            "--manifest-path",
            "products/vityo_coding_agent/Cargo.toml",
            "--bin",
            "vityo-coding-agent",
            "--target-dir",
            "products/vityo_coding_agent/target",
        )
        daemon_build = (
            "cargo",
            "build",
            "--locked",
            "--manifest-path",
            "products/vityo_app/native/vityod/crates/vityod/Cargo.toml",
            "--bin",
            "vityod",
            "--target-dir",
            "products/vityo_app/native/vityod/target",
        )
        self.assertEqual(
            [command for command in commands if command[:2] == ("cargo", "build")],
            [agent_build, daemon_build],
        )
        self.assertLess(
            commands.index(coverage_runs[0]),
            commands.index(agent_build),
        )
        self.assertLess(
            commands.index(agent_build),
            commands.index(daemon_build),
        )
        self.assertLess(
            commands.index(daemon_build),
            min(commands.index(command) for command in suite_runs),
        )
        self.assertFalse(any(command[:2] == ("cargo", "test") for command in commands))
        self.assertLess(
            max(commands.index(command) for command in suite_runs),
            commands.index(("language-fixtures",)),
        )
        self.assertLess(
            commands.index(("language-fixtures",)),
            commands.index(("npm", "run", "governance")),
        )
        self.assertFalse(any(command[0].startswith("<") for command in commands))
        self.assertFalse(
            any(
                "vityo_quality.py" in command and "coding-agent" in command
                for command in commands
            )
        )
        coverage_tools.assert_called_once_with(runner=runner)

    def test_language_fixture_failure_stops_before_prototype_checks(self) -> None:
        runner = mock.Mock(return_value=0)
        with mock.patch.object(self.delivery, "resolve_pinned_cli", return_value=Path("/pinned/styio")), mock.patch.object(
            self.delivery, "require_rust_toolchain", return_value=True
        ), mock.patch.object(self.delivery, "ensure_rust_coverage_tools", return_value=True), mock.patch.object(
            self.delivery.shutil, "which", return_value="/tools/flutter"
        ), mock.patch.object(self.delivery, "_run_language_fixture_gate", return_value=19):
            self.assertEqual(
                self.delivery.run_test_stage(self.delivery.DeliveryOptions(platform="macos"), runner=runner),
                19,
            )
        self.assertFalse(any(call.args[0][0] == "npm" for call in runner.call_args_list))

    def test_macos_launch_opens_new_candidate_and_propagates_launch_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            install_root = Path(temporary) / "Vityo.app"
            executable = install_root / self.delivery.PACKAGE_EXECUTABLES["macos"]
            executable.parent.mkdir(parents=True)
            executable.touch()
            options = self.delivery.DeliveryOptions(platform="macos", install_root=install_root)
            for code in (0, 11):
                with self.subTest(exit_code=code), mock.patch.object(
                    self.delivery, "host_platform", return_value="macos"
                ), mock.patch.object(self.delivery, "_load_package_candidate"), mock.patch.object(
                    self.delivery.shutil, "which", return_value="/usr/bin/open"
                ), mock.patch.object(self.delivery, "run_command", return_value=code) as runner:
                    self.assertEqual(self.delivery.run_launch_stage(options), code)
                runner.assert_called_once_with(
                    ["/usr/bin/open", "-n", "-a", str(install_root)], ROOT, None
                )

    def test_each_product_lane_validates_its_real_report_and_stops_on_oracle_failure(self) -> None:
        for platform in ("linux", "windows", "macos"):
            options = self.delivery.DeliveryOptions(platform=platform)
            with self.subTest(platform=platform), mock.patch.object(
                self.delivery, "run_command", side_effect=(0, 17)
            ) as runner:
                self.assertEqual(
                    self.delivery._run_product_acceptance(options, Path("styio"), Path("pafio")),
                    17,
                )
            self.assertEqual(runner.call_count, 2)
            producer = runner.call_args_list[0].args[0]
            self.assertIn("--require-real-matrix", producer)
            self.assertEqual(producer[producer.index("--platform") + 1], platform)
            report = producer[producer.index("--output") + 1]
            self.assertEqual(
                runner.call_args_list[1].args[0],
                ("dart", "run", "tests/acceptance/vityo_app/trusted_desktop_styio_loop_acceptance_test.dart",
                 "--report", report, "--platform", platform),
            )

    def test_coverage_scope_collects_only_through_project_gate(self) -> None:
        options = self.delivery.DeliveryOptions(platform="linux", scope="coverage")
        with mock.patch.object(self.delivery, "require_rust_toolchain", return_value=True), mock.patch.object(
            self.delivery, "ensure_rust_coverage_tools", return_value=True
        ) as coverage_tools, mock.patch.object(
            self.delivery, "_project_coverage_command", return_value=("python3", "project-coverage-gate.py", "--collect-only")
        ) as project_command:
            runner = mock.Mock(return_value=0)
            self.assertEqual(
                self.delivery.run_test_stage(
                    options,
                    runner=runner,
                ),
                0,
            )
        project_command.assert_called_once_with(options, collect_only=True)
        coverage_tools.assert_called_once_with(runner=runner)
        runner.assert_called_once_with(
            ("python3", "project-coverage-gate.py", "--collect-only"),
            self.delivery.ROOT,
            None,
        )

    def test_coverage_tool_preparation_reuses_only_the_pinned_cli_version(self) -> None:
        runner = mock.Mock(return_value=0)
        with mock.patch.object(
            self.delivery.shutil,
            "which",
            side_effect=("/tools/rustup", "/tools/cargo", "/tools/cargo-llvm-cov"),
        ), mock.patch.object(
            self.delivery.subprocess,
            "run",
            return_value=mock.Mock(returncode=0, stdout="cargo-llvm-cov 0.9.0\n"),
        ):
            self.assertTrue(self.delivery.ensure_rust_coverage_tools(runner=runner))

        runner.assert_called_once_with(
            ("/tools/rustup", "component", "add", "llvm-tools-preview"),
            ROOT,
            None,
        )

    def test_coverage_tool_preparation_installs_and_rechecks_exact_version(self) -> None:
        runner = mock.Mock(return_value=0)
        with mock.patch.object(
            self.delivery.shutil,
            "which",
            side_effect=(
                "/tools/rustup",
                "/tools/cargo",
                "/tools/cargo-llvm-cov",
                "/tools/cargo-llvm-cov",
            ),
        ), mock.patch.object(
            self.delivery.subprocess,
            "run",
            side_effect=(
                mock.Mock(returncode=0, stdout="cargo-llvm-cov 0.8.0\n"),
                mock.Mock(returncode=0, stdout="cargo-llvm-cov 0.9.0\n"),
            ),
        ):
            self.assertTrue(self.delivery.ensure_rust_coverage_tools(runner=runner))

        self.assertEqual(
            [call.args[0] for call in runner.call_args_list],
            [
                ("/tools/rustup", "component", "add", "llvm-tools-preview"),
                (
                    "/tools/cargo",
                    "install",
                    "--locked",
                    "--version",
                    "0.9.0",
                    "--force",
                    "cargo-llvm-cov",
                ),
            ],
        )

    def test_coverage_tool_preparation_requires_rustup_and_cargo(self) -> None:
        with mock.patch.object(self.delivery.shutil, "which", return_value=None):
            self.assertFalse(self.delivery.ensure_rust_coverage_tools())

    def test_coverage_tool_preparation_propagates_component_and_install_failures(self) -> None:
        with self.subTest(stage="component"):
            runner = mock.Mock(return_value=12)
            with mock.patch.object(
                self.delivery.shutil,
                "which",
                side_effect=("/tools/rustup", "/tools/cargo"),
            ):
                self.assertFalse(self.delivery.ensure_rust_coverage_tools(runner=runner))
            runner.assert_called_once_with(
                ("/tools/rustup", "component", "add", "llvm-tools-preview"),
                ROOT,
                None,
            )

        with self.subTest(stage="install"):
            runner = mock.Mock(side_effect=(0, 12))
            with mock.patch.object(
                self.delivery.shutil,
                "which",
                side_effect=("/tools/rustup", "/tools/cargo", None),
            ):
                self.assertFalse(self.delivery.ensure_rust_coverage_tools(runner=runner))
            self.assertEqual(runner.call_count, 2)

    def test_coverage_tool_preparation_rejects_a_failed_installed_version_check(self) -> None:
        runner = mock.Mock(return_value=0)
        with mock.patch.object(
            self.delivery.shutil,
            "which",
            side_effect=(
                "/tools/rustup",
                "/tools/cargo",
                "/tools/cargo-llvm-cov",
                "/tools/cargo-llvm-cov",
            ),
        ), mock.patch.object(
            self.delivery.subprocess,
            "run",
            side_effect=(
                mock.Mock(returncode=0, stdout="cargo-llvm-cov 0.8.0\n"),
                mock.Mock(returncode=1, stdout=""),
            ),
        ):
            self.assertFalse(self.delivery.ensure_rust_coverage_tools(runner=runner))
        self.assertEqual(runner.call_count, 2)

    def test_coverage_stage_reports_existing_reports_without_collection(self) -> None:
        options = self.delivery.DeliveryOptions(evidence_dir=Path("build/ci-evidence"))
        calls: list[tuple[str, ...]] = []

        def runner(argv, _cwd, _environment):
            calls.append(tuple(argv))
            return 0

        with mock.patch.object(
            self.delivery, "_project_coverage_command", return_value=("python3", "project-coverage-gate.py", "--report-only")
        ) as project_command:
            self.assertEqual(self.delivery.run_coverage_stage(options, runner=runner), 0)
        project_command.assert_called_once_with(options, collect_only=False)
        self.assertEqual(calls, [("python3", "project-coverage-gate.py", "--report-only")])

    def test_command_pipeline_stops_at_first_failure(self) -> None:
        calls: list[tuple[str, ...]] = []

        def runner(argv, _cwd, _environment):
            calls.append(tuple(argv))
            return 23 if len(calls) == 2 else 0

        code = self.delivery.run_commands(
            (
                self.delivery.Command("first", ("first",)),
                self.delivery.Command("second", ("second",)),
                self.delivery.Command("must not run", ("third",)),
            ),
            runner=runner,
        )
        self.assertEqual(code, 23)
        self.assertEqual(calls, [("first",), ("second",)])

    def test_explicit_unpinned_tool_override_fails_without_provisioning(self) -> None:
        candidate = ROOT / "scripts" / "vityo.py"
        with mock.patch.object(self.delivery, "validate_executable", return_value=False), mock.patch.object(
            self.delivery, "provision"
        ) as provision:
            with self.assertRaisesRegex(ValueError, "not built from the pinned product-matrix revision"):
                self.delivery.resolve_pinned_cli(
                    "styio", str(candidate), environment={}
                )
        provision.assert_not_called()


if __name__ == "__main__":
    unittest.main()
