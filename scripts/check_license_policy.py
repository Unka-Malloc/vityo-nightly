#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
import tomllib
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PUBSPEC_PATH = Path("products/vityo_app/pubspec.yaml")
DEPENDENCY_USAGE_PATH = Path("DEPENDENCY-USAGE.md")
THIRD_PARTY_PATH = Path("docs/specs/THIRD-PARTY.md")
SECURITY_POLICY_PATH = Path("docs/governance/SECURITY-AND-SUPPLY-CHAIN.md")
RUST_LICENSE_CONFIG_PATH = Path("toolchain/licenses/about.toml")
RUST_PACKAGE_TARGET_MANIFESTS = (
    ("linux", Path("packaging/linux/nightly.json")),
    ("windows", Path("packaging/windows/nightly.json")),
    ("macos", Path("packaging/macos/nightly.json")),
)
RUST_PACKAGE_TARGET_EXPANSIONS = {
    "x86_64-unknown-linux-gnu": {"x86_64-unknown-linux-gnu"},
    "x86_64-pc-windows-msvc": {"x86_64-pc-windows-msvc"},
    "native-apple-darwin": {"x86_64-apple-darwin", "aarch64-apple-darwin"},
}
RUST_PACKAGE_COMPONENTS = ("vityod", "coding_agent")

ALLOWED_EXTERNAL_DART_PACKAGES = {
    "flutter",
    "crypto",
    "ffi",
    "file_selector",
    "flutter_secure_storage",
    "cupertino_icons",
    "shared_preferences",
    "path_provider",
    "cryptography",
    "web",
    "flutter_test",
    "integration_test",
    "flutter_lints",
    "test",
    "vm_service",
}

FIRST_PARTY_DART_PACKAGE_PATHS = {
    "vityo_agent_protocol": "../../packages/vityo_agent_protocol",
    "vityo_daemon_protocol": "../../packages/vityo_daemon_protocol",
}

FORBIDDEN_LICENSE_MARKERS = (
    "GPL-2.0",
    "GPL-3.0",
    "AGPL",
    "SSPL",
)


def parse_pubspec_dependencies(pubspec: Path) -> tuple[set[str], dict[str, str]]:
    if not pubspec.is_file():
        return set(), {}
    packages: set[str] = set()
    local_paths: dict[str, str] = {}
    in_dependency_block = False
    current_package: str | None = None
    for line in pubspec.read_text(encoding="utf-8").splitlines():
        if re.match(r"^(dependencies|dev_dependencies):\s*$", line):
            in_dependency_block = True
            current_package = None
            continue
        if in_dependency_block and line and not line.startswith(" "):
            in_dependency_block = False
            current_package = None
        if not in_dependency_block:
            continue
        match = re.match(r"^\s{2}([A-Za-z0-9_]+):", line)
        if match:
            current_package = match.group(1)
            packages.add(current_package)
            continue
        path_match = re.match(r"^\s{4}path:\s*(\S.*?)\s*$", line)
        if current_package is not None and path_match:
            local_paths[current_package] = path_match.group(1).strip("\"'")
    return packages, local_paths


def _rust_notice_generator(root: Path, output: Path) -> list[str]:
    generator_path = root / "scripts/vityo_rust_notices.py"
    if not generator_path.is_file():
        return ["missing scripts/vityo_rust_notices.py"]
    spec = importlib.util.spec_from_file_location("vityo_rust_notices", generator_path)
    if spec is None or spec.loader is None:
        return ["unable to load the Rust license notice generator"]
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    try:
        module.generate_notices(root=root, output=output)
    except module.RustNoticeError as exc:
        return [str(exc)]
    return []


def _check_rust_license_allowlist(root: Path) -> list[str]:
    policy_path = root / SECURITY_POLICY_PATH
    config_path = root / RUST_LICENSE_CONFIG_PATH
    if not policy_path.is_file() or not config_path.is_file():
        return ["Rust license policy or cargo-about configuration is missing"]
    policy_text = policy_path.read_text(encoding="utf-8")
    policy_line = next(
        (line for line in policy_text.splitlines() if "Permissible licenses:" in line),
        None,
    )
    if policy_line is None:
        return ["SECURITY-AND-SUPPLY-CHAIN.md is missing its Permissible licenses declaration"]
    policy_value = policy_line.split("Permissible licenses:", 1)[1]
    documented = {value.strip().strip("`.") for value in policy_value.split(",") if value.strip()}
    try:
        configuration = tomllib.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError):
        return ["toolchain/licenses/about.toml is invalid"]
    accepted = configuration.get("accepted")
    if not isinstance(accepted, list) or not all(isinstance(item, str) for item in accepted):
        return ["cargo-about accepted license list is invalid"]
    if len(accepted) != len(set(accepted)):
        return ["cargo-about accepted license list contains duplicates"]
    if documented != set(accepted):
        return ["cargo-about accepted license IDs differ from the maintained security policy"]
    if any(
        configuration.get(field) is not False
        for field in (
            "ignore-build-dependencies",
            "ignore-dev-dependencies",
            "ignore-transitive-dependencies",
        )
    ):
        return ["cargo-about must include build, development, and transitive dependencies"]
    errors = _check_rust_target_scope(root, configuration)
    if errors:
        return errors
    return []


