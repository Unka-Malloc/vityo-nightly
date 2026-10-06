"""Acceptance for the single-invocation Rust Agent quality runner."""

from __future__ import annotations

import json
import pathlib
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))

import vityo_quality as quality  # noqa: E402


def main() -> None:
    assert len(quality.FULL_AGENT_PLAN) == 9
    assert {entry.requirement for entry in quality.FULL_AGENT_PLAN} == {
        f"REQ-AGENT-{index:03d}" for index in range(1, 10)
    }
    assert all(entry.rust_source_roots for entry in quality.FULL_AGENT_PLAN)
    assert all(entry.cargo_test_args for entry in quality.FULL_AGENT_PLAN)

    original_platform = quality._host_platform
    original_tool = quality.tool
    original_run = quality.run
    commands: list[list[str]] = []
    try:
        quality._host_platform = lambda: "fixture"
        quality.tool = lambda name: "/tools/cargo" if name == "cargo" else name
        quality.run = lambda command: (commands.append(command) or 0)
        with tempfile.TemporaryDirectory() as directory:
            destination = pathlib.Path(directory) / "rust-report.json"
            assert quality.coding_agent_full(receipt_path=destination) == 0
            report = json.loads(destination.read_text(encoding="utf-8"))
            _assert_report(report, "passed")
            assert report["platform"] == "fixture"
            assert commands == [[
                "/tools/cargo",
                "test",
                "--locked",
                "--offline",
                "--manifest-path",
                quality.AGENT_MANIFEST,
                "--workspace",
                "--all-targets",
            ]]
            for entry in quality.FULL_AGENT_PLAN:
                outcome = report["requirements"][entry.requirement]
                assert outcome["source_roots"] == list(entry.rust_source_roots)
                assert outcome["test_args"] == list(entry.cargo_test_args)

            commands.clear()
            quality.run = lambda command: (commands.append(command) or 0)
            assert quality.coding_agent_full(
                receipt_path=destination,
                collect_coverage=True,
                coverage_output_dir="build/evidence/fixture-rust-coverage",
            ) == 0
            coverage_report = json.loads(destination.read_text(encoding="utf-8"))
            _assert_report(coverage_report, "passed")
            assert coverage_report["rust_coverage"] == {
                "status": "passed",
                "product": "coding-agent",
                "output_dir": "build/evidence/fixture-rust-coverage",
                "exit_code": 0,
            }
            assert len(commands) == 1
            assert "--collect-only" in commands[0]
            mappings = [
                commands[0][index + 1]
                for index, arg in enumerate(commands[0][:-1])
                if arg == "--require-module"
            ]
            assert len(mappings) == sum(
                len(entry.rust_source_roots) for entry in quality.FULL_AGENT_PLAN
            )
            assert {item.split("=", 1)[0] for item in mappings} == {
                f"REQ-AGENT-{index:03d}" for index in range(1, 10)
            }

            commands.clear()
            quality.run = lambda command: (commands.append(command) or 5)
            assert quality.coding_agent_full(receipt_path=destination) == 1
            failed = json.loads(destination.read_text(encoding="utf-8"))
            _assert_report(failed, "failed")
            assert failed["failure_code"] == "suite_failed"
            assert all(
                item["status"] == "failed"
                for item in failed["requirements"].values()
            )
            assert len(commands) == 1
    finally:
        quality._host_platform = original_platform
        quality.tool = original_tool
        quality.run = original_run


def _assert_report(report: dict[str, object], status: str) -> None:
    expected = {
        "schema_version",
        "product",
        "suite",
        "status",
        "failure_code",
        "platform",
        "requirements",
    }
    if "rust_coverage" in report:
        expected.add("rust_coverage")
    assert set(report) == expected
    assert report["schema_version"] == 1
    assert report["product"] == "vityo_coding_agent"
    assert report["suite"] == "full"
    assert report["status"] == status
    requirements = report["requirements"]
    assert isinstance(requirements, dict)
    assert set(requirements) == {f"REQ-AGENT-{index:03d}" for index in range(1, 10)}
    assert all(
        "runner" in outcome and "duration_ms" in outcome
        for outcome in requirements.values()
    )


if __name__ == "__main__":
    main()
