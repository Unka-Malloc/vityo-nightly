#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
import zipfile
import json
import hashlib
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
            "pafio": {
                "target": "x86_64-pc-windows-msvc",
                "package_relative_path": "components/pafio.exe",
                "required_runtime_libraries": ["vcruntime140.dll"],
                "manifest_relative_path": "components/pafio-component.json",
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
            pafio = root / "pinned/pafio.exe"
            pafio.parent.mkdir(parents=True)
            pafio.write_bytes(b"pafio cli")
            notices = root / "build/evidence/rust-third-party-notices.txt"
            notices.parent.mkdir(parents=True)
            notices.write_text("Rust notices\n", encoding="utf-8")
            output = root / "vityo-nightly-windows.zip"
            self.packager.ROOT = root

            with mock.patch.object(self.packager.subprocess, "run"):
                self.packager.package_windows(
                    self._windows_config(), output, pafio_binary=pafio
                )

            with zipfile.ZipFile(output) as archive:
                names = set(archive.namelist())
        self.assertEqual(
            names,
            {
                "Vityo-Nightly/install.ps1",
                "Vityo-Nightly/uninstall.ps1",
                "Vityo-Nightly/vityo_app.exe",
                "Vityo-Nightly/components/vityo-coding-agent.exe",
                "Vityo-Nightly/components/pafio.exe",
                "Vityo-Nightly/components/pafio-component.json",
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
            (versions, {**valid, "pafio": None}),
            (versions, {**valid, "pafio": {**valid["pafio"], "target": "wrong"}}),
            (versions, {**valid, "pafio": {**valid["pafio"], "required_runtime_libraries": []}}),
            (versions, {**valid, "pafio": {**valid["pafio"], "package_relative_path": "../pafio"}}),
            (
                versions,
                {
                    **valid,
                    "pafio": {
                        **valid["pafio"],
                        "package_relative_path": valid["coding_agent"][
                            "package_relative_path"
                        ],
                    },
                },
            ),
            (versions, {**valid, "pafio": {**valid["pafio"], "manifest_relative_path": "../pafio-component.json"}}),
            (versions, {**valid, "pafio": {**valid["pafio"], "manifest_relative_path": "components/pafio.exe"}}),
            (
                versions,
                {
                    **valid,
                    "pafio": {
                        **valid["pafio"],
                        "manifest_relative_path": valid["rust_notices_path"],
                    },
                },
            ),
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

        with_vityod = {
            **valid,
            "vityod": {
                "package_relative_path": "components/vityod.exe",
                "manifest_relative_path": "components/vityod-component.json",
            },
            "pafio": {
                **valid["pafio"],
                "manifest_relative_path": "components/vityod-component.json",
            },
        }
        with self.assertRaisesRegex(ValueError, "path conflicts with"):
            self.packager.validate_release_inputs("windows", with_vityod, versions)

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
            if os.name != "nt":
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

    def test_stage_pafio_copies_binary_and_records_its_own_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            source = root / "pinned/pafio"
            source.parent.mkdir(parents=True)
            source.write_bytes(b"pafio cli")
            destination_root = root / "application"
            self.packager.ROOT = root
            config = {
                "pafio": {
                    "target": "x86_64-unknown-linux-gnu",
                    "package_relative_path": "components/pafio",
                    "required_runtime_libraries": ["glibc"],
                    "manifest_relative_path": "components/pafio-component.json",
                }
            }
            staged = self.packager.stage_pafio(config, destination_root, source)
            self.assertEqual(staged, destination_root / "components/pafio")
            self.assertEqual(staged.read_bytes(), b"pafio cli")
            if os.name != "nt":
                self.assertTrue(staged.stat().st_mode & 0o111)
            manifest = json.loads(
                (destination_root / "components/pafio-component.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(manifest["component"], "pafio")
            self.assertEqual(manifest["schema_version"], 1)
            self.assertEqual(manifest["target"], "x86_64-unknown-linux-gnu")
            self.assertEqual(manifest["package_relative_path"], "components/pafio")
            self.assertEqual(manifest["required_runtime_libraries"], ["glibc"])
            self.assertEqual(
                manifest["executable_sha256"],
                hashlib.sha256(b"pafio cli").hexdigest(),
            )

    def test_stage_pafio_defaults_its_manifest_beside_the_binary(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            source = root / "pafio"
            source.write_bytes(b"pafio cli")
            destination_root = root / "application"
            self.packager.ROOT = root
            config = {
                "pafio": {
                    "target": "x86_64-unknown-linux-gnu",
                    "package_relative_path": "components/pafio",
                    "required_runtime_libraries": ["glibc"],
                }
            }
            self.packager.stage_pafio(config, destination_root, source)
            self.assertTrue(
                (destination_root / "components/pafio-component.json").is_file()
            )

    def test_stage_pafio_rejects_escapes_and_requires_a_binary(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            source = root / "pafio"
            source.write_bytes(b"pafio cli")
            destination_root = root / "application"
            self.packager.ROOT = root
            base = {
                "target": "x86_64-unknown-linux-gnu",
                "package_relative_path": "components/pafio",
                "required_runtime_libraries": ["glibc"],
            }
            for escaped in ("/tmp/pafio", "../pafio", ""):
                with self.subTest(package_relative_path=escaped):
                    config = {"pafio": {**base, "package_relative_path": escaped}}
                    with self.assertRaisesRegex(ValueError, "must stay inside"):
                        self.packager.stage_pafio(config, destination_root, source)
            with self.assertRaisesRegex(ValueError, "manifest must not overwrite"):
                self.packager.stage_pafio(
                    {
                        "pafio": {
                            **base,
                            "manifest_relative_path": "components/pafio",
                        }
                    },
                    destination_root,
                    source,
                )
            with self.assertRaisesRegex(ValueError, "pinned pafio executable is required"):
                self.packager.stage_pafio({"pafio": base}, destination_root, None)
        with self.assertRaisesRegex(ValueError, "must be an object"):
            self.packager.stage_pafio({"pafio": "invalid"}, Path("application"), Path("pafio"))

    def test_pafio_manifest_keeps_the_exactly_one_vityod_manifest_contract(self) -> None:
        """The pafio record must not collide with the daemon's manifest name.

        The desktop matrix gate requires exactly one ``vityod-component.json``
        per package, so the bundled pafio record uses its own file name.
        """
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            vityod = root / "vityod"
            vityod.write_bytes(b"daemon")
            pafio = root / "pafio"
            pafio.write_bytes(b"pafio cli")
            destination_root = root / "application"
            self.packager.ROOT = root
            config = {
                "vityod": {
                    "source_relative_path": "vityod",
                    "package_relative_path": "Contents/Helpers/vityod",
                    "manifest_relative_path": "Contents/Resources/vityod-component.json",
                    "required_runtime_libraries": [],
                },
                "pafio": {
                    "target": "native-apple-darwin",
                    "package_relative_path": "Contents/Helpers/pafio",
                    "required_runtime_libraries": [],
                    "manifest_relative_path": "Contents/Resources/pafio-component.json",
                },
            }
            with mock.patch.object(
                self.packager,
                "vityod_build_identity",
                return_value={"target": "native-apple-darwin"},
            ):
                self.packager.stage_vityod(config, destination_root)
                self.packager.stage_pafio(config, destination_root, pafio)
            self.assertEqual(
                len(list(destination_root.rglob("vityod-component.json"))), 1
            )
            self.assertEqual(
                len(list(destination_root.rglob("pafio-component.json"))), 1
            )

    def test_macos_pafio_digest_describes_the_sealed_binary(self) -> None:
        """Sealing rewrites the pafio helper, so its record is corrected in-window."""
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            self.packager.ROOT = root
            app = root / "build/macos/Vityo.app"
            app.mkdir(parents=True)
            script = root / "packaging/macos/create-dmg.sh"
            script.parent.mkdir(parents=True)
            script.write_text("#!/bin/sh\n", encoding="utf-8")
            pafio = root / "pafio"
            pafio.write_bytes(b"staged pafio")
            agent = root / "products/vityo_coding_agent/target/release/vityo-coding-agent"
            agent.parent.mkdir(parents=True)
            agent.write_bytes(b"coding agent")
            notices = root / "build/evidence/rust-third-party-notices.txt"
            notices.parent.mkdir(parents=True)
            notices.write_text("Rust notices\n", encoding="utf-8")
            config = {
                "build_relative_path": "build/macos/Vityo.app",
                "installer_definition": "packaging/macos/create-dmg.sh",
                "coding_agent": {
                    "target": "native-apple-darwin",
                    "source_relative_path": "products/vityo_coding_agent/target/release/vityo-coding-agent",
                    "package_relative_path": "Contents/Helpers/vityo-coding-agent",
                    "required_runtime_libraries": [],
                },
                "pafio": {
                    "target": "native-apple-darwin",
                    "package_relative_path": "Contents/Helpers/pafio",
                    "required_runtime_libraries": [],
                    "manifest_relative_path": "Contents/Resources/pafio-component.json",
                },
                "rust_notices_path": "Contents/Resources/licenses/RUST-THIRD-PARTY-NOTICES.txt",
            }
            seen: list[dict[str, object]] = []

            def seal(app_path: Path, *, before_bundle_seal=None):
                # sealing the nested helper rewrites its bytes
                (app_path / "Contents/Helpers/pafio").write_bytes(b"sealed pafio")
                if before_bundle_seal is not None:
                    before_bundle_seal(app_path)
                manifest = (
                    app_path / "Contents/Resources/pafio-component.json"
                ).read_text(encoding="utf-8")
                seen.append(json.loads(manifest))
                return {"status": "configured", "identity": "fixture", "notarization": "keychain-profile"}

            with mock.patch.object(self.packager.subprocess, "run"), mock.patch.object(
                self.packager.vityo_macos_signing, "apply_signing", side_effect=seal
            ), mock.patch.object(
                self.packager.vityo_macos_signing, "notarize"
            ), mock.patch.object(
                self.packager.vityo_macos_signing,
                "resolve_configuration",
                return_value=mock.Mock(),
            ):
                package = self.packager.package_macos(
                    config, root / "vityo.dmg", pafio_binary=pafio
                )

            expected = hashlib.sha256(b"sealed pafio").hexdigest()
            self.assertEqual(package.pafio_executable_sha256, expected)
            self.assertEqual(len(seen), 1)
            self.assertEqual(seen[0]["executable_sha256"], expected)
            self.assertEqual(seen[0]["component"], "pafio")

    def test_build_pafio_resolves_only_when_declared(self) -> None:
        self.assertIsNone(self.packager.build_pafio({}))
        with self.assertRaisesRegex(ValueError, "must be an object"):
            self.packager.build_pafio({"pafio": "invalid"})
        with mock.patch.object(
            self.packager, "resolve_pafio_binary", return_value=Path("/pinned/pafio")
        ) as resolve:
            self.assertEqual(
                self.packager.build_pafio({"pafio": {}}, "/explicit/pafio"),
                Path("/pinned/pafio"),
            )
        resolve.assert_called_once_with("/explicit/pafio")

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
                package = self.packager.package_macos(
                    mac_config,
                    mac_output,
                )
            # The DMG is written in place; the return value carries the signing
            # block and the shipped component that packaging records in the
            # artifact evidence.
            self.assertEqual(
                package.signing,
                {
                    "status": "explicit-gap",
                    "reason": self.packager.vityo_macos_signing.SIGNING_GAP_REASON,
                },
            )
            self.assertIsNone(package.vityod_executable_sha256)
            self.assertEqual(run.call_args.args[0][:2], ["bash", script])
            staged_app = run.call_args.args[0][2]
            self.assertEqual(staged_app.name, app.name)
            self.assertEqual(run.call_args.args[0][3], mac_output)

    def test_macos_staging_preserves_framework_symlinks(self) -> None:
        """A versioned framework must survive staging as links, not copies.

        ``codesign`` rejects a framework root that carries both the linked
        bundle and a dereferenced copy of it, so staging has to keep the links
        the Flutter build produced.
        """
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            self.packager.ROOT = root
            app = root / "build/macos/Vityo.app"
            framework = app / "Contents/Frameworks/App.framework"
            version = framework / "Versions/A"
            (version / "Resources").mkdir(parents=True)
            (version / "App").write_bytes(b"framework binary")
            (version / "Resources/Info.plist").write_text("<plist/>", encoding="utf-8")
            (framework / "Versions/Current").symlink_to("A")
            (framework / "App").symlink_to("Versions/Current/App")
            (framework / "Resources").symlink_to("Versions/Current/Resources")
            script = root / "packaging/macos/create-dmg.sh"
            script.parent.mkdir(parents=True)
            script.write_text("#!/bin/sh\n", encoding="utf-8")
            agent = root / "products/vityo_coding_agent/target/release/vityo-coding-agent"
            agent.parent.mkdir(parents=True)
            agent.write_bytes(b"coding agent")
            notices = root / "build/evidence/rust-third-party-notices.txt"
            notices.parent.mkdir(parents=True)
            notices.write_text("Rust notices\n", encoding="utf-8")
            config = {
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
            observed: dict[str, bool] = {}

            def capture(command: list[str], **kwargs: object) -> mock.Mock:
                if Path(command[1]).name != "create-dmg.sh":
                    return mock.Mock(returncode=0)
                staged = Path(command[2]) / "Contents/Frameworks/App.framework"
                observed["App"] = (staged / "App").is_symlink()
                observed["Resources"] = (staged / "Resources").is_symlink()
                observed["Current"] = (staged / "Versions/Current").is_symlink()
                return mock.Mock(returncode=0)

            with mock.patch.object(self.packager.subprocess, "run", side_effect=capture):
                self.packager.package_macos(config, root / "vityo.dmg")

            self.assertEqual(observed, {"App": True, "Resources": True, "Current": True})

    def test_macos_component_digest_describes_the_sealed_binary(self) -> None:
        """The shipped component identity must match the bytes sealing wrote.

        Signing a helper rewrites the file, so a digest recorded during staging
        would name a binary the package cannot contain. The corrected record has
        to be written before the bundle seal, because sealing covers resources.
        """
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            self.packager.ROOT = root
            self.packager.vityod_build_identity = lambda: {
                "daemon_version": "0.1.0",
                "build_source_fingerprint": "c" * 64,
                "target": "fixture-desktop",
            }
            app = root / "build/macos/Vityo.app"
            app.mkdir(parents=True)
            script = root / "packaging/macos/create-dmg.sh"
            script.parent.mkdir(parents=True)
            script.write_text("#!/bin/sh\n", encoding="utf-8")
            source = root / "vityod"
            source.write_bytes(b"staged helper")
            agent = root / "products/vityo_coding_agent/target/release/vityo-coding-agent"
            agent.parent.mkdir(parents=True)
            agent.write_bytes(b"coding agent")
            notices = root / "build/evidence/rust-third-party-notices.txt"
            notices.parent.mkdir(parents=True)
            notices.write_text("Rust notices\n", encoding="utf-8")
            config = {
                "build_relative_path": "build/macos/Vityo.app",
                "installer_definition": "packaging/macos/create-dmg.sh",
                "vityod": {
                    "target": "fixture-desktop",
                    "source_relative_path": "vityod",
                    "package_relative_path": "Contents/Helpers/vityod",
                    "manifest_relative_path": "Contents/Resources/vityod-component.json",
                    "required_runtime_libraries": [],
                },
                "coding_agent": {
                    "target": "native-apple-darwin",
                    "source_relative_path": "products/vityo_coding_agent/target/release/vityo-coding-agent",
                    "package_relative_path": "Contents/Helpers/vityo-coding-agent",
                    "required_runtime_libraries": [],
                },
                "rust_notices_path": "Contents/Resources/licenses/RUST-THIRD-PARTY-NOTICES.txt",
            }
            seen: list[dict[str, object]] = []

            def seal(app_path: Path, *, before_bundle_seal=None):
                # sealing a nested helper rewrites its bytes
                (app_path / "Contents/Helpers/vityod").write_bytes(b"sealed helper")
                if before_bundle_seal is not None:
                    before_bundle_seal(app_path)
                manifest = (
                    app_path / "Contents/Resources/vityod-component.json"
                ).read_text(encoding="utf-8")
                seen.append(json.loads(manifest))
                return {"status": "configured", "identity": "fixture", "notarization": "keychain-profile"}

            with mock.patch.object(self.packager.subprocess, "run"), mock.patch.object(
                self.packager.vityo_macos_signing, "apply_signing", side_effect=seal
            ), mock.patch.object(
                self.packager.vityo_macos_signing, "notarize"
            ), mock.patch.object(
                self.packager.vityo_macos_signing,
                "resolve_configuration",
                return_value=mock.Mock(),
            ):
                package = self.packager.package_macos(config, root / "vityo.dmg")

            expected = hashlib.sha256(b"sealed helper").hexdigest()
            self.assertEqual(package.vityod_executable_sha256, expected)
            self.assertEqual(len(seen), 1)
            self.assertEqual(seen[0]["executable_sha256"], expected)
            self.assertEqual(seen[0]["component"], "vityod")

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
            pafio = root / "pinned-pafio"
            pafio.write_bytes(b"pafio")
            with (
                mock.patch.object(
                    sys,
                    "argv",
                    ["package-nightly.py", "--platform", "windows", "--output-dir", str(output_dir)],
                ),
                mock.patch.object(self.packager, "build_coding_agent", return_value=Path("agent")),
                mock.patch.object(self.packager, "build_pafio", return_value=pafio),
                mock.patch.object(self.packager, "coding_agent_version", return_value="0.1.0"),
                mock.patch.object(self.packager, "package_windows", side_effect=lambda _config, path, **_: path.touch() or path),
                mock.patch("builtins.print"),
            ):
                self.assertEqual(self.packager.main(), 0)
            artifacts = list(output_dir.glob("*.zip"))
            receipt = json.loads(
                artifacts[0].with_suffix(".zip.json").read_text(encoding="utf-8")
            )
        self.assertEqual(receipt["platform"], "windows")
        self.assertEqual(receipt["adapter_version"], "0.1.0-nightly.1")
        self.assertEqual(receipt["pafio"]["package_relative_path"], "components/pafio.exe")
        self.assertEqual(
            receipt["pafio"]["executable_sha256"],
            hashlib.sha256(b"pafio").hexdigest(),
        )


if __name__ == "__main__":
    unittest.main()
