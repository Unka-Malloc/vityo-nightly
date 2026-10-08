"""Compile the actual shim against fake Win32 APIs; never executes Windows I/O."""
from pathlib import Path, PureWindowsPath
import json
import os
import re
import sys
from unittest import mock
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'products/vityo_app/native/windows_pipe/windows_pipe.cpp'
sys.path.insert(0, str(ROOT / 'scripts'))
from vityo_startup_probe import _redact

DIAGNOSTIC_LIMIT = 8192

HEADER = r'''
#pragma once
#include <cstdint>
#ifdef __declspec
#undef __declspec
#endif
#define __declspec(x)
using DWORD = uint32_t;
using BOOL = int32_t;
using HANDLE = void*;
using LPSECURITY_ATTRIBUTES = void*;
struct OVERLAPPED { uintptr_t a, b; uint32_t c, d; HANDLE event; };
#define INVALID_HANDLE_VALUE reinterpret_cast<HANDLE>(intptr_t(-1))
#define ERROR_SUCCESS 0
inline DWORD error_value = 0;
inline bool succeeds = false;
inline int captures = 0;
inline HANDLE good = reinterpret_cast<HANDLE>(intptr_t(7));
inline DWORD GetLastError() { ++captures; return error_value; }
inline HANDLE CreateFileW(const wchar_t*, DWORD, DWORD, void*, DWORD, DWORD, HANDLE) {
  return succeeds ? good : INVALID_HANDLE_VALUE;
}
inline HANDLE CreateEventW(void*, BOOL, BOOL, const wchar_t*) {
  return succeeds ? good : nullptr;
}
inline BOOL ReadFile(HANDLE, void*, DWORD, DWORD*, OVERLAPPED*) { return succeeds; }
inline BOOL WriteFile(HANDLE, const void*, DWORD, DWORD*, OVERLAPPED*) { return succeeds; }
inline BOOL GetOverlappedResult(HANDLE, OVERLAPPED*, DWORD*, BOOL) { return succeeds; }
'''
PROGRAM = r'''
#include <cassert>
#include "windows_pipe.cpp"
int main() {
  assert(vityo_pipe_abi_version() == 1);
  DWORD out = 123;
  OVERLAPPED op{};
  for (DWORD expected : {DWORD(997), DWORD(996), DWORD(995), DWORD(109), DWORD(0)}) {
    succeeds = false;
    error_value = expected;
    int before = captures;
    assert(vityo_pipe_create_file(L"pipe", 0, 0, nullptr, 0, 0, nullptr, &out) == INVALID_HANDLE_VALUE);
    assert(out == expected);
    assert(vityo_pipe_create_event(nullptr, 1, 0, nullptr, &out) == nullptr);
    assert(out == expected);
    assert(vityo_pipe_read(good, nullptr, 0, nullptr, &op, &out) == 0);
    assert(out == expected);
    assert(vityo_pipe_write(good, nullptr, 0, nullptr, &op, &out) == 0);
    assert(out == expected);
    assert(vityo_pipe_get_result(good, &op, nullptr, 0, &out) == 0);
    assert(out == expected && captures == before + 5);
    // Simulate the VM changing thread-local error after the native call.
    error_value = 42;
    assert(out == expected);
  }
  succeeds = true;
  const int before = captures;
  assert(vityo_pipe_create_file(L"pipe", 0, 0, nullptr, 0, 0, nullptr, &out) == good && out == 0);
  assert(vityo_pipe_create_event(nullptr, 1, 0, nullptr, &out) == good && out == 0);
  assert(vityo_pipe_read(good, nullptr, 0, nullptr, &op, &out) != 0 && out == 0);
  assert(vityo_pipe_write(good, nullptr, 0, nullptr, &op, &out) != 0 && out == 0);
  assert(vityo_pipe_get_result(good, &op, nullptr, 0, &out) != 0 && out == 0);
  assert(captures == before);
}
'''


