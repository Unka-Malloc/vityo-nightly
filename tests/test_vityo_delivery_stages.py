from __future__ import annotations

import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
import zipfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "vityo.py"


def load_delivery():
    spec = importlib.util.spec_from_file_location("vityo_delivery_stages_target", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _load_docs_gate_module():
    path = ROOT / "scripts" / "docs_gate.py"
    spec = importlib.util.spec_from_file_location("docs_gate_under_test", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class DeliveryStageTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.delivery = load_delivery()
        self.temporary = tempfile.TemporaryDirectory(prefix="vityo-stage-test-")
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def options(self, **overrides) -> object:
        return self.delivery.DeliveryOptions(**overrides)

    def write_candidate(self, name: str, platform: str) -> Path:
        artifact = self.root / name
        artifact.write_bytes(b"package")
        sidecar = artifact.with_suffix(artifact.suffix + ".json")
        sidecar.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "platform": platform,
                    "artifact": artifact.name,
                }
            ),
            encoding="utf-8",
        )
        return artifact

    def write_release_versions(self, platform: str, version: str = "9.9.9") -> None:
        path = self.root / "packaging/release-versions.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps({"platform_adapters": {platform: version}}),
            encoding="utf-8",
        )


class HostPlatformTest(DeliveryStageTestCase):
    def test_host_platform_maps_each_supported_system(self) -> None:
        for value, expected in (
            ("darwin", "macos"),
            ("win32", "windows"),
            ("linux", "linux"),
        ):
            with self.subTest(value=value), mock.patch.object(sys, "platform", value):
                self.assertEqual(self.delivery.host_platform(), expected)


class RustToolchainTest(DeliveryStageTestCase):
    def _rustc_result(self, stdout: str, returncode: int = 0) -> SimpleNamespace:
        return SimpleNamespace(returncode=returncode, stdout=stdout)

    def test_missing_rustc_or_cargo_fails_closed(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery.shutil, "which", return_value=None
        ):
            self.assertFalse(self.delivery.require_rust_toolchain())
        self.assertIn("rustc and cargo", stderr.getvalue())

    def test_unidentified_rust_version_fails_closed(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery.shutil, "which", return_value="/tools/rustc"
        ), mock.patch.object(
            self.delivery.subprocess,
            "run",
            return_value=self._rustc_result("garbage", returncode=1),
        ):
            self.assertFalse(self.delivery.require_rust_toolchain())
        self.assertIn("unable to identify", stderr.getvalue())

    def test_older_rust_version_fails_closed(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery.shutil, "which", return_value="/tools/rustc"
        ), mock.patch.object(
            self.delivery.subprocess,
            "run",
            return_value=self._rustc_result("rustc 1.87.0 (abc 2025-01-01)"),
        ), mock.patch.object(sys, "platform", "darwin"):
            self.assertFalse(self.delivery.require_rust_toolchain())
        self.assertIn("1.88.0 or newer", stderr.getvalue())

    def test_linux_requires_pkg_config_and_openssl(self) -> None:
        def which(name: str):
            return None if name == "pkg-config" else "/tools/rustc"

        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery.shutil, "which", side_effect=which
        ), mock.patch.object(
            self.delivery.subprocess,
            "run",
            return_value=self._rustc_result("rustc 1.95.0 (abc 2026-01-01)"),
        ), mock.patch.object(sys, "platform", "linux"):
            self.assertFalse(self.delivery.require_rust_toolchain())
        self.assertIn("pkg-config", stderr.getvalue())

        with mock.patch.object(
            self.delivery.shutil, "which", return_value="/tools/rustc"
        ), mock.patch.object(
            self.delivery.subprocess,
            "run",
            return_value=self._rustc_result("rustc 1.95.0 (abc 2026-01-01)"),
        ), mock.patch.object(sys, "platform", "linux"):
            self.assertTrue(self.delivery.require_rust_toolchain())

    def test_supported_rust_version_passes(self) -> None:
        with mock.patch.object(
            self.delivery.shutil, "which", return_value="/tools/rustc"
        ), mock.patch.object(
            self.delivery.subprocess,
            "run",
            return_value=self._rustc_result("rustc 1.88.0 (abc 2025-06-26)"),
        ), mock.patch.object(sys, "platform", "darwin"):
            self.assertTrue(self.delivery.require_rust_toolchain())

    def test_pinned_coverage_cli_detection(self) -> None:
        pinned = SimpleNamespace(
            returncode=0, stdout=f"cargo-llvm-cov {self.delivery.RUST_COVERAGE_CLI_VERSION}\n"
        )
        drifted = SimpleNamespace(returncode=0, stdout="cargo-llvm-cov 0.8.0\n")
        failing = SimpleNamespace(returncode=101, stdout="")
        with mock.patch.object(self.delivery.subprocess, "run", return_value=pinned):
            self.assertTrue(self.delivery._rust_coverage_cli_is_pinned("cargo"))
        with mock.patch.object(self.delivery.subprocess, "run", return_value=drifted):
            self.assertFalse(self.delivery._rust_coverage_cli_is_pinned("cargo"))
        with mock.patch.object(self.delivery.subprocess, "run", return_value=failing):
            self.assertFalse(self.delivery._rust_coverage_cli_is_pinned("cargo"))

    def test_missing_rustup_fails_closed(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery.shutil, "which", return_value=None
        ):
            self.assertFalse(self.delivery.ensure_rust_coverage_tools())
        self.assertIn("rustup and Cargo", stderr.getvalue())

    def test_component_installation_failure_fails_closed(self) -> None:
        stderr = io.StringIO()
        commands: list[tuple[str, ...]] = []

        def runner(argv, _cwd, _environment):
            commands.append(tuple(argv))
            return 1

        with redirect_stderr(stderr), mock.patch.object(
            self.delivery.shutil, "which", return_value="/tools/rustup"
        ):
            self.assertFalse(self.delivery.ensure_rust_coverage_tools(runner=runner))
        self.assertEqual(commands[0][1:3], ("component", "add"))
        self.assertIn("llvm-tools-preview", stderr.getvalue())

    def test_installed_pinned_cli_skips_installation(self) -> None:
        commands: list[tuple[str, ...]] = []

        def runner(argv, _cwd, _environment):
            commands.append(tuple(argv))
            return 0

        with mock.patch.object(
            self.delivery.shutil, "which", return_value="/tools/cargo"
        ), mock.patch.object(
            self.delivery, "_rust_coverage_cli_is_pinned", return_value=True
        ):
            self.assertTrue(self.delivery.ensure_rust_coverage_tools(runner=runner))
        self.assertEqual(len(commands), 1)

    def test_install_failure_and_unpinned_result_fail_closed(self) -> None:
        outcomes = iter((0, 1))

        def runner(_argv, _cwd, _environment):
            return next(outcomes)

        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery.shutil, "which", return_value="/tools/cargo"
        ), mock.patch.object(
            self.delivery, "_rust_coverage_cli_is_pinned", return_value=False
        ):
            self.assertFalse(self.delivery.ensure_rust_coverage_tools(runner=runner))
        self.assertIn("installing cargo-llvm-cov", stderr.getvalue())

        stderr = io.StringIO()

        def runner_unpinned(_argv, _cwd, _environment):
            return 0

        with redirect_stderr(stderr), mock.patch.object(
            self.delivery.shutil, "which", return_value="/tools/cargo"
        ), mock.patch.object(
            self.delivery, "_rust_coverage_cli_is_pinned", return_value=False
        ):
            self.assertFalse(
                self.delivery.ensure_rust_coverage_tools(runner=runner_unpinned)
            )
        self.assertIn("is unavailable after installation", stderr.getvalue())


