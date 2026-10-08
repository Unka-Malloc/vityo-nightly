from __future__ import annotations

import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    'dart_pipe', ROOT / 'scripts/test-windows-dart-pipe.py')
harness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(harness)


class DartPipeHarnessTests(unittest.TestCase):
    def fake_spawn(self, *, client_timeout=False, client_output=True):
        self.server = Mock(returncode=0)
        self.client = Mock(returncode=0)
        self.server.poll.return_value = None
        self.client.poll.return_value = None
        if client_timeout:
            self.client.wait.side_effect = [subprocess.TimeoutExpired('dart', 20), 0]

        def spawn(command, **kwargs):
            if '--server' in command:
                control = Path(command[command.index('--control') + 1])
                (control / 'ready').write_text('ready')
                return self.server
            if client_output:
                kwargs['stdout'].write((json.dumps({'phase': 'passed', 'case': command[3]}) + '\n').encode())
                kwargs['stdout'].flush()
            return self.client
        return spawn

    def test_real_worker_command_and_natural_completion(self):
        with patch.object(harness.subprocess, 'Popen', side_effect=self.fake_spawn()) as spawn:
            report = harness.supervise('reader-first', 'verified-dart.exe')
        self.assertEqual(report['status'], 'passed')
        self.assertTrue(report['cleanup_completed'])
        command = spawn.call_args_list[1].args[0]
        self.assertEqual(command[0], 'verified-dart.exe')
        self.assertIn('windows_named_pipe_regression.dart', command[2])
        self.assertEqual(command[3], 'reader-first')
        self.assertNotIn('shell', spawn.call_args_list[1].kwargs)

    def test_watchdog_kills_only_both_owned_children_with_bounded_reap(self):
        with patch.object(harness.subprocess, 'Popen',
                          side_effect=self.fake_spawn(client_timeout=True)):
            report = harness.supervise('stalled-write', 'dart.exe')
        self.assertEqual(report['status'], 'timeout')
        self.assertTrue(report['watchdog_expired'])
        self.client.kill.assert_called_once_with()
        self.server.kill.assert_called_once_with()
        self.assertEqual(self.client.wait.call_args.kwargs, {'timeout': 2})
        self.assertEqual(self.server.wait.call_args.kwargs, {'timeout': 2})

    def test_zero_exit_without_assertions_is_failure(self):
        with patch.object(harness.subprocess, 'Popen',
                          side_effect=self.fake_spawn(client_output=False)):
            report = harness.supervise('peer-disconnect', 'dart.exe')
        self.assertEqual(report['status'], 'failed')
        self.assertIn('without passing assertions', report['error'])

    def test_failed_reap_is_reported_and_other_child_still_reaped(self):
        spawn = self.fake_spawn(client_timeout=True)
        self.client.wait.side_effect = subprocess.TimeoutExpired('dart', 20)
        with patch.object(harness.subprocess, 'Popen', side_effect=spawn):
            report = harness.supervise('queued-close', 'dart.exe')
        self.assertEqual(report['status'], 'cleanup-failed')
        self.assertFalse(report['cleanup_completed'])
        self.server.kill.assert_called_once_with()

    def test_spawn_failure_still_writes_failure_report(self):
        with patch.object(harness.subprocess, 'Popen', side_effect=OSError('spawn failed')):
            report = harness.supervise('reader-first', 'dart.exe')
        self.assertEqual(report['status'], 'failed')
        self.assertTrue(report['cleanup_completed'])

    def test_flutter_batch_wrapper_resolves_to_direct_native_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            wrapper = Path(directory) / 'dart.bat'
            wrapper.write_text('wrapper')
            native = Path(directory) / 'cache/dart-sdk/bin/dart.exe'
            native.parent.mkdir(parents=True)
            native.write_bytes(b'placeholder')
            with patch.object(harness.shutil, 'which', return_value=str(wrapper)):
                self.assertEqual(harness.resolve_dart('dart'), str(native.resolve()))

    def test_batch_wrapper_without_native_executable_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            wrapper = Path(directory) / 'dart.bat'
            with patch.object(harness.shutil, 'which', return_value=str(wrapper)):
                self.assertIsNone(harness.resolve_dart('dart'))

    def test_suite_stops_when_an_owned_child_cannot_be_reaped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'products/vityo_app/.dart_tool/package_config.json'
            config.parent.mkdir(parents=True)
            config.write_text('{}')
            output = root / 'report.json'
            with patch.object(harness, 'ROOT', root), \
                 patch.object(harness, 'os', SimpleNamespace(name='nt')), \
                 patch.object(harness, 'resolve_dart', return_value='dart.exe'), \
                 patch.object(harness, 'supervise', return_value={
                     'case': 'reader-first', 'status': 'cleanup-failed',
                     'cleanup_completed': False}) as supervise, \
                 patch('sys.stdout', new=io.StringIO()):
                self.assertEqual(harness.main(['--output', str(output)]), 1)
            self.assertEqual(supervise.call_count, 1)
            self.assertEqual(json.loads(output.read_text())['status'], 'failed')

    def test_logs_are_bounded_marked_and_redacted(self):
        root = Path('/workspace/private-repo')
        text = str(root / 'products/vityo_app/tool/worker.dart') + '\n'
        log = io.BytesIO(text.encode() + b'x' * harness.MAX_LOG_BYTES)
        output, truncated = harness.read_log(log, [
            (root / 'products/vityo_app', '<app>'), (root, '<repo>')])
        self.assertTrue(truncated)
        self.assertIn('<app>', output)
        self.assertNotIn(str(root), output)
        self.assertEqual(log.tell(), harness.MAX_LOG_BYTES + 1)
        self.assertFalse(harness.read_log(io.BytesIO(b'hello'), [])[1])

    def test_error_paths_are_redacted_and_elapsed_is_recorded(self):
        private = str(ROOT / 'products/vityo_app/missing-file')
        with patch.object(harness.subprocess, 'Popen', side_effect=OSError(private)):
            report = harness.supervise('reader-first', 'dart.exe')
        self.assertNotIn(str(ROOT), report['error'])
        self.assertIn('<app>', report['error'])
        self.assertGreaterEqual(report['elapsed_seconds'], 0)
        self.assertFalse(report['client_output_truncated'])

    def test_pass_marker_must_be_json_for_the_actual_case(self):
        self.assertFalse(harness.passed_case('prefix "phase":"passed"', 'reader-first'))
        self.assertFalse(harness.passed_case(
            '{"phase":"passed","case":"queued-close"}', 'reader-first'))
        self.assertTrue(harness.passed_case(
            'noise\n{"phase":"passed","case":"reader-first"}', 'reader-first'))

    def test_fixed_cases_only(self):
        with self.assertRaises(ValueError):
            harness.supervise('arbitrary', 'dart.exe')

    @unittest.skipIf(harness.os.name == 'nt', 'tests non-Windows refusal')
    def test_non_windows_is_not_a_native_pass(self):
        with tempfile.TemporaryDirectory() as directory, patch('sys.stdout', new=io.StringIO()):
            output = Path(directory) / 'report.json'
            self.assertEqual(harness.main(['--output', str(output)]), 2)
            report = json.loads(output.read_text())
            self.assertEqual(report['status'], 'not-run')
            self.assertEqual(report['schema_version'], 1)
            self.assertTrue(report['os'])
            self.assertTrue(report['architecture'])

    @unittest.skipIf(harness.os.name == 'nt', 'symlink privilege is not assumed')
    def test_batch_wrapper_through_directory_alias_is_canonical(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            real = root / 'real'
            real.mkdir()
            wrapper = real / 'dart.bat'
            wrapper.write_text('wrapper', encoding='ascii')
            native = real / 'cache/dart-sdk/bin/dart.exe'
            native.parent.mkdir(parents=True)
            native.write_text('fixture', encoding='ascii')
            alias = root / 'alias'
            alias.symlink_to(real, target_is_directory=True)
            with patch.object(harness.shutil, 'which', return_value=str(alias / 'dart.bat')):
                self.assertEqual(harness.resolve_dart('dart'), str(native.resolve()))

    def test_reader_must_be_live_before_peer_disconnect(self):
        source = (ROOT / 'products/vityo_app/tool/windows_named_pipe_regression.dart').read_text()
        self.assertLess(source.index('check(!done.isCompleted'), source.index("scenario == 'peer-disconnect'"))
        self.assertIn('reader failed before scenario action', source)

    def test_last_error_is_resolved_before_first_fallible_api(self):
        source = (ROOT / 'products/vityo_app/lib/src/ide/local_service/transport/windows_named_pipe.dart').read_text()
        opening = source.split('int _openPipe(String endpoint)', 1)[1]
        self.assertLess(opening.index('_getLastError();'), opening.index('_createFile('))
        getter = source.split('final _GetLastErrorDart _getLastError', 1)[1].split('int _openPipe', 1)[0]
        self.assertIn('isLeaf: true', getter)
        waiting = source.split('final _WaitNamedPipeWDart', 1)[1].split('final _ReadFileDart', 1)[0]
        self.assertNotIn('isLeaf: true', waiting)

    def test_dart_worker_imports_production_transport_without_mocks(self):
        source = (ROOT / 'products/vityo_app/tool/windows_named_pipe_regression.dart').read_text()
        self.assertIn("import 'package:vityo_app/src/ide/local_service/transport/windows_named_pipe.dart'", source)
        self.assertIn('WindowsNamedPipeConnection.connect', source)
        self.assertNotIn('exit(', source.replace('exit():', 'exit:'))


if __name__ == '__main__':
    unittest.main()
