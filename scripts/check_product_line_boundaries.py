#!/usr/bin/env python3
"""Validate permanent Vityo product dependency boundaries."""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
IDE = ROOT / "products" / "vityo_app"
AGENT = ROOT / "products" / "vityo_coding_agent"
PROTOCOL = ROOT / "packages" / "vityo_agent_protocol"


def dart_sources(root: pathlib.Path) -> list[pathlib.Path]:
    return sorted(path for path in root.rglob("*.dart") if "build" not in path.parts)


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)


def dart_package_metadata(root: pathlib.Path) -> str:
    return (root / "pubspec.yaml").read_text(encoding="utf-8")


def rust_package_metadata(root: pathlib.Path) -> str:
    return (root / "Cargo.toml").read_text(encoding="utf-8")


def main() -> int:
    errors = 0
    for root in (IDE, PROTOCOL):
        if not (root / "pubspec.yaml").is_file():
            fail(f"missing package metadata: {root.relative_to(ROOT)}")
            errors += 1
    if not (AGENT / "Cargo.toml").is_file():
        fail(f"missing Rust package metadata: {AGENT.relative_to(ROOT)}")
        errors += 1

    forbidden = (
        (IDE, re.compile(r"package:vityo_coding_agent/"), "IDE imports Coding Agent"),
        (PROTOCOL, re.compile(r"package:(?:flutter|vityo_app|vityo_coding_agent)/"),
         "protocol imports a product or presentation framework"),
    )
    for root, pattern, label in forbidden:
        for path in dart_sources(root):
            if pattern.search(path.read_text(encoding="utf-8")):
                fail(f"{label}: {path.relative_to(ROOT)}")
                errors += 1

    metadata_rules = (
        (IDE, re.compile(r"(?m)^\s+vityo_coding_agent\s*:"), "IDE depends on Coding Agent"),
        (
            PROTOCOL,
            re.compile(r"(?m)^\s+(?:flutter|vityo_app|vityo_coding_agent)\s*:"),
            "protocol has a product or presentation dependency",
        ),
    )
    for root, pattern, label in metadata_rules:
        if pattern.search(dart_package_metadata(root)):
            fail(f"{label}: {root.relative_to(ROOT) / 'pubspec.yaml'}")
            errors += 1

    agent_cargo = (
        rust_package_metadata(AGENT) if (AGENT / "Cargo.toml").is_file() else ""
    )
    if re.search(r"(?m)^\s*(?:flutter|vityo_app|vityo_agent_protocol)\s*=", agent_cargo):
        fail("Coding Agent has a forbidden product or UI dependency")
        errors += 1
    if 'agent-client-protocol = ' not in agent_cargo:
        fail("Coding Agent does not consume the standard Rust ACP package")
        errors += 1

    if "vityo_agent_protocol:" not in dart_package_metadata(IDE):
        fail("IDE does not consume the shared protocol package")
        errors += 1

    if errors:
        return 1
    print("OK: Vityo product-line dependency boundaries are valid.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
