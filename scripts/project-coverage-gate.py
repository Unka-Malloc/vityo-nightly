#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PYTHON_COVERAGE_GATE = ROOT / "scripts" / "python-coverage-gate.py"
RUST_COVERAGE_GATE = ROOT / "scripts" / "rust-coverage-gate.py"
AGENT_QUALITY_RUNNER = ROOT / "scripts" / "vityo_quality.py"
DEFAULT_FLUTTER_DIR = Path("products/vityo_app")
DEFAULT_FAIL_UNDER = 95
LCOV_RELATIVE_PATH = Path("coverage/lcov.info")
VITYOD_CARGO_MANIFEST = Path("native/vityod/Cargo.toml")
CODING_AGENT_CARGO_MANIFEST = Path("products/vityo_coding_agent/Cargo.toml")
DEFAULT_RUST_COVERAGE_DIR = Path("build/evidence/rust-coverage")
DEFAULT_AGENT_RECEIPT = Path("build/evidence/vityo-coding-agent-full.json")


@dataclass(frozen=True)
class LineCoverage:
    found: int
    hit: int

    @property
    def percent(self) -> float:
        return 100.0 * self.hit / self.found


def parse_lcov(path: Path) -> LineCoverage:
    if not path.is_file():
        raise RuntimeError(f"lcov report is missing: {path}")

    found = 0
    hit = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("LF:"):
            try:
                found += int(line.removeprefix("LF:"))
            except ValueError as exc:
                raise RuntimeError(f"invalid LF counter in {path}: {line}") from exc
        elif line.startswith("LH:"):
            try:
                hit += int(line.removeprefix("LH:"))
            except ValueError as exc:
                raise RuntimeError(f"invalid LH counter in {path}: {line}") from exc

    if found <= 0:
        raise RuntimeError(f"lcov report has no line data: {path}")
    if hit > found:
        raise RuntimeError(f"lcov report has more hit lines than found lines: {path}")
    return LineCoverage(found=found, hit=hit)


def run_command(command: list[str], *, cwd: Path) -> int:
    return subprocess.run(command, cwd=cwd, check=False).returncode


def run_python_gate(
    fail_under: int,
    *,
    collect: bool = True,
    report: bool = True,
) -> int:
    command = [sys.executable, str(PYTHON_COVERAGE_GATE), "--fail-under", str(fail_under)]
    if collect and not report:
        command.append("--collect-only")
    elif report and not collect:
        command.append("--report-only")
    elif not collect and not report:
        print("Python coverage collection or reporting must be selected", file=sys.stderr)
        return 2
    return run_command(command, cwd=ROOT)


def resolve_flutter_binary(raw: str | None) -> str | None:
    if raw:
        return shutil.which(raw) or (raw if Path(raw).is_file() else None)
    return shutil.which("flutter")


def resolve_lcov_path(*, app_dir: Path, flutter_coverage_path: Path | None) -> Path:
    if flutter_coverage_path is None:
        return app_dir / LCOV_RELATIVE_PATH
    if flutter_coverage_path.is_absolute():
        return flutter_coverage_path
    return ROOT / flutter_coverage_path


def run_flutter_gate(
    *,
    fail_under: int,
    flutter_dir: Path,
    flutter_bin: str | None,
    collect: bool = True,
    report: bool = True,
    use_existing_report: bool = False,
    flutter_coverage_path: Path | None = None,
) -> int:
    flutter = resolve_flutter_binary(flutter_bin)
    should_collect = collect and not use_existing_report
    if should_collect and flutter is None:
        print("flutter is required for Flutter coverage; install Flutter or pass --flutter-bin", file=sys.stderr)
        return 2

    app_dir = ROOT / flutter_dir
    needs_app_dir = should_collect or flutter_coverage_path is None
    if needs_app_dir and not app_dir.is_dir():
        print(f"Flutter app directory is missing: {flutter_dir}", file=sys.stderr)
        return 2

    if should_collect:
        assert flutter is not None
        vityod_manifest = app_dir / VITYOD_CARGO_MANIFEST
        if not vityod_manifest.is_file():
            print(
                f"vityod Cargo manifest is missing: {vityod_manifest}",
                file=sys.stderr,
            )
            return 2
        code = run_command(
            [
                "cargo",
                "build",
                "--locked",
                "--manifest-path",
                str(vityod_manifest),
                "-p",
                "vityod",
            ],
            cwd=ROOT,
        )
        if code != 0:
            return code
        # The packaged-Agent handshake test drives the real Coding Agent
        # executable, so it needs the same kind of prerequisite the daemon test
        # already has. Without this the test has nothing to launch and fails on
        # every host instead of exercising the protocol.
        agent_manifest = ROOT / CODING_AGENT_CARGO_MANIFEST
        if not agent_manifest.is_file():
            print(
                f"Coding Agent Cargo manifest is missing: {agent_manifest}",
                file=sys.stderr,
            )
            return 2
        code = run_command(
            [
                "cargo",
                "build",
                "--locked",
                "--manifest-path",
                str(agent_manifest),
                "--bin",
                "vityo-coding-agent",
            ],
            cwd=ROOT,
        )
        if code != 0:
            return code
        code = run_command([flutter, "test", "--coverage"], cwd=app_dir)
        if code != 0:
            return code

    if not report:
        return 0

    try:
        coverage = parse_lcov(
            resolve_lcov_path(
                app_dir=app_dir,
                flutter_coverage_path=flutter_coverage_path,
            )
        )
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    print(
        "[project-coverage] Flutter line coverage: "
        f"{coverage.percent:.2f}% ({coverage.hit}/{coverage.found} lines)"
    )
    return 0 if coverage.percent >= fail_under else 1


