#!/usr/bin/env python3
"""Retain HOST checks and execute the explicitly selected remaining local stage."""

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
from pathlib import Path

from baseline import ROOT, APP, file_identity, write_json

sys.path.insert(0, str(ROOT / "scripts"))
from vityo_check_log import run_logged

EVIDENCE = ROOT / "build/task-resource-final"
LOCAL_ONLY = ("CI", "GITHUB_ACTIONS", "VITYO_PRODUCT_GATE")
# A completed-step token reuses one retained exit-0 command record from this
# milestone's ignored host directories instead of re-executing that step.
# token -> (stage label, logged executable basename, logged argv tail)
COMPLETED_STEPS = {
    "rust-coverage-tools": ("prepare pinned Rust coverage tools", "rustup",
                            ("component", "add", "llvm-tools-preview")),
    "flutter-analysis": ("Flutter analysis", "flutter", ("analyze",)),
}
ENVIRONMENT_KEYS = (
    *LOCAL_ONLY, "CARGO_TARGET_DIR", "CARGO_BUILD_TARGET", "RUSTUP_TOOLCHAIN",
    "RUSTFLAGS", "LLVM_PROFILE_FILE", "DEVELOPER_DIR", "SDKROOT",
    "MACOSX_DEPLOYMENT_TARGET", "VITYO_CHROME_PATH", "COVERAGE_FILE", "COVERAGE_RCFILE",
)


OPEN_FILE_FLOOR = 10240


def raise_open_file_floor(minimum: int = OPEN_FILE_FLOOR) -> None:
    """Raise the soft descriptor limit for coverage-scale test runs.

    The complete Flutter coverage run spawns a development-service child per
    test suite; on hosts whose soft RLIMIT_NOFILE is the macOS default of 256
    the tool exhausts its table mid-run and stalls until killed. The raise is
    best-effort and never lowers or fails the process.
    """
    try:
        import resource
    except ImportError:
        return
    try:
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        if soft >= minimum:
            return
        target = minimum if hard == resource.RLIM_INFINITY else min(hard, minimum)
        if target <= soft:
            return
        resource.setrlimit(resource.RLIMIT_NOFILE, (target, hard))
    except (OSError, ValueError) as error:
        print(f"[vityo] could not raise open-file limit above {soft}: {error}", flush=True)
        return
    print(f"[vityo] raised open-file soft limit: {soft} -> {target}", flush=True)


