from __future__ import annotations

import pathlib
import re
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[3]
IDE = ROOT / "products" / "vityo_app"
AGENT = ROOT / "products" / "vityo_coding_agent"
PROTOCOL = ROOT / "packages" / "vityo_agent_protocol"


def _pubspec_name(package: pathlib.Path) -> str:
    match = re.search(
        r"(?m)^name:\s*([a-z][a-z0-9_]*)\s*$",
        (package / "pubspec.yaml").read_text(encoding="utf-8"),
    )
    assert match is not None, f"missing package name in {package}"
    return match.group(1)


def _cargo_package_name(package: pathlib.Path) -> str:
    text = (package / "Cargo.toml").read_text(encoding="utf-8")
    section = re.search(r"(?ms)^\[package\]\s*(.*?)(?=^\[|\Z)", text)
    assert section is not None, f"missing Cargo package section in {package}"
    match = re.search(r'(?m)^name\s*=\s*"([a-z][a-z0-9-]*)"\s*$', section.group(1))
    assert match is not None, f"missing Cargo package name in {package}"
    return match.group(1)


def test_product_line_boundary_gate() -> None:
    result = subprocess.run(
        [sys.executable, "scripts/check_product_line_boundaries.py"],
        cwd=ROOT,
        check=False,
    )
    assert result.returncode == 0


def test_final_product_metadata_has_one_canonical_identity_per_line() -> None:
    assert _pubspec_name(IDE) == "vityo_app"
    assert _cargo_package_name(AGENT) == "vityo-coding-agent"
    assert _pubspec_name(PROTOCOL) == "vityo_agent_protocol"


def test_ide_package_does_not_link_the_coding_agent_runtime() -> None:
    pubspec = (IDE / "pubspec.yaml").read_text(encoding="utf-8")
    assert "vityo_coding_agent" not in pubspec
    dart_sources = [
        path
        for path in (IDE / "lib").rglob("*.dart")
        if "build" not in path.parts
    ]
    assert not any(
        "package:vityo_coding_agent/" in path.read_text(encoding="utf-8")
        for path in dart_sources
    )


def main() -> None:
    checks = (
        test_product_line_boundary_gate,
        test_final_product_metadata_has_one_canonical_identity_per_line,
        test_ide_package_does_not_link_the_coding_agent_runtime,
    )
    for check in checks:
        check()
    print(f"cutover acceptance: {len(checks)} passed")


if __name__ == "__main__":
    main()
