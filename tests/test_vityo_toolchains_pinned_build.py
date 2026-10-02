#!/usr/bin/env python3
"""Behaviour tests for the pinned product toolchain builder.

Every test works inside a temporary directory and uses real (local) git
plumbing; module globals such as ``PRODUCTS``, ``LLVM_CMAKE_ROOTS``,
``_build_commands`` and ``_checkout_matches`` are patched so no network,
install tree or user cache is touched.
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "vityo_toolchains.py"


def load_toolchains_module():
    spec = importlib.util.spec_from_file_location(
        "vityo_toolchains_pinned_build", SCRIPT
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class VityoToolchainsPinnedBuildTest(unittest.TestCase):
    def setUp(self) -> None:
        self.toolchains = load_toolchains_module()
        self.temporary = tempfile.TemporaryDirectory(prefix="vityo-pinned-build-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "vityo"
        (self.root / "toolchain").mkdir(parents=True)

        self.origin = self.base / "styio-upstream"
        self.commit = self._init_repository(self.origin)

        products = {
            "styio": {
                "repository": str(self.origin),
                "executable": "styio.exe" if os.name == "nt" else "styio",
                "target": "styio",
            },
            "pafio": {
                "repository": str(self.origin),
                "executable": "pafio.exe" if os.name == "nt" else "pafio",
                "target": "pafio",
            },
        }
        self.products_patch = mock.patch.object(
            self.toolchains, "PRODUCTS", products
        )
        self.products_patch.start()
        self.addCleanup(self.products_patch.stop)

        self._write_matrix(self.commit)

    # ------------------------------------------------------------------
    # helpers
    # ------------------------------------------------------------------

    def _git(self, cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            ["git", *args],
            cwd=cwd,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise AssertionError(f"git {' '.join(args)} failed: {result.stderr}")
        return result

    def _init_repository(self, path: Path) -> str:
        path.mkdir(parents=True, exist_ok=True)
        self._git(path, "init", "--quiet")
        self._git(path, "config", "user.email", "tests@example.invalid")
        self._git(path, "config", "user.name", "Vityo toolchain tests")
        (path / "CMakeLists.txt").write_text("project(pinned)\n", encoding="utf-8")
        self._git(path, "add", "CMakeLists.txt")
        self._git(path, "commit", "--quiet", "-m", "pinned source")
        self._git(path, "remote", "add", "origin", str(path))
        return self._git(path, "rev-parse", "HEAD").stdout.strip()

    def _second_commit(self, path: Path) -> str:
        marker = path / "CMakeLists.txt"
        marker.write_text("project(pinned)\n# second\n", encoding="utf-8")
        self._git(path, "commit", "--quiet", "-am", "second")
        return self._git(path, "rev-parse", "HEAD").stdout.strip()

    def _write_matrix(self, commit: str, *, product: str = "styio") -> Path:
        matrix = self.root / "toolchain" / "product-matrix.json"
        matrix.write_text(
            json.dumps({"repositories": {product: commit}}), encoding="utf-8"
        )
        return matrix

    def _managed_source(self, commit: str | None = None) -> Path:
        return self.toolchains.managed_source_root(
            "styio", commit or self.commit, root=self.root
        )

    def _seed_cache(self, *, head: str | None = None) -> Path:
        """Clone ``self.origin`` into the managed cache path."""
        source = self._managed_source()
        source.parent.mkdir(parents=True, exist_ok=True)
        self._git(self.base, "clone", "--quiet", str(self.origin), str(source))
        self._git(source, "checkout", "--detach", "--quiet", head or self.commit)
        return source

    def _executable_path(self, source: Path, product: str = "styio") -> Path:
        name = str(self.toolchains.PRODUCTS[product]["executable"])
        return source / "build/default/bin" / name

    def _make_executable(self, path: Path) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        path.chmod(0o755)
        return path

    @staticmethod
    def _clean_environment() -> mock._patch_dict:
        patcher = mock.patch.dict(os.environ)
        patcher.start()
        os.environ.pop("LLVM_DIR", None)
        os.environ.pop("STYIO_NATIVE_TOOLCHAIN_ROOT", None)
        return patcher

    # ------------------------------------------------------------------
    # default runner and matrix parsing
    # ------------------------------------------------------------------

    def test_default_runner_returns_the_child_exit_status(self) -> None:
        command = (sys.executable, "-c", "raise SystemExit(0)")
        self.assertEqual(self.toolchains._run(command, self.base), 0)
        failing = (sys.executable, "-c", "raise SystemExit(7)")
        self.assertEqual(self.toolchains._run(failing, self.base), 7)

    def test_matrix_commit_rejects_an_unsupported_product(self) -> None:
        with self.assertRaisesRegex(
            self.toolchains.ToolchainError, "unsupported pinned product tool: vityod"
        ):
            self.toolchains._matrix_commit("vityod", root=self.root)

    def test_matrix_commit_reports_a_missing_or_invalid_matrix(self) -> None:
        matrix = self.root / "toolchain" / "product-matrix.json"
        matrix.unlink()
        with self.assertRaisesRegex(
            self.toolchains.ToolchainError, "the product matrix could not be read"
        ):
            self.toolchains._matrix_commit("styio", root=self.root)

        matrix.write_text("{not json", encoding="utf-8")
        with self.assertRaisesRegex(
            self.toolchains.ToolchainError, "the product matrix could not be read"
        ):
            self.toolchains._matrix_commit("styio", root=self.root)

        invalid_payloads = (
            [],
            {"repositories": []},
            {"repositories": {}},
            {"repositories": {"styio": "abc"}},
        )
        for payload in invalid_payloads:
            with self.subTest(payload=payload):
                matrix.write_text(json.dumps(payload), encoding="utf-8")
                with self.assertRaisesRegex(
                    self.toolchains.ToolchainError,
                    "the product matrix has no valid styio commit",
                ):
                    self.toolchains._matrix_commit("styio", root=self.root)

        matrix.write_text(
            json.dumps({"repositories": {"styio": self.commit.upper()}}),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            self.toolchains.ToolchainError,
            "the product matrix has no valid styio commit",
        ):
            self.toolchains._matrix_commit("styio", root=self.root)

    def test_matrix_commit_returns_the_pinned_revision(self) -> None:
        self.assertEqual(
            self.toolchains._matrix_commit("styio", root=self.root), self.commit
        )

    def test_managed_source_root_rejects_an_invalid_identity(self) -> None:
        with self.assertRaisesRegex(
            self.toolchains.ToolchainError, "pinned product source identity is invalid"
        ):
            self.toolchains.managed_source_root("vityod", self.commit, root=self.root)
        for commit in ("", "abc", self.commit[:-1], self.commit + "0", "Z" * 40):
            with self.subTest(commit=commit):
                with self.assertRaisesRegex(
                    self.toolchains.ToolchainError,
                    "pinned product source identity is invalid",
                ):
                    self.toolchains.managed_source_root("styio", commit, root=self.root)

    def test_managed_source_root_is_derived_from_product_and_commit(self) -> None:
        source = self.toolchains.managed_source_root(
            "styio", self.commit, root=self.root
        )
        self.assertEqual(
            source,
            self.root / "build" / "toolchains" / "styio-nightly" / self.commit,
        )

    # ------------------------------------------------------------------
    # git plumbing
    # ------------------------------------------------------------------

    def test_git_value_returns_empty_when_git_fails(self) -> None:
        plain = self.base / "not-a-repository"
        plain.mkdir()
        self.assertEqual(
            self.toolchains._git_value(
                ("git", "rev-parse", "--show-toplevel"), cwd=plain
            ),
            "",
        )

    def test_git_value_strips_successful_output(self) -> None:
        self.assertEqual(
            self.toolchains._git_value(
                ("git", "rev-parse", "--show-toplevel"), cwd=self.origin
            ),
            str(self.origin.resolve()),
        )

    def test_checkout_matches_rejects_missing_and_plain_directories(self) -> None:
        self.assertFalse(
            self.toolchains._checkout_matches(
                self.base / "absent", "styio", self.commit
            )
        )
        plain = self.base / "plain"
        plain.mkdir()
        self.assertFalse(
            self.toolchains._checkout_matches(plain, "styio", self.commit)
        )

    def test_checkout_matches_rejects_a_nested_subdirectory(self) -> None:
        nested = self.origin / "nested"
        nested.mkdir()
        self.assertFalse(
            self.toolchains._checkout_matches(nested, "styio", self.commit)
        )

    def test_checkout_matches_rejects_a_foreign_origin(self) -> None:
        foreign = self.base / "foreign"
        self._init_repository(foreign)
        self.assertFalse(
            self.toolchains._checkout_matches(foreign, "styio", self.commit)
        )

    def test_checkout_matches_rejects_a_different_revision(self) -> None:
        head = self._second_commit(self.origin)
        self.assertFalse(
            self.toolchains._checkout_matches(self.origin, "styio", self.commit)
        )
        self.assertTrue(
            self.toolchains._checkout_matches(self.origin, "styio", head)
        )

    def test_checkout_matches_accepts_the_pinned_origin_and_revision(self) -> None:
        self.assertTrue(
            self.toolchains._checkout_matches(self.origin, "styio", self.commit)
        )

    def test_checkout_matches_normalizes_a_trailing_slash_origin(self) -> None:
        with mock.patch.object(
            self.toolchains,
            "PRODUCTS",
            {
                "styio": {
                    **self.toolchains.PRODUCTS["styio"],
                    "repository": f"{self.toolchains.PRODUCTS['styio']['repository']}/",
                }
            },
        ):
            self.assertTrue(
                self.toolchains._checkout_matches(self.origin, "styio", self.commit)
            )

    def test_tracked_tree_clean_tracks_only_tracked_changes(self) -> None:
        self.assertTrue(self.toolchains._tracked_tree_clean(self.origin))
        (self.origin / "untracked.txt").write_text("x", encoding="utf-8")
        self.assertTrue(self.toolchains._tracked_tree_clean(self.origin))
        (self.origin / "CMakeLists.txt").write_text("changed\n", encoding="utf-8")
        self.assertFalse(self.toolchains._tracked_tree_clean(self.origin))

    # ------------------------------------------------------------------
    # ensure_pinned_checkout
    # ------------------------------------------------------------------

    def test_missing_cache_is_cloned_and_moved_into_place(self) -> None:
        source = self.toolchains.ensure_pinned_checkout("styio", root=self.root)
        self.assertEqual(source, self._managed_source())
        self.assertEqual(
            self._git(source, "rev-parse", "HEAD").stdout.strip(), self.commit
        )
        self.assertTrue((source / "CMakeLists.txt").is_file())
        # no temporary checkout directories survive a successful move
        self.assertEqual(
            [path.name for path in source.parent.iterdir()], [self.commit]
        )

    def test_clone_and_fetch_failures_do_not_install_a_cache(self) -> None:
        with self.assertRaisesRegex(
            self.toolchains.ToolchainError, "cloning the pinned styio source failed"
        ):
            self.toolchains.ensure_pinned_checkout(
                "styio", root=self.root, runner=lambda _command, _cwd: 8
            )
        self.assertEqual(list(self._managed_source().parent.iterdir()), [])

        def fail_fetch(command, cwd):
            if tuple(command)[:2] == ("git", "fetch"):
                return 9
            return self.toolchains._run(command, cwd)

        with self.assertRaisesRegex(
            self.toolchains.ToolchainError, "fetching the pinned styio source failed"
        ):
            self.toolchains.ensure_pinned_checkout(
                "styio", root=self.root, runner=fail_fetch
            )
        self.assertEqual(list(self._managed_source().parent.iterdir()), [])

    def test_clone_checkout_failure_does_not_install_a_cache(self) -> None:
        checkout_command = ("git", "checkout", "--detach", self.commit)

        def fail_checkout(command, cwd):
            if tuple(command) == checkout_command:
                return 3
            return self.toolchains._run(command, cwd)

        with self.assertRaisesRegex(
            self.toolchains.ToolchainError, "selecting the pinned styio source failed"
        ):
            self.toolchains.ensure_pinned_checkout(
                "styio", root=self.root, runner=fail_checkout
            )
        self.assertEqual(list(self._managed_source().parent.iterdir()), [])

    def test_clone_that_does_not_match_the_pinned_identity_is_rejected(self) -> None:
        with mock.patch.object(
            self.toolchains, "_checkout_matches", return_value=False
        ):
            with self.assertRaisesRegex(
                self.toolchains.ToolchainError,
                "the styio source did not resolve to the product-matrix commit",
            ):
                self.toolchains.ensure_pinned_checkout("styio", root=self.root)
        self.assertEqual(list(self._managed_source().parent.iterdir()), [])

    def test_cache_with_a_foreign_origin_is_rejected(self) -> None:
        source = self._managed_source()
        foreign = self.base / "other-upstream"
        self._init_repository(foreign)
        source.parent.mkdir(parents=True, exist_ok=True)
        self._git(self.base, "clone", "--quiet", str(foreign), str(source))
        with self.assertRaisesRegex(
            self.toolchains.ToolchainError,
            "the managed styio cache is not its pinned upstream checkout",
        ):
            self.toolchains.ensure_pinned_checkout(
                "styio", root=self.root, runner=lambda _command, _cwd: 0
            )

    def test_cache_that_is_not_a_repository_is_rejected(self) -> None:
        source = self._managed_source()
        source.mkdir(parents=True)
        with self.assertRaisesRegex(
            self.toolchains.ToolchainError,
            "the managed styio cache is not its pinned upstream checkout",
        ):
            self.toolchains.ensure_pinned_checkout(
                "styio", root=self.root, runner=lambda _command, _cwd: 0
            )

    def test_cache_with_local_tracked_changes_is_rejected(self) -> None:
        source = self._seed_cache()
        (source / "CMakeLists.txt").write_text("dirty\n", encoding="utf-8")
        with self.assertRaisesRegex(
            self.toolchains.ToolchainError,
            "the managed styio source has local tracked changes",
        ):
            self.toolchains.ensure_pinned_checkout(
                "styio", root=self.root, runner=lambda _command, _cwd: 0
            )

    def test_stale_cache_is_fetched_and_detached_to_the_matrix_commit(self) -> None:
        head = self._second_commit(self.origin)
        self.assertNotEqual(head, self.commit)
        source = self._seed_cache(head=head)
        calls: list[tuple[str, ...]] = []

        def runner(command, cwd):
            calls.append(tuple(command))
            return self.toolchains._run(command, cwd)

        result = self.toolchains.ensure_pinned_checkout(
            "styio", root=self.root, runner=runner
        )
        self.assertEqual(result, source)
        self.assertEqual(
            self._git(source, "rev-parse", "HEAD").stdout.strip(), self.commit
        )
        self.assertEqual(
            calls,
            [
                ("git", "fetch", "--depth=1", "origin", self.commit),
                ("git", "checkout", "--detach", self.commit),
            ],
        )

    def test_stale_cache_fetch_failure_is_reported(self) -> None:
        head = self._second_commit(self.origin)
        self._seed_cache(head=head)

        def fail_fetch(command, cwd):
            if tuple(command)[:2] == ("git", "fetch"):
                return 5
            return self.toolchains._run(command, cwd)

        with self.assertRaisesRegex(
            self.toolchains.ToolchainError, "fetching the pinned styio source failed"
        ):
            self.toolchains.ensure_pinned_checkout(
                "styio", root=self.root, runner=fail_fetch
            )

    def test_stale_cache_checkout_failure_is_reported(self) -> None:
        head = self._second_commit(self.origin)
        self._seed_cache(head=head)

        def fail_checkout(command, cwd):
            if tuple(command)[:2] == ("git", "checkout"):
                return 6
            return self.toolchains._run(command, cwd)

        with self.assertRaisesRegex(
            self.toolchains.ToolchainError, "selecting the pinned styio source failed"
        ):
            self.toolchains.ensure_pinned_checkout(
                "styio", root=self.root, runner=fail_checkout
            )

    # ------------------------------------------------------------------
    # LLVM discovery
    # ------------------------------------------------------------------

    def _llvm_config(self, directory: Path, version: str, *, quoted: bool = False) -> Path:
        directory.mkdir(parents=True, exist_ok=True)
        value = f'"{version}"' if quoted else version
        (directory / "LLVMConfig.cmake").write_text(
            f"set(LLVM_PACKAGE_VERSION {value})\n", encoding="utf-8"
        )
        return directory

    def test_llvm_cmake_dir_prefers_llvm_dir_over_bundled_roots(self) -> None:
        explicit = self._llvm_config(self.base / "explicit-llvm", "18.1.8")
        stale = self._llvm_config(self.base / "stale-llvm", "17.0.6")
        env = mock.patch.dict(os.environ, {"LLVM_DIR": str(explicit)})
        with env, mock.patch.object(
            self.toolchains, "LLVM_CMAKE_ROOTS", (stale,)
        ), mock.patch.object(self.toolchains.shutil, "which", return_value=None):
            resolved = self.toolchains._llvm_cmake_dir()
        self.assertEqual(resolved, explicit.resolve())

    def test_llvm_cmake_dir_prefers_the_explicit_override_over_a_path_llvm_config(
        self,
    ) -> None:
        explicit = self._llvm_config(self.base / "explicit-llvm", "18.1.8")
        discovered = self._llvm_config(self.base / "path-llvm", "18.2.0")
        stale = self._llvm_config(self.base / "stale-llvm", "17.0.6")

        def fake_run(command, **_kwargs):
            if command[-1] == "--version":
                return SimpleNamespace(returncode=0, stdout="18.2.0\n")
            return SimpleNamespace(returncode=0, stdout=f"{discovered}\n")

        env = mock.patch.dict(os.environ, {"LLVM_DIR": str(explicit)})
        with env, mock.patch.object(
            self.toolchains, "LLVM_CMAKE_ROOTS", (stale,)
        ), mock.patch.object(
            self.toolchains.shutil, "which", return_value="/usr/bin/llvm-config-18"
        ), mock.patch.object(
            self.toolchains.subprocess, "run", side_effect=fake_run
        ):
            resolved = self.toolchains._llvm_cmake_dir()
        # The operator's LLVM_DIR is an explicit request, so discovery through
        # PATH must not override it.
        self.assertEqual(resolved, explicit.resolve())

    def test_llvm_cmake_dir_falls_back_to_known_roots(self) -> None:
        without_config = self.base / "no-config"
        without_config.mkdir()
        stale = self._llvm_config(self.base / "stale-root", "17.0.6")
        current = self._llvm_config(self.base / "llvm-18", "18.0.0", quoted=True)
        patcher = self._clean_environment()
        try:
            with mock.patch.object(
                self.toolchains,
                "LLVM_CMAKE_ROOTS",
                (without_config, stale, current),
            ), mock.patch.object(self.toolchains.shutil, "which", return_value=None):
                resolved = self.toolchains._llvm_cmake_dir()
        finally:
            patcher.stop()
        self.assertEqual(resolved, current.resolve())

    def test_llvm_cmake_dir_ignores_llvm_dir_without_llvm_18_config(self) -> None:
        empty = self.base / "empty-llvm-dir"
        empty.mkdir()
        stale = self._llvm_config(self.base / "old-llvm", "17.0.6")
        env = mock.patch.dict(os.environ, {"LLVM_DIR": str(empty)})
        with env, mock.patch.object(
            self.toolchains, "LLVM_CMAKE_ROOTS", (stale,)
        ), mock.patch.object(self.toolchains.shutil, "which", return_value=None):
            with self.assertRaisesRegex(
                self.toolchains.ToolchainError, "set LLVM_DIR"
            ):
                self.toolchains._llvm_cmake_dir()

    def test_llvm_cmake_dir_fails_when_no_llvm_18_is_installed(self) -> None:
        stale = self._llvm_config(self.base / "only-17", "17.0.6")
        patcher = self._clean_environment()
        try:
            with mock.patch.object(
                self.toolchains, "LLVM_CMAKE_ROOTS", (stale,)
            ), mock.patch.object(self.toolchains.shutil, "which", return_value=None):
                with self.assertRaisesRegex(
                    self.toolchains.ToolchainError,
                    "Styio requires LLVM 18 CMake development files",
                ):
                    self.toolchains._llvm_cmake_dir()
        finally:
            patcher.stop()

    def test_llvm_cmake_dir_uses_llvm_config_18_cmakedir(self) -> None:
        cmake_dir = self._llvm_config(self.base / "from-llvm-config", "18.1.3")
        empty_root = self.base / "empty-root"
        empty_root.mkdir()
        commands: list[list[str]] = []

        def which(command: str) -> str | None:
            return "/usr/bin/llvm-config-18" if command == "llvm-config-18" else None

        def fake_run(command, **_kwargs):
            commands.append(list(command))
            if command[-1] == "--version":
                return SimpleNamespace(returncode=0, stdout="18.1.3\n")
            return SimpleNamespace(returncode=0, stdout=f"{cmake_dir}\n")

        patcher = self._clean_environment()
        try:
            with mock.patch.object(
                self.toolchains, "LLVM_CMAKE_ROOTS", (empty_root,)
            ), mock.patch.object(
                self.toolchains.shutil, "which", side_effect=which
            ), mock.patch.object(
                self.toolchains.subprocess, "run", side_effect=fake_run
            ):
                resolved = self.toolchains._llvm_cmake_dir()
        finally:
            patcher.stop()
        self.assertEqual(resolved, cmake_dir.resolve())
        self.assertEqual(
            commands,
            [
                ["/usr/bin/llvm-config-18", "--version"],
                ["/usr/bin/llvm-config-18", "--cmakedir"],
            ],
        )

    def test_llvm_cmake_dir_skips_llvm_config_that_is_not_18(self) -> None:
        current = self._llvm_config(self.base / "root-llvm-18", "18.1.0")
        calls: list[list[str]] = []

        def which(command: str) -> str | None:
            return f"/usr/bin/{command}"

        def fake_run(command, **_kwargs):
            calls.append(list(command))
            if command[-1] == "--version":
                if command[0].endswith("llvm-config-18"):
                    return SimpleNamespace(returncode=0, stdout="19.1.0\n")
                return SimpleNamespace(returncode=1, stdout="")
            raise AssertionError("--cmakedir must not be probed for a non-18 LLVM")

        patcher = self._clean_environment()
        try:
            with mock.patch.object(
                self.toolchains, "LLVM_CMAKE_ROOTS", (current,)
            ), mock.patch.object(
                self.toolchains.shutil, "which", side_effect=which
            ), mock.patch.object(
                self.toolchains.subprocess, "run", side_effect=fake_run
            ):
                resolved = self.toolchains._llvm_cmake_dir()
        finally:
            patcher.stop()
        self.assertEqual(resolved, current.resolve())
        self.assertEqual(
            calls,
            [
                ["/usr/bin/llvm-config-18", "--version"],
                ["/usr/bin/llvm-config", "--version"],
            ],
        )

    def test_llvm_cmake_dir_ignores_a_failing_cmakedir_probe(self) -> None:
        current = self._llvm_config(self.base / "fallback-llvm-18", "18.0.1")

        def fake_run(command, **_kwargs):
            if command[-1] == "--version":
                return SimpleNamespace(returncode=0, stdout="18.0.1\n")
            return SimpleNamespace(returncode=2, stdout="")

        patcher = self._clean_environment()
        try:
            with mock.patch.object(
                self.toolchains, "LLVM_CMAKE_ROOTS", (current,)
            ), mock.patch.object(
                self.toolchains.shutil, "which", return_value="/usr/bin/llvm-config-18"
            ), mock.patch.object(
                self.toolchains.subprocess, "run", side_effect=fake_run
            ):
                resolved = self.toolchains._llvm_cmake_dir()
        finally:
            patcher.stop()
        self.assertEqual(resolved, current.resolve())

    # ------------------------------------------------------------------
    # build command construction
    # ------------------------------------------------------------------

    def _which_map(self, mapping: dict[str, str | None]):
        return mock.patch.object(
            self.toolchains.shutil, "which", side_effect=lambda name: mapping.get(name)
        )

    def test_build_commands_requires_cmake(self) -> None:
        with self._which_map({}):
            with self.assertRaisesRegex(
                self.toolchains.ToolchainError, "CMake is required"
            ):
                self.toolchains._build_commands("styio", self.base / "source")

    def test_build_commands_configure_styio_with_llvm_on_linux(self) -> None:
        source = self.base / "styio-source"
        llvm_dir = Path("/opt/llvm-18/lib/cmake/llvm")
        mapping = {
            "cmake": "/usr/bin/cmake",
            "clang-18": "/usr/bin/clang-18",
            "clang++-18": "/usr/bin/clang++-18",
        }
        with self._which_map(mapping), mock.patch.object(
            self.toolchains, "_llvm_cmake_dir", return_value=llvm_dir
        ), mock.patch.object(self.toolchains.sys, "platform", "linux"):
            configure, build = self.toolchains._build_commands("styio", source)
        self.assertEqual(
            configure,
            (
                "cmake",
                "-S",
                str(source),
                "-B",
                str(source / "build/default"),
                "-DCMAKE_BUILD_TYPE=Debug",
                f"-DLLVM_DIR={llvm_dir}",
                "-DSTYIO_NATIVE_TOOLCHAIN_MODE=auto",
                "-DCMAKE_C_COMPILER=clang-18",
                "-DCMAKE_CXX_COMPILER=clang++-18",
            ),
        )
        self.assertEqual(
            build,
            (
                "cmake",
                "--build",
                str(source / "build/default"),
                "--target",
                "styio",
                "--config",
                "Debug",
                "--parallel",
                "2",
            ),
        )

    def test_build_commands_omits_clang_when_linux_lacks_clang_18(self) -> None:
        source = self.base / "styio-source"
        mapping = {"cmake": "/usr/bin/cmake"}
        with self._which_map(mapping), mock.patch.object(
            self.toolchains, "_llvm_cmake_dir", return_value=Path("/opt/llvm18")
        ), mock.patch.object(self.toolchains.sys, "platform", "linux"):
            configure, _build = self.toolchains._build_commands("styio", source)
        self.assertEqual(
            configure,
            (
                "cmake",
                "-S",
                str(source),
                "-B",
                str(source / "build/default"),
                "-DCMAKE_BUILD_TYPE=Debug",
                "-DLLVM_DIR=/opt/llvm18",
                "-DSTYIO_NATIVE_TOOLCHAIN_MODE=auto",
            ),
        )

    def test_build_commands_omits_clang_when_only_one_compiler_exists(self) -> None:
        source = self.base / "styio-source"
        mapping = {"cmake": "/usr/bin/cmake", "clang-18": "/usr/bin/clang-18"}
        with self._which_map(mapping), mock.patch.object(
            self.toolchains, "_llvm_cmake_dir", return_value=Path("/opt/llvm18")
        ), mock.patch.object(self.toolchains.sys, "platform", "linux"):
            configure, _build = self.toolchains._build_commands("styio", source)
        self.assertNotIn("-DCMAKE_C_COMPILER=clang-18", configure)
        self.assertNotIn("-DCMAKE_CXX_COMPILER=clang++-18", configure)

    def test_build_commands_adds_the_windows_native_toolchain_root(self) -> None:
        source = self.base / "styio-source"
        native_root = str(self.base / "native-toolchain")
        env = mock.patch.dict(
            os.environ, {"STYIO_NATIVE_TOOLCHAIN_ROOT": native_root}
        )
        with env, self._which_map({"cmake": "cmake"}), mock.patch.object(
            self.toolchains, "_llvm_cmake_dir", return_value=Path("C:/llvm18")
        ), mock.patch.object(self.toolchains.os, "name", "nt"), mock.patch.object(
            self.toolchains.sys, "platform", "win32"
        ):
            configure, _build = self.toolchains._build_commands("styio", source)
        self.assertIn(
            f"-DSTYIO_NATIVE_TOOLCHAIN_ROOT={native_root}", configure
        )
        self.assertNotIn("-DCMAKE_C_COMPILER=clang-18", configure)

    def test_build_commands_omits_the_native_root_when_windows_env_is_unset(self) -> None:
        source = self.base / "styio-source"
        patcher = self._clean_environment()
        try:
            with self._which_map({"cmake": "cmake"}), mock.patch.object(
                self.toolchains, "_llvm_cmake_dir", return_value=Path("C:/llvm18")
            ), mock.patch.object(self.toolchains.os, "name", "nt"), mock.patch.object(
                self.toolchains.sys, "platform", "win32"
            ):
                configure, _build = self.toolchains._build_commands("styio", source)
        finally:
            patcher.stop()
        self.assertFalse(
            any(part.startswith("-DSTYIO_NATIVE_TOOLCHAIN_ROOT=") for part in configure)
        )

    def test_build_commands_configure_pafio_without_llvm(self) -> None:
        source = self.base / "pafio-source"
        with self._which_map({"cmake": "/usr/bin/cmake"}), mock.patch.object(
            self.toolchains,
            "_llvm_cmake_dir",
            side_effect=AssertionError("pafio must not need LLVM"),
        ):
            configure, build = self.toolchains._build_commands("pafio", source)
        self.assertEqual(
            configure,
            (
                "cmake",
                "-S",
                str(source),
                "-B",
                str(source / "build/default"),
                "-DCMAKE_BUILD_TYPE=Release",
                "-DPAFIO_BUILD_TESTS=OFF",
            ),
        )
        self.assertEqual(
            build,
            (
                "cmake",
                "--build",
                str(source / "build/default"),
                "--target",
                "pafio",
                "--config",
                "Release",
                "--parallel",
                "2",
            ),
        )

    # ------------------------------------------------------------------
    # provision
    # ------------------------------------------------------------------

    def test_provision_rejects_an_unsupported_product(self) -> None:
        with self.assertRaisesRegex(
            self.toolchains.ToolchainError, "unsupported pinned product tool: vityod"
        ):
            self.toolchains.provision("vityod", root=self.root)

    def test_provision_builds_prints_progress_and_returns_the_executable(self) -> None:
        calls: list[tuple[str, ...]] = []

        def runner(command, cwd):
            command = tuple(command)
            calls.append(command)
            if command[0] == "git":
                return self.toolchains._run(command, cwd)
            if command == ("cmake-build",):
                self._make_executable(self._executable_path(self._managed_source()))
            return 0

        captured = io.StringIO()
        with mock.patch.object(
            self.toolchains,
            "_build_commands",
            return_value=(("cmake-configure",), ("cmake-build",)),
        ), redirect_stdout(captured):
            executable = self.toolchains.provision(
                "styio", root=self.root, runner=runner
            )

        self.assertEqual(executable, self._executable_path(self._managed_source()))
        self.assertTrue(executable.is_file())
        self.assertIn(("cmake-configure",), calls)
        self.assertIn(("cmake-build",), calls)
        self.assertEqual(calls[-1], (str(executable), "--version"))
        output = captured.getvalue()
        self.assertIn(
            f"[vityo-toolchains] configure pinned styio source {self.commit[:12]}",
            output,
        )
        self.assertIn("[vityo-toolchains] build pinned styio CLI", output)

    def test_provision_reuses_an_existing_executable(self) -> None:
        source = self._seed_cache()
        executable = self._make_executable(self._executable_path(source))
        calls: list[tuple[str, ...]] = []
        with mock.patch.object(
            self.toolchains,
            "_build_commands",
            side_effect=AssertionError("a valid binary must be reused"),
        ):
            result = self.toolchains.provision(
                "styio",
                root=self.root,
                runner=lambda command, _cwd: calls.append(tuple(command)) or 0,
            )
        self.assertEqual(result, executable)
        self.assertEqual(calls, [(str(executable), "--version")])

    def test_provision_rejects_an_existing_executable_failing_version_check(self) -> None:
        source = self._seed_cache()
        executable = self._make_executable(self._executable_path(source))
        with mock.patch.object(
            self.toolchains,
            "_build_commands",
            side_effect=AssertionError("no rebuild may happen"),
        ):
            with self.assertRaisesRegex(
                self.toolchains.ToolchainError,
                "the pinned styio CLI failed its version check",
            ):
                self.toolchains.provision(
                    "styio", root=self.root, runner=lambda _command, _cwd: 4
                )
        self.assertTrue(executable.is_file())

    def test_provision_reports_configure_and_build_failures(self) -> None:
        self._seed_cache()

        def fail_configure(command, _cwd):
            return 3 if tuple(command) == ("cmake-configure",) else 0

        calls: list[tuple[str, ...]] = []

        def fail_build(command, _cwd):
            calls.append(tuple(command))
            return 4 if tuple(command) == ("cmake-build",) else 0

        with mock.patch.object(
            self.toolchains,
            "_build_commands",
            return_value=(("cmake-configure",), ("cmake-build",)),
        ), redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(
                self.toolchains.ToolchainError,
                "configuring the pinned styio source failed",
            ):
                self.toolchains.provision(
                    "styio", root=self.root, runner=fail_configure
                )

            with self.assertRaisesRegex(
                self.toolchains.ToolchainError,
                "building the pinned styio CLI failed",
            ):
                self.toolchains.provision("styio", root=self.root, runner=fail_build)

        self.assertEqual(calls, [("cmake-configure",), ("cmake-build",)])
        self.assertFalse(self._executable_path(self._managed_source()).exists())

    def test_provision_reports_a_build_that_produced_no_executable(self) -> None:
        self._seed_cache()
        with mock.patch.object(
            self.toolchains,
            "_build_commands",
            return_value=(("cmake-configure",), ("cmake-build",)),
        ):
            with self.assertRaisesRegex(
                self.toolchains.ToolchainError,
                "the pinned styio build did not produce its CLI executable",
            ):
                self.toolchains.provision(
                    "styio", root=self.root, runner=lambda _command, _cwd: 0
                )

    def test_provision_reports_a_post_build_version_check_failure(self) -> None:
        source_executable = self._executable_path(self._managed_source())

        def runner(command, cwd):
            command = tuple(command)
            if command[0] == "git":
                return self.toolchains._run(command, cwd)
            if command == ("cmake-build",):
                self._make_executable(source_executable)
                return 0
            if command == (str(source_executable), "--version"):
                return 9
            return 0

        with mock.patch.object(
            self.toolchains,
            "_build_commands",
            return_value=(("cmake-configure",), ("cmake-build",)),
        ):
            with self.assertRaisesRegex(
                self.toolchains.ToolchainError,
                "the pinned styio CLI failed its version check",
            ):
                self.toolchains.provision("styio", root=self.root, runner=runner)

    # ------------------------------------------------------------------
    # validate_executable
    # ------------------------------------------------------------------

    def test_validate_executable_rejects_unknown_product_and_missing_file(self) -> None:
        executable = self._make_executable(self.base / "loose" / "styio")
        self.assertFalse(
            self.toolchains.validate_executable("vityod", executable, root=self.root)
        )
        self.assertFalse(
            self.toolchains.validate_executable(
                "styio", self.base / "absent", root=self.root
            )
        )

    def test_validate_executable_rejects_a_non_executable_file(self) -> None:
        plain = self.base / "loose" / "not-executable"
        plain.parent.mkdir(parents=True, exist_ok=True)
        plain.write_text("#!/bin/sh\n", encoding="utf-8")
        plain.chmod(0o644)
        self.assertFalse(
            self.toolchains.validate_executable("styio", plain, root=self.root)
        )

    def test_validate_executable_requires_a_pinned_checkout(self) -> None:
        source = self._seed_cache()
        executable = self._make_executable(self._executable_path(source))
        self.assertTrue(
            self.toolchains.validate_executable("styio", executable, root=self.root)
        )

        head = self._second_commit(self.origin)
        self.assertNotEqual(head, self.commit)
        self._write_matrix(head)
        self.assertFalse(
            self.toolchains.validate_executable("styio", executable, root=self.root)
        )

    def test_validate_executable_rejects_files_outside_a_repository(self) -> None:
        loose = self._make_executable(self.base / "loose" / "styio")
        self.assertFalse(
            self.toolchains.validate_executable("styio", loose, root=self.root)
        )

        foreign = self.base / "foreign-checkout"
        self._init_repository(foreign)
        foreign_executable = self._make_executable(
            foreign / "build/default/bin/styio"
        )
        self.assertFalse(
            self.toolchains.validate_executable(
                "styio", foreign_executable, root=self.root
            )
        )


if __name__ == "__main__":
    unittest.main()
