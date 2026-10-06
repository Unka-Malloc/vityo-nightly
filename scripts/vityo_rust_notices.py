#!/usr/bin/env python3
"""Generate a complete license notice from the locked Rust dependency graphs."""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
TOOL_VERSION = "0.9.2"
TOOL_ROOT = Path("build/tools/cargo-about-0.9.2")
CONFIG_PATH = Path("toolchain/licenses/about.toml")
TEMPLATE_PATH = Path("toolchain/licenses/third-party-notices.txt.hbs")
OUTPUT_PATH = Path("build/evidence/rust-third-party-notices.txt")
WORKSPACES = (
    ("Coding Agent", Path("products/vityo_coding_agent/Cargo.toml")),
    ("vityod", Path("products/vityo_app/native/vityod/Cargo.toml")),
)


class RustNoticeError(RuntimeError):
    """A locked Rust license graph or notice could not be produced."""


def _cargo_about_binary(root: Path) -> Path:
    executable = "cargo-about.exe" if os.name == "nt" else "cargo-about"
    tool = root / TOOL_ROOT / "bin" / executable
    if tool.is_file():
        try:
            version = subprocess.run(
                [str(tool), "--version"],
                cwd=root,
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError as exc:
            raise RustNoticeError("Unable to inspect the pinned Cargo notice tool") from exc
        if version.returncode == 0 and version.stdout.strip().split()[-1:] == [TOOL_VERSION]:
            return tool
        try:
            tool.unlink()
        except OSError as exc:
            raise RustNoticeError("Unable to replace the stale pinned Cargo notice tool") from exc

    cargo_root = root / TOOL_ROOT
    try:
        cargo_root.mkdir(parents=True, exist_ok=True)
        installed = subprocess.run(
            [
                "cargo",
                "install",
                "--locked",
                "--version",
                TOOL_VERSION,
                "--features",
                "cli",
                "--root",
                str(cargo_root),
                "cargo-about",
            ],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError as exc:
        raise RustNoticeError("Cargo is required to install the pinned Cargo notice tool") from exc
    except OSError as exc:
        raise RustNoticeError("Unable to install the pinned Cargo notice tool") from exc
    if installed.returncode != 0:
        raise RustNoticeError(f"Unable to install cargo-about {TOOL_VERSION} (exit {installed.returncode})")
    if not tool.is_file():
        raise RustNoticeError(f"cargo-about {TOOL_VERSION} installation produced no executable")
    return tool


def _generate_workspace_notice(
    root: Path,
    tool: Path,
    label: str,
    manifest: Path,
    output: Path,
) -> str:
    manifest_path = root / manifest
    if not manifest_path.is_file():
        raise RustNoticeError(f"Missing Rust notice workspace: {manifest.as_posix()}")
    if not (manifest_path.parent / "Cargo.lock").is_file():
        raise RustNoticeError(f"Missing Cargo.lock for `{manifest.as_posix()}`")
    if not (root / CONFIG_PATH).is_file() or not (root / TEMPLATE_PATH).is_file():
        raise RustNoticeError("Cargo notice configuration or template is missing")

    command = [
        str(tool),
        "generate",
        "--workspace",
        "--fail",
        "--locked",
        "--manifest-path",
        manifest.as_posix(),
        "--config",
        CONFIG_PATH.as_posix(),
        "--output-file",
        str(output),
        TEMPLATE_PATH.as_posix(),
    ]
    try:
        result = subprocess.run(
            command,
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        raise RustNoticeError(f"Unable to run cargo-about for `{label}`") from exc
    if result.returncode != 0:
        raise RustNoticeError(f"cargo-about could not resolve the `{label}` locked license graph")
    try:
        text = output.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise RustNoticeError(f"cargo-about did not produce UTF-8 notices for `{label}`") from exc
    if not text.strip():
        raise RustNoticeError(f"cargo-about produced an empty notice for `{label}`")
    return text.strip()


def generate_notices(root: Path = REPO_ROOT, output: Path = OUTPUT_PATH) -> Path:
    """Check both Cargo graphs and atomically write their UTF-8 license notices."""
    destination = output if output.is_absolute() else root / output
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        tool = _cargo_about_binary(root)
        with tempfile.TemporaryDirectory(prefix=".rust-notices-", dir=destination.parent) as temporary:
            temporary_root = Path(temporary)
            sections: list[str] = []
            for index, (label, manifest) in enumerate(WORKSPACES):
                temporary_output = temporary_root / f"workspace-{index}.txt"
                text = _generate_workspace_notice(root, tool, label, manifest, temporary_output)
                sections.append(f"{label}\n{'=' * len(label)}\n\n{text}")
            combined = "\n\n".join(sections).rstrip() + "\n"
            temporary_notice = temporary_root / "rust-third-party-notices.txt"
            temporary_notice.write_text(combined, encoding="utf-8", newline="\n")
            temporary_notice.replace(destination)
    except OSError as exc:
        raise RustNoticeError("Unable to write the Rust third-party notices") from exc
    return destination


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Check locked Rust licenses and generate third-party notices.")
    parser.add_argument(
        "--output",
        type=Path,
        default=OUTPUT_PATH,
        help="Output path relative to the repository root.",
    )
    args = parser.parse_args(argv)
    try:
        output = generate_notices(output=args.output)
    except RustNoticeError as exc:
        print(f"[rust-notices] FAILED: {exc}", file=sys.stderr)
        return 1
    try:
        output_label = output.resolve().relative_to(REPO_ROOT.resolve()).as_posix()
    except ValueError:
        output_label = output.name
    print(f"[rust-notices] OK: {output_label}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
