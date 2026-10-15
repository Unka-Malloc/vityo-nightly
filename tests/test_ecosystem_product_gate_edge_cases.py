"""Marker framing, privacy, true exits and full output retention."""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from test_ecosystem_product_gate import load_gate_module, markers


class EcosystemProductGateEdgeCaseTest(unittest.TestCase):
    def setUp(self):
        self.gate = load_gate_module()

    def test_host_platform_maps_supported_platforms(self):
        for raw, expected in (("darwin", "macos"), ("win32", "windows"), ("linux", "linux")):
            with mock.patch.object(self.gate.sys, "platform", raw):
                self.assertEqual(self.gate.host_platform(), expected)

    def test_exact_markers_and_flutter_prefix(self):
        for content in (markers(self.gate), b"\n".join(b"Shell: " + line for line in markers(self.gate).splitlines())):
            self.gate.validate_product_reports(*self.gate.parse_product_reports(content))

    def test_invalid_embedded_duplicate_json_and_oversized_markers_fail(self):
        for value in (b"", b"[]", b"null", b"{", b'{"case":1,"case":2}',
                      b'{"value":NaN}', b'{"value":Infinity}', b"x" * (self.gate.MARKER_LIMIT + 1)):
            with self.assertRaises(ValueError):
                self.gate.parse_product_reports(self.gate.PRODUCT_MARKER + value)
        with self.assertRaises(ValueError):
            self.gate.parse_product_reports(b"prefix " + self.gate.PRODUCT_MARKER + b"{}")

    def test_privacy_rejects_fields_and_cross_platform_paths(self):
        for value in ({"stdout": "private"}, {"nested": {"password": "private"}},
                      {"path": "/private/example"}, {"path": "C:/private/example"},
                      {"text": "x" * (self.gate.PROJECTED_STRING_LIMIT + 1)}):
            with self.assertRaises(ValueError):
                self.gate._validate_privacy(value)

    def test_full_output_and_true_failure_exit(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            result = self.gate.run_product_process(
                [sys.executable, "-c", "import sys; sys.stdout.write('x'*1100000); sys.stderr.write('complete'); sys.exit(37)"],
                cwd=root, env={**os.environ, "VITYO_PRODUCT_EVIDENCE": str(root)})
            self.assertEqual(result.returncode, 37)
            self.assertIsNone(result.failure_category)
            self.assertEqual(len(result.stdout), 1100000)
            self.assertEqual(result.stderr, b"complete")
            self.assertEqual((root / "flutter.stdout.log").read_bytes(), result.stdout)
            self.assertEqual(json.loads((root / "process.json").read_text())["exit_code"], 37)

    def test_launch_failure_is_unexecuted(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            with self.assertRaises(OSError):
                self.gate.run_product_process([str(root / "missing")], cwd=root,
                    env={"VITYO_PRODUCT_EVIDENCE": str(root)})
            self.assertIsNone(json.loads((root / "process.json").read_text())["exit_code"])

    def test_no_timeout_is_sent_to_process_owner(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            with mock.patch.object(self.gate.subprocess, "run", return_value=mock.Mock(returncode=0)) as run:
                self.gate.run_product_process(["held"], cwd=root, env={"VITYO_PRODUCT_EVIDENCE": str(root)})
            self.assertNotIn("timeout", run.call_args.kwargs)


if __name__ == "__main__":
    unittest.main()
