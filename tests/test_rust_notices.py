from __future__ import annotations

import importlib.util
import io
import runpy
import sys
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[1]
GENERATOR_PATH = REPO_ROOT / "scripts" / "vityo_rust_notices.py"


def load_generator_module():
    spec = importlib.util.spec_from_file_location("vityo_rust_notices_test", GENERATOR_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("Unable to load Rust notice generator")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class RustNoticeGeneratorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.generator = load_generator_module()

    def test_generates_one_atomic_notice_from_both_locked_workspaces(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rust-notice-test-") as temporary:
            root = Path(temporary)
            output = root / "build/evidence/rust-third-party-notices.txt"
            generated = {
                "Coding Agent": "Apache-2.0\nagent-client-protocol 2.2.0",
                "vityod": "MIT\nrusqlite 0.37.0",
            }

            def render(_root: Path, _tool: Path, label: str, _manifest: Path, _output: Path) -> str:
                return generated[label]

            with (
                patch.object(self.generator, "_cargo_about_binary", return_value=root / "cargo-about") as tool,
                patch.object(self.generator, "_generate_workspace_notice", side_effect=render) as render_workspace,
            ):
                result = self.generator.generate_notices(root=root, output=output)

            self.assertEqual(result, output)
            self.assertEqual(
                [item.args[2:4] for item in render_workspace.call_args_list],
                [
                    ("Coding Agent", self.generator.WORKSPACES[0][1]),
                    ("vityod", self.generator.WORKSPACES[1][1]),
                ],
            )
            notice = output.read_text(encoding="utf-8")
            self.assertIn("Coding Agent", notice)
            self.assertIn("agent-client-protocol 2.2.0", notice)
            self.assertIn("vityod", notice)
            self.assertIn("rusqlite 0.37.0", notice)
            self.assertTrue(notice.endswith("\n"))
            tool.assert_called_once_with(root)

    def test_does_not_replace_output_when_either_workspace_fails(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rust-notice-test-") as temporary:
            root = Path(temporary)
            output = root / "build/evidence/rust-third-party-notices.txt"
            output.parent.mkdir(parents=True)
            output.write_text("previous complete evidence\n", encoding="utf-8")

            with (
                patch.object(self.generator, "_cargo_about_binary", return_value=root / "cargo-about"),
                patch.object(
                    self.generator,
                    "_generate_workspace_notice",
                    side_effect=["valid first graph", self.generator.RustNoticeError("second graph failed")],
                ),
                self.assertRaises(self.generator.RustNoticeError),
            ):
                self.generator.generate_notices(root=root, output=output)

            self.assertEqual(output.read_text(encoding="utf-8"), "previous complete evidence\n")

    def test_notice_generation_hides_filesystem_errors(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rust-notice-test-") as temporary:
            root = Path(temporary)
            output = root / "build/evidence/notices.txt"
            with (
                patch.object(self.generator.Path, "mkdir", side_effect=PermissionError("private path")),
                self.assertRaisesRegex(self.generator.RustNoticeError, "Unable to write"),
            ):
                self.generator.generate_notices(root=root, output=output)

    def test_cargo_about_binary_reuses_only_the_pinned_version(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rust-notice-test-") as temporary:
            root = Path(temporary)
            tool_root = Path("tool-cache")
            tool = root / tool_root / "bin" / "cargo-about"
            tool.parent.mkdir(parents=True)
            tool.write_text("old tool", encoding="utf-8")
            calls: list[list[str]] = []

            def run(command: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
                calls.append(command)
                if command[-1:] == ["--version"]:
                    return subprocess.CompletedProcess(command, 0, "cargo-about 0.9.20\n", "")
                self.assertFalse(tool.exists())
                tool.write_text("pinned tool", encoding="utf-8")
                return subprocess.CompletedProcess(command, 0, "", "")

            with (
                patch.object(self.generator, "TOOL_ROOT", tool_root),
                patch.object(self.generator.subprocess, "run", side_effect=run),
            ):
                result = self.generator._cargo_about_binary(root)

            self.assertEqual(result, tool)
            self.assertEqual(len(calls), 2)
            install = calls[1]
            self.assertEqual(install[:6], ["cargo", "install", "--locked", "--version", "0.9.2", "--features"])
            self.assertIn("cli", install)
            self.assertIn("cargo-about", install)

    def test_cargo_about_binary_reports_missing_cargo_and_failed_install(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rust-notice-test-") as temporary:
            root = Path(temporary)
            with (
                patch.object(self.generator, "TOOL_ROOT", Path("tool-cache")),
                patch.object(self.generator.subprocess, "run", side_effect=FileNotFoundError()),
                self.assertRaisesRegex(self.generator.RustNoticeError, "Cargo is required"),
            ):
                self.generator._cargo_about_binary(root)

        with tempfile.TemporaryDirectory(prefix="rust-notice-test-") as temporary:
            root = Path(temporary)
            failed = subprocess.CompletedProcess(["cargo"], 17, "", "private path omitted")
            with (
                patch.object(self.generator, "TOOL_ROOT", Path("tool-cache")),
                patch.object(self.generator.subprocess, "run", return_value=failed),
                self.assertRaisesRegex(self.generator.RustNoticeError, "exit 17"),
            ):
                self.generator._cargo_about_binary(root)

    def test_cargo_about_binary_requires_the_installed_executable(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rust-notice-test-") as temporary:
            root = Path(temporary)
            installed = subprocess.CompletedProcess(["cargo"], 0, "", "")
            with (
                patch.object(self.generator, "TOOL_ROOT", Path("tool-cache")),
                patch.object(self.generator.subprocess, "run", return_value=installed),
                self.assertRaisesRegex(self.generator.RustNoticeError, "produced no executable"),
            ):
                self.generator._cargo_about_binary(root)

    def test_cargo_about_binary_hides_process_errors(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rust-notice-test-") as temporary:
            root = Path(temporary)
            tool = root / "tool-cache/bin/cargo-about"
            tool.parent.mkdir(parents=True)
            tool.touch()
            with (
                patch.object(self.generator, "TOOL_ROOT", Path("tool-cache")),
                patch.object(self.generator.subprocess, "run", side_effect=PermissionError("private path")),
                self.assertRaisesRegex(self.generator.RustNoticeError, "Unable to inspect"),
            ):
                self.generator._cargo_about_binary(root)

        with tempfile.TemporaryDirectory(prefix="rust-notice-test-") as temporary:
            root = Path(temporary)
            tool = root / "tool-cache/bin/cargo-about"
            tool.parent.mkdir(parents=True)
            tool.touch()
            wrong_version = subprocess.CompletedProcess([str(tool)], 0, "cargo-about 0.8.0\n", "")
            with (
                patch.object(self.generator, "TOOL_ROOT", Path("tool-cache")),
                patch.object(self.generator.subprocess, "run", return_value=wrong_version),
                patch.object(Path, "unlink", side_effect=PermissionError("private path")),
                self.assertRaisesRegex(self.generator.RustNoticeError, "Unable to replace"),
            ):
                self.generator._cargo_about_binary(root)

        with tempfile.TemporaryDirectory(prefix="rust-notice-test-") as temporary:
            root = Path(temporary)
            with (
                patch.object(self.generator, "TOOL_ROOT", Path("tool-cache")),
                patch.object(Path, "mkdir", side_effect=PermissionError("private path")),
                self.assertRaisesRegex(self.generator.RustNoticeError, "Unable to install"),
            ):
                self.generator._cargo_about_binary(root)

    def _write_workspace_inputs(self, root: Path, manifest: Path) -> Path:
        manifest_path = root / manifest
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text("[package]\nname='fixture'\n", encoding="utf-8")
        (manifest_path.parent / "Cargo.lock").write_text("version = 4\n", encoding="utf-8")
        (root / self.generator.CONFIG_PATH).parent.mkdir(parents=True, exist_ok=True)
        (root / self.generator.CONFIG_PATH).write_text("accepted = []\n", encoding="utf-8")
        (root / self.generator.TEMPLATE_PATH).parent.mkdir(parents=True, exist_ok=True)
        (root / self.generator.TEMPLATE_PATH).write_text("{{text}}\n", encoding="utf-8")
        return manifest_path

    def test_workspace_notice_checks_manifest_lock_and_license_assets(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rust-notice-test-") as temporary:
            root = Path(temporary)
            manifest = Path("products/test/Cargo.toml")
            tool = root / "cargo-about"
            output = root / "notice.txt"

            with self.assertRaisesRegex(self.generator.RustNoticeError, "Missing Rust notice workspace"):
                self.generator._generate_workspace_notice(root, tool, "fixture", manifest, output)

            self._write_workspace_inputs(root, manifest)
            (root / manifest.parent / "Cargo.lock").unlink()
            with self.assertRaisesRegex(self.generator.RustNoticeError, "Missing Cargo.lock"):
                self.generator._generate_workspace_notice(root, tool, "fixture", manifest, output)

            (root / manifest.parent / "Cargo.lock").write_text("version = 4\n", encoding="utf-8")
            (root / self.generator.CONFIG_PATH).unlink()
            with self.assertRaisesRegex(self.generator.RustNoticeError, "configuration or template is missing"):
                self.generator._generate_workspace_notice(root, tool, "fixture", manifest, output)

    def test_workspace_notice_runs_locked_fail_closed_command_and_returns_utf8(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rust-notice-test-") as temporary:
            root = Path(temporary)
            manifest = Path("products/test/Cargo.toml")
            self._write_workspace_inputs(root, manifest)
            tool = root / "cargo-about"
            output = root / "notice.txt"
            commands: list[list[str]] = []

            def run(command: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
                commands.append(command)
                output.write_text("  License text\n", encoding="utf-8")
                return subprocess.CompletedProcess(command, 0, "", "")

            with patch.object(self.generator.subprocess, "run", side_effect=run):
                result = self.generator._generate_workspace_notice(root, tool, "fixture", manifest, output)

            self.assertEqual(result, "License text")
            self.assertEqual(commands[0][1:5], ["generate", "--workspace", "--fail", "--locked"])
            self.assertIn("--manifest-path", commands[0])
            self.assertIn("--config", commands[0])
            self.assertIn("--output-file", commands[0])
            self.assertEqual(commands[0][-1], self.generator.TEMPLATE_PATH.as_posix())

    def test_workspace_notice_reports_subprocess_and_output_failures(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rust-notice-test-") as temporary:
            root = Path(temporary)
            manifest = Path("products/test/Cargo.toml")
            self._write_workspace_inputs(root, manifest)
            tool = root / "cargo-about"
            output = root / "notice.txt"
            with (
                patch.object(self.generator.subprocess, "run", side_effect=OSError("private path")),
                self.assertRaisesRegex(self.generator.RustNoticeError, "Unable to run cargo-about"),
            ):
                self.generator._generate_workspace_notice(root, tool, "fixture", manifest, output)

            failed = subprocess.CompletedProcess([str(tool)], 2, "", "private path")
            with (
                patch.object(self.generator.subprocess, "run", return_value=failed),
                self.assertRaisesRegex(self.generator.RustNoticeError, "could not resolve"),
            ):
                self.generator._generate_workspace_notice(root, tool, "fixture", manifest, output)

            completed = subprocess.CompletedProcess([str(tool)], 0, "", "")
            with (
                patch.object(self.generator.subprocess, "run", return_value=completed),
                self.assertRaisesRegex(self.generator.RustNoticeError, "did not produce UTF-8"),
            ):
                self.generator._generate_workspace_notice(root, tool, "fixture", manifest, output)

            output.write_text("\n \t", encoding="utf-8")
            with (
                patch.object(self.generator.subprocess, "run", return_value=completed),
                self.assertRaisesRegex(self.generator.RustNoticeError, "produced an empty notice"),
            ):
                self.generator._generate_workspace_notice(root, tool, "fixture", manifest, output)

            output.write_bytes(b"\xff")
            with (
                patch.object(self.generator.subprocess, "run", return_value=completed),
                self.assertRaisesRegex(self.generator.RustNoticeError, "did not produce UTF-8"),
            ):
                self.generator._generate_workspace_notice(root, tool, "fixture", manifest, output)

    def test_main_reports_safe_success_and_generator_failure(self) -> None:
        output = Path("build/evidence/rust-third-party-notices.txt")
        success = io.StringIO()
        with patch.object(self.generator, "generate_notices", return_value=output), redirect_stdout(success):
            self.assertEqual(self.generator.main([]), 0)
        self.assertIn("OK: build/evidence/rust-third-party-notices.txt", success.getvalue())

        outside = Path("/private/path/notices.txt")
        success = io.StringIO()
        with patch.object(self.generator, "generate_notices", return_value=outside), redirect_stdout(success):
            self.assertEqual(self.generator.main(["--output", str(outside)]), 0)
        self.assertIn("OK: notices.txt", success.getvalue())
        self.assertNotIn("/private/path", success.getvalue())

        error = io.StringIO()
        with (
            patch.object(self.generator, "generate_notices", side_effect=self.generator.RustNoticeError("blocked")),
            redirect_stderr(error),
        ):
            self.assertEqual(self.generator.main([]), 1)
        self.assertIn("FAILED: blocked", error.getvalue())

    def test_script_entry_point_uses_the_pinned_command_and_safe_output_label(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rust-notice-test-") as temporary:
            root = Path(temporary)
            output = root / "notice.txt"
            tool_path = REPO_ROOT / self.generator.TOOL_ROOT / "bin" / "cargo-about"
            original_is_file = Path.is_file

            def is_file(path: Path) -> bool:
                return True if path == tool_path else original_is_file(path)

            def run(command: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
                if command[-1:] == ["--version"]:
                    return subprocess.CompletedProcess(command, 0, "cargo-about 0.9.2\n", "")
                notice_output = Path(command[command.index("--output-file") + 1])
                notice_output.write_text("License text\n", encoding="utf-8")
                return subprocess.CompletedProcess(command, 0, "", "")

            stdout = io.StringIO()
            with (
                patch.object(Path, "is_file", is_file),
                patch.object(self.generator.subprocess, "run", side_effect=run),
                patch.object(sys, "argv", [str(GENERATOR_PATH), "--output", str(output)]),
                redirect_stdout(stdout),
            ):
                with self.assertRaises(SystemExit) as exit_info:
                    runpy.run_path(str(GENERATOR_PATH), run_name="__main__")

            self.assertEqual(exit_info.exception.code, 0)
            self.assertEqual(output.read_text(encoding="utf-8"), "Coding Agent\n============\n\nLicense text\n\nvityod\n======\n\nLicense text\n")
            self.assertIn("OK: notice.txt", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
