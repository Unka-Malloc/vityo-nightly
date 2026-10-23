"""Tests for current-invocation validation reports and atomic persistence."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "vityo_validation_receipt.py"


def load_module():
    spec = importlib.util.spec_from_file_location(
        "vityo_validation_report_test_target",
        SCRIPT_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class VityoValidationReportTest(unittest.TestCase):
    def setUp(self) -> None:
        self.reports = load_module()

    def _plan(self) -> list[dict[str, object]]:
        return [
            {
                "requirement": f"REQ-IDE-{index:03d}",
                "suite": f"suite-{index}",
                "runner": f"runner_{index}",
            }
            for index in range(1, 9)
        ]

    def _outcomes(self) -> dict[str, dict[str, object]]:
        return {
            f"REQ-IDE-{index:03d}": {
                "status": "passed",
                "suite": f"suite-{index}",
                "runner": f"runner_{index}",
                "duration_ms": index,
            }
            for index in range(1, 9)
        }

    def test_full_suite_plan_requires_canonical_unique_mapping(self) -> None:
        self.reports.validate_full_suite_plan(self._plan())
        invalid_plans = []
        missing = self._plan()
        missing[0]["runner"] = None
        invalid_plans.append(missing)
        duplicate = self._plan()
        duplicate[-1]["requirement"] = "REQ-IDE-007"
        invalid_plans.append(duplicate)
        duplicate_runner = self._plan()
        duplicate_runner[-1]["runner"] = "runner_7"
        invalid_plans.append(duplicate_runner)
        for plan in invalid_plans:
            with self.subTest(plan=plan):
                with self.assertRaisesRegex(
                    self.reports.ValidationReportError,
                    "invalid_requirement_mapping",
                ):
                    self.reports.validate_full_suite_plan(plan)

    def test_ide_report_records_pass_fail_and_not_run_outcomes(self) -> None:
        outcomes = self._outcomes()
        passed = self.reports.build_ide_report(
            platform="linux",
            outcomes=outcomes,
        )
        self.assertEqual(
            passed,
            {
                "schema_version": 1,
                "product": "vityo",
                "suite": "full",
                "status": "passed",
                "failure_code": None,
                "platform": "linux",
                "requirements": outcomes,
            },
        )

        outcomes["REQ-IDE-008"]["status"] = "not-run"
        outcomes["REQ-IDE-008"]["failure_code"] = "tool_unavailable"
        failed = self.reports.build_ide_report(
            platform="macos",
            outcomes=outcomes,
            failure_code="tool_unavailable",
        )
        self.assertEqual(failed["status"], "failed")
        self.assertEqual(failed["failure_code"], "tool_unavailable")
        self.assertEqual(failed["requirements"]["REQ-IDE-008"]["status"], "not-run")

    def test_ide_report_requires_every_mapped_requirement_and_valid_outcomes(self) -> None:
        incomplete = self._outcomes()
        incomplete.pop("REQ-IDE-008")
        with self.assertRaisesRegex(
            self.reports.ValidationReportError,
            "missing_requirement_outcome",
        ):
            self.reports.build_ide_report(platform="linux", outcomes=incomplete)

        invalid = self._outcomes()
        invalid["REQ-IDE-001"]["duration_ms"] = -1
        with self.assertRaisesRegex(
            self.reports.ValidationReportError,
            "invalid_requirement_outcome",
        ):
            self.reports.build_ide_report(platform="linux", outcomes=invalid)

    def test_atomic_write_creates_and_overwrites_current_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "nested" / "report.json"
            self.reports.write_report_atomic(destination, {"status": "failed"})
            self.reports.write_report_atomic(destination, {"status": "passed"})
            self.assertEqual(
                json.loads(destination.read_text(encoding="utf-8")),
                {"status": "passed"},
            )
            self.assertEqual(list(destination.parent.glob(".*.tmp")), [])

    def test_atomic_write_cleans_up_after_replace_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "report.json"
            with (
                mock.patch.object(
                    self.reports.os,
                    "replace",
                    side_effect=OSError("synthetic replace failure"),
                ),
                self.assertRaises(OSError),
            ):
                self.reports.write_report_atomic(destination, {"status": "passed"})
            self.assertFalse(destination.exists())
            self.assertEqual(list(destination.parent.glob(".*.tmp")), [])

    def test_atomic_write_keeps_report_size_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "report.json"
            with self.assertRaisesRegex(
                self.reports.ValidationReportError,
                "report_too_large",
            ):
                self.reports.write_report_atomic(
                    destination,
                    {"payload": "x" * self.reports.MAX_REPORT_BYTES},
                )
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