def resolve_compiler():
    explicit = os.environ.get('CXX')
    choices = [explicit] if explicit else ['g++', 'clang++', 'c++', 'cl', 'clang-cl']
    for candidate in choices:
        path = shutil.which(candidate)
        if path is None:
            if explicit:
                raise ValueError('Explicit CXX compiler is unavailable; no fallback')
            continue
        name = PureWindowsPath(path).name.lower().removesuffix('.exe')
        if name in ('cl', 'clang-cl'):
            return path, 'msvc'
        if re.fullmatch(r'(?:.*-)?(?:g\+\+|clang\+\+|c\+\+)(?:-\d+(?:\.\d+)*)?', name):
            return path, 'gnu'
        raise ValueError('CXX must name one supported compiler executable, without flags')
    return None


def compiler_command(compiler, root, output):
    executable, style = compiler
    source = str(root / 'test.cpp')
    if style == 'gnu':
        return [executable, '-std=c++17', '-Wall', '-Wextra', '-Werror',
                '-I', str(root), '-I', str(SOURCE.parent), source, '-o', str(output)]
    if style == 'msvc':
        return [executable, '/nologo', '/std:c++17', '/EHsc', '/W4', '/WX',
                '/I' + str(root), '/I' + str(SOURCE.parent), source,
                '/Fe' + str(output), '/Fo' + str(root / 'boundary-test.obj')]
    raise ValueError('Unsupported compiler command adapter')


def diagnostic_text(value, root):
    text = _redact(str(value))
    for path, label in ((root, '<build>'), (ROOT, '<repo>'), (Path.home(), '<home>')):
        for spelling in (str(path), str(path).replace('\\', '/')):
            text = text.replace(spelling, label)
    return text[:DIAGNOSTIC_LIMIT]


def run_boundary_command(command, root, phase, timeout):
    # File-backed output keeps compiler diagnostics out of unbounded RAM pipes.
    # Only a bounded, redacted prefix reaches unittest/CI, including on timeout.
    with tempfile.TemporaryFile('w+b') as stdout, tempfile.TemporaryFile('w+b') as stderr:
        report = {'phase': phase, 'command': [diagnostic_text(arg, root) for arg in command],
                  'status': 'passed', 'returncode': None, 'timeout_seconds': timeout}
        try:
            result = subprocess.run(command, cwd=root, check=False, stdout=stdout,
                                    stderr=stderr, timeout=timeout)
            report['returncode'] = result.returncode
            if result.returncode != 0:
                report['status'] = 'failed'
        except (OSError, subprocess.TimeoutExpired) as error:
            report['status'] = 'timeout' if isinstance(error, subprocess.TimeoutExpired) else 'spawn-error'
            report['error'] = diagnostic_text(error, root)
        for name, stream in (('stdout', stdout), ('stderr', stderr)):
            stream.seek(0)
            data = stream.read(DIAGNOSTIC_LIMIT + 1)
            truncated = len(data) > DIAGNOSTIC_LIMIT
            data = data[:DIAGNOSTIC_LIMIT]
            if truncated:
                # Do not expose a credential cut in half at the capture boundary.
                data = data[:data.rfind(b'\n') + 1]
            report[name] = diagnostic_text(data.decode('utf-8', errors='replace'), root)
            report[name + '_truncated'] = truncated
        if report['status'] != 'passed':
            raise AssertionError(json.dumps(report, sort_keys=True))
        return report


