#!/usr/bin/env python3
"""Behaviour tests for the Linux host readiness gate.

The tests drive the gate through temporary repositories/trees and patched
module globals only; no real host tooling, network or install tree is used.
"""

from __future__ import annotations

import importlib.util
import io
import json
import runpy
import subprocess
import sys
import tempfile
import unittest
from contextlib import contextmanager, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
GATE_PATH = REPO_ROOT / "scripts" / "check-linux-host-readiness-gate.py"


def load_gate_module():
    spec = importlib.util.spec_from_file_location(
        "check_linux_host_readiness_gate_extended", GATE_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {GATE_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def check_result(
    name: str,
    ok: bool,
    *,
    blocked: bool | None = None,
    detail: str = "detail",
) -> dict[str, object]:
    result: dict[str, object] = {"name": name, "ok": ok, "detail": detail}
    if blocked is not None:
        result["blocked"] = blocked
    return result


class LinuxHostReadinessGateExtendedTest(unittest.TestCase):
    def setUp(self) -> None:
        self.gate = load_gate_module()
        self.temporary = tempfile.TemporaryDirectory(prefix="linux-readiness-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)

    # ------------------------------------------------------------------
    # helpers
    # ------------------------------------------------------------------

    def _version_file(self, key: str, content: str | None) -> Path:
        path = self.base / f"{key}-version"
        if content is not None:
            path.write_text(content, encoding="utf-8")
        return path

    @contextmanager
    def _versions(self, **contents: str | None):
        files = {
            key: self._version_file(key, contents.get(key))
            for key in ("python", "flutter", "node", "chromium")
        }
        with mock.patch.object(self.gate, "VERSION_FILES", files):
            yield files

    @contextmanager
    def _checks(self, **results: dict[str, object]):
        registry = {name: (f"{name} check", name) for name in results}
        funcs = {
            name: (lambda result=result: dict(result))
            for name, result in results.items()
        }
        with mock.patch.object(
            self.gate, "CHECK_REGISTRY", registry
        ), mock.patch.dict(self.gate._CHECK_FUNCS, funcs, clear=True):
            yield

    # ------------------------------------------------------------------
    # version files and small helpers
    # ------------------------------------------------------------------

    def test_read_version_file_handles_missing_and_empty_files(self) -> None:
        self.assertIsNone(self.gate._read_version_file("not-registered"))
        with self._versions(python=None):
            self.assertIsNone(self.gate._read_version_file("python"))
        with self._versions(python="  3.13.5\n"):
            self.assertEqual(self.gate._read_version_file("python"), "3.13.5")
        with self._versions(python="\n   \n"):
            self.assertIsNone(self.gate._read_version_file("python"))

    def test_run_returns_stripped_stdout_and_passes_the_timeout(self) -> None:
        with mock.patch.object(self.gate.subprocess, "run") as run:
            run.return_value = SimpleNamespace(returncode=0, stdout="  hello  \n")
            self.assertEqual(self.gate._run(["tool", "--flag"], timeout=3.0), "hello")
        run.assert_called_once_with(
            ["tool", "--flag"], capture_output=True, text=True, timeout=3.0
        )

    def test_run_returns_none_for_failures_and_host_errors(self) -> None:
        with mock.patch.object(self.gate.subprocess, "run") as run:
            run.return_value = SimpleNamespace(returncode=1, stdout="broken")
            self.assertIsNone(self.gate._run(["tool"]))

            run.side_effect = FileNotFoundError("no such tool")
            self.assertIsNone(self.gate._run(["missing"]))

            run.side_effect = subprocess.TimeoutExpired(cmd="tool", timeout=1.0)
            self.assertIsNone(self.gate._run(["slow"]))

            run.side_effect = OSError("permission denied")
            self.assertIsNone(self.gate._run(["blocked"]))

    def test_normalize_node_version_strips_an_optional_v_prefix(self) -> None:
        self.assertIsNone(self.gate._normalize_node_version(None))
        self.assertEqual(self.gate._normalize_node_version("v24.15.0"), "24.15.0")
        self.assertEqual(self.gate._normalize_node_version(" v24.15.0 "), "24.15.0")
        self.assertEqual(self.gate._normalize_node_version("24.15.0"), "24.15.0")

    def test_has_crlf_reads_bytes_and_tolerates_unreadable_paths(self) -> None:
        unix = self.base / "unix.sh"
        unix.write_bytes(b"#!/bin/sh\nset -e\n")
        windows = self.base / "windows.sh"
        windows.write_bytes(b"#!/bin/sh\r\nset -e\r\n")
        self.assertFalse(self.gate._has_crlf(unix))
        self.assertTrue(self.gate._has_crlf(windows))
        directory = self.base / "directory.sh"
        directory.mkdir()
        self.assertFalse(self.gate._has_crlf(directory))

    def test_flutter_sdk_crlf_files_lists_scripts_with_crlf(self) -> None:
        sdk = self.base / "flutter-sdk" / "bin"
        sdk.mkdir(parents=True)
        flutter = sdk / "flutter"
        flutter.write_bytes(b"#!/usr/bin/env bash\r\n")
        shared = sdk / "internal" / "shared.sh"
        shared.parent.mkdir(parents=True)
        shared.write_bytes(b"#!/usr/bin/env bash\r\n")

        found = self.gate._flutter_sdk_crlf_files(str(flutter))
        self.assertEqual(found, [str(flutter), str(shared)])

    def test_flutter_sdk_crlf_files_skips_the_binary_for_windows_launchers(self) -> None:
        sdk = self.base / "flutter-sdk" / "bin"
        sdk.mkdir(parents=True)
        launcher = sdk / "flutter.bat"
        launcher.write_bytes(b"@echo off\r\n")
        shared = sdk / "internal" / "shared.sh"
        shared.parent.mkdir(parents=True)
        shared.write_bytes(b"#!/usr/bin/env bash\r\n")

        self.assertEqual(
            self.gate._flutter_sdk_crlf_files(str(launcher)), [str(shared)]
        )

    def test_flutter_sdk_crlf_files_returns_nothing_for_lf_checkouts(self) -> None:
        sdk = self.base / "flutter-sdk" / "bin"
        sdk.mkdir(parents=True)
        flutter = sdk / "flutter"
        flutter.write_bytes(b"#!/usr/bin/env bash\n")
        shared = sdk / "internal" / "shared.sh"
        shared.parent.mkdir(parents=True)
        shared.write_bytes(b"#!/usr/bin/env bash\n")
        self.assertEqual(self.gate._flutter_sdk_crlf_files(str(flutter)), [])

    def test_result_builders_set_the_expected_flags(self) -> None:
        found = self.gate._check_found("python", "Python 3.13.5 on PATH")
        self.assertEqual(
            found,
            {"name": "python", "ok": True, "detail": "Python 3.13.5 on PATH"},
        )
        blocked = self.gate._check_blocked("python", "missing")
        self.assertTrue(blocked["blocked"])
        self.assertFalse(blocked["ok"])
        warn = self.gate._check_warn("python", "stale")
        self.assertFalse(warn["blocked"])
        self.assertFalse(warn["ok"])

    # ------------------------------------------------------------------
    # python check
    # ------------------------------------------------------------------

    def test_python_blocks_when_python3_is_absent(self) -> None:
        with mock.patch.object(self.gate.shutil, "which", return_value=None):
            result = self.gate.check_python()
        self.assertTrue(result["blocked"])
        self.assertIn("python3 not found on PATH", str(result["detail"]))

    def test_python_blocks_when_version_probe_fails(self) -> None:
        with mock.patch.object(
            self.gate.shutil, "which", return_value="/usr/bin/python3"
        ), mock.patch.object(self.gate, "_run", return_value=None):
            result = self.gate.check_python()
        self.assertTrue(result["blocked"])
        self.assertIn("python3 found but --version failed", str(result["detail"]))

    def test_python_warns_on_unparseable_and_mismatched_versions(self) -> None:
        with self._versions(python="3.13.5"), mock.patch.object(
            self.gate.shutil, "which", return_value="/usr/bin/python3"
        ), mock.patch.object(self.gate, "_run", return_value="Python weird"):
            unparseable = self.gate.check_python()
        self.assertFalse(unparseable["ok"])
        self.assertFalse(unparseable["blocked"])
        self.assertIn("unparseable version", str(unparseable["detail"]))

        with self._versions(python="3.13.5"), mock.patch.object(
            self.gate.shutil, "which", return_value="/usr/bin/python3"
        ), mock.patch.object(self.gate, "_run", return_value="Python 3.12.0"):
            stale = self.gate.check_python()
        self.assertIn("found Python 3.12.0", str(stale["detail"]))
        self.assertIn("repo expects 3.13.5", str(stale["detail"]))

    def test_python_passes_without_a_pinned_version_and_with_a_match(self) -> None:
        with self._versions(python=None), mock.patch.object(
            self.gate.shutil, "which", return_value="/usr/bin/python3"
        ), mock.patch.object(self.gate, "_run", return_value="Python 3.13.5"):
            unpinned = self.gate.check_python()
        self.assertTrue(unpinned["ok"])
        self.assertIn("Python 3.13.5 on PATH", str(unpinned["detail"]))

        with self._versions(python="3.13.5"), mock.patch.object(
            self.gate.shutil, "which", return_value="/usr/bin/python3"
        ), mock.patch.object(self.gate, "_run", return_value="Python 3.13.5"):
            pinned = self.gate.check_python()
        self.assertTrue(pinned["ok"])

    # ------------------------------------------------------------------
    # flutter check
    # ------------------------------------------------------------------

    def test_flutter_blocks_when_flutter_is_absent(self) -> None:
        with mock.patch.object(self.gate.shutil, "which", return_value=None):
            result = self.gate.check_flutter()
        self.assertTrue(result["blocked"])
        self.assertIn("flutter not found on PATH", str(result["detail"]))

    def test_flutter_blocks_when_version_fails_without_crlf(self) -> None:
        sdk = self.base / "flutter-sdk" / "bin"
        sdk.mkdir(parents=True)
        flutter = sdk / "flutter"
        flutter.write_bytes(b"#!/usr/bin/env bash\n")
        shared = sdk / "internal" / "shared.sh"
        shared.parent.mkdir(parents=True)
        shared.write_bytes(b"#!/usr/bin/env bash\n")

        with mock.patch.object(
            self.gate.shutil, "which", return_value=str(flutter)
        ), mock.patch.object(self.gate, "_run", return_value=None):
            result = self.gate.check_flutter()
        self.assertTrue(result["blocked"])
        self.assertEqual(
            result["detail"], "flutter found but --version failed"
        )

    def test_flutter_blocks_when_version_fails_with_crlf_sdk_scripts(self) -> None:
        sdk = self.base / "flutter-sdk" / "bin"
        sdk.mkdir(parents=True)
        flutter = sdk / "flutter"
        flutter.write_bytes(b"#!/usr/bin/env bash\r\n")
        shared = sdk / "internal" / "shared.sh"
        shared.parent.mkdir(parents=True)
        shared.write_bytes(b"#!/usr/bin/env bash\r\n")

        with mock.patch.object(
            self.gate.shutil, "which", return_value=str(flutter)
        ), mock.patch.object(self.gate, "_run", return_value=None):
            result = self.gate.check_flutter()
        self.assertTrue(result["blocked"])
        self.assertIn("CRLF line endings", str(result["detail"]))
        self.assertIn("shared.sh", str(result["detail"]))

    def test_flutter_reports_versions_and_pinned_mismatch(self) -> None:
        sample = (
            "Flutter 3.41.7 - channel stable - https://github.com/flutter/flutter\n"
            "Dart 3.11.5\n"
        )
        with self._versions(flutter="3.41.7"), mock.patch.object(
            self.gate.shutil, "which", return_value="/opt/flutter/bin/flutter"
        ), mock.patch.object(self.gate, "_run", return_value=sample):
            matching = self.gate.check_flutter()
        self.assertTrue(matching["ok"])
        self.assertEqual(matching["detail"], "Flutter 3.41.7, Dart 3.11.5 on PATH")

        stale_sample = sample.replace("Flutter 3.41.7", "Flutter 3.40.0")
        with self._versions(flutter="3.41.7"), mock.patch.object(
            self.gate.shutil, "which", return_value="/opt/flutter/bin/flutter"
        ), mock.patch.object(self.gate, "_run", return_value=stale_sample):
            stale = self.gate.check_flutter()
        self.assertFalse(stale["ok"])
        self.assertFalse(stale["blocked"])
        self.assertIn("Flutter 3.40.0 installed, repo expects 3.41.7", str(stale["detail"]))

    def test_flutter_warns_when_versions_cannot_be_parsed(self) -> None:
        with self._versions(flutter=None), mock.patch.object(
            self.gate.shutil, "which", return_value="/opt/flutter/bin/flutter"
        ), mock.patch.object(self.gate, "_run", return_value="unusable output"):
            result = self.gate.check_flutter()
        self.assertFalse(result["ok"])
        self.assertIn(
            "could not parse Flutter version from output", str(result["detail"])
        )
        self.assertIn("could not parse Dart version", str(result["detail"]))

    def test_flutter_found_without_a_dart_version(self) -> None:
        # Dart line absent -> the missing Dart version is warned about.
        with self._versions(flutter=None), mock.patch.object(
            self.gate.shutil, "which", return_value="/opt/flutter/bin/flutter"
        ), mock.patch.object(
            self.gate, "_run", return_value="Flutter 3.41.7 - channel stable\n"
        ):
            result = self.gate.check_flutter()
        self.assertFalse(result["ok"])
        self.assertIn("could not parse Dart version", str(result["detail"]))

    # ------------------------------------------------------------------
    # npm check
    # ------------------------------------------------------------------

    def test_npm_blocks_when_node_is_absent(self) -> None:
        with mock.patch.object(self.gate.shutil, "which", return_value=None):
            result = self.gate.check_npm()
        self.assertTrue(result["blocked"])
        self.assertIn("node not found on PATH", str(result["detail"]))

    def test_npm_blocks_when_node_version_probe_fails(self) -> None:
        with mock.patch.object(
            self.gate.shutil, "which", return_value="/usr/bin/node"
        ), mock.patch.object(self.gate, "_run", return_value=None):
            result = self.gate.check_npm()
        self.assertTrue(result["blocked"])
        self.assertIn("node found but --version failed", str(result["detail"]))

    def test_npm_warns_on_a_version_mismatch(self) -> None:
        with self._versions(node="v24.15.0"), mock.patch.object(
            self.gate.shutil,
            "which",
            side_effect=lambda name: f"/usr/bin/{name}",
        ), mock.patch.object(self.gate, "_run", return_value="v22.0.0"):
            result = self.gate.check_npm()
        self.assertFalse(result["ok"])
        self.assertFalse(result["blocked"])
        self.assertIn("Node v22.0.0 installed, repo expects v24.15.0", str(result["detail"]))

    def test_npm_warns_when_npm_is_missing(self) -> None:
        with self._versions(node="v24.15.0"), mock.patch.object(
            self.gate.shutil,
            "which",
            side_effect=lambda name: "/usr/bin/node" if name == "node" else None,
        ), mock.patch.object(self.gate, "_run", return_value="v24.15.0"):
            result = self.gate.check_npm()
        self.assertFalse(result["ok"])
        self.assertIn("Node v24.15.0 on PATH but npm is missing", str(result["detail"]))

    def test_npm_reports_node_and_npm_on_path(self) -> None:
        with self._versions(node="24.15.0"), mock.patch.object(
            self.gate.shutil,
            "which",
            side_effect=lambda name: f"/usr/bin/{name}",
        ), mock.patch.object(self.gate, "_run", return_value="v24.15.0"):
            result = self.gate.check_npm()
        self.assertTrue(result["ok"])
        self.assertEqual(result["detail"], "Node v24.15.0 and npm on PATH")

    # ------------------------------------------------------------------
    # chromium check
    # ------------------------------------------------------------------

    def test_chromium_blocks_when_no_browser_is_installed(self) -> None:
        with mock.patch.object(self.gate.shutil, "which", return_value=None):
            result = self.gate.check_chromium()
        self.assertTrue(result["blocked"])
        self.assertIn("no Chromium/Chrome binary found", str(result["detail"]))

    def test_chromium_warns_when_version_probe_fails(self) -> None:
        with mock.patch.object(
            self.gate.shutil,
            "which",
            side_effect=lambda name: "/usr/bin/chromium" if name == "chromium" else None,
        ), mock.patch.object(self.gate, "_run", return_value=None):
            result = self.gate.check_chromium()
        self.assertFalse(result["ok"])
        self.assertFalse(result["blocked"])
        self.assertIn("chromium found on PATH but --version failed", str(result["detail"]))

    def test_chromium_reports_a_version_and_flags_a_mismatch(self) -> None:
        with self._versions(chromium="147.0.7727.116"), mock.patch.object(
            self.gate.shutil,
            "which",
            side_effect=lambda name: "/usr/bin/chromium" if name == "chromium" else None,
        ), mock.patch.object(
            self.gate, "_run", return_value="Chromium 147.0.7727.116"
        ):
            matching = self.gate.check_chromium()
        self.assertTrue(matching["ok"])
        self.assertEqual(matching["detail"], "chromium 147.0.7727.116 on PATH")

        with self._versions(chromium="147.0.7727.116"), mock.patch.object(
            self.gate.shutil,
            "which",
            side_effect=lambda name: "/usr/bin/google-chrome" if name == "google-chrome" else None,
        ), mock.patch.object(self.gate, "_run", return_value="Google Chrome 127.0.0.1"):
            stale = self.gate.check_chromium()
        self.assertFalse(stale["ok"])
        self.assertIn(
            "google-chrome version 127.0.0.1, repo expects 147.0.7727.116",
            str(stale["detail"]),
        )

    def test_chromium_uses_raw_output_when_no_version_is_parseable(self) -> None:
        with self._versions(chromium=None), mock.patch.object(
            self.gate.shutil,
            "which",
            side_effect=lambda name: (
                "/usr/bin/chromium-browser" if name == "chromium-browser" else None
            ),
        ), mock.patch.object(self.gate, "_run", return_value="Chromium dev build"):
            result = self.gate.check_chromium()
        self.assertTrue(result["ok"])
        self.assertEqual(
            result["detail"], "chromium-browser Chromium dev build on PATH"
        )

    # ------------------------------------------------------------------
    # docker-flutter check
    # ------------------------------------------------------------------

    def test_docker_flutter_blocks_when_docker_is_absent(self) -> None:
        with mock.patch.object(self.gate.shutil, "which", return_value=None):
            result = self.gate.check_docker_flutter()
        self.assertTrue(result["blocked"])
        self.assertIn("docker not found on PATH", str(result["detail"]))

    def test_docker_flutter_blocks_when_the_daemon_is_unreachable(self) -> None:
        with mock.patch.object(
            self.gate.shutil, "which", return_value="/usr/bin/docker"
        ), mock.patch.object(self.gate, "_run", return_value=None):
            result = self.gate.check_docker_flutter()
        self.assertTrue(result["blocked"])
        self.assertIn("daemon unreachable", str(result["detail"]))

    def test_docker_flutter_warns_when_the_image_is_missing(self) -> None:
        outputs = {
            ("docker", "info", "--format", "{{.ServerVersion}}"): "24.0.7",
            (
                "docker",
                "images",
                "--format",
                "{{.Repository}}:{{.Tag}}",
                self.gate.DEV_CONTAINER_TAG,
            ): "other/image:latest",
        }

        def fake_run(command, timeout=15.0):
            return outputs.get(tuple(command))

        with mock.patch.object(
            self.gate.shutil, "which", return_value="/usr/bin/docker"
        ), mock.patch.object(self.gate, "_run", side_effect=fake_run):
            result = self.gate.check_docker_flutter()
        self.assertFalse(result["ok"])
        self.assertFalse(result["blocked"])
        self.assertIn("Docker daemon 24.0.7 reachable", str(result["detail"]))
        self.assertIn("not found locally", str(result["detail"]))

    def test_docker_flutter_warns_when_inspect_fails(self) -> None:
        def fake_run(command, timeout=15.0):
            if tuple(command)[:2] == ("docker", "info"):
                return "24.0.7"
            return None

        with mock.patch.object(
            self.gate.shutil, "which", return_value="/usr/bin/docker"
        ), mock.patch.object(self.gate, "_run", side_effect=fake_run):
            result = self.gate.check_docker_flutter()
        self.assertFalse(result["ok"])
        self.assertIn("not found locally", str(result["detail"]))

    def test_docker_flutter_warns_when_the_container_probe_fails(self) -> None:
        def fake_run(command, timeout=15.0):
            if tuple(command)[:2] == ("docker", "info"):
                return "24.0.7"
            if tuple(command)[:2] == ("docker", "images"):
                return self.gate.DEV_CONTAINER_TAG
            return None

        with mock.patch.object(
            self.gate.shutil, "which", return_value="/usr/bin/docker"
        ), mock.patch.object(self.gate, "_run", side_effect=fake_run):
            result = self.gate.check_docker_flutter()
        self.assertFalse(result["ok"])
        self.assertIn("flutter --version failed inside container", str(result["detail"]))

    def test_docker_flutter_reports_the_container_flutter_version(self) -> None:
        calls: list[tuple[tuple[str, ...], float]] = []

        def fake_run(command, timeout=15.0):
            calls.append((tuple(command), timeout))
            if tuple(command)[:2] == ("docker", "info"):
                return "27.1.1"
            if tuple(command)[:2] == ("docker", "images"):
                return self.gate.DEV_CONTAINER_TAG
            return "Flutter 3.41.7 - channel stable\n"

        with mock.patch.object(
            self.gate.shutil, "which", return_value="/usr/bin/docker"
        ), mock.patch.object(self.gate, "_run", side_effect=fake_run):
            result = self.gate.check_docker_flutter()
        self.assertTrue(result["ok"])
        self.assertEqual(
            result["detail"],
            f"Docker 27.1.1, image {self.gate.DEV_CONTAINER_TAG} available, "
            "Flutter 3.41.7 inside",
        )
        self.assertIn(
            (("docker", "run", "--rm", self.gate.DEV_CONTAINER_TAG, "flutter", "--version"), 30.0),
            calls,
        )

    def test_docker_flutter_accepts_an_image_override_and_unparsed_version(self) -> None:
        tag = "registry.example.invalid/vityo/dev-env:2026-10"
        calls: list[tuple[str, ...]] = []

        def fake_run(command, timeout=15.0):
            calls.append(tuple(command))
            if tuple(command)[:2] == ("docker", "info"):
                return "27.1.1"
            if tuple(command)[:2] == ("docker", "images"):
                return f"{tag}\n"
            return "no flutter banner here"

        with mock.patch.dict(
            self.gate.os.environ, {"VITYO_DOCKER_IMAGE": tag}
        ), mock.patch.object(
            self.gate.shutil, "which", return_value="/usr/bin/docker"
        ), mock.patch.object(self.gate, "_run", side_effect=fake_run):
            result = self.gate.check_docker_flutter()
        self.assertTrue(result["ok"])
        self.assertEqual(
            result["detail"],
            f"Docker 27.1.1, image {tag} available, Flutter ? inside",
        )
        self.assertIn(
            ("docker", "images", "--format", "{{.Repository}}:{{.Tag}}", tag), calls
        )
        self.assertIn(("docker", "run", "--rm", tag, "flutter", "--version"), calls)

    # ------------------------------------------------------------------
    # CRLF shell-script check
    # ------------------------------------------------------------------

    def test_crlf_scripts_passes_for_lf_trees_and_skips_absent_roots(self) -> None:
        (self.base / "products" / "vityo_app" / "tooling").mkdir(parents=True)
        (self.base / "products" / "vityo_app" / "tooling" / "build.sh").write_bytes(
            b"#!/usr/bin/env bash\nset -euo pipefail\n"
        )
        with mock.patch.object(self.gate, "REPO_ROOT", self.base):
            result = self.gate.check_crlf_scripts()
        self.assertTrue(result["ok"])
        self.assertEqual(result["detail"], "all shell scripts use LF line endings")

        empty_root = self.base / "shallow-checkout"
        empty_root.mkdir()
        with mock.patch.object(self.gate, "REPO_ROOT", empty_root):
            shallow = self.gate.check_crlf_scripts()
        self.assertTrue(shallow["ok"])
        self.assertEqual(shallow["detail"], "all shell scripts use LF line endings")

    def test_crlf_scripts_reports_crlf_files_in_both_trees(self) -> None:
        product = self.base / "products" / "vityo_app" / "tooling"
        product.mkdir(parents=True)
        (product / "flutter-run.sh").write_bytes(b"#!/bin/sh\r\n")
        scripts = self.base / "scripts"
        scripts.mkdir()
        (scripts / "gate.sh").write_bytes(b"#!/bin/sh\r\n")
        docker = self.base / "docker"
        docker.mkdir()
        (docker / "entrypoint.sh").write_bytes(b"#!/bin/sh\r\n")

        with mock.patch.object(self.gate, "REPO_ROOT", self.base):
            result = self.gate.check_crlf_scripts()
        self.assertTrue(result["blocked"])
        detail = str(result["detail"]).replace("\\", "/")
        self.assertIn("3 shell script(s) have CRLF line endings", detail)
        for name in (
            "products/vityo_app/tooling/flutter-run.sh",
            "scripts/gate.sh",
            "docker/entrypoint.sh",
        ):
            self.assertIn(name, detail)

    def test_crlf_scripts_skips_unreadable_entries(self) -> None:
        product = self.base / "products" / "vityo_app"
        product.mkdir(parents=True)
        (product / "unreadable.sh").mkdir()
        (product / "clean.sh").write_bytes(b"#!/bin/sh\n")
        scripts = self.base / "scripts"
        scripts.mkdir()
        (scripts / "unreadable.sh").mkdir()

        with mock.patch.object(self.gate, "REPO_ROOT", self.base):
            result = self.gate.check_crlf_scripts()
        self.assertTrue(result["ok"])
        self.assertEqual(result["detail"], "all shell scripts use LF line endings")

    # ------------------------------------------------------------------
    # registry and runner
    # ------------------------------------------------------------------

    def test_populate_check_funcs_binds_every_registry_entry(self) -> None:
        original = dict(self.gate._CHECK_FUNCS)
        self.addCleanup(
            lambda: (self.gate._CHECK_FUNCS.clear(), self.gate._CHECK_FUNCS.update(original))
        )
        self.gate._CHECK_FUNCS.clear()
        self.gate._populate_check_funcs()
        self.assertEqual(set(self.gate._CHECK_FUNCS), set(self.gate.CHECK_REGISTRY))
        for name, (_description, func_name) in self.gate.CHECK_REGISTRY.items():
            self.assertIs(self.gate._CHECK_FUNCS[name], getattr(self.gate, func_name))

    def test_run_single_check_returns_an_unknown_check_failure(self) -> None:
        result = self.gate.run_single_check("no-such-check")
        self.assertEqual(
            result,
            {
                "name": "no-such-check",
                "ok": False,
                "detail": "unknown check: no-such-check",
            },
        )

    def test_run_all_checks_filters_with_include(self) -> None:
        with self._checks(
            python=check_result("python", True),
            npm=check_result("npm", True),
        ):
            all_results = self.gate.run_all_checks()
            included = self.gate.run_all_checks(include={"npm"})
        self.assertEqual([r["name"] for r in all_results], ["python", "npm"])
        self.assertEqual([r["name"] for r in included], ["npm"])

    # ------------------------------------------------------------------
    # main
    # ------------------------------------------------------------------

    def test_main_reports_ok_blocked_and_warn_checks_in_text_mode(self) -> None:
        with self._checks(
            python=check_result("python", True, detail="Python 3.13.5 on PATH"),
            flutter=check_result("flutter", False, blocked=True, detail="missing"),
            chromium=check_result("chromium", False, blocked=False, detail="stale"),
        ), redirect_stdout(io.StringIO()) as output:
            exit_code = self.gate.main([])
        text = output.getvalue()
        self.assertEqual(exit_code, 1)
        self.assertIn(
            "[linux-readiness] ok: python (Python 3.13.5 on PATH)", text
        )
        self.assertIn("[linux-readiness] BLOCKED: flutter (missing)", text)
        self.assertIn("[linux-readiness] WARN: chromium (stale)", text)
        self.assertIn(
            "[linux-readiness] 1 blocked check(s) - resolve before building on Linux",
            text,
        )
        self.assertIn(
            "[linux-readiness] 1 warning(s) - review before building on Linux", text
        )

    def test_main_exits_two_for_warnings_only(self) -> None:
        with self._checks(
            chromium=check_result("chromium", False, blocked=False, detail="stale"),
        ), redirect_stdout(io.StringIO()) as output:
            exit_code = self.gate.main([])
        text = output.getvalue()
        self.assertEqual(exit_code, 2)
        self.assertIn("[linux-readiness] WARN: chromium (stale)", text)
        self.assertIn("1 warning(s)", text)
        self.assertNotIn("blocked check(s)", text)

    def test_main_reports_all_checks_passed(self) -> None:
        with self._checks(
            python=check_result("python", True),
            npm=check_result("npm", True),
        ), redirect_stdout(io.StringIO()) as output:
            exit_code = self.gate.main([])
        self.assertEqual(exit_code, 0)
        self.assertIn("[linux-readiness] all checks passed", output.getvalue())

    def test_main_emits_a_json_summary(self) -> None:
        with self._checks(
            python=check_result("python", True, detail="Python 3.13.5"),
            flutter=check_result("flutter", False, blocked=True, detail="missing"),
        ), redirect_stdout(io.StringIO()) as output:
            exit_code = self.gate.main(["--json"])
        self.assertEqual(exit_code, 1)
        payload = json.loads(output.getvalue())
        self.assertEqual(payload["ok"], False)
        self.assertEqual(payload["blocked"], 1)
        self.assertEqual(payload["warnings"], 0)
        self.assertEqual(
            [check["name"] for check in payload["checks"]], ["python", "flutter"]
        )

    def test_main_runs_a_single_check_by_name(self) -> None:
        with self._checks(
            flutter=check_result("flutter", True, detail="Flutter 3.41.7 on PATH"),
            python=check_result("python", True, detail="must not run"),
        ), redirect_stdout(io.StringIO()) as output:
            exit_code = self.gate.main(["--check", "flutter"])
        text = output.getvalue()
        self.assertEqual(exit_code, 0)
        self.assertIn("ok: flutter (Flutter 3.41.7 on PATH)", text)
        self.assertNotIn("python", text)

    def test_main_reports_an_unknown_check_as_a_warning(self) -> None:
        with redirect_stdout(io.StringIO()) as output:
            exit_code = self.gate.main(["--check", "no-such-check"])
        text = output.getvalue()
        self.assertEqual(exit_code, 2)
        self.assertIn(
            "[linux-readiness] WARN: no-such-check (unknown check: no-such-check)",
            text,
        )

    def test_main_reads_sys_argv_when_argv_is_omitted(self) -> None:
        with self._checks(
            python=check_result("python", True, detail="Python 3.13.5 on PATH"),
        ), mock.patch.object(sys, "argv", ["check-linux-host-readiness-gate.py"]), redirect_stdout(
            io.StringIO()
        ) as output:
            exit_code = self.gate.main()
        self.assertEqual(exit_code, 0)
        self.assertIn("ok: python (Python 3.13.5 on PATH)", output.getvalue())

    def test_script_entrypoint_returns_the_gate_exit_code(self) -> None:
        argv = ["check-linux-host-readiness-gate.py", "--check", "no-such-check"]
        with mock.patch.object(sys, "argv", argv), redirect_stdout(
            io.StringIO()
        ) as output:
            with self.assertRaises(SystemExit) as caught:
                runpy.run_path(str(GATE_PATH), run_name="__main__")
        self.assertEqual(caught.exception.code, 2)
        self.assertIn("unknown check: no-such-check", output.getvalue())


if __name__ == "__main__":
    unittest.main()