class GitModeCommandsTest(DeliveryStageTestCase):
    def test_local_mode_uses_worktree_checks(self) -> None:
        hygiene, docs = self.delivery._git_mode_commands(self.options(mode="local"))
        self.assertIn("--mode", hygiene)
        self.assertEqual(hygiene[hygiene.index("--mode") + 1], "tracked")
        # Delivery runs the Python gate implementation so the docs gate works on
        # Windows, where `bash` can resolve to a WSL launcher with no distro.
        self.assertEqual(docs[1], "scripts/docs_gate.py")
        self.assertIn("--python-bin", docs)
        self.assertEqual(docs[docs.index("--mode") + 1], "worktree")

    def test_ci_mode_uses_event_range(self) -> None:
        hygiene, docs = self.delivery._git_mode_commands(
            self.options(mode="ci", base="origin/nightly", revision_range="a..b")
        )
        self.assertEqual(hygiene[hygiene.index("--range") + 1], "a..b")
        self.assertEqual(docs[docs.index("--base") + 1], "origin/nightly")

    def test_ci_mode_requires_resolved_refs(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            self.assertEqual(
                self.delivery.run_privacy_stage(
                    self.options(mode="ci"), runner=lambda *_: 0
                ),
                2,
            )
        self.assertIn("--base and --range", stderr.getvalue())

        stderr = io.StringIO()
        with redirect_stderr(stderr):
            self.assertEqual(
                self.delivery.run_architecture_stage(
                    self.options(mode="ci"), runner=lambda *_: 0
                ),
                2,
            )
        self.assertIn("--base and --range", stderr.getvalue())

    def test_privacy_stage_runs_scan_and_hygiene(self) -> None:
        recorded: list[tuple[str, ...]] = []

        def runner(argv, _cwd, _environment):
            recorded.append(tuple(argv))
            return 0

        self.assertEqual(
            self.delivery.run_privacy_stage(self.options(), runner=runner), 0
        )
        self.assertEqual(len(recorded), 2)
        self.assertIn("scripts/vityo_privacy.py", recorded[0])
        self.assertIn("scripts/repo-hygiene-gate.py", recorded[1])

    def test_architecture_stage_requires_rust_and_runs_every_gate(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery, "require_rust_toolchain", return_value=False
        ):
            self.assertEqual(
                self.delivery.run_architecture_stage(
                    self.options(), runner=lambda *_: 0
                ),
                2,
            )
        self.assertEqual(stderr.getvalue(), "")

        recorded: list[tuple[str, ...]] = []

        def runner(argv, _cwd, _environment):
            recorded.append(tuple(argv))
            return 0

        with mock.patch.object(
            self.delivery, "require_rust_toolchain", return_value=True
        ):
            self.assertEqual(
                self.delivery.run_architecture_stage(
                    self.options(flutter_dir=Path("products/custom")), runner=runner
                ),
                0,
            )
        labels = [entry[1] for entry in recorded]
        for expected in (
            "scripts/vityo_architecture.py",
            "scripts/check_security_baseline.py",
            "scripts/check_license_policy.py",
            "scripts/check_architecture_boundaries.py",
            "scripts/check_product_line_boundaries.py",
            "scripts/import-boundary-gate.py",
            "scripts/dependency-policy-gate.py",
            "scripts/supply-chain-governance-gate.py",
            "scripts/release-readiness-gate.py",
        ):
            self.assertIn(expected, labels)
        release = recorded[labels.index("scripts/release-readiness-gate.py")]
        self.assertEqual(
            Path(release[release.index("--flutter-dir") + 1]),
            Path("products/custom"),
        )
        self.assertIn("--skip-build", release)

    def test_architecture_stage_propagates_gate_failure(self) -> None:
        calls: list[int] = []

        def runner(_argv, _cwd, _environment):
            calls.append(1)
            return 7 if len(calls) == 3 else 0

        with mock.patch.object(
            self.delivery, "require_rust_toolchain", return_value=True
        ):
            self.assertEqual(
                self.delivery.run_architecture_stage(self.options(), runner=runner), 7
            )


class ArtifactTest(DeliveryStageTestCase):
    def test_artifact_path_uses_release_versions(self) -> None:
        self.write_release_versions("macos")
        with mock.patch.object(self.delivery, "ROOT", self.root):
            artifact = self.delivery._artifact_path(self.options(platform="macos"))
        self.assertEqual(
            artifact, self.root / "build/nightly/vityo-nightly-macos-9.9.9.dmg"
        )

    def test_artifact_path_honours_explicit_and_relative_overrides(self) -> None:
        absolute = self.root / "custom/package.zip"
        with mock.patch.object(self.delivery, "ROOT", self.root):
            self.assertEqual(
                self.delivery._artifact_path(
                    self.options(artifact=absolute, platform="windows")
                ),
                absolute,
            )
            self.assertEqual(
                self.delivery._artifact_path(
                    self.options(artifact=Path("relative.zip"), platform="windows")
                ),
                self.root / "relative.zip",
            )

    def test_package_sidecar_path_appends_json(self) -> None:
        self.assertEqual(
            self.delivery._package_sidecar_path(Path("build/app.dmg")),
            Path("build/app.dmg.json"),
        )

    def test_load_package_candidate_rejects_mismatches(self) -> None:
        platform = "macos"
        artifact = self.write_candidate("vityo-nightly-macos-0.1.0.dmg", platform)
        self.assertEqual(
            self.delivery._load_package_candidate(artifact, platform)["artifact"],
            artifact.name,
        )

        sidecar = self.delivery._package_sidecar_path(artifact)
        sidecar.unlink()
        with self.assertRaisesRegex(ValueError, "metadata is missing"):
            self.delivery._load_package_candidate(artifact, platform)

        missing = self.root / "absent.dmg"
        missing.write_bytes(b"x")
        with self.assertRaisesRegex(ValueError, "metadata is missing"):
            self.delivery._load_package_candidate(missing, platform)

        sidecar.write_text(json.dumps({"schema_version": 1}), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.delivery._load_package_candidate(artifact, platform)

        sidecar.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "platform": "linux",
                    "artifact": artifact.name,
                }
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.delivery._load_package_candidate(artifact, platform)

        with self.assertRaisesRegex(ValueError, "candidate is missing"):
            self.delivery._load_package_candidate(self.root / "gone.dmg", platform)

    def test_product_matrix_commit_requires_pinned_revision(self) -> None:
        matrix = self.root / "toolchain/product-matrix.json"
        matrix.parent.mkdir(parents=True, exist_ok=True)
        matrix.write_text(
            json.dumps({"repositories": {"styio": "a" * 40}}), encoding="utf-8"
        )
        with mock.patch.object(self.delivery, "ROOT", self.root):
            self.assertEqual(self.delivery._product_matrix_commit("styio"), "a" * 40)
            with self.assertRaisesRegex(ValueError, "pinned pafio revision"):
                self.delivery._product_matrix_commit("pafio")

        matrix.write_text(json.dumps({"repositories": []}), encoding="utf-8")
        with mock.patch.object(self.delivery, "ROOT", self.root):
            with self.assertRaisesRegex(ValueError, "pinned styio revision"):
                self.delivery._product_matrix_commit("styio")

    def test_git_helpers_report_missing_repository(self) -> None:
        with mock.patch.object(
            self.delivery.subprocess,
            "run",
            return_value=SimpleNamespace(returncode=1, stdout=""),
        ):
            self.assertIsNone(self.delivery._git_root(Path("/tmp")))
            self.assertIsNone(self.delivery._git_head(Path("/tmp")))

        with mock.patch.object(
            self.delivery.subprocess,
            "run",
            return_value=SimpleNamespace(returncode=0, stdout="/repo\n"),
        ):
            self.assertEqual(
                self.delivery._git_root(Path("/tmp")), Path("/repo").resolve()
            )
            self.assertEqual(self.delivery._git_head(Path("/tmp")), "/repo")


class ResolvePinnedCliTest(DeliveryStageTestCase):
    def test_explicit_executable_must_be_validated(self) -> None:
        binary = self.root / "styio"
        binary.write_text("#!/bin/sh\n", encoding="utf-8")
        with mock.patch.object(
            self.delivery, "validate_executable", return_value=True
        ) as validate:
            resolved = self.delivery.resolve_pinned_cli("styio", str(binary))
        self.assertEqual(resolved, binary.resolve())
        validate.assert_called_once()

        with mock.patch.object(
            self.delivery, "validate_executable", return_value=False
        ):
            with self.assertRaisesRegex(ValueError, "not built from the pinned"):
                self.delivery.resolve_pinned_cli("styio", str(binary))

    def test_environment_configuration_and_path_lookup(self) -> None:
        with mock.patch.object(
            self.delivery.shutil, "which", return_value="/usr/local/bin/styio"
        ), mock.patch.object(
            self.delivery, "validate_executable", return_value=True
        ):
            resolved = self.delivery.resolve_pinned_cli(
                "styio", environment={"STYIO": "styio"}
            )
        self.assertEqual(resolved, Path("/usr/local/bin/styio").resolve())

        with mock.patch.object(
            self.delivery.shutil, "which", return_value=None
        ), mock.patch.object(self.delivery, "validate_executable", return_value=True):
            with self.assertRaisesRegex(ValueError, "configured styio executable"):
                self.delivery.resolve_pinned_cli(
                    "styio", environment={"STYIO": "styio"}
                )

    def test_checkout_candidates_and_provision_fallback(self) -> None:
        checkout = self.root / "styio-nightly"
        candidate = checkout / "build/default/bin/styio"
        candidate.parent.mkdir(parents=True, exist_ok=True)
        candidate.write_text("binary", encoding="utf-8")
        try:
            with mock.patch.object(
                self.delivery, "ROOT", self.root / "vityo-nightly"
            ), mock.patch.object(
                self.delivery, "validate_executable", return_value=True
            ):
                resolved = self.delivery.resolve_pinned_cli("styio")
            self.assertEqual(resolved, candidate.resolve())
        finally:
            shutil.rmtree(checkout, ignore_errors=True)

    def test_provision_failure_is_reported_as_value_error(self) -> None:
        with mock.patch.object(
            self.delivery, "ROOT", self.root / "vityo-nightly"
        ), mock.patch.object(
            self.delivery, "validate_executable", return_value=False
        ), mock.patch.object(
            self.delivery,
            "provision",
            side_effect=self.delivery.ToolchainError("no pinned checkout"),
        ):
            with self.assertRaisesRegex(ValueError, "no pinned checkout"):
                self.delivery.resolve_pinned_cli("styio")


class LanguageFixtureTest(DeliveryStageTestCase):
    def test_language_fixture_gate_reports_resolution_failure(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery,
            "resolve_pinned_cli",
            side_effect=ValueError("the configured styio executable is unavailable"),
        ):
            self.assertEqual(
                self.delivery._run_language_fixture_gate(self.options()), 2
            )
        self.assertIn("language fixture stage", stderr.getvalue())

    def test_language_fixture_gate_runs_both_roots(self) -> None:
        recorded: list[tuple[tuple[str, ...], Path]] = []

        def runner(argv, cwd=None, environment=None):
            recorded.append((tuple(argv), Path(cwd)))
            return 0

        with mock.patch.object(
            self.delivery, "resolve_pinned_cli", return_value=Path("/pinned/styio")
        ), mock.patch.object(self.delivery, "run_command", side_effect=runner):
            self.assertEqual(
                self.delivery._run_language_fixture_gate(
                    self.options(flutter_dir=Path("products/vityo_app"))
                ),
                0,
            )
        argv, cwd = recorded[0]
        self.assertEqual(argv[:3], ("dart", "run", "tool/language_fixture_gate.dart"))
        self.assertEqual(
            Path(argv[argv.index("--styio") + 1]), Path("/pinned/styio")
        )
        self.assertEqual(argv.count("--root"), 2)
        self.assertEqual(cwd, self.delivery.ROOT / "products/vityo_app")

    def test_quality_suite_passes_receipt_when_requested(self) -> None:
        recorded: list[tuple[str, ...]] = []

        def runner(argv, cwd=None, environment=None):
            recorded.append(tuple(argv))
            return 0

        with mock.patch.object(self.delivery, "run_command", side_effect=runner):
            self.assertEqual(
                self.delivery._run_quality_suite("ide", "daemon-core"), 0
            )
            self.assertEqual(
                self.delivery._run_quality_suite(
                    "ide", "daemon-core", receipt="build/receipt.json"
                ),
                0,
            )
        self.assertNotIn("--receipt", recorded[0])
        self.assertEqual(
            recorded[1][recorded[1].index("--receipt") + 1], "build/receipt.json"
        )


class ProductAcceptanceTest(DeliveryStageTestCase):
    def test_product_acceptance_runs_each_step_in_order(self) -> None:
        recorded: list[tuple[str, ...]] = []

        def runner(argv, cwd=None, environment=None):
            recorded.append(tuple(argv))
            return 0

        with mock.patch.object(self.delivery, "run_command", side_effect=runner), mock.patch.object(
            self.delivery, "resolve_pinned_cli", return_value=Path("/pinned/styio")
        ), mock.patch.object(
            self.delivery, "_git_root", return_value=Path("/checkout")
        ):
            self.assertEqual(
                self.delivery._run_product_acceptance(
                    self.options(platform="macos"), Path("/pinned/styio"), Path("/pinned/pafio")
                ),
                0,
            )
        self.assertEqual(len(recorded), 4)
        self.assertIn("scripts/ecosystem-product-gate.py", recorded[0])
        self.assertIn("--require-real-matrix", recorded[0])
        self.assertIn("trusted_desktop_styio_loop_acceptance_test.dart", recorded[1][2])
        self.assertIn("scripts/run-native-pty-matrix.py", recorded[2])
        record = recorded[3]
        self.assertIn("scripts/record-product-matrix-evidence.py", record)
        self.assertEqual(
            Path(record[record.index("--styio") + 1]), Path("/checkout")
        )

    def test_product_acceptance_propagates_failures(self) -> None:
        def runner_for(failing_index: int):
            calls: list[int] = []

            def runner(_argv, _cwd=None, _environment=None):
                calls.append(1)
                return 5 if len(calls) == failing_index else 0

            return runner

        for failing_index in (1, 2):
            with self.subTest(failing_index=failing_index), mock.patch.object(
                self.delivery, "run_command", side_effect=runner_for(failing_index)
            ), mock.patch.object(
                self.delivery, "resolve_pinned_cli", return_value=Path("/pinned/styio")
            ), mock.patch.object(
                self.delivery, "_git_root", return_value=Path("/checkout")
            ):
                self.assertEqual(
                    self.delivery._run_product_acceptance(
                        self.options(platform="macos"),
                        Path("/pinned/styio"),
                        Path("/pinned/pafio"),
                    ),
                    5,
                )

    def test_product_acceptance_requires_matrix_checkouts(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery, "run_command", return_value=0
        ), mock.patch.object(
            self.delivery, "resolve_pinned_cli", return_value=Path("/pinned/styio")
        ), mock.patch.object(self.delivery, "_git_root", return_value=None):
            self.assertEqual(
                self.delivery._run_product_acceptance(
                    self.options(platform="macos"), Path("/pinned/styio"), Path("/pinned/pafio")
                ),
                2,
            )
        self.assertIn("product matrix evidence", stderr.getvalue())


class TestStageTest(DeliveryStageTestCase):
    def test_unsupported_platform_fails(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            self.assertEqual(
                self.delivery.run_test_stage(self.options(platform="solaris")), 2
            )
        self.assertIn("unsupported host platform", stderr.getvalue())

    def test_coverage_scope_requires_tools(self) -> None:
        with mock.patch.object(
            self.delivery, "require_rust_toolchain", return_value=False
        ):
            self.assertEqual(
                self.delivery.run_test_stage(
                    self.options(platform="macos", scope="coverage")
                ),
                2,
            )
        with mock.patch.object(
            self.delivery, "require_rust_toolchain", return_value=True
        ), mock.patch.object(
            self.delivery, "ensure_rust_coverage_tools", return_value=False
        ):
            self.assertEqual(
                self.delivery.run_test_stage(
                    self.options(platform="macos", scope="coverage")
                ),
                2,
            )

    def test_coverage_scope_runs_collection_only(self) -> None:
        recorded: list[tuple[str, ...]] = []

        def runner(argv, _cwd, _environment):
            recorded.append(tuple(argv))
            return 0

        with mock.patch.object(
            self.delivery, "require_rust_toolchain", return_value=True
        ), mock.patch.object(
            self.delivery, "ensure_rust_coverage_tools", return_value=True
        ):
            self.assertEqual(
                self.delivery.run_test_stage(
                    self.options(platform="macos", scope="coverage"), runner=runner
                ),
                0,
            )
        self.assertEqual(len(recorded), 1)
        self.assertIn("--collect-only", recorded[0])

    def test_unresolved_styio_and_missing_flutter_fail_closed(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery,
            "resolve_pinned_cli",
            side_effect=ValueError("the configured styio executable is unavailable"),
        ):
            self.assertEqual(
                self.delivery.run_test_stage(
                    self.options(platform="macos"), runner=lambda *_: 0
                ),
                2,
            )
        self.assertIn("test stage", stderr.getvalue())

        stderr = io.StringIO()

        def which(name: str):
            return None if name == "flutter" else "/tools/tool"

        with redirect_stderr(stderr), mock.patch.object(
            self.delivery, "resolve_pinned_cli", return_value=Path("/pinned/styio")
        ), mock.patch.object(
            self.delivery, "require_rust_toolchain", return_value=True
        ), mock.patch.object(
            self.delivery, "ensure_rust_coverage_tools", return_value=True
        ), mock.patch.object(self.delivery.shutil, "which", side_effect=which):
            self.assertEqual(
                self.delivery.run_test_stage(
                    self.options(platform="macos"), runner=lambda *_: 0
                ),
                2,
            )
        self.assertIn("Flutter is not available", stderr.getvalue())

    def test_ci_mode_appends_native_desktop_suites_and_product_gate(self) -> None:
        recorded: list[tuple[str, ...]] = []

        def runner(argv, _cwd, _environment):
            recorded.append(tuple(argv))
            return 0

        with mock.patch.dict(
            os.environ, {"VITYO_PRODUCT_GATE": "1"}, clear=False
        ), mock.patch.object(
            self.delivery, "resolve_pinned_cli", return_value=Path("/pinned/tool")
        ), mock.patch.object(
            self.delivery, "require_rust_toolchain", return_value=True
        ), mock.patch.object(
            self.delivery, "ensure_rust_coverage_tools", return_value=True
        ), mock.patch.object(
            self.delivery.shutil, "which", return_value="/tools/flutter"
        ), mock.patch.object(
            self.delivery, "run_command", return_value=0
        ), mock.patch.object(
            self.delivery, "_run_product_acceptance", return_value=0
        ) as acceptance:
            self.assertEqual(
                self.delivery.run_test_stage(
                    self.options(
                        platform="macos", mode="ci", base="origin/nightly", revision_range="a..b"
                    ),
                    runner=runner,
                ),
                0,
            )
        suites = [
            command[command.index("--suite") + 1]
            for command in recorded
            if "--suite" in command
        ]
        self.assertIn("native-desktop", suites)
        self.assertIn("macos-native-ui", suites)
        acceptance.assert_called_once()


class BuildStageTest(DeliveryStageTestCase):
    def test_build_stage_requires_matching_host(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ):
            self.assertEqual(
                self.delivery.run_build_stage(self.options(platform="linux")), 2
            )
        self.assertIn("matching host", stderr.getvalue())

    def test_build_stage_requires_rust_toolchain(self) -> None:
        with mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ), mock.patch.object(
            self.delivery, "require_rust_toolchain", return_value=False
        ):
            self.assertEqual(
                self.delivery.run_build_stage(self.options(platform="macos")), 2
            )

    def test_build_stage_runs_license_check_when_not_validated(self) -> None:
        recorded: list[tuple[str, ...]] = []

        def runner(argv, _cwd, _environment):
            recorded.append(tuple(argv))
            return 3

        with mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ), mock.patch.object(
            self.delivery, "require_rust_toolchain", return_value=True
        ):
            self.assertEqual(
                self.delivery.run_build_stage(self.options(platform="macos"), runner=runner),
                3,
            )
        self.assertTrue(
            any("check_license_policy.py" in argument for argument in recorded[0])
        )

    def test_build_stage_propagates_build_failures(self) -> None:
        def runner_for(failing_label: str):
            def runner(argv, _cwd, _environment):
                return 4 if failing_label in " ".join(argv) else 0

            return runner

        for label in ("macos", "package-nightly.py"):
            with self.subTest(label=label), mock.patch.object(
                self.delivery, "host_platform", return_value="macos"
            ), mock.patch.object(
                self.delivery, "require_rust_toolchain", return_value=True
            ), mock.patch.object(
                self.delivery.shutil, "which", return_value="/tools/flutter"
            ):
                options = self.options(platform="macos", notices_validated=True)
                self.assertEqual(
                    self.delivery.run_build_stage(options, runner=runner_for(label)), 4
                )

    def test_build_stage_requires_flutter(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ), mock.patch.object(
            self.delivery, "require_rust_toolchain", return_value=True
        ), mock.patch.object(self.delivery.shutil, "which", return_value=None):
            self.assertEqual(
                self.delivery.run_build_stage(
                    self.options(platform="macos", notices_validated=True),
                    runner=lambda *_: 0,
                ),
                2,
            )
        self.assertIn("Flutter is not available", stderr.getvalue())

    def test_build_stage_validates_the_packaged_candidate(self) -> None:
        with mock.patch.object(
            self.delivery, "ROOT", self.root
        ), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ), mock.patch.object(
            self.delivery, "require_rust_toolchain", return_value=True
        ), mock.patch.object(
            self.delivery.shutil, "which", return_value="/tools/flutter"
        ):
            self.write_release_versions("macos")
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                self.assertEqual(
                    self.delivery.run_build_stage(
                        self.options(platform="macos", notices_validated=True),
                        runner=lambda *_: 0,
                    ),
                    2,
                )
            self.assertIn("candidate is missing", stderr.getvalue())

            artifact = self.delivery._artifact_path(
                self.options(platform="macos")
            )
            artifact.parent.mkdir(parents=True, exist_ok=True)
            artifact.write_bytes(b"package")
            self.delivery._package_sidecar_path(artifact).write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "platform": "macos",
                        "artifact": artifact.name,
                    }
                ),
                encoding="utf-8",
            )
            self.assertEqual(
                self.delivery.run_build_stage(
                    self.options(platform="macos", notices_validated=True),
                    runner=lambda *_: 0,
                ),
                0,
            )

    def test_build_stage_forwards_the_explicit_pafio_override(self) -> None:
        recorded: list[tuple[str, ...]] = []

        def runner(argv, _cwd, _environment):
            recorded.append(tuple(argv))
            return 0

        with mock.patch.object(
            self.delivery, "ROOT", self.root
        ), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ), mock.patch.object(
            self.delivery, "require_rust_toolchain", return_value=True
        ), mock.patch.object(
            self.delivery.shutil, "which", return_value="/tools/flutter"
        ):
            self.write_release_versions("macos")
            self.delivery.run_build_stage(
                self.options(
                    platform="macos",
                    notices_validated=True,
                    pafio_bin="/opt/pinned/pafio",
                ),
                runner=runner,
            )
        packaging = next(
            command
            for command in recorded
            if any("package-nightly.py" in argument for argument in command)
        )
        self.assertEqual(packaging[packaging.index("--pafio-bin") + 1], "/opt/pinned/pafio")

    def test_build_stage_omits_the_pafio_override_when_unset(self) -> None:
        recorded: list[tuple[str, ...]] = []

        def runner(argv, _cwd, _environment):
            recorded.append(tuple(argv))
            return 0

        with mock.patch.object(
            self.delivery, "ROOT", self.root
        ), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ), mock.patch.object(
            self.delivery, "require_rust_toolchain", return_value=True
        ), mock.patch.object(
            self.delivery.shutil, "which", return_value="/tools/flutter"
        ):
            self.write_release_versions("macos")
            self.delivery.run_build_stage(
                self.options(platform="macos", notices_validated=True), runner=runner
            )
        packaging = next(
            command
            for command in recorded
            if any("package-nightly.py" in argument for argument in command)
        )
        self.assertNotIn("--pafio-bin", packaging)