class NativeBoundaryTests(unittest.TestCase):
    def test_actual_wrappers_capture_each_error_before_return(self):
        compiler = resolve_compiler()
        if compiler is None:
            self.skipTest('portable C++ compiler unavailable')
        # A native MinGW compiler predefines this macro. Simulate that condition
        # on other compilers too, after system includes, without changing APIs.
        preamble = '#include <initializer_list>\n#include <cassert>\n#include <cstdint>\n'
        inherited_macro = ('#ifndef __declspec\n'
                           '#define __declspec(x) __attribute__((x))\n#endif\n')
        for case, prefix in (('ordinary', ''), ('predefined-declspec', inherited_macro)):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / 'windows.h').write_text(HEADER)
                (root / 'test.cpp').write_text(preamble + prefix + PROGRAM)
                output = root / ('boundary-test.exe' if os.name == 'nt' else 'boundary-test')
                run_boundary_command(compiler_command(compiler, root, output), root,
                                     'compile:' + case, 30)
                run_boundary_command([str(output)], root, 'run:' + case, 5)

    def test_dart_never_reads_thread_local_error(self):
        source = (ROOT / 'products/vityo_app/lib/src/ide/local_service/transport/windows_named_pipe.dart').read_text()
        self.assertNotIn('_getLastError', source)
        self.assertNotIn('isLeaf: true', source)
        self.assertIn("'GetOverlappedResult'", source)
        self.assertIn('nativeError.value', source)

    def test_loader_validates_complete_abi_before_io(self):
        source = (ROOT / 'products/vityo_app/lib/src/ide/local_service/transport/windows_pipe_library.dart').read_text()
        self.assertIn('validateWindowsPipeLibraryAbi(version())', source)
        self.assertIn('version != windowsPipeLibraryAbi', source)
        self.assertNotIn('Platform.environment', source)
        self.assertIn('file.resolveSymbolicLinksSync()', source)
        for symbol in ('create_file', 'create_event', 'read', 'write', 'get_result'):
            self.assertIn(f"'vityo_pipe_{symbol}'", source)
        cmake = (ROOT / 'products/vityo_app/windows/CMakeLists.txt').read_text()
        self.assertIn('install(TARGETS vityo_windows_pipe', cmake)


