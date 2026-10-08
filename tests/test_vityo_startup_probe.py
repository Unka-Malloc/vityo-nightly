from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import vityo_startup_probe as probe


@unittest.skipIf(os.name != "posix", "macOS CI uses POSIX pipe supervision")
class StartupSupervisorTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.diagnostics = self.root / "diagnostics.json"

    def run_child(self, source, **kwargs):
        code = probe.run_macos_startup_probe(
            [sys.executable, "-c", source], self.root, self.diagnostics, **kwargs
        )
        return code, json.loads(self.diagnostics.read_text())

    def test_success_captures_output_and_real_exit_status(self):
        code, report = self.run_child("import sys; print('ready'); print('warning', file=sys.stderr)")
        self.assertEqual(code, 0)
        self.assertEqual(report["stdout"], "ready\n")
        self.assertEqual(report["stderr"], "warning\n")
        self.assertGreater(report["pid"], 0)
        self.assertFalse(report["timed_out"])
        self.assertEqual(report["returncode"], 0)

    def test_nonzero_exit_is_not_success(self):
        code, report = self.run_child("raise SystemExit(7)")
        self.assertEqual(code, 7)
        self.assertEqual(report["returncode"], 7)

    def test_hung_child_is_terminated_and_reaped(self):
        code, report = self.run_child("import time; time.sleep(60)", timeout_seconds=0.2, grace_seconds=0.2)
        self.assertEqual(code, 2)
        self.assertTrue(report["timed_out"])
        self.assertFalse(report["forced_kill"])
        with self.assertRaises(ChildProcessError):
            os.waitpid(report["pid"], os.WNOHANG)
        with self.assertRaises(ProcessLookupError):
            os.kill(report["pid"], 0)

    def test_timeout_leaves_an_unrelated_process_alive(self):
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        try:
            code, report = self.run_child("import time; time.sleep(60)", timeout_seconds=0.2, grace_seconds=0.2)
            self.assertEqual(code, 2)
            self.assertNotEqual(report["pid"], unrelated.pid)
            self.assertIsNone(unrelated.poll())
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=5)

    def test_ignored_termination_is_killed_and_reaped(self):
        code, report = self.run_child(
            "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready', flush=True); time.sleep(60)",
            timeout_seconds=0.5, grace_seconds=0.1,
        )
        self.assertEqual(code, 2)
        self.assertEqual(report["stdout"], "ready\n")
        self.assertTrue(report["forced_kill"])
        with self.assertRaises(ChildProcessError):
            os.waitpid(report["pid"], os.WNOHANG)

    def test_inherited_pipes_have_a_separate_bounded_post_exit_drain(self):
        import signal
        for active_writer in (False, True):
            with self.subTest(active_writer=active_writer):
                marker = self.root / "descendant.pid"
                source = (
                    "import os,time\n"
                    "child = os.fork()\n"
                    "if child:\n"
                    f" open({str(marker)!r}, 'w').write(str(child))\n"
                    " os._exit(0)\n"
                    + ("while True:\n os.write(1, b'x'*4096)\n" if active_writer else "time.sleep(30)\n")
                )
                try:
                    code, report = self.run_child(source, timeout_seconds=3)
                    self.assertEqual(code, 0)
                    self.assertFalse(report["timed_out"])
                    self.assertFalse(report["forced_kill"])
                    self.assertLess(report["elapsed_seconds"], 1.5)
                finally:
                    # This test owns its synthetic descendant; the supervisor
                    # must never discover or signal it.
                    if marker.exists():
                        try:
                            os.kill(int(marker.read_text()), signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                        marker.unlink()

    def test_output_is_drained_but_storage_is_bounded(self):
        code, report = self.run_child(
            "import sys; print('ready'); sys.stdout.write('x'*1000000); sys.stderr.write('y'*1000000)"
        )
        self.assertEqual(code, 0)
        self.assertEqual(report["stdout"], "ready\n")
        self.assertEqual(report["stderr"], "")
        self.assertEqual(report["truncated"], {"stdout": True, "stderr": True})
        self.assertLess(self.diagnostics.stat().st_size, 2000)

    def test_diagnostics_redact_inherited_credentials_without_environment_dump(self):
        value = "synthetic-" + "credential-value"
        with mock.patch.dict(os.environ, {"VITYO_TEST_TOKEN": value, "VITYO_TEST_ORDINARY": "not-to-be-dumped"}):
            code, report = self.run_child("import os; print(os.environ['VITYO_TEST_TOKEN'])")
        self.assertEqual(code, 0)
        self.assertEqual(report["stdout"], "[redacted]\n")
        self.assertNotIn(value, self.diagnostics.read_text())
        self.assertNotIn("not-to-be-dumped", self.diagnostics.read_text())

    def test_pipe_setup_failure_reaps_the_owned_child(self):
        with mock.patch.object(probe.os, "set_blocking", side_effect=OSError("synthetic failure")):
            code, report = self.run_child("import time; time.sleep(60)", grace_seconds=0.2)
        self.assertEqual(code, 2)
        self.assertEqual(report["failure"], "OSError")
        with self.assertRaises(ChildProcessError):
            os.waitpid(report["pid"], os.WNOHANG)

    def test_missing_executable_fails_with_diagnostics(self):
        code = probe.run_macos_startup_probe([str(self.root / "missing")], self.root, self.diagnostics)
        report = json.loads(self.diagnostics.read_text())
        self.assertEqual(code, 2)
        self.assertEqual(report["failure"], "FileNotFoundError")
        self.assertIsNone(report["pid"])


class InstalledMacProbeContractTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("startup_delivery_under_test", ROOT / "scripts/vityo.py")
        self.delivery = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = self.delivery
        spec.loader.exec_module(self.delivery)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.options = self.delivery.DeliveryOptions(mode="ci", platform="macos")
        self.app = self.root / "installed app.app"
        self.candidate = "vityo-test.dmg"
        self.evidence = self.root / "build/evidence/startup-macos.json"
        patch = mock.patch.object(self.delivery, "ROOT", self.root)
        patch.start()
        self.addCleanup(patch.stop)
        import shutil
        contract = self.root / "packaging/vityo/desktop_delivery.py"
        contract.parent.mkdir(parents=True)
        shutil.copy(ROOT / "packaging/vityo/desktop_delivery.py", contract)

    def payload(self, **changes):
        return dict(schema_version=1, candidate=self.candidate, platform="macos", launched=True, first_frame=True, **changes)

    def invoke(self, runner):
        with mock.patch.object(self.delivery, "host_platform", return_value="macos"), mock.patch.object(
            self.delivery, "run_macos_startup_probe", side_effect=runner
        ), mock.patch.object(self.delivery, "run_command", side_effect=AssertionError("CI must not use open")):
            return self.delivery._run_ci_startup_probe(self.options, app_root=self.app, candidate=self.candidate)

    def test_direct_installed_binary_and_arguments_preserve_spaces_and_identity(self):
        def runner(command, cwd, diagnostics):
            self.assertEqual(command, [str(self.app / "Contents/MacOS/Vityo"), "--vityo-startup-probe", "--vityo-candidate", self.candidate, "--vityo-evidence-file", str(self.evidence)])
            self.assertEqual(cwd, self.app)
            self.assertEqual(diagnostics, self.evidence.with_name("startup-macos-diagnostics.json"))
            self.evidence.write_text(json.dumps(self.payload()))
            return 0
        self.assertEqual(self.invoke(runner), 0)

    def test_zero_exit_cannot_reuse_stale_evidence(self):
        self.evidence.parent.mkdir(parents=True)
        self.evidence.write_text(json.dumps(self.payload()))
        neighbor = self.evidence.with_name("other-evidence.json")
        neighbor.write_text("keep")
        def runner(*args):
            self.assertFalse(self.evidence.exists())
            return 0
        self.assertEqual(self.invoke(runner), 2)
        self.assertEqual(neighbor.read_text(), "keep")

    def test_malformed_and_wrong_candidate_evidence_fail(self):
        for text in ("{", json.dumps({**self.payload(), "candidate": "other.dmg"}), json.dumps({**self.payload(), "first_frame": False})):
            with self.subTest(text=text):
                def runner(*args):
                    self.evidence.write_text(text)
                    return 0
                self.assertEqual(self.invoke(runner), 2)

    def test_nonzero_exit_fails_even_with_valid_evidence(self):
        def runner(*args):
            self.evidence.write_text(json.dumps(self.payload()))
            return 7
        self.assertEqual(self.invoke(runner), 7)