class InstallRootTest(DeliveryStageTestCase):
    def test_default_install_root_per_platform(self) -> None:
        with self.assertRaisesRegex(ValueError, "isolated --install-root"):
            self.delivery.default_install_root("macos", "ci")

        with mock.patch.dict(os.environ, {"LOCALAPPDATA": ""}, clear=False):
            with self.assertRaisesRegex(ValueError, "LOCALAPPDATA"):
                self.delivery.default_install_root("windows", "local")

        with mock.patch.dict(
            os.environ, {"LOCALAPPDATA": str(self.root / "appdata")}, clear=False
        ):
            self.assertEqual(
                self.delivery.default_install_root("windows", "local"),
                self.root / "appdata/Programs/Vityo-Nightly",
            )

        self.assertEqual(
            self.delivery.default_install_root("macos", "local"),
            Path.home() / "Applications/Vityo.app",
        )

        with mock.patch.dict(
            os.environ, {"XDG_DATA_HOME": str(self.root / "data")}, clear=False
        ):
            self.assertEqual(
                self.delivery.default_install_root("linux", "local"),
                self.root / "data/vityo-nightly",
            )

    def test_application_root_layout(self) -> None:
        self.assertEqual(
            self.delivery.application_root(Path("/opt/vityo-nightly"), "linux"),
            Path("/opt/vityo-nightly/opt/vityo"),
        )
        self.assertEqual(
            self.delivery.application_root(Path("/Applications/Vityo.app"), "macos"),
            Path("/Applications/Vityo.app"),
        )

    def test_replace_install_tree_fresh_and_upgrade(self) -> None:
        staged = self.root / "staged"
        staged.mkdir()
        (staged / "new.txt").write_text("new", encoding="utf-8")
        destination = self.root / "app"
        self.delivery._replace_install_tree(staged, destination)
        self.assertEqual((destination / "new.txt").read_text(encoding="utf-8"), "new")

        staged = self.root / "staged-2"
        staged.mkdir()
        (staged / "newer.txt").write_text("newer", encoding="utf-8")
        self.delivery._replace_install_tree(staged, destination)
        self.assertTrue((destination / "newer.txt").is_file())
        self.assertFalse((self.root / "app.rollback").exists())

    def test_replace_install_tree_refuses_pending_rollback(self) -> None:
        destination = self.root / "app"
        destination.mkdir()
        (self.root / "app.rollback").mkdir()
        with self.assertRaisesRegex(ValueError, "manual recovery"):
            self.delivery._replace_install_tree(self.root / "staged", destination)

    def test_replace_install_tree_restores_previous_tree_on_failure(self) -> None:
        destination = self.root / "app"
        destination.mkdir()
        (destination / "old.txt").write_text("old", encoding="utf-8")
        with self.assertRaises(FileNotFoundError):
            self.delivery._replace_install_tree(self.root / "missing-staged", destination)
        self.assertTrue((destination / "old.txt").is_file())
        self.assertFalse((self.root / "app.rollback").exists())

        real_rmtree = shutil.rmtree
        calls = {"count": 0}

        def flaky_rmtree(path, *args, **kwargs):
            calls["count"] += 1
            if calls["count"] == 1:
                raise OSError("rollback cleanup failed")
            return real_rmtree(path, *args, **kwargs)

        staged = self.root / "staged-3"
        staged.mkdir()
        (staged / "fresh.txt").write_text("fresh", encoding="utf-8")
        with mock.patch.object(
            self.delivery.shutil, "rmtree", side_effect=flaky_rmtree
        ):
            with self.assertRaises(OSError):
                self.delivery._replace_install_tree(staged, destination)
        self.assertTrue((destination / "old.txt").is_file())