class CompilerAdapterTests(unittest.TestCase):
    def test_available_compiler_frontends_use_their_own_adapter(self):
        candidates = [('g++', 'gnu'), ('clang++', 'gnu'), ('c++', 'gnu'),
                      ('cl', 'msvc'), ('clang-cl', 'msvc')]
        for name, style in candidates:
            with self.subTest(name=name), mock.patch.dict(os.environ, {}, clear=True), \
                 mock.patch.object(shutil, 'which', side_effect=lambda key: name if key == name else None):
                self.assertEqual(resolve_compiler(), (name, style))
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(shutil, 'which', return_value=None):
            self.assertIsNone(resolve_compiler())

    def test_explicit_frontend_and_missing_override_never_fallback(self):
        for path, style in [(r'C:\Program Files\VC\cl.EXE', 'msvc'),
                            ('/opt/bin/clang-cl', 'msvc'), ('/opt/bin/clang++-18', 'gnu'),
                            ('/opt/bin/g++-14', 'gnu'), ('/opt/bin/x86_64-w64-mingw32-g++', 'gnu')]:
            with self.subTest(path=path), mock.patch.dict(os.environ, {'CXX': path}, clear=True), \
                 mock.patch.object(shutil, 'which', return_value=path) as which:
                self.assertEqual(resolve_compiler(), (path, style))
                which.assert_called_once_with(path)
        for available in (None, '/opt/unknown-frontend'):
            with mock.patch.dict(os.environ, {'CXX': 'selected'}, clear=True), \
                 mock.patch.object(shutil, 'which', return_value=available) as which, \
                 self.assertRaises(ValueError):
                resolve_compiler()
            which.assert_called_once_with('selected')

    def test_command_adapters_preserve_cxx17_warnings_and_spaces(self):
        root = Path('path with spaces')
        output = root / 'boundary-test.exe'
        for compiler in ('g++', 'clang++', 'c++'):
            command = compiler_command((compiler, 'gnu'), root, output)
            self.assertEqual(command[0], compiler)
            self.assertIn('-std=c++17', command)
            self.assertIn('-Werror', command)
            self.assertEqual(command[-2:], ['-o', str(output)])
            self.assertIn(str(root / 'test.cpp'), command)
        for compiler in ('cl.exe', 'clang-cl.exe'):
            command = compiler_command((compiler, 'msvc'), root, output)
            self.assertEqual(command[0], compiler)
            self.assertIn('/std:c++17', command)
            self.assertIn('/WX', command)
            self.assertIn('/Fe' + str(output), command)
            self.assertIn('/Fo' + str(root / 'boundary-test.obj'), command)
            self.assertNotIn('-Werror', command)
        with self.assertRaises(ValueError):
            compiler_command(('unknown', 'unknown'), root, output)

    def test_nonzero_retains_structured_redacted_stdout_stderr_and_has_no_retry(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            secret = 'synthetic inherited private value'
            def failure(command, **kwargs):
                self.assertEqual(kwargs['timeout'], 30)
                self.assertFalse(kwargs['check'])
                self.assertNotIn('shell', kwargs)
                kwargs['stdout'].write(b'compiler identity\n')
                kwargs['stderr'].write(f'{root}: __declspec redefined {secret}\n'.encode())
                return subprocess.CompletedProcess(command, 7)
            with mock.patch.dict(os.environ, {'BOUNDARY_TEST_TOKEN': secret}), \
                 mock.patch.object(subprocess, 'run', side_effect=failure) as run, \
                 self.assertRaises(AssertionError) as raised:
                run_boundary_command(['compiler', str(root / 'test.cpp')], root, 'compile', 30)
            report = json.loads(str(raised.exception))
            self.assertEqual(report['returncode'], 7)
            self.assertEqual(report['status'], 'failed')
            self.assertIn('__declspec redefined', report['stderr'])
            self.assertIn('compiler identity', report['stdout'])
            self.assertIn('[redacted]', report['stderr'])
            self.assertNotIn(secret, str(raised.exception))
            self.assertNotIn(str(root), str(raised.exception))
            run.assert_called_once()

    def test_timeout_spawn_failure_and_truncated_output_stay_explicit(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            for error, status in [(subprocess.TimeoutExpired('compiler', 30), 'timeout'),
                                  (OSError('compiler missing'), 'spawn-error')]:
                def fail(command, **kwargs):
                    kwargs['stderr'].write(b'partial diagnostic\n')
                    raise error
                with self.subTest(status=status), mock.patch.object(subprocess, 'run', side_effect=fail), \
                     self.assertRaises(AssertionError) as raised:
                    run_boundary_command(['compiler'], root, 'compile', 30)
                report = json.loads(str(raised.exception))
                self.assertEqual(report['status'], status)
                self.assertIsNone(report['returncode'])
                self.assertIn('partial diagnostic', report['stderr'])
            def excessive(command, **kwargs):
                kwargs['stderr'].write(b'first complete line\n' + b'x' * DIAGNOSTIC_LIMIT)
                return subprocess.CompletedProcess(command, 1)
            with mock.patch.object(subprocess, 'run', side_effect=excessive), \
                 self.assertRaises(AssertionError) as raised:
                run_boundary_command(['compiler'], root, 'compile', 30)
            report = json.loads(str(raised.exception))
            self.assertTrue(report['stderr_truncated'])
            self.assertEqual(report['stderr'], 'first complete line\n')
            self.assertLessEqual(len(report['stderr']), DIAGNOSTIC_LIMIT)

    def test_real_compiler_failure_retains_its_diagnostic(self):
        compiler = resolve_compiler()
        if compiler is None:
            self.skipTest('portable C++ compiler unavailable')
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / 'test.cpp').write_text('#error boundary-diagnostic-fixture\n')
            output = root / ('boundary-test.exe' if os.name == 'nt' else 'boundary-test')
            with self.assertRaises(AssertionError) as raised:
                run_boundary_command(compiler_command(compiler, root, output), root,
                                     'compile:expected-failure', 30)
            report = json.loads(str(raised.exception))
            self.assertEqual(report['status'], 'failed')
            self.assertNotEqual(report['returncode'], 0)
            self.assertIn('boundary-diagnostic-fixture', report['stdout'] + report['stderr'])
            self.assertNotIn(str(root), str(raised.exception))

    def test_success_remains_success_and_real_timeout_is_bounded(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            report = run_boundary_command([sys.executable, '-c', 'print("ready")'], root, 'run', 5)
            self.assertEqual(report['returncode'], 0)
            self.assertEqual(report['status'], 'passed')
            self.assertEqual(report['stdout'].splitlines(), ['ready'])
            with self.assertRaises(AssertionError) as raised:
                run_boundary_command([sys.executable, '-c', 'import time; time.sleep(20)'], root, 'run', 0.1)
            self.assertEqual(json.loads(str(raised.exception))['status'], 'timeout')
