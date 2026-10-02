"""Acceptance for current Coding Agent suite and coverage reports."""

from __future__ import annotations

import json
import pathlib
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))

import vityo_quality as quality  # noqa: E402


def main() -> None:
    original = {
        entry.runner_name: getattr(quality, entry.runner_name)
        for entry in quality.FULL_AGENT_PLAN
    }
    original_platform = quality._host_platform
    original_run = quality.run
    calls: list[str] = []
    try:
        quality._host_platform = lambda: "fixture"
        for entry in quality.FULL_AGENT_PLAN:
            setattr(quality, entry.runner_name, _runner(entry.requirement, calls))
        with tempfile.TemporaryDirectory() as directory:
            destination = pathlib.Path(directory) / "current-report.json"
            run = _run_mock(0)
            quality.run = run
            assert quality.coding_agent_full(
                receipt_path=destination,
                collect_coverage=True,
                coverage_output_dir="build/evidence/fixture-rust-coverage",
            ) == 0
            passed = json.loads(destination.read_text(encoding="utf-8"))
            _assert_report(passed, "passed")
            assert passed["platform"] == "fixture"
            assert passed["rust_coverage"] == {
                "status": "passed",
                "product": "coding-agent",
                "output_dir": "build/evidence/fixture-rust-coverage",
                "exit_code": 0,
            }
            assert run.calls == 1
            assert "--collect-only" in run.command[0]
            assert calls == [f"REQ-AGENT-{index:03d}" for index in range(1, 10)]

            calls.clear()
            setattr(
                quality,
                quality.FULL_AGENT_PLAN[4].runner_name,
                _failing_runner(calls),
            )
            run = _run_mock(0)
            quality.run = run
            assert quality.coding_agent_full(
                receipt_path=destination,
                collect_coverage=True,
            ) == 1
            failed = json.loads(destination.read_text(encoding="utf-8"))
            _assert_report(failed, "failed")
            assert failed["failure_code"] == "suite_failed"
            assert failed["requirements"]["REQ-AGENT-005"]["status"] == "failed"
            assert failed["rust_coverage"]["status"] == "not-run"
            assert run.calls == 0

            calls.clear()
            for entry in quality.FULL_AGENT_PLAN:
                setattr(quality, entry.runner_name, _runner(entry.requirement, calls))
            run = _run_mock(5)
            quality.run = run
            assert quality.coding_agent_full(
                receipt_path=destination,
                collect_coverage=True,
            ) == 1
            coverage_failed = json.loads(destination.read_text(encoding="utf-8"))
            _assert_report(coverage_failed, "failed")
            assert coverage_failed["failure_code"] == "coverage_collection_failed"
            assert coverage_failed["rust_coverage"]["status"] == "failed"
            assert coverage_failed["rust_coverage"]["exit_code"] == 5
    finally:
        for name, runner in original.items():
            setattr(quality, name, runner)
        quality._host_platform = original_platform
        quality.run = original_run


class _RunMock:
    def __init__(self, exit_code: int) -> None:
        self.exit_code = exit_code
        self.calls = 0
        self.command: list[list[str]] = []

    def __call__(self, command: list[str]) -> int:
        self.calls += 1
        self.command.append(command)
        return self.exit_code


def _run_mock(exit_code: int) -> _RunMock:
    return _RunMock(exit_code)


def _runner(requirement: str, calls: list[str]):
    def run() -> int:
        calls.append(requirement)
        return 0

    return run


def _failing_runner(calls: list[str]):
    def run() -> int:
        calls.append("REQ-AGENT-005")
        raise RuntimeError("synthetic fixture detail")

    return run


def _assert_report(report: dict[str, object], status: str) -> None:
    assert set(report) == {
        "schema_version",
        "product",
        "suite",
        "status",
        "failure_code",
        "platform",
        "requirements",
        "rust_coverage",
    }
    assert report["schema_version"] == 1
    assert report["product"] == "vityo_coding_agent"
    assert report["suite"] == "full"
    assert report["status"] == status
    requirements = report["requirements"]
    assert isinstance(requirements, dict)
    assert set(requirements) == {f"REQ-AGENT-{index:03d}" for index in range(1, 10)}
    assert all("runner" in outcome and "duration_ms" in outcome for outcome in requirements.values())


if __name__ == "__main__":
    main()