class PackageInstallTest(DeliveryStageTestCase):
    def test_linux_install_requires_dpkg_deb(self) -> None:
        with mock.patch.object(self.delivery.shutil, "which", return_value=None):
            with self.assertRaisesRegex(ValueError, "dpkg-deb"):
                self.delivery._install_linux(self.root / "app.deb", self.root / "install")

    def test_linux_install_extracts_and_activates(self) -> None:
        artifact = self.root / "app.deb"
        artifact.write_bytes(b"deb")

        def fake_run(argv, cwd=None, check=False):
            if argv[0] == "dpkg-deb":
                extracted = Path(argv[argv.index("--extract") + 2])
                app = extracted / "opt/vityo/vityo_app"
                app.parent.mkdir(parents=True, exist_ok=True)
                app.write_text("binary", encoding="utf-8")
                return SimpleNamespace(returncode=0)
            raise AssertionError(argv)

        install_root = self.root / "install"
        with mock.patch.object(
            self.delivery.shutil, "which", return_value="/usr/bin/dpkg-deb"
        ), mock.patch.object(self.delivery.subprocess, "run", side_effect=fake_run):
            self.delivery._install_linux(artifact, install_root)
        self.assertTrue((install_root / "opt/vityo/vityo_app").is_file())

    def test_linux_install_rejects_failed_extraction(self) -> None:
        artifact = self.root / "app.deb"
        artifact.write_bytes(b"deb")
        with mock.patch.object(
            self.delivery.shutil, "which", return_value="/usr/bin/dpkg-deb"
        ), mock.patch.object(
            self.delivery.subprocess,
            "run",
            return_value=SimpleNamespace(returncode=2),
        ):
            with self.assertRaisesRegex(RuntimeError, "could not extract"):
                self.delivery._install_linux(artifact, self.root / "install")

    def test_linux_install_rejects_package_without_application(self) -> None:
        artifact = self.root / "app.deb"
        artifact.write_bytes(b"deb")
        with mock.patch.object(
            self.delivery.shutil, "which", return_value="/usr/bin/dpkg-deb"
        ), mock.patch.object(
            self.delivery.subprocess,
            "run",
            return_value=SimpleNamespace(returncode=0),
        ):
            with self.assertRaisesRegex(ValueError, "does not contain the Vityo application"):
                self.delivery._install_linux(artifact, self.root / "install")

    def test_windows_install_requires_powershell(self) -> None:
        with mock.patch.object(self.delivery.shutil, "which", return_value=None):
            with self.assertRaisesRegex(ValueError, "PowerShell"):
                self.delivery._install_windows(
                    self.root / "app.zip", self.root / "install"
                )

    def test_windows_install_requires_packaged_installer(self) -> None:
        artifact = self.root / "app.zip"
        with zipfile.ZipFile(artifact, "w") as archive:
            archive.writestr("readme.txt", "no installer")
        with mock.patch.object(
            self.delivery.shutil, "which", return_value="/usr/bin/powershell"
        ):
            with self.assertRaisesRegex(ValueError, "installer is missing"):
                self.delivery._install_windows(artifact, self.root / "install")

    def test_windows_install_runs_packaged_installer(self) -> None:
        artifact = self.root / "app.zip"
        with zipfile.ZipFile(artifact, "w") as archive:
            archive.writestr("Vityo-Nightly/install.ps1", "# installer")
        recorded: list[tuple[str, ...]] = []

        def fake_run(argv, cwd=None, check=False):
            recorded.append(tuple(argv))
            return SimpleNamespace(returncode=0)

        with mock.patch.object(
            self.delivery.shutil, "which", return_value="/usr/bin/powershell"
        ), mock.patch.object(self.delivery.subprocess, "run", side_effect=fake_run):
            self.delivery._install_windows(artifact, self.root / "install")
        self.assertEqual(recorded[0][0], "/usr/bin/powershell")
        self.assertIn("-Destination", recorded[0])

    def test_windows_install_reports_installer_failure(self) -> None:
        artifact = self.root / "app.zip"
        with zipfile.ZipFile(artifact, "w") as archive:
            archive.writestr("Vityo-Nightly/install.ps1", "# installer")
        with mock.patch.object(
            self.delivery.shutil, "which", return_value="/usr/bin/powershell"
        ), mock.patch.object(
            self.delivery.subprocess,
            "run",
            return_value=SimpleNamespace(returncode=1),
        ):
            with self.assertRaisesRegex(RuntimeError, "installer failed"):
                self.delivery._install_windows(artifact, self.root / "install")

    def test_macos_install_requires_hdiutil(self) -> None:
        with mock.patch.object(self.delivery.shutil, "which", return_value=None):
            with self.assertRaisesRegex(ValueError, "hdiutil"):
                self.delivery._install_macos(self.root / "app.dmg", self.root / "install")

    def test_macos_install_mounts_and_activates(self) -> None:
        artifact = self.root / "app.dmg"
        artifact.write_bytes(b"dmg")
        detach: list[tuple[str, ...]] = []

        def fake_run(argv, cwd=None, check=False):
            if argv[1] == "attach":
                mount = Path(argv[argv.index("-mountpoint") + 1])
                bundle = mount / "Vityo.app/Contents"
                bundle.mkdir(parents=True, exist_ok=True)
                (bundle / "Info.plist").write_text("plist", encoding="utf-8")
                framework = bundle / "Frameworks/App.framework"
                (framework / "Versions/A").mkdir(parents=True, exist_ok=True)
                (framework / "App").symlink_to("Versions/Current/App")
                return SimpleNamespace(returncode=0)
            if argv[1] == "detach":
                detach.append(tuple(argv))
                return SimpleNamespace(returncode=0)
            raise AssertionError(argv)

        install_root = self.root / "Vityo.app"
        with mock.patch.object(
            self.delivery.shutil, "which", return_value="/usr/bin/hdiutil"
        ), mock.patch.object(self.delivery.subprocess, "run", side_effect=fake_run):
            self.delivery._install_macos(artifact, install_root)
        self.assertTrue((install_root / "Contents/Info.plist").is_file())
        # A versioned framework link must stay a link: dereferencing it would
        # rewrite the bundle the signature sealed.
        self.assertTrue(
            (install_root / "Contents/Frameworks/App.framework/App").is_symlink()
        )
        self.assertEqual(len(detach), 1)

    def test_macos_install_rejects_mount_failures_and_wrong_bundle_count(self) -> None:
        artifact = self.root / "app.dmg"
        artifact.write_bytes(b"dmg")
        with mock.patch.object(
            self.delivery.shutil, "which", return_value="/usr/bin/hdiutil"
        ), mock.patch.object(
            self.delivery.subprocess,
            "run",
            return_value=SimpleNamespace(returncode=1),
        ):
            with self.assertRaisesRegex(RuntimeError, "could not be mounted"):
                self.delivery._install_macos(artifact, self.root / "install")

        def empty_mount(argv, cwd=None, check=False):
            if argv[1] == "attach":
                return SimpleNamespace(returncode=0)
            return SimpleNamespace(returncode=0)

        with mock.patch.object(
            self.delivery.shutil, "which", return_value="/usr/bin/hdiutil"
        ), mock.patch.object(self.delivery.subprocess, "run", side_effect=empty_mount):
            with self.assertRaisesRegex(ValueError, "one application bundle"):
                self.delivery._install_macos(artifact, self.root / "install")


