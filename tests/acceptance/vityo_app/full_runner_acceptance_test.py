"""Acceptance for truthful IDE full-suite plans and execution reports."""

from __future__ import annotations

import importlib.util
import json
import pathlib
import re
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
QUALITY_SCRIPT = ROOT / "scripts" / "vityo_quality.py"
REPORT_SCRIPT = ROOT / "scripts" / "vityo_validation_receipt.py"
DEFAULT_REPORT = ROOT / "artifacts" / "validation" / "vityo-full.json"
REQUIRED = tuple(f"REQ-IDE-{index:03d}" for index in range(1, 9))


def _load_module(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path.name}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


quality = _load_module("vityo_quality_full_runner_acceptance", QUALITY_SCRIPT)
reports = _load_module("vityo_report_full_runner_acceptance", REPORT_SCRIPT)


class IdeFullRunnerAcceptanceTest(unittest.TestCase):
    def test_plan_only_lists_each_requirement_and_runner_without_execution(self) -> None:
        original = {
            entry.runner_name: getattr(quality, entry.runner_name)
            for entry in quality.FULL_IDE_PLAN
        }
        calls: list[str] = []
        for entry in quality.FULL_IDE_PLAN:
            setattr(quality, entry.runner_name, lambda name=entry.runner_name: calls.append(name) or 1)
        try:
            with tempfile.TemporaryDirectory() as directory:
                destination = pathlib.Path(directory) / "report.json"
                self.assertEqual(
                    quality.ide_full(
                        plan_only=True,
                        preflight=False,
                        report_path=destination,
                    ),
                    0,
                )
                self.assertFalse(destination.exists())
        finally:
            for name, runner in original.items():
                setattr(quality, name, runner)

        self.assertEqual(calls, [])
        plan = quality.full_suite_plan()
        self.assertEqual(tuple(item["requirement"] for item in plan), REQUIRED)
        self.assertEqual(len({item["suite"] for item in plan}), len(REQUIRED))
        self.assertTrue(all(item["runner"] for item in plan))

    def test_preflight_reports_current_host_tools_and_requirement_mapping(self) -> None:
        before = DEFAULT_REPORT.read_bytes() if DEFAULT_REPORT.exists() else None
        report = quality._preflight_ide_full()
        self.assertEqual(report["schema_version"], 1)
        self.assertEqual(report["product"], "vityo")
        self.assertEqual(report["suite"], "full")
        self.assertEqual(report["mode"], "preflight")
        self.assertEqual(report["platform"], quality._host_platform())
        self.assertEqual(
            tuple(item["requirement"] for item in report["requirements"]),
            REQUIRED,
        )
        self.assertEqual(
            [item["name"] for item in report["checks"]],
            ["requirement_mapping", "tools", "host"],
        )
        self.assertEqual(report["ready"], report["failure_code"] is None)
        after = DEFAULT_REPORT.read_bytes() if DEFAULT_REPORT.exists() else None
        self.assertEqual(after, before)
        encoded = json.dumps(report, sort_keys=True)
        for marker in ("Traceback", "Exception", str(pathlib.Path.home())):
            self.assertNotIn(marker, encoded)

    def test_report_builder_keeps_truthful_outcomes_and_accepts_not_run(self) -> None:
        outcomes = {
            entry.requirement: {
                "status": "passed",
                "suite": entry.suite,
                "runner": entry.runner_name,
                "duration_ms": 1,
            }
            for entry in quality.FULL_IDE_PLAN
        }
        passed = reports.build_ide_report(platform="linux", outcomes=outcomes)
        self.assertEqual(passed["status"], "passed")
        self.assertEqual(passed["platform"], "linux")
        self.assertEqual(tuple(passed["requirements"]), REQUIRED)

        outcomes["REQ-IDE-008"] = {
            **outcomes["REQ-IDE-008"],
            "status": "not-run",
            "failure_code": "tool_unavailable",
        }
        failed = reports.build_ide_report(
            platform="macos",
            outcomes=outcomes,
            failure_code="tool_unavailable",
        )
        self.assertEqual(failed["status"], "failed")
        self.assertEqual(
            failed["requirements"]["REQ-IDE-008"]["status"],
            "not-run",
        )

    def test_report_write_overwrites_current_invocation_atomically(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = pathlib.Path(directory) / "reports" / "ide-full.json"
            self.assertEqual(
                quality._write_formal_report(
                    destination,
                    {"product": "vityo", "suite": "full", "status": "failed"},
                ),
                1,
            )
            self.assertEqual(
                quality._write_formal_report(
                    destination,
                    {"product": "vityo", "suite": "full", "status": "passed"},
                ),
                0,
            )
            self.assertEqual(
                json.loads(destination.read_text(encoding="utf-8"))["status"],
                "passed",
            )
            self.assertEqual(list(destination.parent.glob(".*.tmp")), [])

    def test_runner_has_no_hard_coded_better_plan_or_home_path(self) -> None:
        source = QUALITY_SCRIPT.read_text(encoding="utf-8")
        markers = (
            'ROOT.parent / "better-plan"',
            "ROOT.parent / 'better-plan'",
            'Path.home() / "better-plan"',
            "Path.home() / 'better-plan'",
            "/better-plan/scripts/manifest_tool",
        )
        for marker in markers:
            self.assertNotIn(marker, source)
        self.assertNotRegex(
            source,
            r"[\"']\$HOME[\"']|os\.environ\[\s*[\"']HOME[\"']\s*\]",
        )

    def test_acceptance_does_not_invoke_the_full_execution(self) -> None:
        source = pathlib.Path(__file__).read_text(encoding="utf-8")
        self.assertIsNone(
            re.search(r"quality\.ide_full\(\s*plan_only\s*=\s*False\s*,\s*preflight\s*=\s*False", source)
        )


if __name__ == "__main__":
    unittest.main()
