#!/usr/bin/env python3
"""Fail-closed validation tests for scripts/record-product-matrix-evidence.py."""

from __future__ import annotations

import importlib.util
import io
import json
import runpy
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
from test_ecosystem_product_gate import passing_gate_report


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "record-product-matrix-evidence.py"


def load_script_module():
    spec = importlib.util.spec_from_file_location("product_matrix_evidence_failclosed", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def matrix_payload(styio: str = "a" * 40, pafio: str = "b" * 40) -> dict[str, object]:
    return {
        "schema_version": 1,
        "capability": "trusted-desktop-ide-loop",
        "repositories": {"styio": styio, "pafio": pafio},
    }


def gate_report_payload(platform="linux"):
    return passing_gate_report(platform)


def pty_report_payload(platform: str = "linux", commit: str = "v" * 40) -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "capability": "desktop-native-pty",
        "platform": platform,
        "provider": "conpty" if platform == "windows" else "forkpty",
        "ptyDependency": {"name": "portable-pty", "version": "0.9.0", "owner": "vityod"},
        "vityoCommit": commit,
        "ok": True,
        "scenarios": [
            {"id": scenario, "status": "passed"}
            for scenario in (
                "tty-identity",
                "child-observed-resize",
                "forced-process-close",
                "terminal-environment-propagation",
            )
        ],
    }