class InstallStageTest(DeliveryStageTestCase):
    def _layout(self, install_root: Path, platform: str = "macos") -> None:
        app_root = self.delivery.application_root(install_root, platform)
        for relative in (
            self.delivery.PACKAGE_EXECUTABLES[platform],
            self.delivery.AGENT_PACKAGE_PATHS[platform],
            self.delivery.DAEMON_PACKAGE_PATHS[platform],
            self.delivery.PAFIO_PACKAGE_PATHS[platform],
        ):
            target = app_root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("binary", encoding="utf-8")
            target.chmod(0o755)

    def test_install_stage_requires_matching_host(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ):
            self.assertEqual(
                self.delivery.run_install_stage(self.options(platform="linux")), 2
            )
        self.assertIn("matching host", stderr.getvalue())

    def test_install_stage_rejects_missing_candidate(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery, "ROOT", self.root
        ), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ):
            self.write_release_versions("macos")
            self.assertEqual(
                self.delivery.run_install_stage(self.options(platform="macos")), 2
            )
        self.assertIn("candidate is missing", stderr.getvalue())

    def test_install_stage_installs_and_verifies_components(self) -> None:
        with mock.patch.object(self.delivery, "ROOT", self.root), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ):
            artifact = self.write_candidate("vityo-nightly-macos-0.1.0.dmg", "macos")
            install_root = self.root / "install/Vityo.app"

            def fake_install(_artifact, root):
                self._layout(root)

            with mock.patch.object(
                self.delivery, "_install_macos", side_effect=fake_install
            ), mock.patch.object(
                self.delivery.subprocess,
                "run",
                return_value=SimpleNamespace(returncode=0),
            ) as agent_run:
                self.assertEqual(
                    self.delivery.run_install_stage(
                        self.options(platform="macos", artifact=artifact, install_root=install_root)
                    ),
                    0,
                )
            self.assertIn("--version", agent_run.call_args.args[0])

    def test_install_stage_reports_missing_or_non_executable_components(self) -> None:
        with mock.patch.object(self.delivery, "ROOT", self.root), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ):
            artifact = self.write_candidate("vityo-nightly-macos-0.1.0.dmg", "macos")
            install_root = self.root / "install/Vityo.app"
            stderr = io.StringIO()
            with redirect_stderr(stderr), mock.patch.object(
                self.delivery, "_install_macos", side_effect=lambda *_: None
            ):
                self.assertEqual(
                    self.delivery.run_install_stage(
                        self.options(
                            platform="macos", artifact=artifact, install_root=install_root
                        )
                    ),
                    2,
                )
            self.assertIn("missing a required executable component", stderr.getvalue())

            stderr = io.StringIO()
            with redirect_stderr(stderr), mock.patch.object(
                self.delivery, "_install_macos", side_effect=lambda _artifact, root: self._layout(root)
            ), mock.patch.object(self.delivery.os, "access", return_value=False):
                self.assertEqual(
                    self.delivery.run_install_stage(
                        self.options(
                            platform="macos", artifact=artifact, install_root=install_root
                        )
                    ),
                    2,
                )
            self.assertIn("is not executable", stderr.getvalue())

    def test_install_stage_requires_the_bundled_pafio_component(self) -> None:
        with mock.patch.object(self.delivery, "ROOT", self.root), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ):
            artifact = self.write_candidate("vityo-nightly-macos-0.1.0.dmg", "macos")
            install_root = self.root / "install/Vityo.app"

            def install_without_pafio(_artifact, root):
                self._layout(root)
                (
                    self.delivery.application_root(root, "macos")
                    / self.delivery.PAFIO_PACKAGE_PATHS["macos"]
                ).unlink()

            stderr = io.StringIO()
            with redirect_stderr(stderr), mock.patch.object(
                self.delivery, "_install_macos", side_effect=install_without_pafio
            ):
                self.assertEqual(
                    self.delivery.run_install_stage(
                        self.options(
                            platform="macos", artifact=artifact, install_root=install_root
                        )
                    ),
                    2,
                )
            self.assertIn("missing a required executable component", stderr.getvalue())

    def test_install_stage_reports_agent_version_failure(self) -> None:
        with mock.patch.object(self.delivery, "ROOT", self.root), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ):
            artifact = self.write_candidate("vityo-nightly-macos-0.1.0.dmg", "macos")
            install_root = self.root / "install/Vityo.app"
            stderr = io.StringIO()
            with redirect_stderr(stderr), mock.patch.object(
                self.delivery, "_install_macos", side_effect=lambda _artifact, root: self._layout(root)
            ), mock.patch.object(
                self.delivery.subprocess,
                "run",
                return_value=SimpleNamespace(returncode=1),
            ):
                self.assertEqual(
                    self.delivery.run_install_stage(
                        self.options(
                            platform="macos", artifact=artifact, install_root=install_root
                        )
                    ),
                    2,
                )
            self.assertIn("could not report its version", stderr.getvalue())

    def test_install_stage_ci_mode_runs_desktop_matrix_gate(self) -> None:
        install_root = self.root / "ci/Vityo.app"
        with mock.patch.object(self.delivery, "ROOT", self.root), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ):
            artifact = self.write_candidate("vityo-nightly-macos-0.1.0.dmg", "macos")
            with mock.patch.object(
                self.delivery, "_install_macos", side_effect=lambda _artifact, root: self._layout(root)
            ), mock.patch.object(
                self.delivery.subprocess,
                "run",
                return_value=SimpleNamespace(returncode=0),
            ), mock.patch.object(
                self.delivery, "run_command", return_value=0
            ) as gate:
                self.assertEqual(
                    self.delivery.run_install_stage(
                        self.options(
                            platform="macos",
                            mode="ci",
                            artifact=artifact,
                            install_root=install_root,
                        )
                    ),
                    0,
                )
                self.assertTrue(
                    any(
                        "vityod-desktop-matrix-gate.py" in argument
                        for argument in gate.call_args.args[0]
                    )
                )

            with mock.patch.object(
                self.delivery, "_install_macos", side_effect=lambda _artifact, root: self._layout(root)
            ), mock.patch.object(
                self.delivery.subprocess,
                "run",
                return_value=SimpleNamespace(returncode=0),
            ), mock.patch.object(self.delivery, "run_command", return_value=9):
                self.assertEqual(
                    self.delivery.run_install_stage(
                        self.options(
                            platform="macos",
                            mode="ci",
                            artifact=artifact,
                            install_root=install_root,
                        )
                    ),
                    9,
                )


