"""Compile the actual shim against fake Win32 APIs; never executes Windows I/O."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'products/vityo_app/native/windows_pipe/windows_pipe.cpp'

HEADER = r'''
#pragma once
#include <cstdint>
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


class NativeBoundaryTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('g++'), 'portable C++ compiler unavailable')
    def test_actual_wrappers_capture_each_error_before_return(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'windows.h').write_text(HEADER)
            (root / 'test.cpp').write_text('#include <initializer_list>\n' + PROGRAM)
            output = root / 'boundary-test'
            subprocess.run([
                shutil.which('g++'), '-std=c++17', '-Wall', '-Wextra', '-Werror',
                '-I', str(root), '-I', str(SOURCE.parent),
                str(root / 'test.cpp'), '-o', str(output),
            ], check=True, capture_output=True, text=True)
            subprocess.run([str(output)], check=True, timeout=5)

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