def run_rust_coverage_gate(
    *,
    collect: bool,
    report: bool,
    output_dir: Path,
    agent_receipt: Path,
) -> int:
    if not collect and not report:
        print("Rust coverage collection or reporting must be selected", file=sys.stderr)
        return 2
    output = output_dir.as_posix()
    receipt = agent_receipt.as_posix()
    if collect:
        code = run_command(
            [
                sys.executable,
                str(AGENT_QUALITY_RUNNER),
                "--product",
                "coding-agent",
                "--suite",
                "full",
                "--coverage",
                "--coverage-output-dir",
                output,
                "--receipt",
                receipt,
            ],
            cwd=ROOT,
        )
        if code != 0:
            return code
        code = run_command(
            [
                sys.executable,
                str(RUST_COVERAGE_GATE),
                "--product",
                "vityod",
                "--collect-only",
                "--output-dir",
                output,
            ],
            cwd=ROOT,
        )
        if code != 0:
            return code
    if report:
        code = run_command(
            [
                sys.executable,
                str(AGENT_QUALITY_RUNNER),
                "--product",
                "coding-agent",
                "--suite",
                "coverage-report",
                "--coverage-output-dir",
                output,
            ],
            cwd=ROOT,
        )
        if code != 0:
            return code
        code = run_command(
            [
                sys.executable,
                str(RUST_COVERAGE_GATE),
                "--product",
                "vityod",
                "--report-only",
                "--output-dir",
                output,
            ],
            cwd=ROOT,
        )
        if code != 0:
            return code
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run project coverage gates for Vityo.")
    parser.add_argument("--fail-under", type=int, default=DEFAULT_FAIL_UNDER)
    parser.add_argument("--python-fail-under", type=int)
    parser.add_argument("--flutter-fail-under", type=int)
    parser.add_argument("--flutter-dir", type=Path, default=DEFAULT_FLUTTER_DIR)
    parser.add_argument("--flutter-bin")
    parser.add_argument(
        "--flutter-coverage-path",
        type=Path,
        help="Parse this LCOV report path, relative to the repository root or absolute.",
    )
    parser.add_argument(
        "--use-existing-flutter-coverage",
        action="store_true",
        help="Parse an existing Flutter LCOV report without running flutter test.",
    )
    parser.add_argument("--skip-python", action="store_true")
    parser.add_argument("--skip-flutter", action="store_true")
    parser.add_argument("--rust-coverage-dir", type=Path, default=DEFAULT_RUST_COVERAGE_DIR)
    parser.add_argument("--agent-receipt", type=Path, default=DEFAULT_AGENT_RECEIPT)
    phase = parser.add_mutually_exclusive_group()
    phase.add_argument(
        "--collect-only",
        action="store_true",
        help="Run Python, Flutter, Coding Agent, and daemon tests once and save coverage reports without evaluating thresholds.",
    )
    phase.add_argument(
        "--report-only",
        action="store_true",
        help="Evaluate existing Python, Flutter, Coding Agent, and daemon coverage reports without rerunning tests.",
    )
    args = parser.parse_args(argv)

    collect = not args.report_only
    report = not args.collect_only

    if not args.skip_python:
        code = run_python_gate(
            args.python_fail_under or args.fail_under,
            collect=collect,
            report=report,
        )
        if code != 0:
            return code

    if not args.skip_flutter:
        code = run_flutter_gate(
            fail_under=args.flutter_fail_under or args.fail_under,
            flutter_dir=args.flutter_dir,
            flutter_bin=args.flutter_bin,
            collect=collect,
            report=report,
            use_existing_report=args.use_existing_flutter_coverage,
            flutter_coverage_path=args.flutter_coverage_path,
        )
        if code != 0:
            return code

    code = run_rust_coverage_gate(
        collect=collect,
        report=report,
        output_dir=args.rust_coverage_dir,
        agent_receipt=args.agent_receipt,
    )
    if code != 0:
        return code

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