class LaunchStageTest(DeliveryStageTestCase):
    def test_validate_startup_evidence_rules(self) -> None:
        evidence = self.root / "startup-macos.json"
        valid = {
            "schema_version": 1,
            "candidate": "vityo.dmg",
            "platform": "macos",
            "launched": True,
            "first_frame": True,
        }
        evidence.write_text(json.dumps(valid), encoding="utf-8")
        self.delivery._validate_startup_evidence(
            evidence, platform="macos", candidate="vityo.dmg"
        )

        for broken in (
            {**valid, "schema_version": 2},
            {**valid, "candidate": "other.dmg"},
            {**valid, "platform": "linux"},
            {**valid, "launched": False},
            {**valid, "first_frame": False},
            {"schema_version": 1},
        ):
            with self.subTest(broken=broken):
                evidence.write_text(json.dumps(broken), encoding="utf-8")
                with self.assertRaises(ValueError):
                    self.delivery._validate_startup_evidence(
                        evidence, platform="macos", candidate="vityo.dmg"
                    )

    def test_launch_stage_requires_matching_host_and_installed_app(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ):
            self.assertEqual(
                self.delivery.run_launch_stage(self.options(platform="linux")), 2
            )
        self.assertIn("matching host", stderr.getvalue())

        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery, "ROOT", self.root
        ), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ):
            self.assertEqual(
                self.delivery.run_launch_stage(
                    self.options(platform="macos", install_root=self.root / "install")
                ),
                2,
            )
        self.assertIn("executable is missing", stderr.getvalue())

    def test_launch_stage_requires_matching_candidate_metadata(self) -> None:
        install_root = self.root / "install"
        executable = install_root / self.delivery.PACKAGE_EXECUTABLES["macos"]
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("binary", encoding="utf-8")
        with mock.patch.object(self.delivery, "ROOT", self.root), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ):
            self.write_release_versions("macos")
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                self.assertEqual(
                    self.delivery.run_launch_stage(
                        self.options(platform="macos", install_root=install_root)
                    ),
                    2,
                )
        self.assertIn("candidate is missing", stderr.getvalue())

    def test_local_launch_opens_the_installed_bundle(self) -> None:
        install_root = self.root / "install"
        executable = install_root / self.delivery.PACKAGE_EXECUTABLES["macos"]
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("binary", encoding="utf-8")
        artifact = self.write_candidate("vityo-nightly-macos-0.1.0.dmg", "macos")
        recorded: list[tuple[str, ...]] = []

        def runner(argv, _cwd, _environment):
            recorded.append(tuple(argv))
            return 0

        stdout = io.StringIO()
        with redirect_stdout(stdout), mock.patch.object(
            self.delivery, "ROOT", self.root
        ), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ), mock.patch.object(
            self.delivery.shutil, "which", return_value="/usr/bin/open"
        ), mock.patch.object(self.delivery, "run_command", side_effect=runner):
            self.assertEqual(
                self.delivery.run_launch_stage(
                    self.options(
                        platform="macos", install_root=install_root, artifact=artifact
                    )
                ),
                0,
            )
        self.assertEqual(recorded[0][:2], ("/usr/bin/open", "-n"))
        self.assertIn("opened installed candidate", stdout.getvalue())

    def test_local_launch_reports_open_failure(self) -> None:
        install_root = self.root / "install"
        executable = install_root / self.delivery.PACKAGE_EXECUTABLES["macos"]
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("binary", encoding="utf-8")
        artifact = self.write_candidate("vityo-nightly-macos-0.1.0.dmg", "macos")
        with mock.patch.object(self.delivery, "ROOT", self.root), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ), mock.patch.object(
            self.delivery.shutil, "which", return_value="/usr/bin/open"
        ), mock.patch.object(self.delivery, "run_command", return_value=5):
            self.assertEqual(
                self.delivery.run_launch_stage(
                    self.options(
                        platform="macos", install_root=install_root, artifact=artifact
                    )
                ),
                5,
            )

        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery, "ROOT", self.root
        ), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ), mock.patch.object(self.delivery.shutil, "which", return_value=None):
            self.assertEqual(
                self.delivery.run_launch_stage(
                    self.options(
                        platform="macos", install_root=install_root, artifact=artifact
                    )
                ),
                2,
            )
        self.assertIn("macOS open is unavailable", stderr.getvalue())

    def test_ci_startup_probe_requires_xvfb_on_linux(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery, "host_platform", return_value="linux"
        ), mock.patch.object(self.delivery.shutil, "which", return_value=None):
            self.assertEqual(
                self.delivery._run_ci_startup_probe(
                    self.options(platform="linux", mode="ci"),
                    app_root=self.root / "app",
                    candidate="vityo.deb",
                ),
                2,
            )
        self.assertIn("xvfb-run", stderr.getvalue())

    def test_ci_startup_probe_records_valid_evidence(self) -> None:
        artifact_name = "vityo-nightly-macos-0.1.0.dmg"
        with mock.patch.object(self.delivery, "ROOT", self.root), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ):
            self.write_release_versions("macos")
            contract = self.root / "packaging/vityo/desktop_delivery.py"
            contract.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / "packaging/vityo/desktop_delivery.py", contract)
            artifact = self.write_candidate(artifact_name, "macos")
            install_root = self.root / "install"
            executable = install_root / self.delivery.PACKAGE_EXECUTABLES["macos"]
            executable.parent.mkdir(parents=True, exist_ok=True)
            executable.write_text("binary", encoding="utf-8")
            options = self.delivery.DeliveryOptions(
                mode="ci",
                platform="macos",
                artifact=artifact,
                install_root=install_root,
                evidence_dir=Path("build/evidence"),
            )

            def runner(argv, _cwd, _environment):
                index = argv.index("--vityo-evidence-file") + 1
                Path(argv[index]).write_text(
                    json.dumps(
                        {
                            "schema_version": 1,
                            "candidate": artifact_name,
                            "platform": "macos",
                            "launched": True,
                            "first_frame": True,
                        }
                    ),
                    encoding="utf-8",
                )
                return 0

            with mock.patch.object(
                self.delivery.shutil, "which", return_value="/usr/bin/open"
            ), mock.patch.object(self.delivery, "run_command", side_effect=runner):
                self.assertEqual(self.delivery.run_launch_stage(options), 0)

    def test_ci_startup_probe_rejects_incomplete_evidence(self) -> None:
        artifact_name = "vityo-nightly-macos-0.1.0.dmg"
        with mock.patch.object(self.delivery, "ROOT", self.root), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ):
            self.write_release_versions("macos")
            artifact = self.write_candidate(artifact_name, "macos")
            install_root = self.root / "install"
            executable = install_root / self.delivery.PACKAGE_EXECUTABLES["macos"]
            executable.parent.mkdir(parents=True, exist_ok=True)
            executable.write_text("binary", encoding="utf-8")
            options = self.delivery.DeliveryOptions(
                mode="ci",
                platform="macos",
                artifact=artifact,
                install_root=install_root,
                evidence_dir=Path("build/evidence"),
            )

            def runner(argv, _cwd, _environment):
                index = argv.index("--vityo-evidence-file") + 1
                Path(argv[index]).write_text(
                    json.dumps(
                        {
                            "schema_version": 1,
                            "candidate": artifact_name,
                            "platform": "macos",
                            "launched": True,
                            "first_frame": False,
                        }
                    ),
                    encoding="utf-8",
                )
                return 0

            stderr = io.StringIO()
            with redirect_stderr(stderr), mock.patch.object(
                self.delivery.shutil, "which", return_value="/usr/bin/open"
            ), mock.patch.object(self.delivery, "run_command", side_effect=runner):
                self.assertEqual(self.delivery.run_launch_stage(options), 2)
            self.assertIn("did not complete startup", stderr.getvalue())


