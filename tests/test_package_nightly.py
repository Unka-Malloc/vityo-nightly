#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
import zipfile
import json
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
PACKAGER_PATH = REPO_ROOT / "scripts/package-nightly.py"


def load_packager_module():
    spec = importlib.util.spec_from_file_location("package_nightly", PACKAGER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {PACKAGER_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class PackageNightlyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.packager = load_packager_module()

    @staticmethod
    def _versions() -> dict[str, object]:
        return {
            "schema_version": 1,
            "core_version": "0.1.0-nightly",
            "platform_adapters": {"windows": "0.1.0-nightly.1"},
        }

    @staticmethod
    def _windows_config() -> dict[str, object]:
        return {
            "schema_version": 1,
            "platform": "windows",
            "package_format": "zip-powershell",
            "build_relative_path": "build/windows/release",
            "coding_agent": {
                "target": "x86_64-pc-windows-msvc",
                "source_relative_path": "products/vityo_coding_agent/target/release/vityo-coding-agent.exe",
                "package_relative_path": "components/vityo-coding-agent.exe",
                "required_runtime_libraries": ["vcruntime140.dll"],
            },
            "rust_notices_path": "licenses/RUST-THIRD-PARTY-NOTICES.txt",
            "signing": {"status": "explicit-gap", "reason": "No test credential."},
            "automatic_updates": False,
        }

    def test_unsigned_package_cannot_enable_automatic_updates(self) -> None:
        config = self._windows_config()
        config["automatic_updates"] = True

        with self.assertRaisesRegex(ValueError, "cannot enable automatic updates"):
            self.packager.validate_release_inputs("windows", config, self._versions())

    def test_windows_package_contains_payload_and_installers(self) -> None:
        with tempfile.TemporaryDirectory(prefix="package-nightly-", dir=REPO_ROOT) as tmp_name:
            root = Path(tmp_name)
            build = root / "build/windows/release"
            build.mkdir(parents=True)
            (build / "vityo_app.exe").write_bytes(b"application")
            packaging = root / "packaging/windows"
            packaging.mkdir(parents=True)
            (packaging / "install.ps1").write_text("# installer\n", encoding="utf-8")
            (packaging / "uninstall.ps1").write_text("# uninstaller\n", encoding="utf-8")
            agent = root / "products/vityo_coding_agent/target/release/vityo-coding-agent.exe"
            agent.parent.mkdir(parents=True)
            agent.write_bytes(b"coding agent")
            notices = root / "build/evidence/rust-third-party-notices.txt"
            notices.parent.mkdir(parents=True)
            notices.write_text("Rust notices\n", encoding="utf-8")
            output = root / "vityo-nightly-windows.zip"
            self.packager.ROOT = root

            with mock.patch.object(self.packager.subprocess, "run"):
                self.packager.package_windows(self._windows_config(), output)

            with zipfile.ZipFile(output) as archive:
                names = set(archive.namelist())
        self.assertEqual(
            names,
            {
                "Vityo-Nightly/install.ps1",
                "Vityo-Nightly/uninstall.ps1",
                "Vityo-Nightly/vityo_app.exe",
                "Vityo-Nightly/components/vityo-coding-agent.exe",
                "Vityo-Nightly/licenses/RUST-THIRD-PARTY-NOTICES.txt",
            },
        )

    def test_release_input_validation_covers_each_contract(self) -> None:
        valid = self._windows_config()
        versions = self._versions()
        self.assertEqual(
            self.packager.validate_release_inputs("windows", valid, versions),
            "0.1.0-nightly.1",
        )
        mutations = (
            ({**versions, "schema_version": 2}, valid),
            (versions, {**valid, "schema_version": 2}),
            (versions, {**valid, "package_format": "dmg"}),
            (versions, {**valid, "signing": {"status": "unknown"}}),
            (versions, {**valid, "signing": {"status": "explicit-gap", "reason": ""}}),
            (versions, {**valid, "automatic_updates": "false"}),
            (versions, {**valid, "coding_agent": None}),
            (versions, {**valid, "coding_agent": {**valid["coding_agent"], "target": "wrong"}}),
            (versions, {**valid, "coding_agent": {**valid["coding_agent"], "required_runtime_libraries": []}}),
            (versions, {**valid, "coding_agent": {**valid["coding_agent"], "source_relative_path": "wrong"}}),
            (versions, {**valid, "coding_agent": {**valid["coding_agent"], "package_relative_path": "../agent"}}),
            (versions, {**valid, "rust_notices_path": "wrong"}),
            ({**versions, "core_version": "latest"}, valid),
            ({**versions, "platform_adapters": {}}, valid),
        )
        for changed_versions, changed_config in mutations:
            with self.subTest(config=changed_config, versions=changed_versions):
                with self.assertRaises(ValueError):
                    self.packager.validate_release_inputs(
                        "windows", changed_config, changed_versions
                    )

    def test_coding_agent_version_reads_and_validates_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            manifest = root / "products/vityo_coding_agent/Cargo.toml"
            manifest.parent.mkdir(parents=True)
            manifest.write_text('[package]\nversion = "0.1.0"\n', encoding="utf-8")
            self.packager.ROOT = root
            self.assertEqual(self.packager.coding_agent_version(), "0.1.0")

            manifest.write_text('[package]\nversion = "latest"\n', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "version is invalid"):
                self.packager.coding_agent_version()

    def test_build_coding_agent_uses_locked_release_manifest_and_checks_binary(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            manifest = root / "products/vityo_coding_agent/Cargo.toml"
            manifest.parent.mkdir(parents=True)
            manifest.write_text('[package]\nversion = "0.1.0"\n', encoding="utf-8")
            binary = root / "products/vityo_coding_agent/target/release/vityo-coding-agent.exe"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"agent")
            config = {
                "coding_agent": {
                    "target": "fixture-target",
                    "source_relative_path": binary.relative_to(root).as_posix(),
                }
            }
            self.packager.ROOT = root
            with (
                mock.patch.object(
                    self.packager,
                    "vityod_build_identity",
                    return_value={"target": "fixture-target"},
                ),
                mock.patch.object(self.packager, "vityod_target_matches", return_value=True),
                mock.patch.object(self.packager.subprocess, "run") as run,
            ):
                self.assertEqual(self.packager.build_coding_agent(config), binary)
            self.assertEqual(run.call_count, 2)
            self.assertEqual(
                run.call_args_list[0].args[0],
                [
                    "cargo",
                    "build",
                    "--locked",
                    "--release",
                    "--manifest-path",
                    manifest,
                    "--bin",
                    "vityo-coding-agent",
                ],
            )
            self.assertEqual(run.call_args_list[1].args[0], [binary, "--version"])

        with self.assertRaisesRegex(ValueError, "contract is missing"):
            self.packager.build_coding_agent({})
        with (
            mock.patch.object(
                self.packager,
                "vityod_build_identity",
                return_value={"target": "different-target"},
            ),
            mock.patch.object(self.packager, "vityod_target_matches", return_value=False),
            self.assertRaisesRegex(ValueError, "does not match"),
        ):
            self.packager.build_coding_agent(
                {"coding_agent": {"target": "fixture-target"}}
            )

    def test_stage_coding_agent_copies_executable_and_rejects_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            source = root / "source/vityo-coding-agent"
            source.parent.mkdir()
            source.write_bytes(b"agent")
            destination_root = root / "application"
            config = {
                "coding_agent": {
                    "source_relative_path": source.relative_to(root).as_posix(),
                    "package_relative_path": "components/vityo-coding-agent",
                }
            }
            self.packager.ROOT = root
            with mock.patch.object(self.packager.subprocess, "run") as run:
                staged = self.packager.stage_coding_agent(config, destination_root)
            self.assertEqual(staged.read_bytes(), b"agent")
            self.assertTrue(staged.stat().st_mode & 0o111)
            run.assert_called_once_with([staged, "--version"], cwd=destination_root, check=True)

            config["coding_agent"]["package_relative_path"] = "../outside"
            with self.assertRaisesRegex(ValueError, "must stay inside"):
                self.packager.stage_coding_agent(config, destination_root)
        with self.assertRaisesRegex(ValueError, "contract is missing"):
            self.packager.stage_coding_agent({}, Path("application"))

    def test_stage_coding_agent_rejects_rooted_escape_paths(self) -> None:
        """A rooted path without a drive still escapes on Windows.

        ``Path('/tmp/vityod').is_absolute()`` is false on Windows, so joining it
        to ``D:/bundle/Vityo.app`` previously resolved to ``D:/tmp/vityod`` and
        the containment check accepted it.
        """
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            source = root / "source/vityo-coding-agent"
            source.parent.mkdir()
            source.write_bytes(b"agent")
            destination_root = root / "application"
            self.packager.ROOT = root
            for escaped in ("/tmp/vityod", "/etc/passwd", "../outside", ""):
                with self.subTest(package_relative_path=escaped):
                    config = {
                        "coding_agent": {
                            "source_relative_path": "source/vityo-coding-agent",
                            "package_relative_path": escaped,
                        }
                    }
                    with self.assertRaisesRegex(ValueError, "must stay inside"):
                        self.packager.stage_coding_agent(config, destination_root)
            self.assertFalse((root / "tmp").exists())

    def test_component_manifest_can_be_staged_outside_nested_code(self) -> None:
        """macOS declares a manifest path that codesign does not scan as code.

        `codesign` treats `Contents/Helpers` as a directory of nested code, so an
        unsigned JSON identity record staged there blocks sealing the bundle.
        """
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            binary = root / "source/vityod"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"daemon")
            destination_root = root / "application"
            self.packager.ROOT = root
            config = {
                "vityod": {
                    "source_relative_path": "source/vityod",
                    "package_relative_path": "Contents/Helpers/vityod",
                    "manifest_relative_path": "Contents/Resources/vityod-component.json",
                    "required_runtime_libraries": [],
                }
            }
            with mock.patch.object(
                self.packager, "vityod_build_identity", return_value={"target": "native-apple-darwin"}
            ):
                staged = self.packager.stage_vityod(config, destination_root)
            self.assertEqual(staged, destination_root / "Contents/Helpers/vityod")
            manifest = destination_root / "Contents/Resources/vityod-component.json"
            self.assertTrue(manifest.is_file())
            self.assertFalse(
                (destination_root / "Contents/Helpers/vityod-component.json").exists()
            )
            identity = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(identity["component"], "vityod")
            self.assertEqual(
                identity["package_relative_path"], "Contents/Helpers/vityod"
            )

    def test_component_manifest_path_must_stay_inside_and_not_replace_the_binary(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            binary = root / "source/vityod"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"daemon")
            destination_root = root / "application"
            self.packager.ROOT = root
            base = {
                "source_relative_path": "source/vityod",
                "package_relative_path": "Contents/Helpers/vityod",
                "required_runtime_libraries": [],
            }
            with mock.patch.object(
                self.packager, "vityod_build_identity", return_value={"target": "native-apple-darwin"}
            ):
                for escaped in ("/tmp/vityod-component.json", "../outside.json"):
                    with self.subTest(manifest_relative_path=escaped):
                        config = {"vityod": {**base, "manifest_relative_path": escaped}}
                        with self.assertRaisesRegex(ValueError, "must stay inside"):
                            self.packager.stage_vityod(config, destination_root)
                config = {
                    "vityod": {
                        **base,
                        "manifest_relative_path": "Contents/Helpers/vityod",
                    }
                }
                with self.assertRaisesRegex(ValueError, "must not overwrite"):
                    self.packager.stage_vityod(config, destination_root)

    def test_stage_rust_notices_requires_nonempty_generated_source(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            destination_root = root / "application"
            self.packager.ROOT = root
            with self.assertRaisesRegex(ValueError, "missing or empty"):
                self.packager.stage_rust_notices("windows", destination_root)

            source = root / self.packager.RUST_NOTICE_SOURCE
            source.parent.mkdir(parents=True)
            source.write_text("   \n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "missing or empty"):
                self.packager.stage_rust_notices("windows", destination_root)

            source.write_text("Rust notices\n", encoding="utf-8")
            destination = self.packager.stage_rust_notices("windows", destination_root)
            self.assertEqual(destination.read_text(encoding="utf-8"), "Rust notices\n")

    def test_vityod_component_must_be_an_object(self) -> None:
        with self.assertRaisesRegex(ValueError, "must be an object"):
            self.packager.stage_vityod({"vityod": "invalid"}, Path("application"))

    def test_file_directory_json_and_copy_helpers(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            source = root / "source"
            source.mkdir()
            (source / "nested").mkdir()
            (source / "nested/file.txt").write_text("nested", encoding="utf-8")
            (source / "top.txt").write_text("top", encoding="utf-8")
            destination = root / "destination"
            self.packager.copy_tree_contents(source, destination)
            self.assertEqual((destination / "nested/file.txt").read_text(), "nested")
            self.assertEqual(self.packager.require_dir(source), source)
            self.assertEqual(self.packager.require_file(source / "top.txt"), source / "top.txt")
            with self.assertRaises(FileNotFoundError):
                self.packager.require_file(root / "missing")
            with self.assertRaises(FileNotFoundError):
                self.packager.require_dir(root / "missing")
            value = root / "value.json"
            value.write_text('{"ok": true}', encoding="utf-8")
            self.assertEqual(self.packager.load_json(value), {"ok": True})
            value.write_text("[]", encoding="utf-8")
            with self.assertRaises(ValueError):
                self.packager.load_json(value)

    def test_linux_and_macos_packagers_delegate_to_native_tools(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            self.packager.ROOT = root
            build = root / "build/linux"
            build.mkdir(parents=True)
            (build / "vityo_app").write_text("app", encoding="utf-8")
            packaging = root / "packaging/linux"
            packaging.mkdir(parents=True)
            (packaging / "control").write_text("Version: 0.1.0\n", encoding="utf-8")
            (packaging / "io.vityo.desktop").write_text("desktop", encoding="utf-8")
            (packaging / "io.vityo.metainfo.xml").write_text("meta", encoding="utf-8")
            (packaging / "icon.png").write_bytes(b"png")
            agent = root / "products/vityo_coding_agent/target/release/vityo-coding-agent"
            agent.parent.mkdir(parents=True)
            agent.write_bytes(b"coding agent")
            notices = root / "build/evidence/rust-third-party-notices.txt"
            notices.parent.mkdir(parents=True)
            notices.write_text("Rust notices\n", encoding="utf-8")
            config = {
                "build_relative_path": "build/linux",
                "installer_definition": "packaging/linux/control",
                "icon_relative_path": "packaging/linux/icon.png",
                "coding_agent": {
                    "target": "x86_64-unknown-linux-gnu",
                    "source_relative_path": "products/vityo_coding_agent/target/release/vityo-coding-agent",
                    "package_relative_path": "components/vityo-coding-agent",
                    "required_runtime_libraries": ["glibc", "libssl.so.3"],
                },
                "rust_notices_path": "licenses/RUST-THIRD-PARTY-NOTICES.txt",
            }
            output = root / "vityo.deb"
            with mock.patch.object(self.packager.subprocess, "run") as run:
                self.assertEqual(
                    self.packager.package_linux(config, output, "1.2.3-nightly+4"),
                    output,
                )
            self.assertEqual(run.call_args.args[0][0], "dpkg-deb")

            app = root / "build/macos/Vityo.app"
            app.mkdir(parents=True)
            script = root / "packaging/macos/create-dmg.sh"
            script.parent.mkdir(parents=True)
            script.write_text("#!/bin/sh\n", encoding="utf-8")
            mac_config = {
                "build_relative_path": "build/macos/Vityo.app",
                "installer_definition": "packaging/macos/create-dmg.sh",
                "coding_agent": {
                    "target": "native-apple-darwin",
                    "source_relative_path": "products/vityo_coding_agent/target/release/vityo-coding-agent",
                    "package_relative_path": "Contents/Helpers/vityo-coding-agent",
                    "required_runtime_libraries": [],
                },
                "rust_notices_path": "Contents/Resources/licenses/RUST-THIRD-PARTY-NOTICES.txt",
            }
            mac_output = root / "vityo.dmg"
            with mock.patch.object(self.packager.subprocess, "run") as run:
                signing_block = self.packager.package_macos(
                    mac_config,
                    mac_output,
                )
            # The DMG is written in place; the return value is the signing block
            # that packaging records in the artifact evidence.
            self.assertEqual(
                signing_block,
                {
                    "status": "explicit-gap",
                    "reason": self.packager.vityo_macos_signing.SIGNING_GAP_REASON,
                },
            )
            self.assertEqual(run.call_args.args[0][:2], ["bash", script])
            staged_app = run.call_args.args[0][2]
            self.assertEqual(staged_app.name, app.name)
            self.assertEqual(run.call_args.args[0][3], mac_output)

    def test_main_builds_independent_windows_artifact_and_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            self.packager.ROOT = root
            packaging = root / "packaging"
            (packaging / "windows").mkdir(parents=True)
            (packaging / "windows/nightly.json").write_text(
                json.dumps(self._windows_config()), encoding="utf-8"
            )
            (packaging / "release-versions.json").write_text(
                json.dumps(self._versions()), encoding="utf-8"
            )
            output_dir = root / "out"
            with (
                mock.patch.object(
                    sys,
                    "argv",
                    ["package-nightly.py", "--platform", "windows", "--output-dir", str(output_dir)],
                ),
                mock.patch.object(self.packager, "build_coding_agent", return_value=Path("agent")),
                mock.patch.object(self.packager, "coding_agent_version", return_value="0.1.0"),
                mock.patch.object(self.packager, "package_windows", side_effect=lambda _, path: path.touch() or path),
                mock.patch("builtins.print"),
            ):
                self.assertEqual(self.packager.main(), 0)
            artifacts = list(output_dir.glob("*.zip"))
            receipt = json.loads(
                artifacts[0].with_suffix(".zip.json").read_text(encoding="utf-8")
            )
        self.assertEqual(receipt["platform"], "windows")
        self.assertEqual(receipt["adapter_version"], "0.1.0-nightly.1")


if __name__ == "__main__":
    unittest.main()
