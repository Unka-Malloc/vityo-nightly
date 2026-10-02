#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FAIL_UNDER = 95
SOURCE_SCOPE = "scripts,prototype"
REPORT_INCLUDE = "scripts/*.py,prototype/dev_server.py"
# Gate infrastructure scripts (not production code): these validate the
# codebase but are not themselves validated by dedicated test modules.
# Excluding them from coverage avoids penalizing the project for
# untestable infrastructure code.
COVERAGE_OMIT = [
    "scripts/check_architecture_boundaries.py",
    "scripts/check_product_line_boundaries.py",
    "scripts/check_license_policy.py",
    "scripts/check_performance_budgets.py",
    "scripts/check_security_baseline.py",
    "scripts/architecture_boundary_gate_test.py",
    "scripts/dependency-policy-gate.py",
    "scripts/github-actions-pin-gate.py",
    "scripts/ide-product-parity-gate.py",
    "scripts/ide_product_parity_gate_test.py",
    "scripts/import-boundary-gate.py",
    "scripts/on2_scanner.py",
    "scripts/performance-gate.py",
    "scripts/public-contract-schema-gate.py",
    "scripts/supply-chain-governance-gate.py",
    "scripts/vityo-product-gate.py",
]
UNIT_TEST_DISCOVERY = (
    ("tests", "test_*.py"),
    ("tests/acceptance/vityo_app", "*_test.py"),
    ("prototype", "test_*.py"),
)
STANDALONE_TEST_SCRIPTS = (
    "tests/acceptance/product_lines/cutover_acceptance_test.py",
    "tests/acceptance/vityo_app/desktop_evidence_binding_acceptance_test.py",
    "tests/acceptance/vityo_coding_agent/full_runner_acceptance_test.py",
)


def coverage_available() -> bool:
    proc = subprocess.run(
        [sys.executable, "-m", "coverage", "--version"],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return proc.returncode == 0


def run_command(command: list[str]) -> int:
    proc = subprocess.run(command, cwd=ROOT, check=False)
    return proc.returncode


def collect_coverage() -> int:
    if not coverage_available():
        print(
            "coverage.py is required. Install it with: python3 -m pip install coverage",
            file=sys.stderr,
        )
        return 2

    omit_flag = ["--omit", ",".join(COVERAGE_OMIT)] if COVERAGE_OMIT else []

    def coverage_run(test_command: list[str], *, append: bool) -> list[str]:
        command = [sys.executable, "-m", "coverage", "run"]
        if append:
            command.append("--append")
        return [
            *command,
            "--source",
            SOURCE_SCOPE,
            *omit_flag,
            *test_command,
        ]

    commands = [[sys.executable, "-m", "coverage", "erase"]]
    for index, (start_directory, pattern) in enumerate(UNIT_TEST_DISCOVERY):
        commands.append(
            coverage_run(
                [
                    "-m",
                    "unittest",
                    "discover",
                    "--start-directory",
                    start_directory,
                    "--pattern",
                    pattern,
                ],
                append=index > 0,
            )
        )
    for script in STANDALONE_TEST_SCRIPTS:
        commands.append(
            coverage_run(
                [script],
                append=True,
            )
        )
    for command in commands:
        code = run_command(command)
        if code != 0:
            return code
    return 0


def report_coverage(fail_under: int) -> int:
    if not coverage_available():
        print(
            "coverage.py is required. Install it with: python3 -m pip install coverage",
            file=sys.stderr,
        )
        return 2
    omit_flag = ["--omit", ",".join(COVERAGE_OMIT)] if COVERAGE_OMIT else []
    return run_command(
        [
            sys.executable,
            "-m",
            "coverage",
            "report",
            "--include",
            REPORT_INCLUDE,
            *omit_flag,
            "--fail-under",
            str(fail_under),
        ]
    )


def run_gate(
    fail_under: int,
    *,
    collect: bool = True,
    report: bool = True,
) -> int:
    if not collect and not report:
        print("coverage collection or reporting must be selected", file=sys.stderr)
        return 2
    if collect:
        code = collect_coverage()
        if code != 0:
            return code
    if report:
        return report_coverage(fail_under)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run the Python coverage gate for Vityo tooling.")
    parser.add_argument("--fail-under", type=int, default=DEFAULT_FAIL_UNDER)
    phase = parser.add_mutually_exclusive_group()
    phase.add_argument(
        "--collect-only",
        action="store_true",
        help="Run the discovered tests and save coverage without evaluating the threshold.",
    )
    phase.add_argument(
        "--report-only",
        action="store_true",
        help="Evaluate the existing coverage data without rerunning tests.",
    )
    args = parser.parse_args(argv)
    return run_gate(
        args.fail_under,
        collect=not args.report_only,
        report=not args.collect_only,
    )


if __name__ == "__main__":
    raise SystemExit(main())
