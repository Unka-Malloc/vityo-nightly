"""Portable supervisor tests; mocked Win32 calls are not native launch proof."""
from __future__ import annotations

from contextlib import ExitStack
import ctypes
import importlib.util
import io
import json
from pathlib import Path
import runpy
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, call, patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/diagnose-windows-pafio-launch.py'
SPEC = importlib.util.spec_from_file_location('pafio_launch_diagnostic', SCRIPT)
diagnostic = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(diagnostic)
CASE = 'direct-native'


def result_line(case=CASE, **fields):
    return (json.dumps({'case': case, 'phase': 'result', 'status': 'launched',
                        'exit_code': 0, **fields}) + '\n').encode()


class WindowsJobTests(unittest.TestCase):
    """Exercise the ctypes bindings on every host without loading kernel32."""

    API_NAMES = ('CreateJobObjectW', 'SetInformationJobObject',
                 'AssignProcessToJobObject', 'TerminateJobObject',
                 'QueryInformationJobObject', 'CloseHandle')

    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.kernel = SimpleNamespace(**{name: Mock(return_value=1)
                                        for name in self.API_NAMES})
        self.kernel.CreateJobObjectW.return_value = 71
        self.loader = self.stack.enter_context(patch.object(
            diagnostic.ctypes, 'WinDLL', return_value=self.kernel, create=True))
        self.last_error = self.stack.enter_context(patch.object(
            diagnostic.ctypes, 'get_last_error', return_value=5, create=True))
        self.win_error = self.stack.enter_context(patch.object(
            diagnostic.ctypes, 'WinError',
            side_effect=lambda code: OSError(code, 'mock Win32 failure'), create=True))

    def test_all_signatures_are_bound_before_create_and_kill_on_close_is_set(self):
        from ctypes import wintypes as w
        expected = {
            'CreateJobObjectW': ([ctypes.c_void_p, w.LPCWSTR], w.HANDLE),
            'SetInformationJobObject': ([w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD], w.BOOL),
            'AssignProcessToJobObject': ([w.HANDLE, w.HANDLE], w.BOOL),
            'TerminateJobObject': ([w.HANDLE, w.UINT], w.BOOL),
            'QueryInformationJobObject': ([w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD, ctypes.c_void_p], w.BOOL),
            'CloseHandle': ([w.HANDLE], w.BOOL),
        }
        def create(*args):
            for name, (argtypes, restype) in expected.items():
                function = getattr(self.kernel, name)
                self.assertEqual(function.argtypes, argtypes)
                self.assertIs(function.restype, restype)
            return 71
        self.kernel.CreateJobObjectW.side_effect = create
        job = diagnostic.WindowsJob()
        self.loader.assert_called_once_with('kernel32', use_last_error=True)
        self.kernel.CreateJobObjectW.assert_called_once_with(None, None)
        handle, kind, limits, size = self.kernel.SetInformationJobObject.call_args.args
        self.assertEqual((handle, kind), (71, 9))
        self.assertEqual(limits._obj.basic.flags, 0x2000)
        self.assertEqual(size, ctypes.sizeof(limits._obj))
        job.assign(SimpleNamespace(_handle='93'))
        self.kernel.AssignProcessToJobObject.assert_called_once_with(71, 93)
        job.close()
        job.close()
        self.kernel.CloseHandle.assert_called_once_with(71)
        self.assertIsNone(job.handle)
        self.last_error.assert_not_called()

    def test_create_failure_uses_cached_error_and_has_no_handle_to_close(self):
        self.kernel.CreateJobObjectW.return_value = 0
        with self.assertRaises(OSError) as caught:
            diagnostic.WindowsJob()
        self.assertEqual(caught.exception.errno, 5)
        self.last_error.assert_called_once_with()
        self.kernel.SetInformationJobObject.assert_not_called()
        self.kernel.CloseHandle.assert_not_called()

    def test_configuration_failure_captures_error_before_closing(self):
        self.kernel.SetInformationJobObject.return_value = 0
        order = []
        self.last_error.side_effect = lambda: order.append('error') or 87
        self.kernel.CloseHandle.side_effect = lambda handle: order.append('close') or 1
        with self.assertRaises(OSError) as caught:
            diagnostic.WindowsJob()
        self.assertEqual(caught.exception.errno, 87)
        self.assertEqual(order, ['error', 'close'])
        self.kernel.CloseHandle.assert_called_once_with(71)

    def test_assignment_failure_is_reported_without_relinquishing_job(self):
        job = diagnostic.WindowsJob()
        self.kernel.AssignProcessToJobObject.return_value = 0
        with self.assertRaises(OSError) as caught:
            job.assign(SimpleNamespace(_handle=93))
        self.assertEqual(caught.exception.errno, 5)
        self.assertEqual(job.handle, 71)
        self.kernel.CloseHandle.assert_not_called()
        job.close()

    def test_termination_queries_accounting_until_no_processes_remain(self):
        job = diagnostic.WindowsJob()
        active = iter((2, 1, 0))
        def query(handle, kind, info, size, returned):
            self.assertEqual((handle, kind, returned), (71, 1, None))
            self.assertEqual(size, ctypes.sizeof(job.Accounting))
            info._obj.active = next(active)
            return 1
        self.kernel.QueryInformationJobObject.side_effect = query
        with patch.object(diagnostic.time, 'monotonic', return_value=100), \
             patch.object(diagnostic.time, 'sleep') as sleep:
            self.assertTrue(job.terminate_and_wait())
        self.kernel.TerminateJobObject.assert_called_once_with(71, 1)
        self.assertEqual(sleep.call_args_list, [call(0.01), call(0.01)])
        job.close()

    def test_termination_failure_does_not_query_or_close_the_handle(self):
        job = diagnostic.WindowsJob()
        self.kernel.TerminateJobObject.return_value = 0
        with self.assertRaises(OSError) as caught:
            job.terminate_and_wait()
        self.assertEqual(caught.exception.errno, 5)
        self.kernel.QueryInformationJobObject.assert_not_called()
        self.kernel.CloseHandle.assert_not_called()
        job.close()

    def test_accounting_failure_is_an_error(self):
        job = diagnostic.WindowsJob()
        self.kernel.QueryInformationJobObject.return_value = 0
        with self.assertRaises(OSError) as caught:
            job.terminate_and_wait()
        self.assertEqual(caught.exception.errno, 5)
        job.close()

    def test_termination_deadline_is_bounded(self):
        job = diagnostic.WindowsJob()
        def still_running(*args):
            args[2]._obj.active = 1
            return 1
        self.kernel.QueryInformationJobObject.side_effect = still_running
        with patch.object(diagnostic.time, 'monotonic', side_effect=[10, 11]), \
             patch.object(diagnostic.time, 'sleep') as sleep:
            self.assertFalse(job.terminate_and_wait(timeout=1))
        sleep.assert_not_called()
        job.close()

    def test_failed_close_still_relinquishes_handle_and_never_double_closes(self):
        job = diagnostic.WindowsJob()
        self.kernel.CloseHandle.return_value = 0
        with self.assertRaises(OSError) as caught:
            job.close()
        self.assertEqual(caught.exception.errno, 5)
        self.assertIsNone(job.handle)
        job.close()
        self.kernel.CloseHandle.assert_called_once_with(71)


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.parent = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.fixture = self.parent / 'fixture'
        self.fixture.mkdir()
        self.stack.enter_context(patch.object(diagnostic.tempfile, 'mkdtemp', return_value=str(self.fixture)))
        self.events = []
        self.environment = {'Path': 'untouched-path', 'PATHEXT': '.COM;.EXE;.BAT;.CMD',
                            'SYSTEMROOT': 'native-system', 'ComSpec': 'original-command',
                            'SERVICE_TOKEN': 'supersecret-value'}
        self.process = Mock(returncode=0)
        self.process.stdin = io.BytesIO()
        self.process.poll.return_value = 0
        self.job = Mock()
        self.job.assign.side_effect = lambda process: self.events.append('assign')
        self.job.terminate_and_wait.side_effect = lambda: self.events.append('terminate') or True
        self.job.close.side_effect = lambda: self.events.append('close')
        self.factory = Mock(side_effect=lambda: self.events.append('job') or self.job)
        self.stack.enter_context(patch.object(diagnostic.time, 'monotonic', return_value=10))
        self.sleep = self.stack.enter_context(patch.object(diagnostic.time, 'sleep'))

    def spawn(self, command, **kwargs):
        self.events.append('spawn')
        self.assertIn('--worker', command)
        kwargs['stdout'].write(result_line())
        kwargs['stdout'].flush()
        return self.process

    def run_cell(self, spawn=None, *, deadline=100):
        with patch.object(diagnostic.subprocess, 'Popen', side_effect=spawn or self.spawn) as popen:
            report = diagnostic.supervise(CASE, 'verified-dart.exe', self.environment,
                                          deadline, job_factory=self.factory)
        self.popen = popen
        return report

    def assert_cleaned(self):
        self.job.terminate_and_wait.assert_called_once_with()
        self.job.close.assert_called_once_with()
        self.process.wait.assert_called_once_with(timeout=diagnostic.CLEANUP_TIMEOUT)
        self.assertTrue(self.process.stdin.closed)
        self.assertFalse(self.fixture.exists())

    def test_worker_is_assigned_before_gate_and_cleanup_runs_after_normal_exit(self):
        events = self.events
        class Gate(io.BytesIO):
            def write(self, data):
                events.append('gate-write')
                return super().write(data)
            def flush(self):
                events.append('gate-flush')
                return super().flush()
            def close(self):
                events.append('gate-close')
                super().close()
        self.process.stdin = Gate()
        report = self.run_cell()
        self.assertEqual(self.events, ['job', 'spawn', 'assign', 'gate-write',
                                     'gate-flush', 'gate-close', 'terminate', 'close'])
        self.assertEqual(report['status'], 'completed')
        self.assertEqual(report['result']['exit_code'], 0)
        self.assertFalse(report['watchdog_expired'])
        self.assertFalse(report['output_truncated'])
        self.assertEqual(report['elapsed_seconds'], 0)
        command = self.popen.call_args.args[0]
        self.assertEqual(command, [diagnostic.sys.executable, str(SCRIPT.resolve()),
                                  '--worker', CASE, '--dart', 'verified-dart.exe',
                                  '--fixture', str(self.fixture)])
        self.assertIs(self.popen.call_args.kwargs['env'], self.environment)
        self.assertEqual(self.popen.call_args.kwargs['stdin'], subprocess.PIPE)
        self.assertEqual(self.popen.call_args.kwargs['stderr'], subprocess.STDOUT)
        self.assertNotIn('shell', self.popen.call_args.kwargs)
        self.process.kill.assert_not_called()
        self.assert_cleaned()

    def test_assignment_failure_does_not_release_worker(self):
        self.job.assign.side_effect = OSError('cannot assign supersecret-value')
        self.process.poll.return_value = None
        gate = Mock(wraps=self.process.stdin)
        gate.closed = False
        self.process.stdin = gate
        report = self.run_cell()
        self.assertEqual(report['status'], 'error')
        self.assertIn('<redacted>', report['error'])
        gate.write.assert_not_called()
        gate.flush.assert_not_called()
        gate.close.assert_called_once_with()
        self.process.kill.assert_called_once_with()
        self.job.terminate_and_wait.assert_called_once_with()
        self.job.close.assert_called_once_with()
        self.process.wait.assert_called_once_with(timeout=diagnostic.CLEANUP_TIMEOUT)
        self.assertTrue(report['cleanup_completed'])

    def test_job_creation_failure_never_starts_worker(self):
        self.factory.side_effect = OSError('job unavailable')
        report = self.run_cell()
        self.assertEqual(report['status'], 'error')
        self.assertTrue(report['cleanup_completed'])
        self.assertIsNone(report['result'])
        self.popen.assert_not_called()
        self.job.close.assert_not_called()
        self.assertFalse(self.fixture.exists())

    def test_spawn_failure_terminates_and_closes_created_job(self):
        report = self.run_cell(Mock(side_effect=OSError('spawn unavailable')))
        self.assertEqual(report['status'], 'error')
        self.assertTrue(report['cleanup_completed'])
        self.job.terminate_and_wait.assert_called_once_with()
        self.job.close.assert_called_once_with()
        self.job.assign.assert_not_called()
        self.process.wait.assert_not_called()

    def test_gate_write_failure_cleans_worker_and_job(self):
        self.process.stdin = Mock(closed=False)
        self.process.stdin.write.side_effect = BrokenPipeError('gate closed')
        self.process.poll.return_value = None
        report = self.run_cell()
        self.assertEqual(report['status'], 'error')
        self.assertTrue(report['cleanup_completed'])
        self.process.stdin.flush.assert_not_called()
        self.process.stdin.close.assert_called_once_with()
        self.process.kill.assert_called_once_with()
        self.job.close.assert_called_once_with()

    def test_watchdog_retains_result_and_reaps_owned_process(self):
        self.process.poll.return_value = None
        report = self.run_cell(deadline=10)
        self.assertEqual(report['status'], 'timeout')
        self.assertTrue(report['watchdog_expired'])
        self.assertEqual(report['result']['status'], 'launched')
        self.assertIn('"phase": "result"', report['worker_output'])
        self.process.kill.assert_called_once_with()
        self.sleep.assert_not_called()
        self.assert_cleaned()

    def test_per_cell_deadline_limits_longer_parent_deadline(self):
        self.process.poll.return_value = None
        with patch.object(diagnostic.time, 'monotonic', side_effect=[10, 30, 31]):
            report = self.run_cell(deadline=1000)
        self.assertEqual(report['status'], 'timeout')
        self.assertEqual(report['elapsed_seconds'], 21)
        self.assert_cleaned()

    def test_alive_worker_is_polled_again_after_bounded_sleep(self):
        self.process.poll.side_effect = [None, 0, 0]
        report = self.run_cell()
        self.assertEqual(report['status'], 'completed')
        self.sleep.assert_called_once_with(0.02)
        self.assert_cleaned()

    def test_excessive_worker_output_is_bounded_and_not_success(self):
        self.process.poll.return_value = None
        def spawn(command, **kwargs):
            kwargs['stdout'].write(result_line() + b'x' * diagnostic.MAX_LOG_BYTES)
            kwargs['stdout'].flush()
            return self.process
        report = self.run_cell(spawn)
        self.assertEqual(report['status'], 'error')
        self.assertIn('exceeded', report['error'])
        self.assertTrue(report['output_truncated'])
        self.assertEqual(len(report['worker_output']), diagnostic.MAX_LOG_BYTES)
        self.assertEqual(report['result']['status'], 'launched')
        self.assert_cleaned()

    def test_zero_exit_without_matching_result_is_incomplete(self):
        def spawn(command, **kwargs):
            kwargs['stdout'].write(result_line('daemon-native'))
            return self.process
        report = self.run_cell(spawn)
        self.assertEqual(report['status'], 'incomplete-evidence')
        self.assertIsNone(report['result'])
        self.assertTrue(report['cleanup_completed'])

    def test_nonzero_exit_keeps_result_but_is_incomplete(self):
        self.process.returncode = 7
        report = self.run_cell()
        self.assertEqual(report['status'], 'incomplete-evidence')
        self.assertEqual(report['worker_exit'], 7)
        self.assertIsNotNone(report['result'])
        self.assert_cleaned()

    def test_failed_job_termination_is_redacted_and_still_closes(self):
        self.job.terminate_and_wait.side_effect = OSError(str(self.fixture) + '/supersecret-value')
        report = self.run_cell()
        self.assertEqual(report['status'], 'cleanup-failed')
        self.assertFalse(report['cleanup_completed'])
        self.assertEqual(report['cleanup_error'], '<fixture>/<redacted>')
        self.assertIsNotNone(report['result'])
        self.assert_cleaned()

    def test_gate_close_failure_during_cleanup_is_reported_and_evidence_survives(self):
        self.process.stdin = Mock(closed=False)
        self.process.stdin.write.side_effect = BrokenPipeError('gate write failed')
        self.process.stdin.close.side_effect = OSError('gate close failed')
        self.process.poll.return_value = None
        report = self.run_cell()
        self.assertEqual(report['status'], 'cleanup-failed')
        self.assertFalse(report['cleanup_completed'])
        self.assertEqual(report['result']['status'], 'launched')
        self.process.stdin.close.assert_called_once_with()
        self.process.kill.assert_called_once_with()
        self.process.wait.assert_called_once_with(timeout=diagnostic.CLEANUP_TIMEOUT)
        self.job.close.assert_called_once_with()
        self.assertFalse(self.fixture.exists())

    def test_gate_flush_failure_reaps_worker_before_closing_stdin(self):
        self.process.stdin = Mock(closed=False)
        self.process.stdin.flush.side_effect = BrokenPipeError('gate flush failed')
        self.process.poll.return_value = None
        report = self.run_cell()
        self.assertEqual(report['status'], 'error')
        self.assertTrue(report['cleanup_completed'])
        self.process.stdin.write.assert_called_once_with(b'GO\n')
        self.process.stdin.close.assert_called_once_with()
        self.process.kill.assert_called_once_with()
        self.job.close.assert_called_once_with()

    def test_job_cleanup_deadline_failure_is_not_success(self):
        self.job.terminate_and_wait.side_effect = None
        self.job.terminate_and_wait.return_value = False
        report = self.run_cell()
        self.assertEqual(report['status'], 'cleanup-failed')
        self.assertFalse(report['cleanup_completed'])
        self.assert_cleaned()

    def test_failed_job_close_still_reaps_worker_and_retains_result(self):
        self.job.close.side_effect = OSError('close failed')
        report = self.run_cell()
        self.assertEqual(report['status'], 'cleanup-failed')
        self.assertIsNotNone(report['result'])
        self.assert_cleaned()

    def test_failed_process_reap_is_reported_after_closing_job(self):
        self.process.wait.side_effect = subprocess.TimeoutExpired('worker', 3)
        report = self.run_cell()
        self.assertEqual(report['status'], 'cleanup-failed')
        self.assertFalse(report['cleanup_completed'])
        self.assert_cleaned()

    def test_failed_process_kill_does_not_claim_cleanup(self):
        self.process.poll.return_value = None
        self.process.kill.side_effect = OSError('cannot kill')
        report = self.run_cell(deadline=10)
        self.assertEqual(report['status'], 'cleanup-failed')
        self.assertTrue(report['watchdog_expired'])
        self.process.wait.assert_not_called()
        self.job.close.assert_called_once_with()
        self.assertFalse(self.fixture.exists())

    def test_directory_cleanup_failure_is_not_success(self):
        with patch.object(diagnostic.shutil, 'rmtree', side_effect=OSError('busy')):
            report = self.run_cell()
        self.assertEqual(report['status'], 'cleanup-failed')
        self.assertFalse(report['cleanup_completed'])
        self.assertIsNotNone(report['result'])
        self.job.close.assert_called_once_with()

    def test_unknown_cell_is_rejected_before_resources_are_created(self):
        with self.assertRaisesRegex(ValueError, 'unknown diagnostic cell'):
            diagnostic.supervise('arbitrary-command', 'dart', {}, 100, job_factory=self.factory)
        self.factory.assert_not_called()


