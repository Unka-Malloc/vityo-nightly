"""Required product cases, failure admission and privacy. No ecosystem run."""
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load_gate_module():
    spec = importlib.util.spec_from_file_location("product_gate", ROOT / "scripts/ecosystem-product-gate.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def reports(gate):
    return [{"schema_version": 2, "scenario": gate.SCENARIO, "evidence_kind": "real-production-services",
             "case": name, "outcome": outcome, "accepted": True} for name, outcome in gate.EXPECTED_CASES.items()]


def contracts(gate):
    return [{"schema_version": 1, "scenario": gate.SCENARIO, "evidence_kind": "deterministic-contract",
             "case": name, "outcome": outcome, "accepted": True, "error_category": category,
             "success_observation": False} for name, (outcome, category) in gate.EXPECTED_CONTRACTS.items()]


def markers(gate):
    return b"\n".join(marker + json.dumps(value).encode() for marker, values in (
        (gate.PRODUCT_MARKER, reports(gate)), (gate.CONTRACT_MARKER, contracts(gate))) for value in values)


def passing_gate_report(platform="linux"):
    gate = load_gate_module()
    return gate._payload(platform=platform, required=True,
        process=gate.ProcessResult(0, b"", b""), scenarios=reports(gate),
        contracts=contracts(gate), failure=None, skipped=False)


class EcosystemProductGateTest(unittest.TestCase):
    def setUp(self):
        self.gate = load_gate_module()

    def test_required_cases_include_expected_failures(self):
        self.gate.validate_product_reports(reports(self.gate), contracts(self.gate))
        for name in ("compile_error_build", "unhandled_test", "observed-error"):
            self.assertEqual(self.gate.EXPECTED_CASES[name], "failed")

    def test_every_missing_duplicate_or_wrong_outcome_fails(self):
        complete = reports(self.gate)
        for index in range(len(complete)):
            for changed in (complete[:index] + complete[index + 1:], complete + [complete[index]],
                            [dict(r, outcome="wrong") if i == index else r for i, r in enumerate(complete)]):
                with self.assertRaises(ValueError):
                    self.gate.validate_product_reports(changed, contracts(self.gate))

    def test_closed_schema_identity_and_boolean_integer_substitution(self):
        for change in ({"schema_version": True}, {"accepted": 1}, {"scenario": "other"},
                       {"evidence_kind": "scripted"}, {"extra": "field"}, {"case": "unknown"}):
            values = reports(self.gate)
            values[0].update(change)
            with self.assertRaises(ValueError):
                self.gate.validate_product_reports(values, contracts(self.gate))

    def test_contract_categories_presence_and_duplicates_fail_closed(self):
        values = contracts(self.gate)
        for changed in ([], values[:-1], values + values[:1],
                        [dict(values[0], error_category="wrong"), *values[1:]]):
            with self.assertRaises(ValueError):
                self.gate.validate_product_reports(reports(self.gate), changed)

    def test_workspace_copies_authoritative_inputs(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name) / "project"
            manifest = self.gate.write_product_workspace(root)
            self.assertEqual(manifest.read_bytes(), (self.gate.FIXTURES / "pafio.toml").read_bytes())
            self.assertEqual((root / "src/main.styio").read_bytes(),
                             (self.gate.FIXTURES / "t13_task_history_capture.styio").read_bytes())

    def test_missing_inputs_fail_without_skips(self):
        for environment in ({}, {"CI": "true"}):
            output = io.StringIO()
            with tempfile.TemporaryDirectory() as name, \
                 mock.patch.object(self.gate, "ROOT", Path(name)), \
                 mock.patch.dict("os.environ", environment, clear=True), redirect_stdout(output):
                evidence = Path(name) / "build/resource-integration"
                evidence.mkdir(parents=True)
                (evidence / "latest.json").write_text('{"directory":"previous-success"}')
                self.assertEqual(self.gate.main(["--json"]), 1)
                latest = json.loads((evidence / "latest.json").read_text())
                retained = json.loads((Path(latest['directory']) / "gate-report.json").read_text())
                self.assertFalse(retained['ok'])
                self.assertEqual(retained['failure_category'], 'matrix_inputs_unavailable')
                self.assertFalse((Path(latest['directory']) / "process.json").exists())
            value = json.loads(output.getvalue())
            self.assertFalse(value["ok"])
            self.assertFalse(value["skipped"])

    def run_main(self, result):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            args = ["--platform", self.gate.host_platform(), "--json"]
            for binary, option in (("styio", "--styio-bin"), ("pafio", "--pafio-bin"),
                                   ("styio_lspd", "--lspd-bin"), ("vityod", "--vityod-bin")):
                path = root / binary
                path.touch()
                args += [option, str(path)]
            output = io.StringIO()
            with mock.patch.object(self.gate, "ROOT", root), \
                 mock.patch.object(self.gate, "build_product_environment", return_value={}), \
                 mock.patch.object(self.gate, "run_product_process", return_value=result), redirect_stdout(output):
                code = self.gate.main(args)
            return code, json.loads(output.getvalue())

    def test_complete_report_is_admitted(self):
        code, value = self.run_main(self.gate.ProcessResult(0, markers(self.gate), b""))
        self.assertEqual(code, 0)
        self.assertTrue(value["ok"])
        self.assertEqual(value["report"]["scenario_count"], len(self.gate.EXPECTED_CASES))

    def test_failed_or_invalid_process_never_copies_untrusted_reports(self):
        for result in (self.gate.ProcessResult(37, markers(self.gate), b""),
                       self.gate.ProcessResult(0, b"", b""),
                       self.gate.ProcessResult(0, b'VITYO_PRODUCT_REPORT {"stdout":"private"}', b"")):
            code, value = self.run_main(result)
            self.assertEqual(code, 1)
            self.assertEqual(value["report"]["scenarios"], [])
            self.assertNotIn("private", json.dumps(value))


if __name__ == "__main__":
    unittest.main()