def _check_rust_target_scope(root: Path, configuration: dict[str, object]) -> list[str]:
    declared_targets = configuration.get("targets")
    if not isinstance(declared_targets, list) or not all(
        isinstance(target, str) and target for target in declared_targets
    ):
        return ["cargo-about desktop target list is invalid"]
    if len(declared_targets) != len(set(declared_targets)):
        return ["cargo-about desktop target list contains duplicates"]

    expected: set[str] = set()
    for platform, relative_path in RUST_PACKAGE_TARGET_MANIFESTS:
        manifest_path = root / relative_path
        if not manifest_path.is_file():
            return [f"missing Rust package target manifest: {relative_path.as_posix()}"]
        try:
            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return [f"invalid Rust package target manifest: {relative_path.as_posix()}"]
        if not isinstance(payload, dict) or payload.get("platform") != platform:
            return [f"Rust package target manifest has the wrong platform: {relative_path.as_posix()}"]
        for component in RUST_PACKAGE_COMPONENTS:
            component_config = payload.get(component)
            target = component_config.get("target") if isinstance(component_config, dict) else None
            if not isinstance(target, str) or target not in RUST_PACKAGE_TARGET_EXPANSIONS:
                return [f"Rust package target is missing or unmapped: {relative_path.as_posix()}"]
            expected.update(RUST_PACKAGE_TARGET_EXPANSIONS[target])

    if set(declared_targets) != expected:
        return ["cargo-about desktop targets differ from the packaged Rust target matrix"]
    return []


def check_license_policy(root: Path = REPO_ROOT) -> tuple[list[str], dict[str, object]]:
    errors: list[str] = []
    evidence: dict[str, object] = {}
    pubspec_path = root / PUBSPEC_PATH
    if not pubspec_path.is_file():
        return [f"missing pubspec: {PUBSPEC_PATH.as_posix()}"], evidence

    packages, local_paths = parse_pubspec_dependencies(pubspec_path)
    extra = sorted(packages - ALLOWED_EXTERNAL_DART_PACKAGES - FIRST_PARTY_DART_PACKAGE_PATHS.keys())
    if extra:
        errors.append("pubspec contains packages outside license allowlist: " + ", ".join(extra))
    for package, expected_path in FIRST_PARTY_DART_PACKAGE_PATHS.items():
        if package not in packages:
            continue
        if local_paths.get(package) != expected_path:
            errors.append(f"first-party package `{package}` must use repository path `{expected_path}`")
            continue
        if not (pubspec_path.parent / expected_path / "pubspec.yaml").resolve().is_file():
            errors.append(f"first-party package `{package}` is missing its repository pubspec")

    third_party = root / THIRD_PARTY_PATH
    if not third_party.is_file():
        errors.append(f"missing {THIRD_PARTY_PATH.as_posix()}")

    dependency_usage = root / DEPENDENCY_USAGE_PATH
    if not dependency_usage.is_file():
        errors.append(f"missing {DEPENDENCY_USAGE_PATH.as_posix()}")

    for path in (third_party, dependency_usage):
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        for marker in FORBIDDEN_LICENSE_MARKERS:
            if marker in text:
                errors.append(f"{path.relative_to(root).as_posix()}: forbidden license marker `{marker}`")

    errors.extend(_check_rust_license_allowlist(root))

    if not errors:
        output = root / "build/evidence/rust-third-party-notices.txt"
        generator_errors = _rust_notice_generator(root, output)
        errors.extend(generator_errors)
        if not generator_errors:
            evidence["rust_notices"] = output.relative_to(root).as_posix()

    return errors, evidence


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Check product dependency licenses and generate Rust notices.")
    parser.add_argument("--json", action="store_true", help="Emit JSON.")
    args = parser.parse_args(argv)
    errors, evidence = check_license_policy()
    if args.json:
        print(json.dumps({"ok": not errors, "errors": errors, "evidence": evidence}, indent=2, sort_keys=True))
    elif errors:
        print("[license-policy] FAILED", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
    else:
        print("[license-policy] OK")
        print(f"[license-policy] Rust notices: {evidence['rust_notices']}")
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
