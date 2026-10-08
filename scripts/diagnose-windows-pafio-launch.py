#!/usr/bin/env python3
"""Opt-in six-cell launch evidence; never replaces a product test or builds tools.

The parent assigns a gated worker to a kill-on-close Windows job BEFORE releasing
it. Every Dart, daemon, cmd and Python descendant therefore belongs to that job.
"""
from __future__ import annotations

import argparse
import ctypes
import importlib.util
import json
import os
import platform
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
CASES = tuple(f'{route}-{kind}' for route in ('direct', 'daemon')
              for kind in ('native', 'bare-wrapper', 'absolute-wrapper'))
CASE_TIMEOUT = 20.0
TOTAL_TIMEOUT = 150.0
PARENT_TIMEOUT = 170.0
CLEANUP_TIMEOUT = 3.0
MAX_LOG_BYTES = 65536
RESULT_KEYS = {'case', 'status', 'exit_code', 'stdout', 'stderr', 'message',
               'elapsed_ms', 'started', 'error_code', 'stdout_truncated',
               'stderr_truncated', 'harness_closed', 'cancel_status', 'daemon_executable'}


class WindowsJob:
    """Owned descendant lifetime, including children whose launcher has exited."""
    def __init__(self):
        from ctypes import wintypes as w
        class Basic(ctypes.Structure):
            _fields_ = [('process_time', ctypes.c_int64), ('job_time', ctypes.c_int64),
                        ('flags', w.DWORD), ('min_ws', ctypes.c_size_t),
                        ('max_ws', ctypes.c_size_t), ('active_limit', w.DWORD),
                        ('affinity', ctypes.c_size_t), ('priority', w.DWORD),
                        ('scheduling', w.DWORD)]
        class IO(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint64) for name in
                        ('read_ops', 'write_ops', 'other_ops', 'read_bytes',
                         'write_bytes', 'other_bytes')]
        class Extended(ctypes.Structure):
            _fields_ = [('basic', Basic), ('io', IO),
                        ('process_memory', ctypes.c_size_t),
                        ('job_memory', ctypes.c_size_t),
                        ('peak_process_memory', ctypes.c_size_t),
                        ('peak_job_memory', ctypes.c_size_t)]
        class Accounting(ctypes.Structure):
            _fields_ = [(name, ctypes.c_int64) for name in
                        ('user', 'kernel', 'period_user', 'period_kernel')] + [
                        (name, w.DWORD) for name in
                        ('faults', 'total', 'active', 'terminated')]
        self.Accounting = Accounting
        k = ctypes.WinDLL('kernel32', use_last_error=True)
        # Resolve/configure all functions before any API call, so immediate
        # ctypes.get_last_error() reads the failed call's cached last-error.
        specs = {'CreateJobObjectW': ([ctypes.c_void_p, w.LPCWSTR], w.HANDLE),
                 'SetInformationJobObject': ([w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD], w.BOOL),
                 'AssignProcessToJobObject': ([w.HANDLE, w.HANDLE], w.BOOL),
                 'TerminateJobObject': ([w.HANDLE, w.UINT], w.BOOL),
                 'QueryInformationJobObject': ([w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD, ctypes.c_void_p], w.BOOL),
                 'CloseHandle': ([w.HANDLE], w.BOOL)}
        self.api = {}
        for name, (args, result) in specs.items():
            fn = getattr(k, name)
            fn.argtypes, fn.restype = args, result
            self.api[name] = fn
        self.handle = self.api['CreateJobObjectW'](None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = Extended()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.api['SetInformationJobObject'](self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            error = ctypes.get_last_error()
            self.close()
            raise ctypes.WinError(error)

    def assign(self, process):
        if not self.api['AssignProcessToJobObject'](self.handle, int(process._handle)):
            raise ctypes.WinError(ctypes.get_last_error())

    def terminate_and_wait(self, timeout=CLEANUP_TIMEOUT):
        if not self.api['TerminateJobObject'](self.handle, 1):
            raise ctypes.WinError(ctypes.get_last_error())
        deadline = time.monotonic() + timeout
        while True:
            info = self.Accounting()
            if not self.api['QueryInformationJobObject'](self.handle, 1, ctypes.byref(info), ctypes.sizeof(info), None):
                raise ctypes.WinError(ctypes.get_last_error())
            if info.active == 0:
                return True
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.01)

    def close(self):
        if self.handle:
            handle, self.handle = self.handle, None
            if not self.api['CloseHandle'](handle):
                raise ctypes.WinError(ctypes.get_last_error())


def redact(text, directory, environment, *, tail_truncated=False):
    replacements = [(str(directory), '<fixture>'), (str(ROOT), '<repo>'),
                    (str(Path.home()), '<home>'), (str(Path(sys.executable).parent), '<python>')]
    for key, value in environment.items():
        if value and re.search(r'token|secret|password|credential|api.?key|auth', key, re.I):
            replacements.append((value, '<redacted>'))
    for value, label in sorted(replacements, key=lambda item: len(item[0]), reverse=True):
        variants = {value, value.replace('\\', '/'), value.replace('/', '\\')}
        variants.update(json.dumps(variant)[1:-1] for variant in tuple(variants))
        for variant in sorted(variants, key=len, reverse=True):
            text = re.sub(re.escape(variant), lambda _: label, text, flags=re.I)
    if tail_truncated:
        for key, value in environment.items():
            if value and re.search(r'token|secret|password|credential|api.?key|auth', key, re.I):
                for size in range(len(value) - 1, 0, -1):
                    if text.lower().endswith(value[:size].lower()):
                        text = text[:-size] + '<redacted>'
                        break
    return text


def read_evidence(path, case, directory, environment):
    with path.open('rb') as stream:
        data = stream.read(MAX_LOG_BYTES + 1)
    raw = data[:MAX_LOG_BYTES].decode('utf-8', errors='replace')
    output = redact(raw, directory, environment, tail_truncated=len(data) > MAX_LOG_BYTES)
    result = None
    for line in raw.splitlines():
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if isinstance(item, dict) and item.get('case') == case and item.get('phase') == 'result':
            # Deliberately no arbitrary environment/metadata from a worker.
            observation = {key: (redact(value, directory, environment) if isinstance(value, str) and key not in ('case', 'status') else value)
                           for key, value in item.items() if key in RESULT_KEYS}
            if result is not None and item.get('status') == 'diagnostic-error':
                result['diagnostic_error'] = observation
            else:
                result = observation
    return result, output, len(data) > MAX_LOG_BYTES


def worker(args):
    # No subprocess, daemon, fixture or log creation occurs before the gate.
    if sys.stdin.readline() != 'GO\n':
        return 2
    app = ROOT / 'products/vityo_app'
    command = [args.dart, f'--packages={app / ".dart_tool/package_config.json"}',
               str(app / 'tool/windows_pafio_launch_diagnostic.dart'),
               args.worker, str(Path(sys.executable).resolve()), str(args.fixture)]
    return subprocess.call(command, cwd=app, env=dict(os.environ))


def supervise(case, dart, environment, deadline, *, job_factory=WindowsJob):
    if case not in CASES:
        raise ValueError('unknown diagnostic cell')
    started = time.monotonic()
    report = {'case': case, 'status': 'not-run', 'cleanup_completed': False,
              'watchdog_expired': False}
    directory = Path(tempfile.mkdtemp(prefix='vityo-pafio-launch-'))
    process = job = None
    try:
        with (directory / 'worker.log').open('w+b') as log:
            try:
                job = job_factory()
                process = subprocess.Popen(
                    [sys.executable, str(Path(__file__).resolve()), '--worker', case,
                     '--dart', dart, '--fixture', str(directory)],
                    stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT,
                    env=environment)
                job.assign(process)
                process.stdin.write(b'GO\n')
                process.stdin.flush()
                process.stdin.close()
                cell_deadline = min(deadline, started + CASE_TIMEOUT)
                while process.poll() is None:
                    if time.monotonic() >= cell_deadline:
                        raise subprocess.TimeoutExpired('owned launch cell', CASE_TIMEOUT)
                    if log.tell() > MAX_LOG_BYTES:
                        raise RuntimeError('worker output exceeded diagnostic limit')
                    time.sleep(0.02)
                report['worker_exit'] = process.returncode
                report['status'] = 'completed'
            except subprocess.TimeoutExpired:
                report.update(status='timeout', watchdog_expired=True)
            except (OSError, RuntimeError) as error:
                report.update(status='error', error=redact(str(error), directory, environment))
            finally:
                # A failed assignment leaves only the gated worker, never a
                # spawned descendant. Always terminate the job even after a
                # normal worker exit: detached descendants must not survive.
                cleanup = True
                if job is not None:
                    try:
                        cleanup = job.terminate_and_wait()
                    except OSError as error:
                        cleanup = False
                        report['cleanup_error'] = redact(str(error), directory, environment)
                    finally:
                        try:
                            job.close()
                        except OSError:
                            cleanup = False
                if process is not None:
                    try:
                        if process.poll() is None:
                            process.kill()
                        process.wait(timeout=CLEANUP_TIMEOUT)
                    except (OSError, subprocess.TimeoutExpired):
                        cleanup = False
                    if process.stdin and not process.stdin.closed:
                        try:
                            process.stdin.close()
                        except OSError:
                            cleanup = False
                report['cleanup_completed'] = cleanup
        result, output, truncated = read_evidence(directory / 'worker.log', case, directory, environment)
        report.update(result=result, worker_output=output, output_truncated=truncated)
        if report['status'] == 'completed' and (report['worker_exit'] != 0 or result is None):
            report['status'] = 'incomplete-evidence'
    finally:
        try:
            shutil.rmtree(directory)
        except OSError:
            report['cleanup_completed'] = False
        if not report['cleanup_completed']:
            report['status'] = 'cleanup-failed'
    report['elapsed_seconds'] = round(time.monotonic() - started, 3)
    return report


def resolve_dart(command):
    spec = importlib.util.spec_from_file_location('pipe_diagnostic', ROOT / 'scripts/test-windows-dart-pipe.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.resolve_dart(command)


def save(path, report):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)


def collect(dart, output, environment):
    started = time.monotonic()
    report = {'schema_version': 1, **host_metadata(), 'status': 'running', 'cases': [
                  {'case': case, 'status': 'not-run'} for case in CASES],
              'environment_keys': {name: [key for key in environment if key.upper() == name]
                                   for name in ('PATH', 'PATHEXT', 'SYSTEMROOT', 'COMSPEC')},
              'daemon_source': 'existing native/vityod/target/debug/vityod.exe'}
    save(output, report)
    stop = None
    for index, case in enumerate(CASES):
        if stop is None and time.monotonic() >= started + TOTAL_TIMEOUT:
            stop = 'parent deadline reached'
        if stop:
            result = {'case': case, 'status': 'not-run', 'reason': stop}
        else:
            report['cases'][index] = {'case': case, 'status': 'running'}
            save(output, report)
            result = supervise(case, dart, environment, started + TOTAL_TIMEOUT)
            if not result['cleanup_completed']:
                stop = 'owned tree cleanup failed'
        report['cases'][index] = result
        save(output, report)
        print(json.dumps(result), flush=True)
    # completed means six observations, not six successful tool launches.
    report['status'] = 'completed' if all(case['status'] == 'completed' for case in report['cases']) else 'incomplete'
    save(output, report)
    return 0 if report['status'] == 'completed' else 1


def host_metadata():
    return {'os': platform.system(), 'os_release': platform.release(),
            'architecture': platform.machine(),
            'parent_timeout_seconds': PARENT_TIMEOUT}


def run_bounded(action, *, timer_factory=threading.Timer):
    # This thread must never wait for cleanup or write evidence: a blocked
    # Win32 operation releases the GIL, allowing this independent deadline to
    # exit the owner. Windows then closes our non-inherited Job handles and
    # KILL_ON_JOB_CLOSE terminates their descendants. Per-cell JSON has already
    # been persisted; its running marker honestly denotes incomplete evidence.
    watchdog = timer_factory(PARENT_TIMEOUT, lambda: os._exit(124))
    watchdog.daemon = True
    watchdog.start()
    try:
        return action()
    finally:
        watchdog.cancel()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default='dart')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/evidence/windows-pafio-launch.json')
    parser.add_argument('--worker', choices=CASES, help=argparse.SUPPRESS)
    parser.add_argument('--fixture', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.worker:
        return worker(args)
    return run_bounded(lambda: collect_if_ready(args))


def collect_if_ready(args):
    save(args.output, {'schema_version': 1, **host_metadata(),
                      'status': 'checking-prerequisites',
                      'cases': [{'case': case, 'status': 'not-run'} for case in CASES]})
    app = ROOT / 'products/vityo_app'
    dart = resolve_dart(args.dart) if os.name == 'nt' else None
    if (os.name != 'nt' or dart is None or
            not (app / '.dart_tool/package_config.json').is_file() or
            not (app / 'native/vityod/target/debug/vityod.exe').is_file()):
        save(args.output, {'schema_version': 1, **host_metadata(), 'status': 'not-run',
                          'reason': 'requires Windows, native dart.exe, restored app packages and already-built vityod.exe',
                          'cases': [{'case': case, 'status': 'not-run'} for case in CASES]})
        return 2
    return collect(dart, args.output, dict(os.environ))


if __name__ == '__main__':
    raise SystemExit(main())