class DeliveryDispatchTest(DeliveryStageTestCase):
    def test_run_delivery_validates_notices_after_architecture(self) -> None:
        seen: list[tuple[str, bool]] = []

        def stage_runner(stage: str, options) -> int:
            seen.append((stage, options.notices_validated))
            return 0

        self.assertEqual(
            self.delivery.run_delivery(
                self.options(), stage_runner=stage_runner
            ),
            0,
        )
        self.assertEqual([stage for stage, _ in seen], list(self.delivery.DELIVERY_STAGES))
        self.assertFalse(dict(seen)["architecture"])
        self.assertTrue(dict(seen)["test"])

    def test_run_delivery_stops_at_first_failure(self) -> None:
        seen: list[str] = []

        def stage_runner(stage: str, _options) -> int:
            seen.append(stage)
            return 0 if stage == "privacy" else 6

        stderr = io.StringIO()
        with redirect_stderr(stderr):
            self.assertEqual(
                self.delivery.run_delivery(self.options(), stage_runner=stage_runner), 6
            )
        self.assertEqual(seen, ["privacy", "architecture"])
        self.assertIn("delivery stopped at architecture", stderr.getvalue())

    def test_run_stage_reports_stage_errors(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            self.delivery, "run_build_stage", side_effect=ValueError("broken stage")
        ):
            self.assertEqual(
                self.delivery.run_stage("build", self.options(platform="macos")), 2
            )
        self.assertIn("build stage: broken stage", stderr.getvalue())

    def test_options_from_args_maps_every_field(self) -> None:
        args = SimpleNamespace(
            mode="ci",
            platform="linux",
            base="origin/nightly",
            revision_range="a..b",
            flutter_dir=Path("products/app"),
            styio_bin="/bin/styio",
            pafio_bin="/bin/pafio",
            output_dir=Path("build/out"),
            evidence_dir=Path("build/evidence"),
            artifact=Path("build/app.deb"),
            install_root=Path("/tmp/install"),
            scope="coverage",
        )
        options = self.delivery.options_from_args(args)
        self.assertEqual(options.mode, "ci")
        self.assertEqual(options.platform, "linux")
        self.assertEqual(options.base, "origin/nightly")
        self.assertEqual(options.revision_range, "a..b")
        self.assertEqual(options.scope, "coverage")
        self.assertEqual(options.install_root, Path("/tmp/install"))

    def test_main_dispatches_stage_and_deliver(self) -> None:
        with mock.patch.object(
            self.delivery, "run_stage", return_value=3
        ) as run_stage:
            self.assertEqual(self.delivery.main(["privacy"]), 3)
        self.assertEqual(run_stage.call_args.args[0], "privacy")

        with mock.patch.object(
            self.delivery, "run_delivery", return_value=4
        ) as run_delivery:
            self.assertEqual(self.delivery.main(["deliver", "--scope", "coverage"]), 4)
        self.assertEqual(run_delivery.call_args.args[0].scope, "coverage")

    def test_main_requires_a_known_command(self) -> None:
        for argv in (["unknown"], []):
            with self.subTest(argv=argv), redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    self.delivery.main(argv)


class RuntimeHelpersTest(DeliveryStageTestCase):
    def test_run_command_reports_real_exit_codes(self) -> None:
        self.assertEqual(
            self.delivery.run_command((sys.executable, "-c", "raise SystemExit(0)")), 0
        )
        self.assertEqual(
            self.delivery.run_command((sys.executable, "-c", "raise SystemExit(3)")), 3
        )

    def test_run_commands_stops_at_the_first_failure(self) -> None:
        executed: list[str] = []

        def runner(argv, _cwd, _environment):
            executed.append(argv[0])
            return 4 if len(executed) == 2 else 0

        commands = (
            self.delivery.Command("first", ("one",)),
            self.delivery.Command("second", ("two",)),
            self.delivery.Command("third", ("three",)),
        )
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            self.assertEqual(self.delivery.run_commands(commands, runner=runner), 4)
        self.assertEqual(executed, ["one", "two"])
        self.assertIn("[vityo] first", stdout.getvalue())

    def test_install_makes_the_pinned_coverage_cli_available(self) -> None:
        commands: list[tuple[str, ...]] = []

        def runner(argv, _cwd, _environment):
            commands.append(tuple(argv))
            return 0

        with mock.patch.object(
            self.delivery.shutil, "which", return_value="/tools/cargo"
        ), mock.patch.object(
            self.delivery, "_rust_coverage_cli_is_pinned", side_effect=[False, True]
        ):
            self.assertTrue(self.delivery.ensure_rust_coverage_tools(runner=runner))
        self.assertEqual(len(commands), 2)
        self.assertEqual(commands[1][1], "install")

    def test_project_coverage_command_rejects_evidence_outside_the_repository(
        self,
    ) -> None:
        with self.assertRaisesRegex(ValueError, "inside the repository"):
            self.delivery._project_coverage_command(
                self.options(evidence_dir=Path(tempfile.gettempdir()) / "outside-evidence"),
                collect_only=True,
            )

    def test_coverage_stage_runs_the_report_gate(self) -> None:
        recorded: list[tuple[str, ...]] = []

        def runner(argv, _cwd, _environment):
            recorded.append(tuple(argv))
            return 0

        self.assertEqual(
            self.delivery.run_coverage_stage(
                self.options(platform="macos"), runner=runner
            ),
            0,
        )
        self.assertIn("--report-only", recorded[0])
        self.assertIn("scripts/project-coverage-gate.py", recorded[0])


class TestStageFailureTest(DeliveryStageTestCase):
    def _options(self):
        return self.options(platform="macos")

    def _patched(self):
        return (
            mock.patch.object(
                self.delivery, "resolve_pinned_cli", return_value=Path("/pinned/styio")
            ),
            mock.patch.object(self.delivery, "require_rust_toolchain", return_value=True),
            mock.patch.object(
                self.delivery, "ensure_rust_coverage_tools", return_value=True
            ),
            mock.patch.object(self.delivery.shutil, "which", return_value="/tools/flutter"),
        )

    def test_missing_rust_and_coverage_tools_fail_the_full_scope(self) -> None:
        with mock.patch.object(
            self.delivery, "resolve_pinned_cli", return_value=Path("/pinned/styio")
        ), mock.patch.object(self.delivery, "require_rust_toolchain", return_value=False):
            self.assertEqual(
                self.delivery.run_test_stage(self._options(), runner=lambda *_: 0), 2
            )

        with mock.patch.object(
            self.delivery, "resolve_pinned_cli", return_value=Path("/pinned/styio")
        ), mock.patch.object(
            self.delivery, "require_rust_toolchain", return_value=True
        ), mock.patch.object(
            self.delivery, "ensure_rust_coverage_tools", return_value=False
        ):
            self.assertEqual(
                self.delivery.run_test_stage(self._options(), runner=lambda *_: 0), 2
            )

    def test_each_phase_propagates_its_failure(self) -> None:
        first, second, third, fourth = self._patched()
        with first, second, third, fourth, mock.patch.object(
            self.delivery, "run_command", return_value=0
        ):
            self.assertEqual(
                self.delivery.run_test_stage(self._options(), runner=lambda *_: 6), 6
            )

        first, second, third, fourth = self._patched()
        with first, second, third, fourth, mock.patch.object(
            self.delivery, "run_command", return_value=0
        ), mock.patch.object(
            self.delivery, "_run_language_fixture_gate", return_value=7
        ):
            self.assertEqual(
                self.delivery.run_test_stage(self._options(), runner=lambda *_: 0), 7
            )

        def prototype_runner(argv, _cwd, _environment):
            return 8 if argv[0] == "npm" else 0

        first, second, third, fourth = self._patched()
        with first, second, third, fourth, mock.patch.object(
            self.delivery, "run_command", return_value=0
        ), mock.patch.object(
            self.delivery, "_run_language_fixture_gate", return_value=0
        ):
            self.assertEqual(
                self.delivery.run_test_stage(
                    self._options(), runner=prototype_runner
                ),
                8,
            )

    def test_product_gate_requires_a_pinned_pafio(self) -> None:
        def resolve(product, *_args, **_kwargs):
            if product == "pafio":
                raise ValueError("the configured pafio executable is unavailable")
            return Path("/pinned/styio")

        stderr = io.StringIO()
        with redirect_stderr(stderr), mock.patch.dict(
            os.environ, {"VITYO_PRODUCT_GATE": "1"}, clear=False
        ):
            first, second, third, fourth = self._patched()
            with first, second, third, fourth, mock.patch.object(
                self.delivery, "run_command", return_value=0
            ), mock.patch.object(
                self.delivery, "resolve_pinned_cli", side_effect=resolve
            ):
                self.assertEqual(
                    self.delivery.run_test_stage(self._options(), runner=lambda *_: 0), 2
                )
        self.assertIn("test stage", stderr.getvalue())


