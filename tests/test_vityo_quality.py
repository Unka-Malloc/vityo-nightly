"""Focused tests for IDE and Rust Agent quality runner behavior.

Adjacent to acceptance_paths because injectable runners, missing tools, early
harness failure, source drift, and receipt-destination failures cannot be
oracled safely through a real suite subprocess. Never invokes bare ide/full.
"""

from __future__ import annotations

import importlib.util
import io
import json
import pathlib
import sys
import tempfile
import unittest
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "vityo_quality.py"
SCRIPTS_PATH = str(SCRIPT_PATH.parent)
if SCRIPTS_PATH not in sys.path:
    sys.path.insert(0, SCRIPTS_PATH)


def load_module():
    spec = importlib.util.spec_from_file_location(
        "vityo_quality_test_target",
        SCRIPT_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class VityoQualityTest(unittest.TestCase):
    suite_runners = (
        "cutover",
        "workspace_transactions",
        "developer_loop",
        "agent_client_protocol",
        "mcp_host",
        "ide_security",
        "agent_workbench",
        "native_desktop",
        "macos_native_ui",
        "quality_runtime",
        "recovery_isolation",
        "daemon_core",
        "ide_quality",
    )

    def setUp(self) -> None:
        self.quality = load_module()
        # Native build/define wiring has its own portable mocked suite.
        command_patch = mock.patch.object(self.quality, "test_command",
                                          side_effect=lambda command, **kwargs: command)
        command_patch.start()
        self.addCleanup(command_patch.stop)

    def test_tool_and_run_are_fail_closed(self) -> None:
        with mock.patch.object(
            self.quality.shutil,
            "which",
            return_value="/tools/dart",
        ):
            self.assertEqual(self.quality.tool("dart"), "/tools/dart")

        with mock.patch.object(self.quality.shutil, "which", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "required tool"):
                self.quality.tool("missing")

        completed = SimpleNamespace(returncode=7)
        environment = {"VITYO_TEST": "1"}
        stdout = io.StringIO()
        with mock.patch.object(
            self.quality.subprocess,
            "run",
            return_value=completed,
        ) as run:
            with redirect_stdout(stdout):
                code = self.quality.run(
                    ["dart", "test"],
                    self.quality.ROOT,
                    environment,
                )

        self.assertEqual(code, 7)
        self.assertIn("[vityo-quality] .: dart test", stdout.getvalue())
        run.assert_called_once_with(
            ["dart", "test"],
            cwd=self.quality.ROOT,
            check=False,
            env=environment,
        )

    def test_preflight_reports_required_tools_and_supported_host(self) -> None:
        with mock.patch.object(self.quality.shutil, "which", return_value=None):
            with self.assertRaisesRegex(
                self.quality.ValidationReportError,
                "tool_unavailable",
            ):
                self.quality._resolve_required_tools()
        with mock.patch.object(
            self.quality.shutil,
            "which",
            return_value="/tools/fixture",
        ):
            self.quality._resolve_required_tools()

        for raw, expected in (
            ("win32", "windows"),
            ("darwin", "macos"),
            ("linux", "linux"),
            ("other", "other"),
        ):
            with self.subTest(platform=raw):
                with mock.patch.object(self.quality.sys, "platform", raw):
                    self.assertEqual(self.quality._host_platform(), expected)

    def test_all_focused_suite_runners_execute_and_stop_on_failure(self) -> None:
        for name in self.suite_runners:
            runner = getattr(self.quality, name)
            with self.subTest(runner=name, outcome="success"):
                with mock.patch.object(
                    self.quality,
                    "tool",
                    side_effect=lambda tool_name: f"/tools/{tool_name}",
                ):
                    with mock.patch.object(
                        self.quality,
                        "run",
                        return_value=0,
                    ) as run, mock.patch.object(
                        self.quality, "_host_platform", return_value="macos"
                    ):
                        self.assertEqual(runner(), 0)
                self.assertGreater(run.call_count, 0)

            with self.subTest(runner=name, outcome="failure"):
                with mock.patch.object(
                    self.quality,
                    "tool",
                    side_effect=lambda tool_name: f"/tools/{tool_name}",
                ):
                    with mock.patch.object(
                        self.quality,
                        "run",
                        return_value=9,
                    ) as run, mock.patch.object(
                        self.quality, "_host_platform", return_value="macos"
                    ):
                        self.assertEqual(runner(), 9)
                self.assertEqual(run.call_count, 1)

    def test_suite_runner_command_paths_exist(self) -> None:
        commands: list[tuple[list[str], Path]] = []
        for name in self.suite_runners:
            with mock.patch.object(
                self.quality,
                "tool",
                side_effect=lambda tool_name: f"/tools/{tool_name}",
            ):
                with mock.patch.object(
                    self.quality,
                    "run",
                    side_effect=lambda command, cwd, *_args: (
                        commands.append((command, Path(cwd))) or 0
                    ),
                ), mock.patch.object(
                    self.quality, "_host_platform", return_value="macos"
                ):
                    self.assertEqual(getattr(self.quality, name)(), 0)

        for command, cwd in commands:
            for argument in command:
                if argument.startswith("-") or not argument.endswith(
                    (".dart", ".py", ".toml")
                ):
                    continue
                source_path = Path(argument)
                if not source_path.is_absolute():
                    source_path = cwd / source_path
                with self.subTest(command=command, source=source_path.name):
                    self.assertTrue(source_path.is_file(), str(source_path))

    def test_app_integration_tests_are_mapped_to_executable_suites(self) -> None:
        product = self.quality.ROOT / "products" / "vityo_app"
        integration_dir = product / "integration_test"
        runner_source = SCRIPT_PATH.read_text(encoding="utf-8")

        for test_path in sorted(integration_dir.glob("*.dart")):
            with self.subTest(integration_test=test_path.name):
                if test_path.name.endswith("_native_ui_test.dart"):
                    self.assertIn("*_native_ui_test.dart", runner_source)
                else:
                    self.assertIn(test_path.name, runner_source)

        macos_paths = self.quality._macos_native_ui_test_paths(product)
        self.assertEqual(
            set(macos_paths),
            set(integration_dir.glob("*_native_ui_test.dart"))
            | {
                integration_dir / "editor_native_input_test.dart",
                integration_dir / "platform_secure_credential_storage_test.dart",
                integration_dir / "workbench_visual_capture_test.dart",
            },
        )
        self.assertTrue(all(path.is_file() for path in macos_paths))

    def test_native_desktop_rejects_unsupported_host_before_running_tools(self) -> None:
        with mock.patch.object(
            self.quality, "_host_platform", return_value="windows"
        ), mock.patch.object(self.quality, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "requires Linux or macOS"):
                self.quality.native_desktop()
        run.assert_not_called()

    def test_macos_native_ui_runner_targets_all_macos_integration_tests(self) -> None:
        with mock.patch.object(
            self.quality,
            "_host_platform",
            return_value="macos",
        ):
            with mock.patch.object(
                self.quality,
                "tool",
                return_value="/tools/flutter",
            ):
                with mock.patch.object(
                    self.quality,
                    "run",
                    return_value=0,
                ) as run:
                    self.assertEqual(self.quality.macos_native_ui(), 0)

        product = self.quality.ROOT / "products" / "vityo_app"
        expected_paths = self.quality._macos_native_ui_test_paths(product)
        self.assertEqual(run.call_count, len(expected_paths))
        for call, test_path in zip(run.call_args_list, expected_paths, strict=True):
            command, cwd = call.args[:2]
            self.assertEqual(
                command[:5],
                ["/tools/flutter", "test", "--no-pub", "-d", "macos"],
            )
            self.assertEqual(cwd, product)
            self.assertEqual(command[5], str(test_path.relative_to(product)))

        with mock.patch.object(
            self.quality,
            "_host_platform",
            return_value="windows",
        ):
            with self.assertRaisesRegex(RuntimeError, "require a macOS host"):
                self.quality.macos_native_ui()

    def test_formal_quality_lane_owns_one_complete_flutter_test(self) -> None:
        with mock.patch.object(
            self.quality,
            "tool",
            side_effect=lambda tool_name: f"/tools/{tool_name}",
        ):
            with mock.patch.object(
                self.quality,
                "run",
                return_value=0,
            ) as run:
                self.assertEqual(self.quality.ide_quality(), 0)

        commands = [call.args[0] for call in run.call_args_list]
        self.assertIn(["/tools/flutter", "test", "--no-pub"], commands)
        self.assertNotIn(
            ["/tools/flutter", "test", "test/ide_quality"],
            commands,
        )

        with mock.patch.object(
            self.quality,
            "tool",
            side_effect=lambda tool_name: f"/tools/{tool_name}",
        ):
            with mock.patch.object(
                self.quality,
                "run",
                return_value=0,
            ) as run:
                self.assertEqual(self.quality.agent_workbench(), 0)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertIn(
            ["/tools/flutter", "test", "--no-pub", "test/agent_workbench"],
            commands,
        )

    def test_dart_package_preparation_resolves_a_clean_checkout(self) -> None:
        """A clean checkout has no package config, so resolution must run first.

        The protocol packages are analysed with bare `dart analyze`/`dart test`.
        With a warm `.dart_tool` that works, but on a clean CI checkout the
        analyzer cannot resolve `package:test` or `package:lints` and reports the
        package's own libraries as undefined names.
        """
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            package = pathlib.Path(tmp) / "protocol"
            (package / ".dart_tool").mkdir(parents=True)
            (package / ".dart_tool" / "package_config.json").write_text(
                "{}\n", encoding="utf-8"
            )
            with mock.patch.object(self.quality, "run") as run:
                self.assertEqual(
                    self.quality.ensure_dart_package("/tools/dart", package), 0
                )
            run.assert_not_called()

            (package / ".dart_tool" / "package_config.json").unlink()
            with mock.patch.object(self.quality, "run", return_value=0) as run:
                self.assertEqual(
                    self.quality.ensure_dart_package("/tools/dart", package), 0
                )
            run.assert_called_once_with(["/tools/dart", "pub", "get"], package)

            with mock.patch.object(self.quality, "run", return_value=65):
                self.assertEqual(
                    self.quality.ensure_dart_package("/tools/dart", package), 65
                )

    def test_daemon_core_prepares_the_package_before_analyzing(self) -> None:
        """Resolution is wired ahead of analysis, on the daemon package."""
        recorded: list[list[str]] = []

        def record(command, cwd=None, environment=None):
            recorded.append(list(command))
            return 0

        with mock.patch.object(
            self.quality, "tool", return_value="/tools/dart"
        ), mock.patch.object(
            self.quality, "ensure_dart_package", return_value=0
        ) as prepare, mock.patch.object(
            self.quality, "run", side_effect=record
        ):
            self.assertEqual(self.quality.daemon_core(), 0)
        self.assertEqual(
            prepare.call_args.args[1],
            self.quality.ROOT / "packages" / "vityo_daemon_protocol",
        )
        self.assertEqual(recorded[0], ["/tools/dart", "analyze"])
        self.assertEqual(recorded[1], ["/tools/dart", "test"])

    def test_daemon_core_stops_when_the_package_cannot_be_resolved(self) -> None:
        with mock.patch.object(
            self.quality, "tool", return_value="/tools/dart"
        ), mock.patch.object(
            self.quality, "ensure_dart_package", return_value=65
        ), mock.patch.object(self.quality, "run") as run:
            self.assertEqual(self.quality.daemon_core(), 65)
        run.assert_not_called()

    def test_mcp_runners_analyze_only_cutover_authority(self) -> None:
        expected = {
            "mcp_host": [
                "/tools/dart",
                "analyze",
                "lib/src/ide/agent_client/mcp",
                "test/mcp_host",
                "integration_test/mcp_host_test.dart",
            ],
            "ide_security": [
                "/tools/dart",
                "analyze",
                "lib/src/ide/agent_client/mcp",
                "test/mcp_host/mcp_host_security_test.dart",
            ],
        }
        removed_paths = {
            "lib/src/ide/agent_client/tools",
            "lib/src/ide/extensions",
        }

        for runner_name, analyze_command in expected.items():
            with self.subTest(runner=runner_name):
                with mock.patch.object(
                    self.quality,
                    "tool",
                    side_effect=lambda tool_name: f"/tools/{tool_name}",
                ):
                    with mock.patch.object(
                        self.quality,
                        "run",
                        return_value=0,
                    ) as run:
                        self.assertEqual(
                            getattr(self.quality, runner_name)(),
                            0,
                        )

                commands = [call.args[0] for call in run.call_args_list]
                self.assertEqual(commands[0], analyze_command)
                self.assertTrue(
                    removed_paths.isdisjoint(analyze_command),
                    analyze_command,
                )

    def test_host_mapping_is_reported_without_source_checks(self) -> None:
        with (
            mock.patch.object(self.quality.shutil, "which", return_value="/tools/fixture"),
            mock.patch.object(self.quality, "_host_platform", return_value="macos"),
        ):
            report = self.quality._preflight_ide_full()
        self.assertTrue(report["ready"])
        self.assertEqual(report["platform"], "macos")
        self.assertEqual(
            [item["name"] for item in report["checks"]],
            ["requirement_mapping", "tools", "host"],
        )
        self.assertEqual(
            [item["requirement"] for item in report["requirements"]],
            [f"REQ-IDE-{index:03d}" for index in range(1, 9)],
        )

    def _patch_ide_runners(self, stack: ExitStack, *, failing: str | None = None):
        runners = {}
        for entry in self.quality.FULL_IDE_PLAN:
            runners[entry.requirement] = stack.enter_context(
                mock.patch.object(
                    self.quality,
                    entry.runner_name,
                    return_value=1 if entry.requirement == failing else 0,
                )
            )
        return runners

    def test_ide_plan_and_preflight_do_not_run_suites_or_write_reports(self) -> None:
        plan = self.quality.full_suite_plan()
        self.assertEqual(
            [entry["requirement"] for entry in plan],
            [f"REQ-IDE-{index:03d}" for index in range(1, 9)],
        )

        stdout = io.StringIO()
        with redirect_stdout(stdout):
            self.assertEqual(
                self.quality.ide_full(
                    plan_only=True,
                    preflight=False,
                    report_path=Path("unused.json"),
                ),
                0,
            )
        self.assertEqual(json.loads(stdout.getvalue())["mode"], "plan_only")

        with ExitStack() as stack:
            runners = self._patch_ide_runners(stack)
            stack.enter_context(
                mock.patch.object(
                    self.quality.shutil,
                    "which",
                    return_value="/tools/fixture",
                )
            )
            stack.enter_context(
                mock.patch.object(self.quality, "_host_platform", return_value="linux")
            )
            stack.enter_context(
                mock.patch.object(
                    self.quality,
                    "write_report_atomic",
                    side_effect=AssertionError("preflight must not persist a report"),
                )
            )
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                self.assertEqual(
                    self.quality.ide_full(
                        plan_only=False,
                        preflight=True,
                        report_path=Path("unused.json"),
                    ),
                    0,
                )
        report = json.loads(stdout.getvalue())
        self.assertTrue(report["ready"])
        self.assertEqual(report["platform"], "linux")
        self.assertEqual([item["name"] for item in report["checks"]], [
            "requirement_mapping",
            "tools",
            "host",
        ])
        for runner in runners.values():
            runner.assert_not_called()

    def test_ide_formal_run_records_not_run_then_overwrites_with_actual_results(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-quality-report-") as directory:
            report_path = Path(directory) / "nested" / "ide-full.json"
            with ExitStack() as stack:
                runners = self._patch_ide_runners(stack)
                stack.enter_context(
                    mock.patch.object(self.quality.shutil, "which", return_value=None)
                )
                stack.enter_context(
                    mock.patch.object(self.quality, "_host_platform", return_value="linux")
                )
                self.assertEqual(
                    self.quality.ide_full(
                        plan_only=False,
                        preflight=False,
                        report_path=report_path,
                    ),
                    1,
                )
            failed_preflight = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(failed_preflight["status"], "failed")
            self.assertEqual(failed_preflight["failure_code"], "tool_unavailable")
            self.assertEqual(
                {item["status"] for item in failed_preflight["requirements"].values()},
                {"not-run"},
            )
            for runner in runners.values():
                runner.assert_not_called()

            with ExitStack() as stack:
                runners = self._patch_ide_runners(stack)
                stack.enter_context(
                    mock.patch.object(
                        self.quality.shutil,
                        "which",
                        return_value="/tools/fixture",
                    )
                )
                stack.enter_context(
                    mock.patch.object(self.quality, "_host_platform", return_value="linux")
                )
                self.assertEqual(
                    self.quality.ide_full(
                        plan_only=False,
                        preflight=False,
                        report_path=report_path,
                    ),
                    0,
                )
            passed = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(passed["status"], "passed")
            self.assertEqual(passed["platform"], "linux")
            self.assertEqual(len(passed["requirements"]), 8)
            for outcome in passed["requirements"].values():
                self.assertEqual(outcome["status"], "passed")
                self.assertIn("runner", outcome)
                self.assertGreaterEqual(outcome["duration_ms"], 0)
            for runner in runners.values():
                runner.assert_called_once()

    def test_ide_suite_failure_keeps_other_actual_results(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-quality-report-") as directory:
            report_path = Path(directory) / "ide-full.json"
            failing_requirement = "REQ-IDE-004"
            with ExitStack() as stack:
                runners = self._patch_ide_runners(stack, failing=failing_requirement)
                stack.enter_context(
                    mock.patch.object(
                        self.quality.shutil,
                        "which",
                        return_value="/tools/fixture",
                    )
                )
                stack.enter_context(
                    mock.patch.object(self.quality, "_host_platform", return_value="linux")
                )
                self.assertEqual(
                    self.quality.ide_full(
                        plan_only=False,
                        preflight=False,
                        report_path=report_path,
                    ),
                    1,
                )
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(report["failure_code"], "suite_failed")
            self.assertEqual(report["requirements"][failing_requirement]["status"], "failed")
            self.assertEqual(
                sum(item["status"] == "passed" for item in report["requirements"].values()),
                7,
            )
            for runner in runners.values():
                runner.assert_called_once()

    def test_ide_report_write_failure_is_safe(self) -> None:
        with ExitStack() as stack:
            self._patch_ide_runners(stack)
            stack.enter_context(
                mock.patch.object(
                    self.quality.shutil,
                    "which",
                    return_value="/tools/fixture",
                )
            )
            stack.enter_context(
                mock.patch.object(self.quality, "_host_platform", return_value="linux")
            )
            stack.enter_context(
                mock.patch.object(
                    self.quality,
                    "write_report_atomic",
                    side_effect=OSError("private fixture detail"),
                )
            )
            stdout = io.StringIO()
            with tempfile.TemporaryDirectory() as directory, redirect_stdout(stdout):
                result = self.quality.ide_full(
                    plan_only=False,
                    preflight=False,
                    report_path=Path(directory) / "ide-full.json",
                )
        self.assertEqual(result, 1)
        report = json.loads(stdout.getvalue())
        self.assertEqual(report["failure_code"], "report_write_failed")
        self.assertNotIn("private fixture detail", stdout.getvalue())

    def test_agent_focused_selectors_use_locked_rust_test_targets(self) -> None:
        self.assertEqual(len(self.quality.FULL_AGENT_PLAN), 9)
        for entry in self.quality.FULL_AGENT_PLAN:
            with self.subTest(requirement=entry.requirement):
                with mock.patch.object(self.quality, "tool", return_value="/tools/cargo"):
                    with mock.patch.object(self.quality, "run", return_value=0) as run:
                        self.assertEqual(self.quality.coding_agent_suite(entry), 0)
                run.assert_called_once()
                command = run.call_args.args[0]
                self.assertEqual(command[0], "/tools/cargo")
                self.assertEqual(command[1:3], ["test", "--locked"])
                self.assertIn("--offline", command)
                self.assertIn("--manifest-path", command)
                self.assertIn(self.quality.AGENT_MANIFEST, command)
                self.assertEqual(
                    tuple(command[-len(entry.cargo_test_args):]),
                    entry.cargo_test_args,
                )

    def test_coding_agent_full_runs_one_workspace_collection_with_nine_mappings(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-agent-report-") as directory:
            report_path = Path(directory) / "coding-agent-full.json"
            with ExitStack() as stack:
                stack.enter_context(
                    mock.patch.object(self.quality, "_host_platform", return_value="linux")
                )
                run = stack.enter_context(
                    mock.patch.object(self.quality, "run", return_value=0)
                )
                self.assertEqual(
                    self.quality.coding_agent_full(
                        receipt_path=report_path,
                        collect_coverage=True,
                        coverage_output_dir="build/test-evidence/rust-coverage",
                    ),
                    0,
                )
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "passed")
            self.assertEqual(report["platform"], "linux")
            self.assertEqual(len(report["requirements"]), 9)
            self.assertEqual(report["rust_coverage"]["status"], "passed")
            self.assertEqual(
                report["rust_coverage"]["output_dir"],
                "build/test-evidence/rust-coverage",
            )
            run.assert_called_once()
            command = run.call_args.args[0]
            self.assertIn("--collect-only", command)
            required_mappings = [
                command[index + 1]
                for index, value in enumerate(command[:-1])
                if value == "--require-module"
            ]
            expected_mapping_count = sum(
                len(entry.rust_source_roots) for entry in self.quality.FULL_AGENT_PLAN
            )
            self.assertEqual(len(required_mappings), expected_mapping_count)
            self.assertEqual(
                {item.split("=", 1)[0] for item in required_mappings},
                {f"REQ-AGENT-{index:03d}" for index in range(1, 10)},
            )
            for entry in self.quality.FULL_AGENT_PLAN:
                outcome = report["requirements"][entry.requirement]
                self.assertEqual(outcome["source_roots"], list(entry.rust_source_roots))
                self.assertEqual(outcome["test_args"], list(entry.cargo_test_args))

    def test_coding_agent_full_runs_workspace_tests_once_without_coverage(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-agent-report-") as directory:
            report_path = Path(directory) / "coding-agent-full.json"
            with ExitStack() as stack:
                stack.enter_context(
                    mock.patch.object(self.quality, "tool", return_value="/tools/cargo")
                )
                run = stack.enter_context(
                    mock.patch.object(self.quality, "run", return_value=0)
                )
                self.assertEqual(
                    self.quality.coding_agent_full(receipt_path=report_path),
                    0,
                )
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "passed")
            self.assertNotIn("rust_coverage", report)
            run.assert_called_once_with([
                "/tools/cargo",
                "test",
                "--locked",
                "--offline",
                "--manifest-path",
                self.quality.AGENT_MANIFEST,
                "--workspace",
                "--all-targets",
            ])

    def test_coding_agent_workspace_failure_is_truthful(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-agent-report-") as directory:
            report_path = Path(directory) / "coding-agent-full.json"
            with ExitStack() as stack:
                stack.enter_context(
                    mock.patch.object(self.quality, "tool", return_value="/tools/cargo")
                )
                stack.enter_context(
                    mock.patch.object(self.quality, "_host_platform", return_value="macos")
                )
                run = stack.enter_context(
                    mock.patch.object(self.quality, "run", return_value=9)
                )
                self.assertEqual(
                    self.quality.coding_agent_full(receipt_path=report_path),
                    1,
                )
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["failure_code"], "suite_failed")
            self.assertEqual(len(report["requirements"]), 9)
            self.assertTrue(all(
                item["status"] == "failed"
                and item["failure_code"] == "workspace_validation_failed"
                for item in report["requirements"].values()
            ))
            run.assert_called_once()
            self.assertIn("--all-targets", run.call_args.args[0])

    def test_coding_agent_coverage_failure_is_reported(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-agent-report-") as directory:
            report_path = Path(directory) / "coding-agent-full.json"
            with ExitStack() as stack:
                stack.enter_context(
                    mock.patch.object(self.quality, "_host_platform", return_value="linux")
                )
                run = stack.enter_context(
                    mock.patch.object(self.quality, "run", return_value=1)
                )
                self.assertEqual(
                    self.quality.coding_agent_full(
                        receipt_path=report_path,
                        collect_coverage=True,
                    ),
                    1,
                )
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["failure_code"], "coverage_collection_failed")
            self.assertEqual(report["rust_coverage"]["status"], "failed")
            self.assertEqual(report["rust_coverage"]["exit_code"], 1)
            run.assert_called_once()

    def test_main_routes_supported_rust_agent_and_ide_suites(self) -> None:
        routes = (
            ("ide", "cutover", "cutover"),
            ("coding-agent", "stdio-runtime", "coding_agent_suite"),
            ("coding-agent", "providers", "coding_agent_suite"),
            ("coding-agent", "context", "coding_agent_suite"),
            ("coding-agent", "tools-mcp", "coding_agent_suite"),
            ("coding-agent", "agent-security", "coding_agent_suite"),
            ("coding-agent", "coding-loop", "coding_agent_suite"),
            ("coding-agent", "session-recovery", "coding_agent_suite"),
            ("coding-agent", "multi-agent", "coding_agent_suite"),
            ("coding-agent", "protocol-integration", "coding_agent_suite"),
            ("coding-agent", "full", "coding_agent_full"),
            ("coding-agent", "coverage-report", "agent_rust_coverage_report"),
            ("ide", "workspace-transactions", "workspace_transactions"),
            ("ide", "developer-loop", "developer_loop"),
            ("ide", "agent-client-protocol", "agent_client_protocol"),
            ("ide", "mcp-host", "mcp_host"),
            ("ide", "ide-security", "ide_security"),
            ("ide", "agent-workbench", "agent_workbench"),
            ("ide", "native-desktop", "native_desktop"),
            ("ide", "macos-native-ui", "macos_native_ui"),
            ("ide", "quality-runtime", "quality_runtime"),
            ("ide", "recovery-isolation", "recovery_isolation"),
            ("ide", "daemon-core", "daemon_core"),
            ("ide", "ide-quality", "ide_quality"),
            ("ide", "full", "ide_full"),
        )
        for product, suite, target in routes:
            with self.subTest(product=product, suite=suite):
                with mock.patch.object(self.quality, target, return_value=0) as routed:
                    with mock.patch.object(
                        sys,
                        "argv",
                        [str(SCRIPT_PATH), "--product", product, "--suite", suite],
                    ):
                        self.assertEqual(self.quality.main(), 0)
                routed.assert_called_once()
                if product == "coding-agent" and suite in self.quality._AGENT_SUITE_BY_NAME:
                    self.assertEqual(
                        routed.call_args.args[0],
                        self.quality._AGENT_SUITE_BY_NAME[suite],
                    )

        with mock.patch.object(self.quality, "ide_full", return_value=0) as routed:
            with mock.patch.object(
                sys,
                "argv",
                [
                    str(SCRIPT_PATH),
                    "--product",
                    "ide",
                    "--suite",
                    "full",
                    "--preflight",
                    "--receipt",
                    "build/custom-report.json",
                ],
            ):
                self.assertEqual(self.quality.main(), 0)
        routed.assert_called_once()
        self.assertTrue(routed.call_args.kwargs["preflight"])
        self.assertEqual(
            routed.call_args.kwargs["report_path"],
            (self.quality.ROOT / "build/custom-report.json").resolve(),
        )

        with mock.patch.object(
            sys,
            "argv",
            [str(SCRIPT_PATH), "--product", "ide", "--suite", "unknown"],
        ), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.quality.main()


if __name__ == "__main__":
    unittest.main()