class ProductMatrixEvidenceFailClosedTest(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_script_module()

    def test_json_loader_rejects_non_objects_duplicates_constants_and_oversized_input(self) -> None:
        with tempfile.TemporaryDirectory(prefix="matrix-evidence-") as tmp_name:
            path = Path(tmp_name) / "input.json"
            for body in ("NaN", "Infinity", "-Infinity"):
                with self.subTest(body=body):
                    path.write_text(f'{{"value": {body}}}', encoding="utf-8")
                    with self.assertRaisesRegex(ValueError, "invalid constant"):
                        self.module.load_json_object(path)

            path.write_text("[1, 2]", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "must contain a JSON object"):
                self.module.load_json_object(path)

            path.write_text('{"a": 1, "a": 2}', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "duplicate fields"):
                self.module.load_json_object(path)

            path.write_bytes(b"{" + b" " * self.module.MAX_JSON_INPUT_BYTES + b"}")
            with self.assertRaisesRegex(ValueError, "bounded JSON input limit"):
                self.module.load_json_object(path)

            path.write_text('{"a": 1}', encoding="utf-8")
            self.assertEqual(self.module.load_json_object(path), {"a": 1})

    def test_gate_report_rejects_unbounded_or_open_schemas(self) -> None:
        report = gate_report_payload()
        self.assertIsNone(self.module.validate_gate_report(report, platform="linux"))

        oversized = {**report, "failure_category": "x" * (self.module.MAX_GATE_REPORT_BYTES + 1)}
        with self.assertRaisesRegex(ValueError, "bounded report limit"):
            self.module.validate_gate_report(oversized, platform="linux")

        opened = {key: value for key, value in report.items() if key != "skipped"}
        with self.assertRaisesRegex(ValueError, "schema is not closed"):
            self.module.validate_gate_report(opened, platform="linux")

        for version in (2, "1", True):
            with self.subTest(version=version):
                with self.assertRaisesRegex(ValueError, "schema is unsupported"):
                    self.module.validate_gate_report(
                        {**report, "schema_version": version},
                        platform="linux",
                    )

    def test_gate_report_rejects_incomplete_steps_and_loose_scenario_evidence(self) -> None:
        base = gate_report_payload()

        misnamed = gate_report_payload()
        misnamed["steps"][1]["name"] = "not-a-real-step"
        with self.assertRaisesRegex(ValueError, "steps are incomplete"):
            self.module.validate_gate_report(misnamed, platform="linux")

        short_steps = gate_report_payload()
        short_steps["steps"] = short_steps["steps"][:2]
        with self.assertRaisesRegex(ValueError, "steps are incomplete"):
            self.module.validate_gate_report(short_steps, platform="linux")

        for report_section in ([], {"scenario_count": 1, "scenarios": []}):
            with self.subTest(report_section=report_section):
                report = {**base, "report": report_section}
                with self.assertRaisesRegex(ValueError, "missing structured scenario evidence"):
                    self.module.validate_gate_report(report, platform="linux")

        not_an_object = gate_report_payload()
        not_an_object["report"]["scenarios"] = ["not-an-object"]
        with self.assertRaises(ValueError):
            self.module.validate_gate_report(not_an_object, platform="linux")

        opened_scenario = gate_report_payload()
        opened_scenario["report"]["scenarios"][0]["workflow_payload_version"] = 1
        with self.assertRaises(ValueError):
            self.module.validate_gate_report(opened_scenario, platform="linux")

        missing_case = gate_report_payload()
        missing_case["report"]["scenarios"].pop()
        missing_case["report"]["scenario_count"] -= 1
        with self.assertRaises(ValueError):
            self.module.validate_gate_report(missing_case, platform="linux")

    def test_gate_report_contract_cases_fail_closed_on_any_drift(self) -> None:
        base = gate_report_payload()

        for mutation in (
            {"accepted": False},
            {"success_observation": True},
            {"outcome": "passed"},
            {"error_category": "other"},
            {"case": "unknown-case"},
            {"scenario": "other-scenario"},
            {"evidence_kind": "fixture"},
            {"schema_version": 2},
        ):
            with self.subTest(mutation=mutation):
                report = gate_report_payload()
                report["report"]["contract_cases"][1] = {
                    **report["report"]["contract_cases"][1],
                    **mutation,
                }
                with self.assertRaises(ValueError):
                    self.module.validate_gate_report(report, platform="linux")

        extra_field = gate_report_payload()
        extra_field["report"]["contract_cases"][0]["workflow_payload_version"] = 1
        with self.assertRaises(ValueError):
            self.module.validate_gate_report(extra_field, platform="linux")

        self.assertIsNone(self.module.validate_gate_report(base, platform="linux"))

    def test_required_ownership_and_observation_cases_cannot_be_omitted(self):
        for name in ("concurrent-invocation-isolation", "delayed-result-isolation", "retained-parent-delta", "runtime-only"):
            report = gate_report_payload()
            report["report"]["scenarios"] = [case for case in report["report"]["scenarios"] if case["case"] != name]
            report["report"]["scenario_count"] -= 1
            with self.assertRaises(ValueError):
                self.module.validate_gate_report(report, platform="linux")

    def test_matrix_pins_require_a_closed_matrix_of_fixed_commits(self) -> None:
        matrix = matrix_payload()
        self.assertIsNone(self.module.validate_pins(matrix, styio_commit="a" * 40, pafio_commit="b" * 40))

        with self.assertRaisesRegex(ValueError, "schema is unsupported"):
            self.module.validate_pins(
                {**matrix, "schema_version": 2},
                styio_commit="a" * 40,
                pafio_commit="b" * 40,
            )

        with self.assertRaisesRegex(ValueError, "capability is unsupported"):
            self.module.validate_pins(
                {**matrix, "capability": "other-capability"},
                styio_commit="a" * 40,
                pafio_commit="b" * 40,
            )

        with self.assertRaisesRegex(ValueError, "not fixed commits"):
            self.module.validate_pins(
                matrix_payload(styio="main", pafio="b" * 40),
                styio_commit="main",
                pafio_commit="b" * 40,
            )

        with self.assertRaisesRegex(ValueError, "repository pins are missing"):
            self.module.validate_pins(
                {**matrix, "repositories": ["styio"]},
                styio_commit="a" * 40,
                pafio_commit="b" * 40,
            )

    def test_native_pty_report_rejects_a_stale_or_incomplete_matrix(self) -> None:
        report = pty_report_payload()
        self.assertIsNone(
            self.module.validate_pty_report(report, platform="linux", vityo_commit="v" * 40)
        )

        for version in (2, "1"):
            with self.subTest(version=version):
                with self.assertRaisesRegex(ValueError, "schema is unsupported"):
                    self.module.validate_pty_report(
                        {**report, "schemaVersion": version},
                        platform="linux",
                        vityo_commit="v" * 40,
                    )

        for mutation, message in (
            ({"capability": "other"}, "unexpected capability scope"),
            ({"provider": "conpty"}, "provider does not match the platform"),
            ({"vityoCommit": "x" * 40}, "does not match the Vityo commit"),
            (
                {
                    "ptyDependency": {
                        "name": "portable-pty",
                        "version": "0.8.0",
                        "owner": "vityod",
                    }
                },
                "fixed vityod PTY dependency",
            ),
            ({"ok": False}, "native PTY matrix did not pass"),
            ({"scenarios": {"tty-identity": "passed"}}, "missing scenarios"),
        ):
            with self.subTest(mutation=mutation):
                with self.assertRaisesRegex(ValueError, message):
                    self.module.validate_pty_report(
                        {**report, **mutation},
                        platform="linux",
                        vityo_commit="v" * 40,
                    )

    def test_script_entrypoint_writes_proven_evidence_and_exits_zero(self) -> None:
        with tempfile.TemporaryDirectory(prefix="matrix-evidence-") as tmp_name:
            root = Path(tmp_name)
            matrix = root / "matrix.json"
            gate_report = root / "gate-report.json"
            pty_report = root / "pty-report.json"
            output = root / "nested/evidence.json"
            matrix.write_text(json.dumps(matrix_payload()), encoding="utf-8")
            gate_report.write_text(json.dumps(gate_report_payload()), encoding="utf-8")
            pty_report.write_text(json.dumps(pty_report_payload()), encoding="utf-8")
            heads = {"vityo": "v" * 40, "styio": "a" * 40, "pafio": "b" * 40}
            calls: list[list[str]] = []

            def fake_run(command, *, check, capture_output, text):
                calls.append(command)
                self.assertTrue(check)
                self.assertTrue(capture_output)
                self.assertTrue(text)
                repository = Path(command[command.index("-C") + 1]).name
                if command[command.index("-C") + 2] == "status":
                    return SimpleNamespace(stdout="")
                return SimpleNamespace(stdout=f"{heads[repository]}\n")

            argv = [
                str(SCRIPT_PATH),
                "--platform", "linux",
                "--vityo", str(root / "vityo"),
                "--styio", str(root / "styio"),
                "--pafio", str(root / "pafio"),
                "--matrix", str(matrix),
                "--gate-report", str(gate_report),
                "--pty-report", str(pty_report),
                "--output", str(output),
            ]
            stdout = io.StringIO()
            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch("subprocess.run", side_effect=fake_run),
                redirect_stdout(stdout),
            ):
                with self.assertRaises(SystemExit) as raised:
                    runpy.run_path(str(SCRIPT_PATH), run_name="__main__")

            self.assertEqual(raised.exception.code, 0)
            self.assertEqual(len(calls), 6)
            evidence = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(evidence, json.loads(stdout.getvalue()))
        self.assertEqual(evidence["matrixStatus"], "proven")
        self.assertEqual(evidence["completionSemantics"], "fixed-real-product-matrix")
        self.assertTrue(evidence["productCapabilityComplete"])
        self.assertEqual(evidence["repositoryTreeState"], "clean")
        self.assertEqual(
            evidence["pinnedRepositories"],
            {"vityo": "v" * 40, "styio": "a" * 40, "pafio": "b" * 40},
        )
        self.assertEqual(
            evidence["gateEvidence"],
            {"gate": "vityo-desktop-product-gate", "scenarioCount": len(gate_report_payload()["report"]["scenarios"])},
        )
        self.assertEqual(evidence["nativePtyEvidence"]["provider"], "forkpty")
        self.assertEqual(evidence["nativePtyEvidence"]["scenarioCount"], 4)


if __name__ == "__main__":
    unittest.main()