def resolve_completed_steps(tokens) -> tuple[frozenset, list]:
    """Verify each completed step against retained host records; fail closed."""
    records = sorted(EVIDENCE.glob("host-*/commands/**/command.json"))
    labels: list[str] = []
    reused: list[dict] = []
    for token in tokens or ():
        label, executable, tail = COMPLETED_STEPS[token]
        newest = None
        for record_path in records:
            try:
                record = json.loads(record_path.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            argv = record.get("argv") or []
            if (record.get("exit_code") == 0 and len(argv) == len(tail) + 1
                    and Path(argv[0]).name == executable
                    and tuple(argv[1:]) == tail):
                if newest is None or record.get("finished_at", "") > newest[1].get("finished_at", ""):
                    newest = (record_path, record)
        if newest is None:
            raise RuntimeError(
                f"completed step '{token}' has no retained passing command record")
        record_path, record = newest
        labels.append(label)
        reused.append({"step": token, "label": label, "exit_code": 0,
                       "finished_at": record.get("finished_at"),
                       "command_record": str(record_path.relative_to(ROOT))})
    return frozenset(labels), reused


# An in-place selected executable may legitimately drift from the accepted
# integration stat through an authorized channel: this stage's own required
# cargo build relinks vityod, and an owning sibling's scoped final repair
# rebuilds its candidate. Drift is admitted only when a retained authorized
# record attests the exact current stat; unexplained drift still fails.
# name -> (records root or None for this milestone's own evidence, record
# filename, record key)
ATTESTED_RECORDS = {
    "styio": (ROOT.parent / "styio-nightly/build/task-resource-final",
              "executables-after-build.json", "build/default/bin/styio"),
    "styio_lspd": (ROOT.parent / "styio-nightly/build/task-resource-final",
                   "executables-after-build.json", "build/default/bin/styio_lspd"),
    "pafio": (ROOT.parent / "pafio-nightly/build-codex/task-resource-final",
              "selected-after.json", "pafio"),
    "vityod": (None, "selected-after.json", "vityod"),
}


def attested_input_stats(name: str) -> dict:
    """Return {(size, mtime_ns): record} stats authorized runs recorded."""
    stats = {}
    records_root, filename, key = ATTESTED_RECORDS[name]
    if records_root is None:
        records_root = EVIDENCE
    for record_path in sorted(records_root.glob(f"host-*/{filename}")):
        try:
            record = json.loads(record_path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        entry = record.get(key) or {}
        if entry.get("size") is not None and entry.get("mtime_ns") is not None:
            try:
                stats[(entry["size"], entry["mtime_ns"])] = str(
                    record_path.relative_to(ROOT))
            except ValueError:
                stats[(entry["size"], entry["mtime_ns"])] = str(record_path)
    return stats


def admit_selected(name: str, path: Path, accepted: dict) -> str:
    """Verify one in-place input against accepted or attested identity."""
    current = file_identity(path)
    basis = accepted[name]
    if not current.get("executable") or current.get("path") != basis["path"]:
        raise RuntimeError(f"Selected {name} is not the accepted integration input")
    if (current["size"], current["mtime_ns"]) == (basis["size"], basis["mtime_ns"]):
        return "accepted"
    record = attested_input_stats(name).get((current["size"], current["mtime_ns"]))
    if record is None:
        raise RuntimeError(
            f"Selected {name} differs from the accepted integration input "
            "and no authorized run record attests its current stat")
    return record


def run_remaining_local(args) -> int:
    """Post-admission continuation: run remaining commands, reusing verified passes."""
    from vityo import DeliveryOptions, _run_resolved_test_stage

    # This milestone admits only the coordinator's accepted, in-place inputs.
    # Normal delivery still resolves its pinned product-matrix toolchain.
    accepted = json.loads((ROOT / "build/resource-integration/host-gy1mv_16/inputs.json").read_text())
    selected = {
        "styio": args.styio_bin.resolve(), "pafio": args.pafio_bin.resolve(),
        "styio_lspd": ROOT.parent / "styio-nightly/build/default/bin/styio_lspd",
        "vityod": APP / "native/vityod/target/debug/vityod",
    }
    for name, path in selected.items():
        basis = admit_selected(name, path, accepted)
        if basis != "accepted":
            print(f"[vityo] admitted {name} on authorized record {basis}", flush=True)
    if any(key in os.environ for key in LOCAL_ONLY):
        raise RuntimeError("Remaining local checks require the isolated local environment")
    completed, _ = resolve_completed_steps(getattr(args, "completed", None))
    options = DeliveryOptions(mode="local", platform=args.platform,
                              styio_bin=str(selected["styio"]),
                              pafio_bin=str(selected["pafio"]),
                              evidence_dir=args.evidence_dir)
    def run_command(command, cwd, environment=None):
        return run_logged(command, cwd=cwd, environment=environment)

    return _run_resolved_test_stage(options, selected["styio"], runner=run_command,
                                    completed_steps=completed)


def record_inputs(directory: Path, selected: dict, environment: dict) -> None:
    inputs = directory / "inputs"
    inputs.mkdir()
    for name, arguments in (
        ("revision.txt", ["rev-parse", "HEAD"]),
        ("branch.txt", ["branch", "--show-current"]),
        ("status.z", ["status", "--porcelain=v1", "-z"]),
        ("tracked.patch", ["diff", "--binary", "HEAD"]),
    ):
        (inputs / name).write_bytes(subprocess.check_output(["git", *arguments], cwd=ROOT))
    untracked = subprocess.check_output(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=ROOT)
    (inputs / "untracked.z").write_bytes(untracked)
    for raw in untracked.split(b"\0"):
        if raw:
            relative = Path(os.fsdecode(raw))
            destination = inputs / "untracked" / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, destination)
    # Configuration is small, directly relevant and may be rewritten by tools.
    for relative in (
        "rust-toolchain.toml", ".cargo/config.toml", "toolchain/product-matrix.json",
        "products/vityo_app/.metadata", "products/vityo_app/pubspec.lock",
        "products/vityo_app/native/vityod/Cargo.lock",
        "products/vityo_coding_agent/Cargo.lock", "prototype/package-lock.json",
    ):
        source = ROOT / relative
        if source.is_file():
            destination = inputs / "configuration" / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
    write_json(inputs / "selected.json", {name: file_identity(path) for name, path in selected.items()})
    write_json(inputs / "environment.json", {
        "inherited": {key: os.environ[key] for key in ENVIRONMENT_KEYS if key in os.environ},
        "effective": {key: environment[key] for key in (*ENVIRONMENT_KEYS,
            "VITYO_STYIO_BIN", "VITYO_PAFIO_BIN", "VITYO_STYIO_LSPD_BIN")
            if key in environment},
        "removed_for_local_scope": list(LOCAL_ONLY),
        "host": {"platform": sys.platform, "architecture": platform.machine()},
        "interpreter": sys.executable,
        "tools": {name: shutil.which(name) for name in
                  ("python3", "flutter", "dart", "cargo", "rustc", "rustup", "cargo-llvm-cov", "node", "npm")},
        "accepted_e2e": "build/resource-integration/host-gy1mv_16/",
        "sibling_provenance": ["../styio-nightly/docs/plans/task-resource-delivery/HANDOFF.md",
                               "../pafio-nightly/docs/plans/task-resource-delivery/HANDOFF.md"],
    })


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true")
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--remaining-local", action="store_true",
                           help="Retain the post-admission continuation; no local test ran in the first HOST attempt.")
    selection.add_argument("--execute-local", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--completed", action="append", choices=tuple(COMPLETED_STEPS),
                        default=[], metavar="STEP",
                        help="Reuse this retained exit-0 step instead of re-executing it.")
    parser.add_argument("--evidence-dir", type=Path)
    parser.add_argument("--platform", required=True, choices=("macos", "linux", "windows"))
    parser.add_argument("--styio-bin", type=Path, required=True)
    parser.add_argument("--pafio-bin", type=Path, required=True)
    args = parser.parse_args()
    if args.completed and not (args.remaining_local or args.execute_local):
        parser.error("--completed requires --remaining-local or --execute-local")
    os.umask(0o077)
    raise_open_file_floor()
    if args.execute_local:
        if args.evidence_dir is None:
            parser.error("--execute-local requires --evidence-dir")
        return run_remaining_local(args)
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    kind = "preparation" if args.prepare_only else "host"
    directory = Path(tempfile.mkdtemp(prefix=f"{kind}-", dir=EVIDENCE))
    record = {"kind": kind, "process_exit_code": None, "check_exit_code": None,
              "execution": "not executed", "child_skips": None}
    write_json(EVIDENCE / f"latest-{kind}.json", {"evidence": str(directory / "evidence.json")})
    selected = {
        "styio": args.styio_bin.resolve(), "pafio": args.pafio_bin.resolve(),
        "styio_lspd": ROOT.parent / "styio-nightly/build/default/bin/styio_lspd",
        "vityod": APP / "native/vityod/target/debug/vityod",
    }
    environment = dict(os.environ)
    for key in LOCAL_ONLY:
        environment.pop(key, None)
    environment.update({
        "VITYO_CHECK_LOG_DIR": str(directory / "commands"),
        "VITYO_STYIO_BIN": str(selected["styio"]),
        "VITYO_PAFIO_BIN": str(selected["pafio"]),
        "VITYO_STYIO_LSPD_BIN": str(selected["styio_lspd"]),
    })
    command = [sys.executable, "scripts/vityo.py", "test", "--mode", "local",
               "--platform", args.platform, "--styio-bin", str(selected["styio"]),
               "--pafio-bin", str(selected["pafio"]), "--evidence-dir",
               str(directory / "reports")]
    if args.remaining_local:
        command = [sys.executable, "docs/plans/task-resource-delivery/final.py", "--execute-local",
                   "--platform", args.platform, "--styio-bin", str(selected["styio"]),
                   "--pafio-bin", str(selected["pafio"]), "--evidence-dir", str(directory / "reports")]
        for token in args.completed:
            command += ["--completed", token]
    record["argv"] = command
    code = 1
    try:
        subprocess.run(["git", "check-ignore", "-q", str(directory)], cwd=ROOT, check=True)
        record_inputs(directory, selected, environment)
        if args.remaining_local:
            _, reused = resolve_completed_steps(args.completed)
            remaining = ("All original local engineering commands, using the accepted "
                         "source-built compiler.")
            if reused:
                labels = ", ".join(entry["label"] for entry in reused)
                remaining = ("All remaining local engineering commands after the retained "
                             f"passes ({labels}), using the accepted source-built compiler.")
            record["continuation"] = {
                "first_run": "build/task-resource-final/host-jmfne0vj/evidence.json",
                "reason": "Pinned-toolchain admission failed before any local test command started.",
                "remaining": remaining,
                "reused_final_test_results": reused,
            }
        missing = [name for name, path in selected.items() if not path.is_file() or not os.access(path, os.X_OK)]
        if missing:
            raise RuntimeError("Missing selected executables: " + ", ".join(missing))
        if args.prepare_only:
            code = 0
        else:
            record["execution"] = "started"
            write_json(directory / "evidence.json", record)
            code = run_logged(command, cwd=ROOT, environment=environment)
            command_record = next((directory / "commands").glob("command-*/command.json"))
            actual = json.loads(command_record.read_text())
            record.update(execution="returned", process_exit_code=actual["exit_code"],
                          command_record=str(command_record.relative_to(directory)))
            write_json(directory / "selected-after.json",
                       {name: file_identity(path) for name, path in selected.items()})
            (directory / "post-status.z").write_bytes(subprocess.check_output(
                ["git", "status", "--porcelain=v1", "-z"], cwd=ROOT))
    except Exception:
        (directory / "retention-error.log").write_text(traceback.format_exc())
        code = code or 1
        record["evidence_error"] = "retention-error.log"
    record["check_exit_code"] = code if code >= 0 else 128 - code
    write_json(directory / "evidence.json", record)
    print(f"final evidence: {directory.relative_to(ROOT)}; exit={record['check_exit_code']}", flush=True)
    return record["check_exit_code"]


if __name__ == "__main__":
    raise SystemExit(main())
