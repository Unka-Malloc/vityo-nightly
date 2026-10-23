#!/usr/bin/env python3
"""Dependency Policy Gate — enforce that dependency manifests are registered in DEPENDENCY-USAGE.md.

Usage:
    python3 scripts/dependency-policy-gate.py              # check mode (default)
    python3 scripts/dependency-policy-gate.py --json       # machine-readable JSON output
    python3 scripts/dependency-policy-gate.py --help       # show help

Exit codes:
    0 — all dependencies registered
    1 — one or more unregistered dependencies found
    2 — configuration or parse error
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBSPEC_PATH = Path("products/vityo_app/pubspec.yaml")
PACKAGE_JSON_PATH = Path("prototype/package.json")
POLICY_PATH = Path("DEPENDENCY-USAGE.md")
RUST_MANIFEST_PATHS = (
    Path("products/vityo_coding_agent/Cargo.toml"),
    Path("products/vityo_app/native/vityod/Cargo.toml"),
)


class DependencyPolicyError(RuntimeError):
    """A dependency manifest cannot be reliably inventoried."""


def resolve_path(root: Path, path: Path) -> Path:
    return path if path.is_absolute() else root / path


def display_path(root: Path, path: Path) -> str:
    """Return a repository-relative path without exposing checkout locations."""
    if not path.is_absolute():
        return path.as_posix()
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.name

# Dependencies that are part of the Flutter/Dart SDK — always allowed without explicit registration.
SDK_DEPENDENCIES = {
    "flutter",
    "flutter_test",
    "flutter_driver",
    "flutter_web_plugins",
    "flutter_plugin_android_lifecycle",
    "dart",
    "meta",
    "collection",
    "async",
    "convert",
    "typed_data",
    "vector_math",
    "sky_engine",
    "characters",
    "material_color_utilities",
}


def parse_pubspec_dependencies(path: Path) -> dict[str, list[str]]:
    """Parse pubspec.yaml and return {section: [package_names]}.

    Sections returned: 'dependencies', 'dev_dependencies'.
    SDK dependencies (where version is omitted or 'sdk: flutter') are excluded.
    """
    if not path.exists():
        print("ERROR: products/vityo_app/pubspec.yaml is missing", file=sys.stderr)
        sys.exit(2)

    text = path.read_text(encoding="utf-8")
    result: dict[str, list[str]] = {"dependencies": [], "dev_dependencies": []}

    in_section = None
    for line in text.splitlines():
        stripped = line.strip()
        indent = len(line) - len(line.lstrip())

        # Only top-level keys (zero indent) switch sections.
        # Nested indented lines (2+ spaces) are package entries or their properties.
        if indent == 0:
            if stripped == "dependencies:":
                in_section = "dependencies"
                continue
            elif stripped == "dev_dependencies:":
                in_section = "dev_dependencies"
                continue
            elif stripped.startswith("flutter:") or stripped.startswith("environment:"):
                in_section = None
                continue

        if in_section is None:
            continue

        # Match package entries at indent level 2 (normal deps) or 4 (nested under a dep).
        # We only care about entries at indent 2 — indent 4 means a property of a parent entry.
        # Properties like "sdk: flutter" at indent 4 should NOT be treated as package names.
        if indent > 2:
            continue

        match = re.match(r"^\s{2}(\w[\w\d_]*)\s*:", line)
        if match:
            pkg = match.group(1)
            # Only include if the version is on the same line (not an SDK reference)
            rest = line[match.end():].strip()
            if rest and rest != "":
                # Has an inline version specifier
                result[in_section].append(pkg)
            # If no inline version, it might be an SDK dep (e.g. "flutter:\n    sdk: flutter") — skip

    return result


def parse_cargo_workspace_dependencies(
    root: Path,
    manifest_paths: tuple[Path, ...] = RUST_MANIFEST_PATHS,
) -> dict[str, list[dict[str, str | None]]]:
    """Return external direct Cargo deps from each workspace's Cargo metadata.

    Cargo expands `workspace = true` entries and reports package names separately
    from renamed dependency keys. `--no-deps` keeps this inventory focused on
    declared direct dependencies while covering all workspace members, targets,
    build dependencies, and development dependencies without fetching crates.
    Repository path dependencies are first-party and stay outside the third-party
    inventory.
    """
    result: dict[str, list[dict[str, str | None]]] = {}
    for manifest in manifest_paths:
        manifest_path = resolve_path(root, manifest)
        manifest_label = display_path(root, manifest_path)
        if not manifest_path.is_file():
            raise DependencyPolicyError(
                f"Cargo workspace manifest is missing: {manifest_label}"
            )
        try:
            completed = subprocess.run(
                [
                    "cargo",
                    "metadata",
                    "--no-deps",
                    "--format-version",
                    "1",
                    "--manifest-path",
                    str(manifest_path),
                ],
                cwd=root,
                capture_output=True,
                text=True,
                check=False,
            )
        except FileNotFoundError as exc:
            raise DependencyPolicyError("Cargo is required to inventory Rust dependencies") from exc
        if completed.returncode != 0:
            # Cargo diagnostics may contain absolute workspace or user paths.
            # Report the owned manifest and exit status without echoing them.
            raise DependencyPolicyError(
                f"Cargo metadata failed for {manifest_label} (exit {completed.returncode})"
            )
        try:
            metadata = json.loads(completed.stdout)
        except json.JSONDecodeError as exc:
            raise DependencyPolicyError(
                f"Cargo metadata returned invalid JSON for {manifest_label}"
            ) from exc
        packages = metadata.get("packages") if isinstance(metadata, dict) else None
        if not isinstance(packages, list):
            raise DependencyPolicyError(
                f"Cargo metadata has no package inventory for {manifest_label}"
            )
        for package in packages:
            if not isinstance(package, dict) or not isinstance(package.get("dependencies"), list):
                raise DependencyPolicyError(
                    f"Cargo metadata has an invalid package entry for {manifest_label}"
                )
            package_name = package.get("name")
            if not isinstance(package_name, str) or not package_name:
                raise DependencyPolicyError(
                    f"Cargo metadata has an unnamed package for {manifest_label}"
                )
            for dependency in package["dependencies"]:
                if not isinstance(dependency, dict):
                    raise DependencyPolicyError(
                        f"Cargo metadata has an invalid dependency in {manifest_label}"
                    )
                # Cargo metadata uses a null source for repository/workspace path
                # dependencies. They are governed by architecture and licensing
                # rules for first-party code, not third-party package registration.
                if dependency.get("source") is None:
                    continue
                name = dependency.get("name")
                if not isinstance(name, str) or not name:
                    raise DependencyPolicyError(
                        f"Cargo metadata has an unnamed dependency in {manifest_label}"
                    )
                kind = dependency.get("kind")
                if kind not in (None, "dev", "build"):
                    raise DependencyPolicyError(
                        f"Cargo metadata has an unknown dependency kind in {manifest_label}"
                    )
                result.setdefault(name, []).append(
                    {
                        "ecosystem": "cargo",
                        "section": {
                            None: "dependencies",
                            "dev": "dev-dependencies",
                            "build": "build-dependencies",
                        }[kind],
                        "owner": package_name,
                        "alias": dependency.get("rename"),
                        "target": dependency.get("target"),
                        "requirement": dependency.get("req"),
                        "manifest": manifest_label,
                    }
                )
    return result


def parse_policy_registered_deps(path: Path) -> set[str]:
    """Parse DEPENDENCY-USAGE.md and extract all registered package names from markdown tables."""
    if not path.exists():
        print("ERROR: DEPENDENCY-USAGE.md is missing", file=sys.stderr)
        sys.exit(2)

    text = path.read_text(encoding="utf-8")
    registered = set()

    # Find table rows with backtick-quoted package names: | `package_name` | ...
    # Pattern matches the first column of a markdown table row containing a backtick-quoted name
    for line in text.splitlines():
        match = re.match(r"^\|\s*`([^`]+)`\s*\|", line)
        if match:
            name = match.group(1)
            # Skip header rows and placeholder entries
            if name.lower() in ("dependency", "---", "", "flutter (sdk)", "flutter_test (sdk)"):
                continue
            registered.add(name)

    return registered


def parse_package_json_dependencies(path: Path) -> dict[str, list[str]]:
    """Parse package.json and return dependency names by npm dependency section."""
    if not path.exists():
        return {}

    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"ERROR: invalid package.json: {exc}", file=sys.stderr)
        sys.exit(2)
    if not isinstance(payload, dict):
        print("ERROR: package.json root must be an object", file=sys.stderr)
        sys.exit(2)

    result: dict[str, list[str]] = {}
    for section in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies"):
        raw = payload.get(section, {})
        if raw is None:
            continue
        if not isinstance(raw, dict):
            print(f"ERROR: package.json `{section}` must be an object", file=sys.stderr)
            sys.exit(2)
        result[section] = sorted(name for name in raw if isinstance(name, str) and name)
    return result


def run_gate(
    json_output: bool = False,
    root: Path = ROOT,
    rust_manifest_paths: tuple[Path, ...] = RUST_MANIFEST_PATHS,
) -> tuple[bool, list[str], list[str], list[dict]]:
    """Run the dependency policy gate.

    Returns: (passed, registered, unregistered, details_for_json)
    """
    pubspec = parse_pubspec_dependencies(resolve_path(root, PUBSPEC_PATH))
    package_json = parse_package_json_dependencies(resolve_path(root, PACKAGE_JSON_PATH))
    policy = parse_policy_registered_deps(resolve_path(root, POLICY_PATH))
    cargo_deps = parse_cargo_workspace_dependencies(root, rust_manifest_paths)

    dart_deps = set(pubspec.get("dependencies", [])) | set(pubspec.get("dev_dependencies", []))
    npm_deps = {pkg for names in package_json.values() for pkg in names}
    all_deps = dart_deps | npm_deps | set(cargo_deps)
    registered_deps = sorted(all_deps & policy)
    unregistered_deps = sorted(all_deps - policy - SDK_DEPENDENCIES)
    sdk_deps_seen = sorted(dart_deps & SDK_DEPENDENCIES)

    passed = len(unregistered_deps) == 0

    details = [
        {
            "status": "registered",
            "package": p,
            "section": _find_section(p, pubspec, package_json, cargo_deps),
            "declarations": cargo_deps.get(p, []),
        }
        for p in registered_deps
    ] + [
        {
            "status": "unregistered",
            "package": p,
            "section": _find_section(p, pubspec, package_json, cargo_deps),
            "declarations": cargo_deps.get(p, []),
        }
        for p in unregistered_deps
    ] + [
        {
            "status": "sdk_exempt",
            "package": p,
            "section": _find_section(p, pubspec, package_json, cargo_deps),
            "declarations": cargo_deps.get(p, []),
        }
        for p in sdk_deps_seen
    ]

    if json_output:
        output = {
            "gate": "dependency-policy",
            "passed": passed,
            "pubspec_path": PUBSPEC_PATH.as_posix(),
            "package_json_path": PACKAGE_JSON_PATH.as_posix(),
            "cargo_manifest_paths": [display_path(root, path) for path in rust_manifest_paths],
            "policy_path": POLICY_PATH.as_posix(),
            "total_dependencies": len(all_deps),
            "registered": len(registered_deps),
            "unregistered": len(unregistered_deps),
            "sdk_exempt": len(sdk_deps_seen),
            "details": sorted(details, key=lambda d: d["package"]),
        }
        print(json.dumps(output, indent=2))
    else:
        print(f"[dependency-policy-gate] pubspec: {PUBSPEC_PATH.as_posix()}")
        print(f"[dependency-policy-gate] package.json: {PACKAGE_JSON_PATH.as_posix()}")
        for manifest in rust_manifest_paths:
            print(f"[dependency-policy-gate] cargo: {display_path(root, manifest)}")
        print(f"[dependency-policy-gate] policy:  {POLICY_PATH.as_posix()}")
        print(f"[dependency-policy-gate] total dependencies found: {len(all_deps)}")
        print(f"[dependency-policy-gate] registered: {len(registered_deps)}")
        if registered_deps:
            for p in registered_deps:
                print(f"  + {p}")
        print(f"[dependency-policy-gate] sdk/exempt: {len(sdk_deps_seen)}")
        if sdk_deps_seen:
            for p in sdk_deps_seen:
                print(f"  - {p} (SDK)")
        print(f"[dependency-policy-gate] unregistered: {len(unregistered_deps)}")
        if unregistered_deps:
            for p in unregistered_deps:
                print(f"  ! {p} - NOT in DEPENDENCY-USAGE.md")
        print(f"[dependency-policy-gate] result: {'PASS' if passed else 'FAIL'}")

    return passed, registered_deps, unregistered_deps, details


def _find_section(
    pkg: str,
    pubspec: dict[str, list[str]],
    package_json: dict[str, list[str]],
    cargo_deps: dict[str, list[dict[str, str | None]]],
) -> str:
    if pkg in pubspec.get("dependencies", []):
        return "pubspec.dependencies"
    if pkg in pubspec.get("dev_dependencies", []):
        return "pubspec.dev_dependencies"
    for section, names in package_json.items():
        if pkg in names:
            return f"package.json.{section}"
    declarations = cargo_deps.get(pkg, [])
    if declarations:
        return "cargo." + ",".join(sorted({str(item["section"]) for item in declarations}))
    return "unknown"


def main():
    parser = argparse.ArgumentParser(description="Dependency Policy Gate")
    parser.add_argument("--json", action="store_true", help="Output machine-readable JSON")
    args = parser.parse_args()

    try:
        passed, _, unregistered, _ = run_gate(json_output=args.json)
    except DependencyPolicyError as exc:
        print(f"[dependency-policy-gate] ERROR: {exc}", file=sys.stderr)
        sys.exit(2)

    if not passed:
        print(
            "\nAction: Add the unregistered dependencies above to DEPENDENCY-USAGE.md "
            "with license evidence, source boundary, and usage boundary.",
            file=sys.stderr,
        )
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