class EvidenceTests(unittest.TestCase):
    def test_redaction_covers_case_slashes_json_escaping_and_secrets(self):
        fixture = Path('/private/repo/fixture')
        root = Path('/private/repo')
        home = Path('/private/home')
        executable = '/private/python/python.exe'
        secret = 'Sensitive-Credential'
        values = [str(fixture), str(fixture).upper(), str(fixture).replace('/', '\\'),
                  json.dumps(str(fixture).replace('/', '\\'))[1:-1], str(root),
                  str(home), '/private/python', secret, secret.upper(), 'tiny', 'ordinary-value']
        environment = {'API_KEY': secret, 'password': 'tiny', 'APP_NAME': 'ordinary-value'}
        with patch.object(diagnostic, 'ROOT', root), \
             patch.object(diagnostic.Path, 'home', return_value=home), \
             patch.object(diagnostic.sys, 'executable', executable):
            output = diagnostic.redact('\n'.join(values), fixture, environment)
        self.assertEqual(output.splitlines(), ['<fixture>'] * 4 + ['<repo>', '<home>',
                         '<python>', '<redacted>', '<redacted>', '<redacted>', 'ordinary-value'])

    def test_redaction_ignores_empty_secrets_and_regular_values(self):
        output = diagnostic.redact('ordinary text', Path('/private/fixture'),
                                   {'SECRET': '', 'APP_NAME': 'ordinary'})
        self.assertEqual(output, 'ordinary text')

    def test_truncated_secret_prefix_is_redacted_case_insensitively(self):
        for tail in ('top-', 'TOP-', 't'):
            with self.subTest(tail=tail):
                output = diagnostic.redact('log: ' + tail, Path('/private/fixture'),
                                           {'TOKEN': 'top-secret'}, tail_truncated=True)
                self.assertEqual(output, 'log: <redacted>')
        self.assertEqual(diagnostic.redact('log: top-', Path('/private/fixture'),
                                           {'TOKEN': 'top-secret'}), 'log: top-')
        self.assertEqual(diagnostic.redact('ordinary end', Path('/private/fixture'),
                                           {'TOKEN': 'top-secret', 'AUTH': '', 'NAME': 'end'},
                                           tail_truncated=True), 'ordinary end')

    def test_truncated_log_cannot_leak_a_partial_secret_at_read_boundary(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / 'worker.log'
            secret = 'protected-credential'
            prefix = 'protected-'
            path.write_bytes(b'x' * (diagnostic.MAX_LOG_BYTES - len(prefix)) + secret.encode())
            result, output, truncated = diagnostic.read_evidence(path, CASE, directory, {'AUTH': secret})
        self.assertIsNone(result)
        self.assertTrue(truncated)
        self.assertTrue(output.endswith('<redacted>'))
        self.assertNotIn(prefix, output)

    def test_short_secrets_do_not_prevent_parsing_the_result_structure(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / 'worker.log'
            path.write_bytes(result_line(stdout='r', stderr='s'))
            result, output, truncated = diagnostic.read_evidence(path, CASE, directory,
                                                                 {'TOKEN': 'r', 'PASSWORD': 's'})
        self.assertFalse(truncated)
        self.assertIsNotNone(result)
        self.assertEqual(result['stdout'], '<redacted>')
        self.assertEqual(result['stderr'], '<redacted>')
        self.assertEqual(result['case'], CASE)
        self.assertEqual(result['status'], 'launched')
        self.assertIn('exit_code', result)
        self.assertEqual(result['exit_code'], 0)
        self.assertIn('<redacted>', output)

    def test_error_status_secret_does_not_replace_original_launch_observation(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / 'worker.log'
            path.write_bytes(result_line(stdout='launch output', exit_code=11) +
                             result_line(status='diagnostic-error', message='shutdown error'))
            result, _, _ = diagnostic.read_evidence(path, CASE, directory, {'TOKEN': 'error'})
        self.assertEqual(result['stdout'], 'launch output')
        self.assertEqual(result['exit_code'], 11)
        self.assertEqual(result['diagnostic_error']['message'], 'shutdown <redacted>')

    def test_evidence_requires_matching_json_and_filters_result_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / 'worker.log'
            path.write_bytes(b'not json\n[]\n42\n' + result_line('daemon-native') +
                             b'{"case":"direct-native","phase":"started"}\n' +
                             result_line(status='earlier') +
                             result_line(status='latest', stdout='sensitive-secret',
                                         environment={'PRIVATE': 'do not retain'}, extra='noise'))
            result, output, truncated = diagnostic.read_evidence(
                path, CASE, directory, {'AUTH_TOKEN': 'sensitive-secret'})
        self.assertEqual(result, {'case': CASE, 'status': 'latest', 'exit_code': 0,
                                  'stdout': '<redacted>'})
        self.assertNotIn('phase', result)
        self.assertNotIn('environment', result)
        self.assertFalse(truncated)
        self.assertNotIn('sensitive-secret', output)

    def test_later_harness_error_preserves_launch_result_and_native_daemon_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / 'worker.log'
            path.write_bytes(result_line(stdout='original launch', exit_code=11,
                                         daemon_executable=str(directory / 'native/vityod.exe')) +
                             result_line(status='diagnostic-error', message='shutdown failed',
                                         private_metadata='omit this field'))
            result, output, truncated = diagnostic.read_evidence(path, CASE, directory, {})
        self.assertFalse(truncated)
        self.assertEqual(result['status'], 'launched')
        self.assertEqual(result['stdout'], 'original launch')
        self.assertEqual(result['exit_code'], 11)
        self.assertEqual(result['daemon_executable'], '<fixture>/native/vityod.exe')
        self.assertEqual(result['diagnostic_error'], {'case': CASE, 'status': 'diagnostic-error',
                                                    'exit_code': 0, 'message': 'shutdown failed'})
        self.assertIn('shutdown failed', output)

    def test_standalone_diagnostic_error_is_retained_as_result(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / 'worker.log'
            path.write_bytes(result_line(status='diagnostic-error', message='startup failed'))
            result, _, _ = diagnostic.read_evidence(path, CASE, directory, {})
        self.assertEqual(result['status'], 'diagnostic-error')
        self.assertNotIn('diagnostic_error', result)

    def test_bounded_log_decodes_invalid_utf8_without_crashing(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / 'worker.log'
            path.write_bytes(b'\xff' + b'x' * diagnostic.MAX_LOG_BYTES)
            result, output, truncated = diagnostic.read_evidence(path, CASE, directory, {})
        self.assertIsNone(result)
        self.assertTrue(truncated)
        self.assertTrue(output.startswith('\ufffd'))
        self.assertEqual(len(output), diagnostic.MAX_LOG_BYTES)

    def test_evidence_after_read_limit_is_never_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / 'worker.log'
            path.write_bytes(b'x' * diagnostic.MAX_LOG_BYTES + b'\n' + result_line())
            result, _, truncated = diagnostic.read_evidence(path, CASE, directory, {})
        self.assertIsNone(result)
        self.assertTrue(truncated)

    def test_save_creates_parent_and_atomically_replaces_prior_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / 'nested/report.json'
            diagnostic.save(destination, {'status': 'running'})
            diagnostic.save(destination, {'status': 'complete', 'cases': [CASE]})
            self.assertEqual(json.loads(destination.read_text()),
                             {'status': 'complete', 'cases': [CASE]})
            self.assertTrue(destination.read_text().endswith('\n'))
            self.assertFalse(destination.with_suffix('.json.tmp').exists())


class ParentWatchdogTests(unittest.TestCase):
    """No timer threads or process exits are allowed in these unit tests."""

    def test_watchdog_starts_as_daemon_before_action_and_cancels_after_return(self):
        events = []
        timer = Mock()
        factory = Mock(return_value=timer)
        def start():
            self.assertIs(timer.daemon, True)
            events.append('start')
        timer.start.side_effect = start
        timer.cancel.side_effect = lambda: events.append('cancel')
        action = Mock(side_effect=lambda: events.append('action') or 23)
        with patch.object(diagnostic.os, '_exit') as hard_exit:
            self.assertEqual(diagnostic.run_bounded(action, timer_factory=factory), 23)
        factory.assert_called_once()
        self.assertEqual(factory.call_args.args[0], diagnostic.PARENT_TIMEOUT)
        self.assertEqual(diagnostic.PARENT_TIMEOUT, 170)
        self.assertLess(diagnostic.TOTAL_TIMEOUT, diagnostic.PARENT_TIMEOUT)
        self.assertLess(diagnostic.PARENT_TIMEOUT, 180)
        self.assertTrue(callable(factory.call_args.args[1]))
        self.assertEqual(events, ['start', 'action', 'cancel'])
        timer.start.assert_called_once_with()
        timer.cancel.assert_called_once_with()
        action.assert_called_once_with()
        hard_exit.assert_not_called()

    def test_watchdog_is_cancelled_when_action_raises_or_is_interrupted(self):
        for error in (RuntimeError('collection failed'), KeyboardInterrupt()):
            with self.subTest(error=type(error).__name__):
                timer = Mock()
                action = Mock(side_effect=error)
                with patch.object(diagnostic.os, '_exit') as hard_exit:
                    with self.assertRaises(type(error)):
                        diagnostic.run_bounded(action, timer_factory=Mock(return_value=timer))
                timer.start.assert_called_once_with()
                timer.cancel.assert_called_once_with()
                hard_exit.assert_not_called()

    def test_deadline_callback_exits_directly_without_evidence_or_cleanup_io(self):
        timer = Mock()
        factory = Mock(return_value=timer)
        def action():
            # Trigger the captured callback only while _exit is replaced.
            factory.call_args.args[1]()
        with patch.object(diagnostic.os, '_exit', side_effect=SystemExit(124)) as hard_exit, \
             patch.object(diagnostic, 'save') as save, \
             patch.object(diagnostic, 'WindowsJob') as job, \
             patch.object(diagnostic.shutil, 'rmtree') as remove:
            with self.assertRaises(SystemExit) as caught:
                diagnostic.run_bounded(action, timer_factory=factory)
        self.assertEqual(caught.exception.code, 124)
        hard_exit.assert_called_once_with(124)
        save.assert_not_called()
        job.assert_not_called()
        remove.assert_not_called()
        timer.cancel.assert_called_once_with()

    def test_unstartable_watchdog_prevents_running_unbounded_action(self):
        timer = Mock()
        timer.start.side_effect = RuntimeError('cannot start thread')
        action = Mock()
        with self.assertRaisesRegex(RuntimeError, 'cannot start thread'):
            diagnostic.run_bounded(action, timer_factory=Mock(return_value=timer))
        action.assert_not_called()

    def test_host_metadata_contains_os_release_architecture_and_hard_deadline(self):
        with patch.object(diagnostic.platform, 'system', return_value='Windows'), \
             patch.object(diagnostic.platform, 'release', return_value='11'), \
             patch.object(diagnostic.platform, 'machine', return_value='ARM64'):
            self.assertEqual(diagnostic.host_metadata(), {
                'os': 'Windows', 'os_release': '11', 'architecture': 'ARM64',
                'parent_timeout_seconds': 170})

    def test_main_defers_all_readiness_checks_until_inside_watchdog(self):
        with patch.object(diagnostic, 'run_bounded', return_value=43) as bounded, \
             patch.object(diagnostic, 'collect_if_ready', return_value=2) as ready:
            self.assertEqual(diagnostic.main(['--dart', 'requested-dart']), 43)
            ready.assert_not_called()
            action = bounded.call_args.args[0]
            self.assertEqual(action(), 2)
        self.assertEqual(ready.call_args.args[0].dart, 'requested-dart')


class CollectionAndMainTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.directory = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.output = self.directory / 'evidence/report.json'
        self.stdout = self.stack.enter_context(patch.object(diagnostic.sys, 'stdout', new=io.StringIO()))
        self.environment = {'Path': 'one', 'PATH': 'two', 'PATHEXT': '.EXE;.CMD',
                            'SystemRoot': 'root', 'ComSpec': 'cmd', 'SECRET': 'hidden-value'}
        self.clock = self.stack.enter_context(patch.object(diagnostic.time, 'monotonic', return_value=10))
        self.bounded = self.stack.enter_context(patch.object(
            diagnostic, 'run_bounded', side_effect=lambda action: action()))
        self.stack.enter_context(patch.object(diagnostic.platform, 'system', return_value='Test OS'))
        self.stack.enter_context(patch.object(diagnostic.platform, 'release', return_value='test-release'))
        self.stack.enter_context(patch.object(diagnostic.platform, 'machine', return_value='test-arch'))

    @staticmethod
    def observation(case, *args):
        return {'case': case, 'status': 'completed', 'cleanup_completed': True,
                'result': {'status': 'launch-failed', 'exit_code': 12}}

    def test_six_cells_share_exact_environment_and_persist_after_each_observation(self):
        snapshots = []
        original_save = diagnostic.save
        def save(path, report):
            snapshots.append(json.loads(json.dumps(report)))
            original_save(path, report)
        with patch.object(diagnostic, 'supervise', side_effect=self.observation) as supervise, \
             patch.object(diagnostic, 'save', side_effect=save):
            self.assertEqual(diagnostic.collect('dart.exe', self.output, self.environment), 0)
        self.assertEqual([item.args[0] for item in supervise.call_args_list], list(diagnostic.CASES))
        for item in supervise.call_args_list:
            self.assertIs(item.args[2], self.environment)
            self.assertEqual(item.args[3], 10 + diagnostic.TOTAL_TIMEOUT)
        self.assertEqual(len(snapshots), 14)
        self.assertTrue(all(len(item['cases']) == 6 for item in snapshots))
        self.assertEqual(snapshots[0]['cases'], [{'case': case, 'status': 'not-run'}
                                               for case in diagnostic.CASES])
        for index, case in enumerate(diagnostic.CASES):
            self.assertEqual(snapshots[1 + index * 2]['cases'][index],
                             {'case': case, 'status': 'running'})
            self.assertEqual(snapshots[2 + index * 2]['cases'][index], self.observation(case))
        self.assertEqual(snapshots[0]['status'], 'running')
        report = json.loads(self.output.read_text())
        self.assertEqual(report['status'], 'completed')
        self.assertEqual({key: report[key] for key in ('os', 'os_release', 'architecture',
                                                     'parent_timeout_seconds')},
                         {'os': 'Test OS', 'os_release': 'test-release',
                          'architecture': 'test-arch', 'parent_timeout_seconds': 170})
        self.assertEqual(report['environment_keys'], {'PATH': ['Path', 'PATH'], 'PATHEXT': ['PATHEXT'],
                                                    'SYSTEMROOT': ['SystemRoot'], 'COMSPEC': ['ComSpec']})
        self.assertNotIn('hidden-value', self.output.read_text())
        self.assertEqual(len(self.stdout.getvalue().splitlines()), 6)
        self.assertTrue(all(item['result']['status'] == 'launch-failed' for item in report['cases']))

    def test_cleanup_failure_prevents_launching_remaining_cells(self):
        with patch.object(diagnostic, 'supervise', return_value={
                'case': CASE, 'status': 'cleanup-failed', 'cleanup_completed': False}) as supervise:
            self.assertEqual(diagnostic.collect('dart', self.output, self.environment), 1)
        supervise.assert_called_once()
        report = json.loads(self.output.read_text())
        self.assertEqual(report['status'], 'incomplete')
        self.assertEqual(len(report['cases']), 6)
        for result in report['cases'][1:]:
            self.assertEqual(result['status'], 'not-run')
            self.assertEqual(result['reason'], 'owned tree cleanup failed')

    def test_parent_deadline_marks_all_remaining_cells_not_run(self):
        self.clock.side_effect = [10, 10, 10 + diagnostic.TOTAL_TIMEOUT]
        with patch.object(diagnostic, 'supervise', side_effect=self.observation) as supervise:
            self.assertEqual(diagnostic.collect('dart', self.output, self.environment), 1)
        supervise.assert_called_once()
        report = json.loads(self.output.read_text())
        self.assertEqual(report['cases'][0]['status'], 'completed')
        self.assertTrue(all(item.get('reason') == 'parent deadline reached'
                            for item in report['cases'][1:]))

    def test_incomplete_cell_does_not_stop_next_cell_when_cleanup_succeeded(self):
        results = [self.observation(case) for case in diagnostic.CASES]
        results[0]['status'] = 'timeout'
        with patch.object(diagnostic, 'supervise', side_effect=results) as supervise:
            self.assertEqual(diagnostic.collect('dart', self.output, self.environment), 1)
        self.assertEqual(supervise.call_count, 6)
        self.assertEqual(json.loads(self.output.read_text())['status'], 'incomplete')

    def test_interrupted_collection_leaves_previous_observations_on_disk(self):
        with patch.object(diagnostic, 'supervise', side_effect=[self.observation(CASE),
                                                               OSError('unexpected failure')]):
            with self.assertRaisesRegex(OSError, 'unexpected failure'):
                diagnostic.collect('dart', self.output, self.environment)
        report = json.loads(self.output.read_text())
        self.assertEqual(report['status'], 'running')
        self.assertEqual(report['cases'][0], self.observation(CASE))
        self.assertEqual(report['cases'][1], {'case': diagnostic.CASES[1], 'status': 'running'})
        self.assertEqual(report['cases'][2:], [{'case': case, 'status': 'not-run'}
                                               for case in diagnostic.CASES[2:]])
        self.assertFalse(self.output.with_suffix('.json.tmp').exists())

    def test_first_cell_failure_still_leaves_initial_report(self):
        with patch.object(diagnostic, 'supervise', side_effect=OSError('first cell')):
            with self.assertRaises(OSError):
                diagnostic.collect('dart', self.output, self.environment)
        report = json.loads(self.output.read_text())
        self.assertEqual(report['status'], 'running')
        self.assertEqual(report['cases'][0], {'case': CASE, 'status': 'running'})
        self.assertEqual(report['cases'][1:], [{'case': case, 'status': 'not-run'}
                                               for case in diagnostic.CASES[1:]])

    def test_interrupted_preflight_retains_metadata_and_all_six_cells_before_resolving(self):
        def interrupted_resolver(command):
            report = json.loads(self.output.read_text())
            self.assertEqual(report['status'], 'checking-prerequisites')
            self.assertEqual(report['cases'], [{'case': case, 'status': 'not-run'}
                                              for case in diagnostic.CASES])
            self.assertEqual(report['os'], 'Test OS')
            self.assertEqual(report['os_release'], 'test-release')
            self.assertEqual(report['architecture'], 'test-arch')
            self.assertEqual(report['parent_timeout_seconds'], 170)
            raise KeyboardInterrupt()
        with patch.object(diagnostic, 'os', SimpleNamespace(name='nt', environ=self.environment)), \
             patch.object(diagnostic, 'resolve_dart', side_effect=interrupted_resolver), \
             patch.object(diagnostic, 'collect') as collect:
            with self.assertRaises(KeyboardInterrupt):
                diagnostic.main(['--output', str(self.output)])
        collect.assert_not_called()
        self.assertEqual(json.loads(self.output.read_text())['status'], 'checking-prerequisites')
        self.assertFalse(self.output.with_suffix('.json.tmp').exists())

    def test_main_preconditions_never_build_or_launch_missing_dependencies(self):
        for missing in ('windows', 'dart', 'packages', 'daemon'):
            with self.subTest(missing=missing):
                environment = SimpleNamespace(name='posix' if missing == 'windows' else 'nt',
                                              environ=self.environment)
                def is_file(path):
                    return not ((missing == 'packages' and path.name == 'package_config.json') or
                                (missing == 'daemon' and path.name == 'vityod.exe'))
                with patch.object(diagnostic, 'os', environment), \
                     patch.object(diagnostic, 'resolve_dart',
                                  return_value=None if missing == 'dart' else 'native-dart.exe') as resolve, \
                     patch.object(diagnostic.Path, 'is_file', autospec=True, side_effect=is_file), \
                     patch.object(diagnostic, 'collect') as collect, \
                     patch.object(diagnostic.subprocess, 'Popen') as spawn:
                    self.assertEqual(diagnostic.main(['--output', str(self.output)]), 2)
                collect.assert_not_called()
                spawn.assert_not_called()
                if missing == 'windows':
                    resolve.assert_not_called()
                report = json.loads(self.output.read_text())
                self.assertEqual(report['schema_version'], 1)
                self.assertEqual({key: report[key] for key in ('os', 'os_release', 'architecture',
                                                             'parent_timeout_seconds')},
                                 {'os': 'Test OS', 'os_release': 'test-release',
                                  'architecture': 'test-arch', 'parent_timeout_seconds': 170})
                self.assertEqual(report['status'], 'not-run')
                self.assertEqual(report['cases'], [{'case': case, 'status': 'not-run'}
                                                  for case in diagnostic.CASES])

    def test_main_resolves_native_dart_and_copies_unmodified_environment(self):
        with patch.object(diagnostic, 'os', SimpleNamespace(name='nt', environ=self.environment)), \
             patch.object(diagnostic.Path, 'is_file', return_value=True), \
             patch.object(diagnostic, 'resolve_dart', return_value='native-dart.exe') as resolve, \
             patch.object(diagnostic, 'collect', return_value=1) as collect:
            self.assertEqual(diagnostic.main(['--dart', 'requested-dart', '--output', str(self.output)]), 1)
        resolve.assert_called_once_with('requested-dart')
        collect.assert_called_once_with('native-dart.exe', self.output, self.environment)
        self.assertIsNot(collect.call_args.args[2], self.environment)

    def test_worker_dispatch_bypasses_parent_preconditions(self):
        with patch.object(diagnostic, 'worker', return_value=7) as worker, \
             patch.object(diagnostic, 'resolve_dart') as resolve, \
             patch.object(diagnostic, 'collect') as collect:
            self.assertEqual(diagnostic.main(['--worker', CASE, '--fixture', str(self.directory)]), 7)
        self.bounded.assert_not_called()
        self.assertEqual(worker.call_args.args[0].worker, CASE)
        self.assertEqual(worker.call_args.args[0].fixture, self.directory)
        resolve.assert_not_called()
        collect.assert_not_called()

    def test_worker_requires_exact_gate_before_any_child_launch(self):
        args = SimpleNamespace(dart='native-dart.exe', worker=CASE, fixture=self.directory)
        for gate in ('', 'GO', 'NO\n', 'GO\r\n'):
            with self.subTest(gate=gate), \
                 patch.object(diagnostic.sys, 'stdin', new=io.StringIO(gate)), \
                 patch.object(diagnostic.subprocess, 'call') as launch:
                self.assertEqual(diagnostic.worker(args), 2)
                launch.assert_not_called()

    def test_worker_uses_native_dart_directly_with_original_environment(self):
        args = SimpleNamespace(dart='native-dart.exe', worker=CASE, fixture=self.directory)
        with patch.object(diagnostic.sys, 'stdin', new=io.StringIO('GO\n')), \
             patch.object(diagnostic, 'os', SimpleNamespace(environ=self.environment)), \
             patch.object(diagnostic.subprocess, 'call', return_value=23) as launch:
            self.assertEqual(diagnostic.worker(args), 23)
        app = ROOT / 'products/vityo_app'
        launch.assert_called_once_with([
            'native-dart.exe', f'--packages={app / ".dart_tool/package_config.json"}',
            str(app / 'tool/windows_pafio_launch_diagnostic.dart'), CASE,
            str(Path(diagnostic.sys.executable).resolve()), str(self.directory)],
            cwd=app, env=self.environment)
        self.assertIsNot(launch.call_args.kwargs['env'], self.environment)
        self.assertNotIn('shell', launch.call_args.kwargs)

    def test_resolver_delegates_to_existing_native_dart_resolver(self):
        with tempfile.TemporaryDirectory() as directory:
            native = Path(directory) / 'dart.exe'
            native.write_bytes(b'fixture')
            with patch.object(diagnostic.shutil, 'which', return_value=str(native)):
                self.assertEqual(diagnostic.resolve_dart('dart'), str(native.resolve()))

    def test_script_entrypoint_reports_non_windows_without_running_children(self):
        with patch.object(diagnostic.sys, 'argv', [str(SCRIPT), '--output', str(self.output)]), \
             patch.dict(diagnostic.sys.modules, {'os': SimpleNamespace(name='posix')}), \
             patch.object(diagnostic.threading, 'Timer') as timer, \
             patch.object(diagnostic.subprocess, 'Popen') as spawn:
            with self.assertRaises(SystemExit) as caught:
                runpy.run_path(str(SCRIPT), run_name='__main__')
        self.assertEqual(caught.exception.code, 2)
        self.assertEqual(json.loads(self.output.read_text())['status'], 'not-run')
        timer.assert_called_once()
        timer.return_value.start.assert_called_once_with()
        timer.return_value.cancel.assert_called_once_with()
        spawn.assert_not_called()


if __name__ == '__main__':
    unittest.main()
