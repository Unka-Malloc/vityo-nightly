#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib
import zipfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# This module is loaded by path, so its own directory is not importable yet.
_SCRIPTS_DIR = str(Path(__file__).resolve().parent)
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import vityo_macos_signing  # noqa: E402  (needs the path fix above)
import vityo  # noqa: E402  (shared pinned-CLI resolution)

PACKAGE_FORMATS = {"linux": "deb", "windows": "zip-powershell", "macos": "dmg"}
CODING_AGENT_TARGETS = {
    "linux": "x86_64-unknown-linux-gnu",
    "windows": "x86_64-pc-windows-msvc",
    "macos": "native-apple-darwin",
}
CODING_AGENT_RUNTIME_LIBRARIES = {
    "linux": ["glibc", "libssl.so.3"],
    "windows": ["vcruntime140.dll"],
    "macos": [],
}
# pafio is a pinned external CLI, not an in-repository workspace, so its contract
# declares the package target and runtime libraries but no build source path.
PAFIO_TARGETS = {
    "linux": "x86_64-unknown-linux-gnu",
    "windows": "x86_64-pc-windows-msvc",
    "macos": "native-apple-darwin",
}
PAFIO_RUNTIME_LIBRARIES = {
    "linux": ["glibc"],
    "windows": ["vcruntime140.dll"],
    "macos": [],
}
COMPONENT_MANIFEST_NAME = "vityod-component.json"
PAFIO_COMPONENT_MANIFEST_NAME = "pafio-component.json"
RUST_NOTICE_SOURCE = Path("build/evidence/rust-third-party-notices.txt")
RUST_NOTICE_DESTINATIONS = {
    "linux": Path("licenses/RUST-THIRD-PARTY-NOTICES.txt"),
    "windows": Path("licenses/RUST-THIRD-PARTY-NOTICES.txt"),
    "macos": Path("Contents/Resources/licenses/RUST-THIRD-PARTY-NOTICES.txt"),
}
VERSION_PATTERN = re.compile(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?")


@dataclass(frozen=True)
class MacosPackage:
    """What macOS packaging produced: its signing block and shipped components."""

    signing: dict[str, object]
    vityod_executable_sha256: str | None
    pafio_executable_sha256: str | None = None


def load_json(path: Path) -> dict[str, object]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return payload


def require_file(path: Path) -> Path:
    if not path.is_file():
        raise FileNotFoundError(path)
    return path


def require_dir(path: Path) -> Path:
    if not path.is_dir():
        raise FileNotFoundError(path)
    return path


def copy_tree_contents(source: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for item in source.iterdir():
        target = destination / item.name
        if item.is_dir():
            shutil.copytree(item, target, dirs_exist_ok=True)
        else:
            shutil.copy2(item, target)


def vityod_build_identity() -> dict[str, object]:
    workspace = ROOT / "products/vityo_app/native/vityod"
    cargo_manifest = require_file(workspace / "Cargo.toml")
    payload = tomllib.loads(cargo_manifest.read_text(encoding="utf-8"))
    version = payload.get("workspace", {}).get("package", {}).get("version")
    if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
        raise ValueError("vityod workspace version is invalid")
    rustc = subprocess.run(
        ["rustc", "-vV"], check=True, capture_output=True, text=True, timeout=10
    )
    target = next(
        (line.removeprefix("host: ") for line in rustc.stdout.splitlines() if line.startswith("host: ")),
        "",
    )
    if not target or any(character.isspace() for character in target):
        raise ValueError("Rust host target is invalid")
    sources = [cargo_manifest, require_file(workspace / "Cargo.lock")]
    sources.extend(sorted((workspace / "crates").glob("*/Cargo.toml")))
    sources.extend(sorted((workspace / "crates").glob("*/src/**/*.rs")))
    fingerprint = hashlib.sha256()
    for source in sources:
        relative = source.relative_to(workspace).as_posix().encode("utf-8")
        fingerprint.update(len(relative).to_bytes(4, "big"))
        fingerprint.update(relative)
        content = source.read_bytes()
        fingerprint.update(len(content).to_bytes(8, "big"))
        fingerprint.update(content)
    return {
        "daemon_version": version,
        "build_source_fingerprint": fingerprint.hexdigest(),
        "target": target,
    }


def vityod_target_matches(declared: object, actual: object) -> bool:
    declared_target = str(declared)
    actual_target = str(actual)
    return actual_target == declared_target or (
        declared_target == "native-apple-darwin"
        and actual_target.endswith("-apple-darwin")
    )


def build_vityod(config: dict[str, object]) -> Path | None:
    component = config.get("vityod")
    if component is None:
        return None
    if not isinstance(component, dict):
        raise ValueError("vityod package contract must be an object")
    identity = vityod_build_identity()
    if not vityod_target_matches(component.get("target"), identity.get("target")):
        raise ValueError("vityod build host does not match the package target")
    manifest = ROOT / "products/vityo_app/native/vityod/Cargo.toml"
    require_file(manifest)
    subprocess.run(
        [
            "cargo",
            "build",
            "--locked",
            "--release",
            "--manifest-path",
            manifest,
            "-p",
            "vityod",
        ],
        cwd=ROOT,
        check=True,
    )
    return require_file(ROOT / str(component.get("source_relative_path", "")))


def require_contained_relative_path(relative: str, label: str) -> Path:
    """Reject a declared package path that can escape the application directory.

    A bare ``is_absolute()`` check is not enough on Windows: ``/tmp/vityod`` has
    a root but no drive, so it is not absolute there while joining it to
    ``D:/bundle/Vityo.app`` still resolves to ``D:/tmp/vityod``. Testing the
    parsed anchor covers rooted paths, drive-absolute paths, and drive-relative
    paths on every platform, so a declared component path can only ever name a
    location inside the application directory.
    """
    path = Path(relative)
    if not path.parts or ".." in path.parts or path.anchor:
        raise ValueError(f"{label} path must stay inside the application")
    return path


def stage_vityod(config: dict[str, object], destination_root: Path) -> Path | None:
    component = config.get("vityod")
    if component is None:
        return None
    if not isinstance(component, dict):
        raise ValueError("vityod package contract must be an object")
    source = require_file(ROOT / str(component.get("source_relative_path", "")))
    relative = require_contained_relative_path(
        str(component.get("package_relative_path", "")), "vityod package"
    )
    destination = destination_root / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    destination.chmod(
        destination.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
    )
    record_component_manifest(config, destination_root)
    return destination


def record_component_manifest(config: dict[str, object], destination_root: Path) -> str:
    """Bind the vityod component identity to the binary that currently ships.

    Returns the digest it recorded. The digest is read from the staged
    destination rather than the build output because sealing rewrites the
    helper's bytes: macOS packaging calls this a second time between sealing the
    nested helpers and sealing the enclosing bundle, so a signed package records
    the digest of the sealed binary and the bundle seal covers that record.
    """
    component = config.get("vityod")
    if not isinstance(component, dict):
        raise ValueError("vityod package contract must be an object")
    relative = require_contained_relative_path(
        str(component.get("package_relative_path", "")), "vityod package"
    )
    destination = require_file(destination_root / relative)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    identity = vityod_build_identity()
    runtime_libraries = component.get("required_runtime_libraries")
    if not isinstance(runtime_libraries, list) or not all(
        isinstance(library, str) and library.strip() for library in runtime_libraries
    ):
        raise ValueError("vityod required_runtime_libraries must be a string list")
    manifest_path = require_contained_relative_path(
        str(component.get("manifest_relative_path") or (relative.parent / COMPONENT_MANIFEST_NAME).as_posix()),
        "vityod component manifest",
    )
    if manifest_path == relative:
        raise ValueError("vityod component manifest must not overwrite the executable")
    manifest = {
        "schema_version": 1,
        "component": "vityod",
        "protocol_min": 1,
        "protocol_max": 1,
        "executable_sha256": digest,
        **identity,
        "required_runtime_libraries": runtime_libraries,
        "package_relative_path": relative.as_posix(),
    }
    manifest_destination = destination_root / manifest_path
    manifest_destination.parent.mkdir(parents=True, exist_ok=True)
    manifest_destination.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return digest


def coding_agent_version() -> str:
    manifest = require_file(ROOT / "products/vityo_coding_agent/Cargo.toml")
    payload = tomllib.loads(manifest.read_text(encoding="utf-8"))
    package = payload.get("package")
    version = package.get("version") if isinstance(package, dict) else None
    if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
        raise ValueError("Coding Agent Cargo version is invalid")
    return version


def build_coding_agent(config: dict[str, object]) -> Path:
    component = config.get("coding_agent")
    if not isinstance(component, dict):
        raise ValueError("Coding Agent package contract is missing")
    identity = vityod_build_identity()
    if not vityod_target_matches(component.get("target"), identity.get("target")):
        raise ValueError("Coding Agent build host does not match the package target")
    manifest = require_file(ROOT / "products/vityo_coding_agent/Cargo.toml")
    subprocess.run(
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
        cwd=ROOT,
        check=True,
    )
    binary = require_file(ROOT / str(component.get("source_relative_path", "")))
    subprocess.run([binary, "--version"], cwd=ROOT, check=True)
    return binary


def stage_coding_agent(config: dict[str, object], destination_root: Path) -> Path:
    component = config.get("coding_agent")
    if not isinstance(component, dict):
        raise ValueError("Coding Agent package contract is missing")
    source = require_file(ROOT / str(component.get("source_relative_path", "")))
    relative = require_contained_relative_path(
        str(component.get("package_relative_path", "")), "Coding Agent package"
    )
    destination = destination_root / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    destination.chmod(destination.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    subprocess.run([destination, "--version"], cwd=destination_root, check=True)
    return destination


def resolve_pafio_binary(explicit: str | None = None) -> Path:
    """Resolve the pinned pafio CLI through Vityo's shared pinned-CLI resolution.

    An explicit ``--pafio-bin`` wins; otherwise the pinned product-matrix
    revision is located or provisioned the same way the delivery test and
    acceptance stages resolve it.
    """
    return vityo.resolve_pinned_cli("pafio", explicit)


def build_pafio(config: dict[str, object], explicit: str | None = None) -> Path | None:
    """Resolve the pafio binary this package ships, or None when undeclared."""
    component = config.get("pafio")
    if component is None:
        return None
    if not isinstance(component, dict):
        raise ValueError("pafio package contract must be an object")
    return resolve_pafio_binary(explicit)


def record_pafio_manifest(config: dict[str, object], destination_root: Path) -> str:
    """Bind the pafio component identity to the CLI that currently ships.

    Mirrors :func:`record_component_manifest`, but pafio is a pinned external
    CLI rather than an in-repository workspace, so the record carries the
    package target and the staged digest instead of a Cargo version and
    source fingerprint. It writes ``pafio-component.json``, a different name
    from the daemon's ``vityod-component.json``, so a package still contains
    exactly one vityod component manifest. The digest is read from the staged
    destination because macOS sealing rewrites the helper's bytes and packaging
    calls this a second time inside the sealing window.
    """
    component = config.get("pafio")
    if not isinstance(component, dict):
        raise ValueError("pafio package contract must be an object")
    relative = require_contained_relative_path(
        str(component.get("package_relative_path", "")), "pafio package"
    )
    destination = require_file(destination_root / relative)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    runtime_libraries = component.get("required_runtime_libraries")
    if not isinstance(runtime_libraries, list) or not all(
        isinstance(library, str) and library.strip() for library in runtime_libraries
    ):
        raise ValueError("pafio required_runtime_libraries must be a string list")
    target = component.get("target")
    if not isinstance(target, str) or not target.strip():
        raise ValueError("pafio target must be a non-empty string")
    manifest_path = require_contained_relative_path(
        str(component.get("manifest_relative_path") or (relative.parent / PAFIO_COMPONENT_MANIFEST_NAME).as_posix()),
        "pafio component manifest",
    )
    if manifest_path == relative:
        raise ValueError("pafio component manifest must not overwrite the executable")
    manifest = {
        "schema_version": 1,
        "component": "pafio",
        "target": target,
        "executable_sha256": digest,
        "required_runtime_libraries": runtime_libraries,
        "package_relative_path": relative.as_posix(),
    }
    manifest_destination = destination_root / manifest_path
    manifest_destination.parent.mkdir(parents=True, exist_ok=True)
    manifest_destination.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return digest


def stage_pafio(
    config: dict[str, object], destination_root: Path, binary: Path | None
) -> Path | None:
    component = config.get("pafio")
    if component is None:
        return None
    if not isinstance(component, dict):
        raise ValueError("pafio package contract must be an object")
    if binary is None:
        raise ValueError("the pinned pafio executable is required to stage the pafio component")
    source = require_file(binary)
    relative = require_contained_relative_path(
        str(component.get("package_relative_path", "")), "pafio package"
    )
    destination = destination_root / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    destination.chmod(destination.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    record_pafio_manifest(config, destination_root)
    return destination


def stage_rust_notices(platform: str, destination_root: Path) -> Path:
    source = ROOT / RUST_NOTICE_SOURCE
    if not source.is_file() or not source.read_text(encoding="utf-8").strip():
        raise ValueError("the generated Rust third-party notices are missing or empty")
    destination = destination_root / RUST_NOTICE_DESTINATIONS[platform]
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    return destination


def validate_release_inputs(platform: str, config: dict[str, object], versions: dict[str, object]) -> str:
    if versions.get("schema_version") != 1:
        raise ValueError("invalid release versions schema")
    if config.get("schema_version") != 1 or config.get("platform") != platform:
        raise ValueError(f"invalid {platform} package schema")
    if config.get("package_format") != PACKAGE_FORMATS[platform]:
        raise ValueError(f"invalid {platform} package format")
    signing = config.get("signing")
    if not isinstance(signing, dict) or signing.get("status") not in {"configured", "explicit-gap"}:
        raise ValueError(f"invalid {platform} signing policy")
    if signing.get("status") == "explicit-gap" and not str(signing.get("reason", "")).strip():
        raise ValueError(f"missing {platform} signing gap reason")
    if platform == "macos" and vityo_macos_signing.signing_requested():
        try:
            vityo_macos_signing.resolve_configuration()
        except vityo_macos_signing.SigningError as error:
            raise ValueError(f"invalid {platform} signing credentials: {error}") from error
    coding_agent = config.get("coding_agent")
    if not isinstance(coding_agent, dict):
        raise ValueError(f"missing {platform} Coding Agent package component")
    if coding_agent.get("target") != CODING_AGENT_TARGETS[platform]:
        raise ValueError(f"{platform} Coding Agent target is mismatched")
    if coding_agent.get("required_runtime_libraries") != CODING_AGENT_RUNTIME_LIBRARIES[platform]:
        raise ValueError(f"{platform} Coding Agent runtime libraries are mismatched")
    if coding_agent.get("source_relative_path") != (
        "products/vityo_coding_agent/target/release/vityo-coding-agent.exe"
        if platform == "windows"
        else "products/vityo_coding_agent/target/release/vityo-coding-agent"
    ):
        raise ValueError(f"{platform} Coding Agent source path is invalid")
    relative = Path(str(coding_agent.get("package_relative_path", "")))
    if relative.is_absolute() or ".." in relative.parts or not relative.parts:
        raise ValueError(f"{platform} Coding Agent package path is invalid")
    component_outputs: list[tuple[Path, str]] = [(relative, "Coding Agent executable")]
    vityod = config.get("vityod")
    if isinstance(vityod, dict):
        vityod_relative = require_contained_relative_path(
            str(vityod.get("package_relative_path", "")), "vityod package"
        )
        vityod_manifest = require_contained_relative_path(
            str(
                vityod.get("manifest_relative_path")
                or (vityod_relative.parent / COMPONENT_MANIFEST_NAME).as_posix()
            ),
            "vityod component manifest",
        )
        component_outputs.extend(
            (
                (vityod_relative, "vityod executable"),
                (vityod_manifest, "vityod component manifest"),
            )
        )
    pafio = config.get("pafio")
    if not isinstance(pafio, dict):
        raise ValueError(f"missing {platform} pafio package component")
    if pafio.get("target") != PAFIO_TARGETS[platform]:
        raise ValueError(f"{platform} pafio target is mismatched")
    if pafio.get("required_runtime_libraries") != PAFIO_RUNTIME_LIBRARIES[platform]:
        raise ValueError(f"{platform} pafio runtime libraries are mismatched")
    pafio_relative = Path(str(pafio.get("package_relative_path", "")))
    if pafio_relative.is_absolute() or ".." in pafio_relative.parts or not pafio_relative.parts:
        raise ValueError(f"{platform} pafio package path is invalid")
    pafio_manifest = pafio.get("manifest_relative_path")
    if pafio_manifest is not None:
        manifest_relative = Path(str(pafio_manifest))
        if (
            manifest_relative.is_absolute()
            or ".." in manifest_relative.parts
            or not manifest_relative.parts
            or manifest_relative == pafio_relative
        ):
            raise ValueError(f"{platform} pafio component manifest path is invalid")
    else:
        manifest_relative = pafio_relative.parent / PAFIO_COMPONENT_MANIFEST_NAME
    component_outputs.extend(
        (
            (pafio_relative, "pafio executable"),
            (manifest_relative, "pafio component manifest"),
            (RUST_NOTICE_DESTINATIONS[platform], "Rust notices"),
        )
    )
    for index, (output_path, output_name) in enumerate(component_outputs):
        for other_path, other_name in component_outputs[index + 1 :]:
            if (
                output_path == other_path
                or output_path in other_path.parents
                or other_path in output_path.parents
            ):
                raise ValueError(
                    f"{platform} {output_name} path conflicts with {other_name} path"
                )
    if config.get("rust_notices_path") != RUST_NOTICE_DESTINATIONS[platform].as_posix():
        raise ValueError(f"{platform} Rust notices destination is invalid")
    automatic_updates = config.get("automatic_updates")
    if not isinstance(automatic_updates, bool):
        raise ValueError(f"invalid {platform} automatic update policy")
    if signing.get("status") != "configured" and automatic_updates:
        raise ValueError(f"unsigned {platform} package cannot enable automatic updates")
    core_version = versions.get("core_version")
    if not isinstance(core_version, str) or not VERSION_PATTERN.fullmatch(core_version):
        raise ValueError("invalid core version")
    adapters = versions.get("platform_adapters")
    adapter_version = adapters.get(platform) if isinstance(adapters, dict) else None
    if not isinstance(adapter_version, str) or not VERSION_PATTERN.fullmatch(adapter_version):
        raise ValueError(f"missing or invalid adapter version for {platform}")
    return adapter_version


def package_linux(
    config: dict[str, object],
    output: Path,
    version: str,
    *,
    pafio_binary: Path | None = None,
) -> Path:
    build = require_dir(ROOT / str(config["build_relative_path"]))
    with tempfile.TemporaryDirectory(prefix="vityo-deb-") as raw_stage:
        stage = Path(raw_stage)
        app_root = stage / "opt/vityo"
        copy_tree_contents(build, app_root)
        stage_vityod(config, app_root)
        stage_coding_agent(config, app_root)
        stage_pafio(config, app_root, pafio_binary)
        stage_rust_notices("linux", app_root)
        control_root = stage / "DEBIAN"
        control_root.mkdir(parents=True)
        control = require_file(ROOT / str(config["installer_definition"])).read_text(encoding="utf-8")
        debian_version = version.split("+", 1)[0].replace("-", "~", 1)
        control = control.replace("Version: 0.1.0", f"Version: {debian_version}")
        (control_root / "control").write_text(control, encoding="utf-8")
        bin_root = stage / "usr/bin"
        bin_root.mkdir(parents=True)
        wrapper = bin_root / "vityo"
        wrapper.write_text('#!/usr/bin/env sh\nexec /opt/vityo/vityo_app "$@"\n', encoding="utf-8")
        wrapper.chmod(wrapper.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        applications = stage / "usr/share/applications"
        applications.mkdir(parents=True)
        shutil.copy2(
            ROOT / "packaging/linux/io.vityo.desktop",
            applications / "io.vityo.desktop",
        )
        metainfo = stage / "usr/share/metainfo"
        metainfo.mkdir(parents=True)
        shutil.copy2(
            ROOT / "packaging/linux/io.vityo.metainfo.xml",
            metainfo / "io.vityo.metainfo.xml",
        )
        icons = stage / "usr/share/icons/hicolor/512x512/apps"
        icons.mkdir(parents=True)
        shutil.copy2(
            require_file(ROOT / str(config["icon_relative_path"])),
            icons / "io.vityo.png",
        )
        subprocess.run(["dpkg-deb", "--build", "--root-owner-group", stage, output], check=True)
    return output


def package_windows(
    config: dict[str, object], output: Path, *, pafio_binary: Path | None = None
) -> Path:
    build = require_dir(ROOT / str(config["build_relative_path"]))
    with tempfile.TemporaryDirectory(prefix="vityo-win-") as raw_stage:
        stage = Path(raw_stage) / "Vityo-Nightly"
        copy_tree_contents(build, stage)
        stage_vityod(config, stage)
        stage_coding_agent(config, stage)
        stage_pafio(config, stage, pafio_binary)
        stage_rust_notices("windows", stage)
        shutil.copy2(ROOT / "packaging/windows/install.ps1", stage / "install.ps1")
        shutil.copy2(ROOT / "packaging/windows/uninstall.ps1", stage / "uninstall.ps1")
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(stage.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(stage.parent))
    return output


def package_macos(
    config: dict[str, object], output: Path, *, pafio_binary: Path | None = None
) -> MacosPackage:
    """Build the DMG and report the signing block and the shipped components.

    ``vityod_executable_sha256`` and ``pafio_executable_sha256`` are the digests
    of the helpers as they ship. Sealing replaces the staged bytes, so the
    receipt cannot be derived from the build output the way the other platforms
    derive it.
    """
    app = require_dir(ROOT / str(config["build_relative_path"]))
    script = require_file(ROOT / str(config["installer_definition"]))
    component = config.get("vityod")
    pafio_component = config.get("pafio")
    shipped_digest: str | None = None
    shipped_pafio_digest: str | None = None
    with tempfile.TemporaryDirectory(prefix="vityo-macos-") as raw_stage:
        staged_app = Path(raw_stage) / app.name
        # symlinks=True is required, not cosmetic: a versioned framework stores
        # its real bundle under Versions/<letter> and links to it from the
        # framework root. Dereferencing those links copies the framework binary
        # and its Resources directory to the root, which makes ``codesign`` see
        # both an app-shaped and a framework-shaped bundle and refuse it with
        # "bundle format is ambiguous (could be app or framework)".
        shutil.copytree(app, staged_app, symlinks=True)
        stage_vityod(config, staged_app)
        stage_coding_agent(config, staged_app)
        stage_pafio(config, staged_app, pafio_binary)
        stage_rust_notices("macos", staged_app)

        def record_sealed_component(target: Path) -> None:
            """Rewrite the component identities inside the sealing window."""
            nonlocal shipped_digest, shipped_pafio_digest
            if component is not None:
                shipped_digest = record_component_manifest(config, target)
            if pafio_component is not None:
                shipped_pafio_digest = record_pafio_manifest(config, target)

        # Seal the staged bundle before the installer definition captures it in
        # the DMG, so the artifact that ships is the sealed one.
        signing_status = vityo_macos_signing.apply_signing(
            staged_app, before_bundle_seal=record_sealed_component
        )
        if shipped_digest is None and isinstance(component, dict):
            # An unsealed package keeps the digest staging recorded, because
            # nothing rewrote the helper after it was staged.
            staged_helper = staged_app / str(component.get("package_relative_path", ""))
            if staged_helper.is_file():
                shipped_digest = hashlib.sha256(staged_helper.read_bytes()).hexdigest()
        if shipped_pafio_digest is None and isinstance(pafio_component, dict):
            staged_pafio = staged_app / str(pafio_component.get("package_relative_path", ""))
            if staged_pafio.is_file():
                shipped_pafio_digest = hashlib.sha256(staged_pafio.read_bytes()).hexdigest()
        subprocess.run(["bash", script, staged_app, output], check=True)
        if signing_status.get("status") == "configured":
            vityo_macos_signing.notarize(
                output, vityo_macos_signing.resolve_configuration()
            )
    return MacosPackage(
        signing=signing_status,
        vityod_executable_sha256=shipped_digest,
        pafio_executable_sha256=shipped_pafio_digest,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Build one independently releasable Vityo Nightly package")
    parser.add_argument("--platform", required=True, choices=("linux", "windows", "macos"))
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/nightly")
    parser.add_argument(
        "--pafio-bin",
        help="Explicit pinned pafio CLI to bundle; defaults to the product-matrix revision",
    )
    args = parser.parse_args()
    config = load_json(ROOT / f"packaging/{args.platform}/nightly.json")
    versions = load_json(ROOT / "packaging/release-versions.json")
    version = validate_release_inputs(args.platform, config, versions)
    vityod_binary = build_vityod(config)
    build_coding_agent(config)
    pafio_binary = build_pafio(config, args.pafio_bin)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    suffix = {"linux": ".deb", "windows": ".zip", "macos": ".dmg"}[args.platform]
    output = args.output_dir / f"vityo-nightly-{args.platform}-{version}{suffix}"
    if output.exists():
        output.unlink()
    artifact = {"linux": package_linux, "windows": package_windows, "macos": package_macos}[args.platform]
    shipped_vityod_sha256: str | None = None
    shipped_pafio_sha256: str | None = None
    if args.platform == "linux":
        artifact(config, output, version, pafio_binary=pafio_binary)
        signing_block = config["signing"]
    elif args.platform == "macos":
        package = package_macos(config, output, pafio_binary=pafio_binary)
        signing_block = package.signing
        shipped_vityod_sha256 = package.vityod_executable_sha256
        shipped_pafio_sha256 = package.pafio_executable_sha256
    else:
        artifact(config, output, pafio_binary=pafio_binary)
        signing_block = config["signing"]
    evidence = {
        "schema_version": 1,
        "platform": args.platform,
        "core_version": versions["core_version"],
        "adapter_version": version,
        "artifact": output.name,
        "signing": signing_block,
        "automatic_updates": config["automatic_updates"],
    }
    if vityod_binary is not None:
        component = config["vityod"]
        assert isinstance(component, dict)
        evidence["vityod"] = {
            **vityod_build_identity(),
            # Sealing rewrites the macOS helper before it ships, so that package
            # reports the digest it recorded instead of the build output's.
            "executable_sha256": shipped_vityod_sha256
            or hashlib.sha256(vityod_binary.read_bytes()).hexdigest(),
            "package_relative_path": component["package_relative_path"],
        }
    component = config["coding_agent"]
    assert isinstance(component, dict)
    evidence["coding_agent"] = {
        "version": coding_agent_version(),
        "package_relative_path": component["package_relative_path"],
        "target": component["target"],
        "required_runtime_libraries": component["required_runtime_libraries"],
    }
    if pafio_binary is not None:
        component = config["pafio"]
        assert isinstance(component, dict)
        evidence["pafio"] = {
            # Sealing rewrites the macOS helper before it ships, so that package
            # reports the digest it recorded instead of the resolved CLI's.
            "executable_sha256": shipped_pafio_sha256
            or hashlib.sha256(pafio_binary.read_bytes()).hexdigest(),
            "package_relative_path": component["package_relative_path"],
            "target": component["target"],
            "required_runtime_libraries": component["required_runtime_libraries"],
        }
    evidence["rust_notices"] = config["rust_notices_path"]
    output.with_suffix(output.suffix + ".json").write_text(
        json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