class InstallDispatchTest(DeliveryStageTestCase):
    def _layout(self, install_root: Path, platform: str) -> None:
        app_root = self.delivery.application_root(install_root, platform)
        for relative in (
            self.delivery.PACKAGE_EXECUTABLES[platform],
            self.delivery.AGENT_PACKAGE_PATHS[platform],
            self.delivery.DAEMON_PACKAGE_PATHS[platform],
            self.delivery.PAFIO_PACKAGE_PATHS[platform],
        ):
            target = app_root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("binary", encoding="utf-8")
            target.chmod(0o755)

    def test_install_stage_dispatches_to_each_platform_installer(self) -> None:
        cases = (
            ("linux", "vityo-nightly-linux-0.1.0.deb", "_install_linux"),
            ("windows", "vityo-nightly-windows-0.1.0.zip", "_install_windows"),
        )
        for platform, artifact_name, installer in cases:
            with self.subTest(platform=platform), mock.patch.object(
                self.delivery, "ROOT", self.root
            ), mock.patch.object(
                self.delivery, "host_platform", return_value=platform
            ):
                artifact = self.write_candidate(artifact_name, platform)
                install_root = self.root / f"install-{platform}"
                with mock.patch.object(
                    self.delivery,
                    installer,
                    side_effect=lambda _artifact, root, _platform=platform: self._layout(
                        root, _platform
                    ),
                ), mock.patch.object(
                    self.delivery.subprocess,
                    "run",
                    return_value=SimpleNamespace(returncode=0),
                ):
                    self.assertEqual(
                        self.delivery.run_install_stage(
                            self.options(
                                platform=platform,
                                artifact=artifact,
                                install_root=install_root,
                            )
                        ),
                        0,
                    )

    def test_linux_install_refuses_pending_transaction(self) -> None:
        artifact = self.root / "app.deb"
        artifact.write_bytes(b"deb")
        install_root = self.root / "install"
        staged = install_root.with_name(install_root.name + ".installing")
        staged.mkdir(parents=True)

        def fake_run(argv, cwd=None, check=False):
            extracted = Path(argv[argv.index("--extract") + 2])
            app = extracted / "opt/vityo/vityo_app"
            app.parent.mkdir(parents=True, exist_ok=True)
            app.write_text("binary", encoding="utf-8")
            return SimpleNamespace(returncode=0)

        with mock.patch.object(
            self.delivery.shutil, "which", return_value="/usr/bin/dpkg-deb"
        ), mock.patch.object(self.delivery.subprocess, "run", side_effect=fake_run):
            with self.assertRaisesRegex(ValueError, "manual recovery"):
                self.delivery._install_linux(artifact, install_root)

    def test_macos_install_refuses_pending_transaction(self) -> None:
        artifact = self.root / "app.dmg"
        artifact.write_bytes(b"dmg")
        install_root = self.root / "install"
        install_root.with_name(install_root.name + ".installing").mkdir(parents=True)

        def fake_run(argv, cwd=None, check=False):
            if argv[1] == "attach":
                mount = Path(argv[argv.index("-mountpoint") + 1])
                bundle = mount / "Vityo.app/Contents"
                bundle.mkdir(parents=True, exist_ok=True)
            return SimpleNamespace(returncode=0)

        with mock.patch.object(
            self.delivery.shutil, "which", return_value="/usr/bin/hdiutil"
        ), mock.patch.object(self.delivery.subprocess, "run", side_effect=fake_run):
            with self.assertRaisesRegex(ValueError, "manual recovery"):
                self.delivery._install_macos(artifact, install_root)


class LinuxLaunchTest(DeliveryStageTestCase):
    def _install(self, platform: str) -> tuple[Path, Path]:
        install_root = self.root / f"install-{platform}"
        app_root = self.delivery.application_root(install_root, platform)
        executable = app_root / self.delivery.PACKAGE_EXECUTABLES[platform]
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("binary", encoding="utf-8")
        return install_root, executable

    def test_linux_launch_starts_the_installed_executable(self) -> None:
        with mock.patch.object(self.delivery, "ROOT", self.root), mock.patch.object(
            self.delivery, "host_platform", return_value="linux"
        ):
            install_root, executable = self._install("linux")
            artifact = self.write_candidate("vityo-nightly-linux-0.1.0.deb", "linux")
            stdout = io.StringIO()
            with redirect_stdout(stdout), mock.patch.object(
                self.delivery.subprocess, "Popen"
            ) as popen:
                self.assertEqual(
                    self.delivery.run_launch_stage(
                        self.options(
                            platform="linux", install_root=install_root, artifact=artifact
                        )
                    ),
                    0,
                )
            popen.assert_called_once()
            self.assertEqual(popen.call_args.args[0][0], str(executable))
            self.assertIn("opened installed candidate", stdout.getvalue())

    def test_local_launch_reports_opener_errors(self) -> None:
        with mock.patch.object(self.delivery, "ROOT", self.root), mock.patch.object(
            self.delivery, "host_platform", return_value="macos"
        ):
            install_root, _executable = self._install("macos")
            artifact = self.write_candidate("vityo-nightly-macos-0.1.0.dmg", "macos")
            stderr = io.StringIO()
            with redirect_stderr(stderr), mock.patch.object(
                self.delivery.shutil, "which", return_value="/usr/bin/open"
            ), mock.patch.object(
                self.delivery, "run_command", side_effect=OSError("opener missing")
            ):
                self.assertEqual(
                    self.delivery.run_launch_stage(
                        self.options(
                            platform="macos", install_root=install_root, artifact=artifact
                        )
                    ),
                    2,
                )
            self.assertIn("opener missing", stderr.getvalue())

    def test_ci_startup_probe_runs_under_xvfb_on_linux(self) -> None:
        artifact_name = "vityo-nightly-linux-0.1.0.deb"
        with mock.patch.object(self.delivery, "ROOT", self.root), mock.patch.object(
            self.delivery, "host_platform", return_value="linux"
        ):
            contract = self.root / "packaging/vityo/desktop_delivery.py"
            contract.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / "packaging/vityo/desktop_delivery.py", contract)
            artifact = self.write_candidate(artifact_name, "linux")
            install_root, _executable = self._install("linux")
            options = self.delivery.DeliveryOptions(
                mode="ci",
                platform="linux",
                artifact=artifact,
                install_root=install_root,
                evidence_dir=Path("build/evidence"),
            )
            recorded: list[tuple[str, ...]] = []

            def runner(argv, _cwd, _environment):
                recorded.append(tuple(argv))
                index = argv.index("--vityo-evidence-file") + 1
                Path(argv[index]).write_text(
                    json.dumps(
                        {
                            "schema_version": 1,
                            "candidate": artifact_name,
                            "platform": "linux",
                            "launched": True,
                            "first_frame": True,
                        }
                    ),
                    encoding="utf-8",
                )
                return 0

            with mock.patch.object(
                self.delivery.shutil, "which", return_value="/usr/bin/xvfb-run"
            ), mock.patch.object(self.delivery, "run_command", side_effect=runner):
                self.assertEqual(self.delivery.run_launch_stage(options), 0)
            self.assertEqual(recorded[0][0], "/usr/bin/xvfb-run")
            self.assertIn("-a", recorded[0])


if __name__ == "__main__":
    unittest.main()


class DocsGateCompositionTest(unittest.TestCase):
    """The gate runs the same three tools from either entrypoint."""

    def setUp(self) -> None:
        self.gate = _load_docs_gate_module()

    def test_worktree_mode_runs_team_gate_audit_and_ecosystem(self) -> None:
        commands = self.gate.docs_gate_commands("worktree", None, False, "/py")
        self.assertEqual(commands[0][0], ["/py", "scripts/team-docs-gate.py"])
        self.assertEqual(commands[1][0], ["/py", "scripts/docs-audit.py"])
        self.assertEqual(
            commands[2][0],
            ["/py", "scripts/ecosystem-cli-doc-gate.py", "--non-blocking"],
        )

    def test_audit_suppresses_the_team_gate_it_already_ran(self) -> None:
        commands = self.gate.docs_gate_commands("worktree", None, False, "/py")
        audit_env = commands[1][1] or {}
        self.assertEqual(audit_env.get("VITYO_SKIP_TEAM_DOC_GATE"), "1")

    def test_staged_and_push_modes_select_the_change_source(self) -> None:
        staged = self.gate.docs_gate_commands("staged", None, False, "/py")
        self.assertEqual(
            staged[0][0], ["/py", "scripts/team-docs-gate.py", "--mode", "staged"]
        )
        pushed = self.gate.docs_gate_commands("push", "origin/nightly", False, "/py")
        self.assertEqual(
            pushed[0][0],
            ["/py", "scripts/team-docs-gate.py", "--base", "origin/nightly"],
        )

    def test_push_mode_without_a_base_fails_closed(self) -> None:
        with mock.patch.object(self.gate, "_upstream_base", return_value=None):
            with self.assertRaisesRegex(ValueError, "push mode requires --base"):
                self.gate.docs_gate_commands("push", None, False, "/py")

    def test_skip_ecosystem_drops_the_third_command(self) -> None:
        commands = self.gate.docs_gate_commands("worktree", None, True, "/py")
        self.assertEqual(len(commands), 2)
