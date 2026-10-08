#!/usr/bin/env python3
"""Bounded real-Dart transport regressions, independent of daemon/toolchain builds.

The parent owns two direct children (native server and real Dart client). Even a
blocked FFI call/CloseHandle cannot disable the external per-case watchdog.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import platform
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
CASES = ('reader-first', 'stalled-write', 'peer-disconnect', 'queued-close', 'socket-queued-close')
CASE_TIMEOUT = 20
REAP_TIMEOUT = 2
MAX_LOG_BYTES = 65536


def native_server(scenario: str, endpoint: str, control: Path) -> int:
    """A server boundary only: all client operations are production Dart code."""
    from ctypes import wintypes as w

    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    create = kernel.CreateNamedPipeW
    create.argtypes = [w.LPCWSTR, w.DWORD, w.DWORD, w.DWORD, w.DWORD,
                       w.DWORD, w.DWORD, ctypes.c_void_p]
    create.restype = w.HANDLE
    connect = kernel.ConnectNamedPipe
    connect.argtypes = [w.HANDLE, ctypes.c_void_p]
    connect.restype = w.BOOL
    read = kernel.ReadFile
    write = kernel.WriteFile
    for function in (read, write):
        function.argtypes = [w.HANDLE, ctypes.c_void_p, w.DWORD,
                             ctypes.POINTER(w.DWORD), ctypes.c_void_p]
        function.restype = w.BOOL
    close = kernel.CloseHandle
    close.argtypes = [w.HANDLE]
    close.restype = w.BOOL
    handle = create(endpoint, 3, 0, 1, 4096, 4096, 0, None)
    if handle == w.HANDLE(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        (control / 'ready').write_text('ready', encoding='ascii')
        if not connect(handle, None) and ctypes.get_last_error() != 535:
            raise ctypes.WinError(ctypes.get_last_error())
        if scenario == 'reader-first':
            request = bytearray()
            while len(request) < 5:
                buffer = ctypes.create_string_buffer(5 - len(request))
                count = w.DWORD()
                if not read(handle, buffer, len(buffer), ctypes.byref(count), None):
                    raise ctypes.WinError(ctypes.get_last_error())
                if not count.value:
                    raise RuntimeError('client closed before request')
                request.extend(buffer.raw[:count.value])
            if request != b'ping\n':
                raise RuntimeError('unexpected client request')
            count = w.DWORD()
            response = ctypes.create_string_buffer(b'pong\n')
            if not write(handle, response, 5, ctypes.byref(count), None):
                raise ctypes.WinError(ctypes.get_last_error())
            if count.value != 5:
                raise RuntimeError('short server response')
        elif scenario == 'peer-disconnect':
            while not (control / 'disconnect').exists():
                time.sleep(0.01)
            return 0
        # Stay open until the supervisor stops us. Closing a peer to unblock a
        # client would hide precisely the cancellation/reader-first regression.
        while not (control / 'stop').exists():
            time.sleep(0.01)
        return 0
    finally:
        close(handle)


def reap(process: subprocess.Popen | None) -> bool:
    if process is None:
        return True
    try:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=REAP_TIMEOUT)
        return True
    except (OSError, subprocess.TimeoutExpired):
        return False


def sanitize(text: str, paths: list[tuple[Path, str]]) -> str:
    replacements = {}
    for path, replacement in paths:
        value = str(path.resolve())
        for variant in (value, value.replace('\\', '/'),
                        value.replace('/', '\\'), json.dumps(value)[1:-1],
                        path.resolve().as_uri()):
            replacements[variant] = replacement
    for value in sorted(replacements, key=len, reverse=True):
        text = re.sub(re.escape(value), lambda _: replacements[value], text,
                      flags=re.IGNORECASE if os.name == 'nt' else 0)
    return text


def read_log(log, paths: list[tuple[Path, str]]) -> tuple[str, bool]:
    log.seek(0)
    data = log.read(MAX_LOG_BYTES + 1)
    return (sanitize(data[:MAX_LOG_BYTES].decode('utf-8', errors='replace'), paths),
            len(data) > MAX_LOG_BYTES)


def passed_case(output: str, scenario: str) -> bool:
    for line in output.splitlines():
        try:
            message = json.loads(line)
        except (ValueError, TypeError):
            continue
        if isinstance(message, dict) and message == {'phase': 'passed', 'case': scenario}:
            return True
    return False


def supervise(scenario: str, dart: str, root: Path = ROOT) -> dict:
    if scenario not in CASES:
        raise ValueError('unknown fixed regression case')
    started = time.monotonic()
    report = {'case': scenario, 'status': 'failed', 'watchdog_expired': False}
    server = client = None
    with tempfile.TemporaryDirectory(prefix='vityo-dart-pipe-', ignore_cleanup_errors=True) as directory:
        control = Path(directory)
        paths = [(control, '<control>'), (root / 'products/vityo_app', '<app>'),
                 (root, '<repo>'), (Path.home(), '<home>')]
        endpoint = rf'\\.\pipe\vityo-dart-regression-{uuid.uuid4().hex}'
        # File-backed logs avoid pipe deadlocks and blocked communicate threads.
        with (control / 'server.log').open('w+b') as server_log, \
             (control / 'client.log').open('w+b') as client_log:
            deadline = time.monotonic() + CASE_TIMEOUT
            try:
                server = subprocess.Popen(
                    [sys.executable, str(Path(__file__).resolve()), '--server',
                     scenario, '--endpoint', endpoint, '--control', str(control)],
                    stdout=server_log, stderr=subprocess.STDOUT)
                while not (control / 'ready').exists():
                    if server.poll() is not None:
                        raise RuntimeError('server failed before ready')
                    if time.monotonic() >= deadline:
                        raise subprocess.TimeoutExpired('server ready', CASE_TIMEOUT)
                    time.sleep(0.01)
                app = root / 'products/vityo_app'
                client = subprocess.Popen(
                    [dart, f'--packages={app / ".dart_tool/package_config.json"}',
                     str(app / 'tool/windows_named_pipe_regression.dart'),
                     scenario, endpoint, str(control)], cwd=app,
                    stdout=client_log, stderr=subprocess.STDOUT)
                client.wait(timeout=max(0.01, deadline - time.monotonic()))
                report['client_exit'] = client.returncode
                if client.returncode != 0:
                    raise RuntimeError('Dart client failed')
                output, _ = read_log(client_log, paths)
                if not passed_case(output, scenario):
                    raise RuntimeError('Dart client exited without passing assertions')
                (control / 'stop').write_text('stop', encoding='ascii')
                server.wait(timeout=max(0.01, deadline - time.monotonic()))
                if server.returncode != 0:
                    raise RuntimeError('native server failed')
                report['status'] = 'passed'
            except subprocess.TimeoutExpired:
                report.update(status='timeout', watchdog_expired=True)
            except (OSError, RuntimeError) as error:
                report['error'] = sanitize(str(error), paths)
            finally:
                # Always reap both direct children; no taskkill /IM or other
                # broad termination that could hit unrelated Dart processes.
                client_reaped = reap(client)
                server_reaped = reap(server)
                report['cleanup_completed'] = client_reaped and server_reaped
                if not report['cleanup_completed']:
                    report['status'] = 'cleanup-failed'
                for name, log in [('client_output', client_log), ('server_output', server_log)]:
                    report[name], report[f'{name}_truncated'] = read_log(log, paths)
    report['elapsed_seconds'] = round(time.monotonic() - started, 3)
    return report


def resolve_dart(command: str) -> str | None:
    # Flutter puts dart.bat on PATH. Supervising that wrapper would kill cmd.exe
    # and leave its native Dart child alive. Launch only the SDK executable.
    found = shutil.which(command)
    if found is None:
        return None
    path = Path(found).resolve()
    if path.suffix.lower() == '.exe':
        return str(path)
    for candidate in (path.parent / 'dart.exe',
                      path.parent / 'cache/dart-sdk/bin/dart.exe'):
        if candidate.is_file():
            return str(candidate)
    return None


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', choices=CASES, help=argparse.SUPPRESS)
    parser.add_argument('--endpoint', help=argparse.SUPPRESS)
    parser.add_argument('--control', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--dart', default='dart')
    parser.add_argument('--output', type=Path,
                        default=ROOT / 'build/evidence/windows-dart-pipe-tests.json')
    args = parser.parse_args(argv)
    if args.server:
        if os.name != 'nt' or not args.endpoint or args.control is None:
            parser.error('server requires Windows, endpoint and control directory')
        return native_server(args.server, args.endpoint, args.control)
    report = {'schema_version': 1, 'platform': sys.platform,
              'os': platform.system(), 'architecture': platform.machine(),
              'cases': [], 'status': 'not-run'}
    if os.name != 'nt':
        report['reason'] = 'requires native Windows and the real Dart runtime'
        result = 2
    else:
        dart = resolve_dart(args.dart)
        config = ROOT / 'products/vityo_app/.dart_tool/package_config.json'
        if dart is None or not config.exists():
            report['reason'] = 'Native dart.exe and flutter pub get in products/vityo_app are required'
            result = 2
        else:
            for case in CASES:
                case_report = supervise(case, dart)
                report['cases'].append(case_report)
                print(json.dumps(case_report), flush=True)
                if not case_report['cleanup_completed']:
                    break
            passed = (len(report['cases']) == len(CASES) and
                      all(case['status'] == 'passed' for case in report['cases']))
            report['status'] = 'passed' if passed else 'failed'
            result = 0 if passed else 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'status': report['status'], 'output': sanitize(
        str(args.output), [(ROOT, '<repo>'), (Path.home(), '<home>')])}))
    return result


if __name__ == '__main__':
    raise SystemExit(main())
