#include <windows.h>
#include <cstdint>

// Stable C ABI. Dart owns all handles, OVERLAPPED structures and buffers. Never
// allocate, log, close a handle or call any other API between a failed operation
// and GetLastError: returning to the VM before capture can lose the error code.
#define VITYO_PIPE_EXPORT extern "C" __declspec(dllexport)

static_assert(sizeof(DWORD) == sizeof(uint32_t));
static_assert(sizeof(BOOL) == sizeof(int32_t));
static_assert(sizeof(HANDLE) == sizeof(intptr_t));
static_assert(sizeof(OVERLAPPED) == (sizeof(void*) == 8 ? 32 : 20));

VITYO_PIPE_EXPORT uint32_t vityo_pipe_abi_version() { return 1; }

VITYO_PIPE_EXPORT HANDLE vityo_pipe_create_file(
    const wchar_t* name, DWORD access, DWORD sharing,
    LPSECURITY_ATTRIBUTES security, DWORD disposition, DWORD flags,
    HANDLE template_file, DWORD* error) {
  const HANDLE result = CreateFileW(name, access, sharing, security, disposition,
                                    flags, template_file);
  const DWORD captured = result == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
  *error = captured;
  return result;
}

VITYO_PIPE_EXPORT HANDLE vityo_pipe_create_event(
    LPSECURITY_ATTRIBUTES security, BOOL manual_reset, BOOL initial_state,
    const wchar_t* name, DWORD* error) {
  const HANDLE result = CreateEventW(security, manual_reset, initial_state, name);
  const DWORD captured = result == nullptr ? GetLastError() : ERROR_SUCCESS;
  *error = captured;
  return result;
}

VITYO_PIPE_EXPORT BOOL vityo_pipe_read(
    HANDLE handle, void* buffer, DWORD count, DWORD* transferred,
    OVERLAPPED* operation, DWORD* error) {
  const BOOL result = ReadFile(handle, buffer, count, transferred, operation);
  const DWORD captured = result ? ERROR_SUCCESS : GetLastError();
  *error = captured;
  return result;
}

VITYO_PIPE_EXPORT BOOL vityo_pipe_write(
    HANDLE handle, const void* buffer, DWORD count, DWORD* transferred,
    OVERLAPPED* operation, DWORD* error) {
  const BOOL result = WriteFile(handle, buffer, count, transferred, operation);
  const DWORD captured = result ? ERROR_SUCCESS : GetLastError();
  *error = captured;
  return result;
}

VITYO_PIPE_EXPORT BOOL vityo_pipe_get_result(
    HANDLE handle, OVERLAPPED* operation, DWORD* transferred, BOOL wait,
    DWORD* error) {
  const BOOL result = GetOverlappedResult(handle, operation, transferred, wait);
  const DWORD captured = result ? ERROR_SUCCESS : GetLastError();
  *error = captured;
  return result;
}
