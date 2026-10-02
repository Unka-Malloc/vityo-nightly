from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "vityo_toolchains.py"


def load_toolchains():
    spec = importlib.util.spec_from_file_location("vityo_toolchains_test_target", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class VityoToolchainsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.toolchains = load_toolchains()
        self.temporary = tempfile.TemporaryDirectory(prefix="vityo-toolchain-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "vityo"
        self.root.mkdir()
        self.origin = Path(self.temporary.name) / "styio-upstream"
        self.origin.mkdir()
        self._git(self.origin, "init", "--quiet")
        self._git(self.origin, "config", "user.email", "tests@example.invalid")
        self._git(self.origin, "config", "user.name", "Vityo tests")
        (self.origin / "CMakeLists.txt").write_text("project(styio)\n", encoding="utf-8")
        self._git(self.origin, "add", "CMakeLists.txt")
        self._git(self.origin, "commit", "--quiet", "-m", "pinned source")
        self.commit = self._git(self.origin, "rev-parse", "HEAD").stdout.strip()
        (self.root / "toolchain").mkdir()
        (self.root / "toolchain/product-matrix.json").write_text(
            json.dumps({"repositories": {"styio": self.commit}}),
            encoding="utf-8",
        )
        products = dict(self.toolchains.PRODUCTS)
        products["styio"] = {
            "repository": str(self.origin),
            "executable": "styio.exe" if os.name == "nt" else "styio",
            "target": "styio",
        }
        self.products_patch = mock.patch.object(self.toolchains, "PRODUCTS", products)
        self.products_patch.start()
        self.addCleanup(self.products_patch.stop)

    @staticmethod
    def _git(cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            ["git", *args],
            cwd=cwd,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        return result

    def _checkout(self) -> Path:
        return self.toolchains.ensure_pinned_checkout("styio", root=self.root)

    def test_checkout_uses_exact_matrix_revision_and_reuses_managed_source(self) -> None:
        sibling = self.root.parent / "styio-nightly"
        sibling.mkdir()
        marker = sibling / "user-owned.txt"
        marker.write_text("leave this checkout alone", encoding="utf-8")

        source = self._checkout()
        self.assertEqual(source, self.root / "build/toolchains/styio-nightly" / self.commit)
        self.assertEqual(self._git(source, "rev-parse", "HEAD").stdout.strip(), self.commit)

        with mock.patch.object(
            self.toolchains,
            "_run",
            side_effect=AssertionError("a valid managed checkout must not be fetched again"),
        ):
            self.assertEqual(self._checkout(), source)
        self.assertEqual(marker.read_text(encoding="utf-8"), "leave this checkout alone")

    def test_checkout_failure_is_reported_without_creating_a_successful_cache(self) -> None:
        with self.assertRaisesRegex(self.toolchains.ToolchainError, "cloning the pinned styio source failed"):
            self.toolchains.ensure_pinned_checkout(
                "styio",
                root=self.root,
                runner=lambda _command, _cwd: 8,
            )
        managed_parent = self.root / "build/toolchains/styio-nightly"
        self.assertEqual(list(managed_parent.iterdir()), [])

    def test_fetch_failure_does_not_install_an_incomplete_checkout(self) -> None:
        calls: list[tuple[str, ...]] = []

        def fail_fetch(command, cwd):
            command = tuple(command)
            calls.append(command)
            if command[:2] == ("git", "fetch"):
                return 9
            return self.toolchains._run(command, cwd)

        with self.assertRaisesRegex(self.toolchains.ToolchainError, "fetching the pinned styio source failed"):
            self.toolchains.ensure_pinned_checkout("styio", root=self.root, runner=fail_fetch)
        self.assertTrue(any(command[:2] == ("git", "clone") for command in calls))
        managed_parent = self.root / "build/toolchains/styio-nightly"
        self.assertEqual(list(managed_parent.iterdir()), [])

    def test_provision_builds_only_pinned_cli_and_reuses_valid_binary(self) -> None:
        calls: list[tuple[str, ...]] = []
        expected_source = self.root / "build/toolchains/styio-nightly" / self.commit
        executable = expected_source / "build/default/bin" / str(self.toolchains.PRODUCTS["styio"]["executable"])

        def runner(command, cwd):
            command = tuple(command)
            calls.append(command)
            if command and command[0] == "git":
                return self.toolchains._run(command, cwd)
            if command == ("cmake-configure",):
                return 0
            if command == ("cmake-build",):
                executable.parent.mkdir(parents=True, exist_ok=True)
                executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                executable.chmod(0o755)
            return 0

        with mock.patch.object(
            self.toolchains,
            "_build_commands",
            return_value=(("cmake-configure",), ("cmake-build",)),
        ):
            built = self.toolchains.provision("styio", root=self.root, runner=runner)
        self.assertEqual(built, executable)
        self.assertIn(("cmake-configure",), calls)
        self.assertIn(("cmake-build",), calls)
        self.assertEqual(calls[-1], (str(executable), "--version"))

        repeated_calls: list[tuple[str, ...]] = []

        def reuse_runner(command, _cwd):
            repeated_calls.append(tuple(command))
            return 0

        with mock.patch.object(self.toolchains, "_build_commands", side_effect=AssertionError("valid binary should be reused")):
            self.assertEqual(
                self.toolchains.provision("styio", root=self.root, runner=reuse_runner),
                executable,
            )
        self.assertEqual(repeated_calls, [(str(executable), "--version")])

    def test_configure_and_build_failures_propagate(self) -> None:
        source = self._checkout()
        with mock.patch.object(
            self.toolchains,
            "_build_commands",
            return_value=(("configure",), ("build",)),
        ):
            with self.assertRaisesRegex(self.toolchains.ToolchainError, "configuring the pinned styio source failed"):
                self.toolchains.provision("styio", root=self.root, runner=lambda _command, _cwd: 3)

            commands: list[tuple[str, ...]] = []

            def fail_build(command, _cwd):
                commands.append(tuple(command))
                return 4 if tuple(command) == ("build",) else 0

            with self.assertRaisesRegex(self.toolchains.ToolchainError, "building the pinned styio CLI failed"):
                self.toolchains.provision("styio", root=self.root, runner=fail_build)
            self.assertEqual(commands, [("configure",), ("build",)])
        self.assertFalse((source / "build/default/bin/styio").exists())

    def test_build_requires_an_executable_after_the_declared_target(self) -> None:
        self._checkout()
        with mock.patch.object(
            self.toolchains,
            "_build_commands",
            return_value=(("configure",), ("build",)),
        ):
            with self.assertRaisesRegex(self.toolchains.ToolchainError, "did not produce its CLI executable"):
                self.toolchains.provision("styio", root=self.root, runner=lambda _command, _cwd: 0)


if __name__ == "__main__":
    unittest.main()
