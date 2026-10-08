from __future__ import annotations

import importlib.util
import ctypes
from contextlib import ExitStack
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

    def test_nonzero_client_or_server_exit_cannot_pass_assertion_marker(self):
        for failing in ('client', 'server'):
            with self.subTest(failing=failing):
                spawn = self.fake_spawn()
                getattr(self, failing).returncode = 7
                with patch.object(harness.subprocess, 'Popen', side_effect=spawn):
                    report = harness.supervise('reader-first', 'dart.exe')
                self.assertEqual(report['status'], 'failed')
                self.assertEqual(report['error'],
                                 'Dart client failed' if failing == 'client' else 'native server failed')
                self.assertTrue(report['cleanup_completed'])

    def test_delayed_ready_waits_then_launches_the_client(self):
        original_spawn = self.fake_spawn()
        controls = []
        def spawn(command, **kwargs):
            process = original_spawn(command, **kwargs)
            if '--server' in command:
                control = Path(command[command.index('--control') + 1])
                (control / 'ready').unlink()
                controls.append(control)
            return process
        with patch.object(harness.subprocess, 'Popen', side_effect=spawn) as popen, \
             patch.object(harness.time, 'sleep',
                          side_effect=lambda _: (controls[0] / 'ready').touch()) as sleep:
            report = harness.supervise('reader-first', 'dart.exe')
        self.assertEqual(report['status'], 'passed')
        self.assertEqual(popen.call_count, 2)
        sleep.assert_called_once_with(0.01)

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
        root = Path(tempfile.gettempdir()).resolve() / 'private-repo'
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

    def test_non_windows_is_not_a_native_pass(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(harness, 'os', SimpleNamespace(name='posix')), \
             patch('sys.stdout', new=io.StringIO()):
            output = Path(directory) / 'report.json'
            self.assertEqual(harness.main(['--output', str(output)]), 2)
            report = json.loads(output.read_text())
            self.assertEqual(report['status'], 'not-run')
            self.assertEqual(report['schema_version'], 1)
            self.assertTrue(report['os'])
            self.assertTrue(report['architecture'])

    def test_dart_worker_imports_production_transport_without_mocks(self):
        source = (ROOT / 'products/vityo_app/tool/windows_named_pipe_regression.dart').read_text()
        self.assertIn("import 'package:vityo_app/src/ide/local_service/transport/windows_named_pipe.dart'", source)
        self.assertIn('WindowsNamedPipeConnection.connect', source)
        self.assertNotIn('exit(', source.replace('exit():', 'exit:'))


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


class NativeServerBoundaryTests(unittest.TestCase):
    """Portable server-control tests with fake syscalls, not native I/O proof."""

    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.control = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.kernel = SimpleNamespace(**{name: Mock() for name in (
            'CreateNamedPipeW', 'ConnectNamedPipe', 'ReadFile', 'WriteFile', 'CloseHandle')})
        self.kernel.CreateNamedPipeW.return_value = 77
        self.kernel.ConnectNamedPipe.return_value = 1
        self.kernel.CloseHandle.return_value = 1
        self.chunks = [b'pi', b'ng\n']
        self.written = []
        self.kernel.ReadFile.side_effect = self.read
        self.kernel.WriteFile.side_effect = self.write
        self.loader = self.stack.enter_context(patch.object(
            harness.ctypes, 'WinDLL', return_value=self.kernel, create=True))
        self.last_error = self.stack.enter_context(patch.object(
            harness.ctypes, 'get_last_error', return_value=109, create=True))
        self.win_error = self.stack.enter_context(patch.object(
            harness.ctypes, 'WinError', side_effect=lambda code: OSError(code, 'fake Win32 error'),
            create=True))

    @staticmethod
    def set_count(pointer, count):
        from ctypes import wintypes
        ctypes.cast(pointer, ctypes.POINTER(wintypes.DWORD)).contents.value = count

    def read(self, handle, buffer, capacity, count, overlapped):
        self.assertEqual(handle, 77)
        self.assertIsNone(overlapped)
        chunk = self.chunks.pop(0)
        self.assertLessEqual(len(chunk), capacity)
        ctypes.memmove(buffer, chunk, len(chunk))
        self.set_count(count, len(chunk))
        return 1

    def write(self, handle, buffer, size, count, overlapped):
        self.assertEqual(handle, 77)
        self.assertIsNone(overlapped)
        self.written.append(ctypes.string_at(buffer, size))
        self.set_count(count, size)
        return 1

    def run_server(self, scenario='reader-first'):
        return harness.native_server(scenario, 'fake-private-endpoint', self.control)

    def test_partial_request_is_reassembled_then_exact_response_written(self):
        (self.control / 'stop').touch()
        self.assertEqual(self.run_server(), 0)
        self.assertEqual((self.control / 'ready').read_text(), 'ready')
        self.assertEqual(self.kernel.ReadFile.call_count, 2)
        self.assertEqual(self.written, [b'pong\n'])
        self.kernel.CreateNamedPipeW.assert_called_once_with(
            'fake-private-endpoint', 3, 0, 1, 4096, 4096, 0, None)
        self.loader.assert_called_once_with('kernel32', use_last_error=True)
        self.kernel.CloseHandle.assert_called_once_with(77)

    def test_already_connected_race_is_accepted(self):
        self.kernel.ConnectNamedPipe.return_value = 0
        self.last_error.return_value = 535
        (self.control / 'stop').touch()
        self.assertEqual(self.run_server('stalled-write'), 0)
        self.kernel.ReadFile.assert_not_called()
        self.kernel.CloseHandle.assert_called_once_with(77)

    def test_stalled_server_waits_for_stop_without_reading_or_writing(self):
        with patch.object(harness.time, 'sleep',
                          side_effect=lambda _: (self.control / 'stop').touch()) as sleep:
            self.assertEqual(self.run_server('queued-close'), 0)
        sleep.assert_called_once_with(0.01)
        self.kernel.ReadFile.assert_not_called()
        self.kernel.WriteFile.assert_not_called()
        self.kernel.CloseHandle.assert_called_once_with(77)

    def test_peer_waits_for_explicit_disconnect_then_closes(self):
        with patch.object(harness.time, 'sleep',
                          side_effect=lambda _: (self.control / 'disconnect').touch()) as sleep:
            self.assertEqual(self.run_server('peer-disconnect'), 0)
        sleep.assert_called_once_with(0.01)
        self.assertFalse((self.control / 'stop').exists())
        self.kernel.ReadFile.assert_not_called()
        self.kernel.CloseHandle.assert_called_once_with(77)

    def test_invalid_handle_is_reported_without_closing_invalid_handle(self):
        from ctypes import wintypes
        self.kernel.CreateNamedPipeW.return_value = wintypes.HANDLE(-1).value
        with self.assertRaises(OSError):
            self.run_server()
        self.win_error.assert_called_once_with(109)
        self.kernel.CloseHandle.assert_not_called()
        self.assertFalse((self.control / 'ready').exists())

    def test_connect_error_closes_created_handle(self):
        self.kernel.ConnectNamedPipe.return_value = 0
        with self.assertRaises(OSError):
            self.run_server()
        self.kernel.CloseHandle.assert_called_once_with(77)
        self.kernel.ReadFile.assert_not_called()

    def test_read_error_closes_handle_without_response(self):
        self.kernel.ReadFile.side_effect = None
        self.kernel.ReadFile.return_value = 0
        with self.assertRaises(OSError):
            self.run_server()
        self.kernel.CloseHandle.assert_called_once_with(77)
        self.kernel.WriteFile.assert_not_called()

    def test_zero_byte_read_is_eof_not_busy_loop(self):
        self.chunks = [b'']
        with self.assertRaisesRegex(RuntimeError, 'client closed before request'):
            self.run_server()
        self.assertEqual(self.kernel.ReadFile.call_count, 1)
        self.kernel.CloseHandle.assert_called_once_with(77)

    def test_unexpected_request_is_rejected_before_response(self):
        self.chunks = [b'wrong']
        with self.assertRaisesRegex(RuntimeError, 'unexpected client request'):
            self.run_server()
        self.kernel.WriteFile.assert_not_called()
        self.kernel.CloseHandle.assert_called_once_with(77)

    def test_write_error_closes_handle(self):
        self.kernel.WriteFile.side_effect = None
        self.kernel.WriteFile.return_value = 0
        with self.assertRaises(OSError):
            self.run_server()
        self.kernel.CloseHandle.assert_called_once_with(77)

    def test_short_response_is_failure_not_false_pass(self):
        def short_write(handle, buffer, size, count, overlapped):
            self.set_count(count, size - 1)
            return 1
        self.kernel.WriteFile.side_effect = short_write
        with self.assertRaisesRegex(RuntimeError, 'short server response'):
            self.run_server()
        self.kernel.CloseHandle.assert_called_once_with(77)


class HarnessOrchestrationTests(unittest.TestCase):
    def test_resolver_missing_and_direct_executable(self):
        with patch.object(harness.shutil, 'which', return_value=None):
            self.assertIsNone(harness.resolve_dart('missing'))
        executable = Path(tempfile.gettempdir()) / 'custom-DART.EXE'
        with patch.object(harness.shutil, 'which', return_value=str(executable)):
            self.assertEqual(harness.resolve_dart('custom'), str(executable.resolve()))

    def test_reap_finished_process_does_not_kill_and_kill_error_is_bounded(self):
        finished = Mock()
        finished.poll.return_value = 0
        self.assertTrue(harness.reap(finished))
        finished.kill.assert_not_called()
        finished.wait.assert_called_once_with(timeout=harness.REAP_TIMEOUT)
        live = Mock()
        live.poll.return_value = None
        live.kill.side_effect = OSError('denied')
        self.assertFalse(harness.reap(live))
        live.wait.assert_not_called()

    def test_server_dying_before_ready_never_starts_dart(self):
        server = Mock()
        server.poll.return_value = 7
        with patch.object(harness.subprocess, 'Popen', return_value=server) as spawn:
            report = harness.supervise('reader-first', 'dart.exe')
        self.assertEqual(spawn.call_count, 1)
        self.assertEqual(report['error'], 'server failed before ready')
        self.assertTrue(report['cleanup_completed'])

    def test_server_ready_timeout_reaps_server_without_starting_dart(self):
        server = Mock()
        server.poll.return_value = None
        with patch.object(harness.subprocess, 'Popen', return_value=server) as spawn, \
             patch.object(harness.time, 'monotonic', side_effect=[0, 0, 21, 22]):
            report = harness.supervise('reader-first', 'dart.exe')
        self.assertEqual(spawn.call_count, 1)
        self.assertEqual(report['status'], 'timeout')
        self.assertTrue(report['watchdog_expired'])
        server.kill.assert_called_once_with()

    def test_main_windows_missing_prerequisites_is_not_run(self):
        for dart in (None, 'dart.exe'):
            with self.subTest(dart=dart), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                output = root / 'report.json'
                with patch.object(harness, 'ROOT', root), \
                     patch.object(harness, 'os', SimpleNamespace(name='nt')), \
                     patch.object(harness, 'resolve_dart', return_value=dart), \
                     patch.object(harness, 'supervise') as supervise, \
                     patch('sys.stdout', new=io.StringIO()):
                    self.assertEqual(harness.main(['--output', str(output)]), 2)
                self.assertEqual(json.loads(output.read_text())['status'], 'not-run')
                supervise.assert_not_called()

    def test_main_windows_aggregates_all_cases_without_shortcutting_failure(self):
        for failed_index in (None, 1):
            with self.subTest(failed_index=failed_index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                config = root / 'products/vityo_app/.dart_tool/package_config.json'
                config.parent.mkdir(parents=True)
                config.write_text('{}')
                output = root / 'report.json'
                reports = [{'case': case, 'cleanup_completed': True,
                            'status': 'failed' if index == failed_index else 'passed'}
                           for index, case in enumerate(harness.CASES)]
                with patch.object(harness, 'ROOT', root), \
                     patch.object(harness, 'os', SimpleNamespace(name='nt')), \
                     patch.object(harness, 'resolve_dart', return_value='dart.exe'), \
                     patch.object(harness, 'supervise', side_effect=reports) as supervise, \
                     patch('sys.stdout', new=io.StringIO()):
                    self.assertEqual(harness.main(['--output', str(output)]),
                                     0 if failed_index is None else 1)
                result = json.loads(output.read_text())
                self.assertEqual(result['status'], 'passed' if failed_index is None else 'failed')
                self.assertEqual(result['cases'], reports)
                self.assertEqual([call.args[0] for call in supervise.call_args_list], list(harness.CASES))

    def test_server_cli_requires_platform_endpoint_and_control(self):
        for platform_name, extra in [('posix', ['--endpoint', 'pipe', '--control', '.']),
                                     ('nt', []), ('nt', ['--endpoint', 'pipe'])]:
            with self.subTest(platform=platform_name, extra=extra), \
                 patch.object(harness, 'os', SimpleNamespace(name=platform_name)), \
                 patch.object(harness, 'native_server') as server, \
                 patch('sys.stderr', new=io.StringIO()), \
                 self.assertRaises(SystemExit) as raised:
                harness.main(['--server', 'reader-first', *extra])
            self.assertEqual(raised.exception.code, 2)
            server.assert_not_called()

    def test_server_cli_dispatches_only_the_fixed_requested_case(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(harness, 'os', SimpleNamespace(name='nt')), \
             patch.object(harness, 'native_server', return_value=7) as server:
            self.assertEqual(harness.main(['--server', 'peer-disconnect',
                                         '--endpoint', 'private-pipe', '--control', directory]), 7)
            server.assert_called_once_with('peer-disconnect', 'private-pipe', Path(directory))


if __name__ == '__main__':
    unittest.main()
