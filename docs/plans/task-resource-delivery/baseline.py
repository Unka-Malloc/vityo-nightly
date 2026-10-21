#!/usr/bin/env python3
"""Retain private current-input and build evidence for the registered host check."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import traceback
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
APP = ROOT / "products/vityo_app"
TARGET = APP / "native/vityod/target"
EVIDENCE = ROOT / "build/task-resource-baseline"
SELECTED = {
    "styio": ROOT.parent / "styio-nightly/build/default/bin/styio",
    "styio_lspd": ROOT.parent / "styio-nightly/build/default/bin/styio_lspd",
    "pafio": ROOT.parent / "pafio-nightly/build-codex/bin/pafio",
}


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def file_identity(path: Path) -> dict:
    identity = {"path": str(path), "exists": path.is_file()}
    if path.is_file():
        stat = path.stat()
        identity.update(resolved_path=str(path.resolve()), size=stat.st_size,
                        mtime_ns=stat.st_mtime_ns,
                        executable=os.access(path, os.X_OK))
    return identity


def record_source(repo: Path, destination: Path) -> dict:
    destination.mkdir()

    def git(*args: str) -> bytes:
        return subprocess.check_output(["git", "-C", str(repo), *args])

    revision = git("rev-parse", "HEAD").decode().strip()
    (destination / "status.z").write_bytes(git("status", "--porcelain=v1", "-z"))
    return {"root": str(repo), "revision": revision,
            "dirty_inputs": str(destination),
            "identity_note": "Revision plus dirty status; accepted sibling handoffs own build provenance."}


def run_step(step: dict, directory: Path, environment: dict) -> int:
    """Wait for actual completion; output volume and silence never kill a build."""
    step["started_at"] = datetime.now(timezone.utc).isoformat()
    with (directory / f"{step['name']}.stdout.log").open("wb") as stdout, \
            (directory / f"{step['name']}.stderr.log").open("wb") as stderr:
        try:
            result = subprocess.run(step["argv"], cwd=step["cwd"], env=environment,
                                    stdout=stdout, stderr=stderr, check=False)
            step.update(outcome="executed", exit_code=result.returncode)
        except OSError as error:
            stderr.write(str(error).encode())
            step.update(outcome="launch-failed", exit_code=None)
    step["finished_at"] = datetime.now(timezone.utc).isoformat()
    write_json(directory / f"{step['name']}.json", step)
    return step["exit_code"] if step["exit_code"] is not None else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true",
                        help="Record inputs only; do not execute tools or build commands.")
    args = parser.parse_args()
    os.umask(0o077)
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    kind = "preparation" if args.prepare_only else "host"
    directory = Path(tempfile.mkdtemp(prefix=f"{kind}-", dir=EVIDENCE))
    record = {"kind": kind, "recorded_at": datetime.now(timezone.utc).isoformat(),
              "host_build_result": "not yet observed", "exit_code": None,
              "skips": [], "steps": []}
    exit_code = 1
    try:
        subprocess.run(["git", "check-ignore", "-q", str(directory)],
                       cwd=ROOT, check=True)
        record["sources"] = {
            name: record_source(repo, directory / name)
            for name, repo in {"vityo": ROOT, "styio": ROOT.parent / "styio-nightly",
                               "pafio": ROOT.parent / "pafio-nightly"}.items()
        }
        record["accepted_handoff_references"] = {
            "styio": "d0177d43181b49023dbbe65455c9e369",
            "pafio": "798ff72acf150dcfa0891999c7a18e53",
        }
        record["selected_executables"] = {name: file_identity(path)
                                           for name, path in SELECTED.items()}
        record["configuration"] = {
            "platform": sys.platform, "architecture": platform.machine(),
            "python": sys.version, "daemon_profile": "debug", "app_profile": "macos debug",
            "cargo_target_dir": str(TARGET),
            "inherited_build_overrides": {key: os.environ[key] for key in (
                "CARGO_TARGET_DIR", "CARGO_BUILD_TARGET", "RUSTUP_TOOLCHAIN", "RUSTFLAGS",
                "DEVELOPER_DIR", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET") if key in os.environ},
            "tools": {name: shutil.which(name) for name in ("cargo", "rustc", "flutter", "xcodebuild")},
        }
        environment = {**os.environ, "CARGO_TARGET_DIR": str(TARGET)}
        commands = [
            ("cargo-version", ["cargo", "--version"], ROOT),
            ("rustc-version", ["rustc", "--version"], ROOT),
            ("flutter-version", ["flutter", "--version", "--machine"], APP),
            ("xcode-version", ["xcodebuild", "-version"], ROOT),
            ("vityod-build", ["cargo", "build", "--locked", "--manifest-path",
                              "products/vityo_app/native/vityod/Cargo.toml", "--bin", "vityod"], ROOT),
            ("flutter-pub-get", ["flutter", "pub", "get"], APP),
            ("macos-debug-build", ["flutter", "build", "macos", "--debug"], APP),
        ]
        record["steps"] = [{"name": name, "argv": argv, "cwd": str(cwd),
                            "outcome": "not executed", "exit_code": None}
                           for name, argv, cwd in commands]
        missing = [name for name, value in record["selected_executables"].items()
                   if not value.get("executable")]
        missing += [name for name, path in record["configuration"]["tools"].items() if not path]
        record["preparation_errors"] = (["macOS host required"] if sys.platform != "darwin" else [])
        record["preparation_errors"] += [f"missing executable: {name}" for name in missing]
        # The Xcode staging phase expects target/debug/vityod, without a target triple.
        if os.environ.get("CARGO_BUILD_TARGET"):
            record["preparation_errors"].append("CARGO_BUILD_TARGET conflicts with native macOS staging")
        if record["preparation_errors"]:
            record["host_build_result"] = "not executed: preparation failed"
        elif args.prepare_only:
            exit_code = 0
        else:
            exit_code = 0
            for step in record["steps"]:
                exit_code = run_step(step, directory, environment)
                write_json(directory / "evidence.json", record)
                print(f"baseline {step['name']}: {step['outcome']}; exit={step['exit_code']}", flush=True)
                if exit_code != 0:
                    break
            record["host_build_result"] = "failed" if exit_code else "commands succeeded"
            # Dependency restoration can change tracked inputs; retain that evidence too.
            for name, arguments in (("post-build-status.z", ["status", "--porcelain=v1", "-z"]),):
                (directory / name).write_bytes(subprocess.check_output(["git", *arguments], cwd=ROOT))
            if exit_code == 0:
                bundle = APP / "build/macos/Build/Products/Debug/Vityo.app/Contents"
                record["outputs"] = {
                    name: file_identity(path) for name, path in {
                        "vityod": TARGET / "debug/vityod",
                        "application": bundle / "MacOS/Vityo",
                        "bundled_vityod": bundle / "Helpers/vityod",
                    }.items()
                }
                if not all(value.get("executable") for value in record["outputs"].values()):
                    record["host_build_result"] = "failed: expected build output missing"
                    exit_code = 1
    except Exception:
        (directory / "preparation-error.log").write_text(traceback.format_exc(), encoding="utf-8")
        record["host_build_result"] = "not established: evidence or preparation error"
        exit_code = 1
    finally:
        record["exit_code"] = exit_code
        write_json(directory / "evidence.json", record)
        write_json(EVIDENCE / f"latest-{kind}.json", {"evidence": str(directory / "evidence.json")})
    print(f"baseline evidence: {directory.relative_to(ROOT)}; exit={exit_code}", flush=True)
    return exit_code if exit_code >= 0 else 128 - exit_code


if __name__ == "__main__":
    raise SystemExit(main())
