import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class WindowsNamedPipeUnavailable implements Exception {
  const WindowsNamedPipeUnavailable();
}

final class WindowsNamedPipeConnection {
  WindowsNamedPipeConnection._(this._handle);

  final int _handle;
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast(sync: true);
  Future<void> _readerDone = Future<void>.value();
  Future<void> _writeTail = Future<void>.value();
  Future<void>? _closeFuture;
  var _closed = false;

  Stream<Uint8List> get incoming => _incoming.stream;

  static Future<WindowsNamedPipeConnection> connect(String endpoint) async {
    final connection = WindowsNamedPipeConnection._(_openPipe(endpoint));
    // Start on the next event turn so the caller can subscribe before any
    // immediate native completion is delivered.
    connection._readerDone = Future<void>(connection._readLoop);
    return connection;
  }

  Future<void> _readLoop() async {
    try {
      while (!_closed) {
        final bytes = await _readPipeBytes(_handle);
        if (bytes.isEmpty) break;
        if (!_closed && !_incoming.isClosed) _incoming.add(bytes);
      }
    } on _PipeIoException catch (error) {
      if (!_closed && !_incoming.isClosed) _incoming.addError(error);
    } finally {
      // Do not await our own reader future. Closing also owns peer-EOF cleanup.
      unawaited(close());
    }
  }

  Future<void> write(Uint8List bytes) {
    if (_closed) throw StateError('named pipe is closed');
    final payload = Uint8List.fromList(bytes);
    final operation = _writeTail.then((_) async {
      if (_closed) throw StateError('named pipe is closed');
      var offset = 0;
      while (offset < payload.length) {
        if (_closed) throw StateError('named pipe is closed');
        offset += await _writePipeBytes(
          _handle,
          Uint8List.sublistView(payload, offset),
        );
      }
    });
    _writeTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> close() => _closeFuture ??= _finishClose();

  Future<void> _finishClose() async {
    _closed = true;
    // Stop submissions, request cancellation, then observe completion before
    // releasing any operation's buffer/event or the shared native handle.
    _cancelIoEx(_handle, nullptr);
    await _readerDone;
    await _writeTail;
    _closeHandle(_handle);
    if (!_incoming.isClosed) await _incoming.close();
  }
}

const _genericRead = 0x80000000;
const _genericWrite = 0x40000000;
const _openExisting = 3;
const _fileFlagOverlapped = 0x40000000;
const _errorIoPending = 997;
const _errorIoIncomplete = 996;
const _errorBrokenPipe = 109;
const _errorNoData = 232;

final class _PipeIoException implements Exception {
  const _PipeIoException(this.code);
  final int code;
  @override
  String toString() => 'vityod named pipe I/O failed (Win32 $code)';
}

final class _Overlapped extends Struct {
  @UintPtr()
  external int internal;
  @UintPtr()
  external int internalHigh;
  @Uint32()
  external int offset;
  @Uint32()
  external int offsetHigh;
  @IntPtr()
  external int event;
}

const _errorPipeBusy = 231;
const _invalidHandle = -1;

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

typedef _CreateFileWNative =
    IntPtr Function(
      Pointer<Utf16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      IntPtr,
    );
typedef _CreateFileWDart =
    int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int);
typedef _WaitNamedPipeWNative = Int32 Function(Pointer<Utf16>, Uint32);
typedef _WaitNamedPipeWDart = int Function(Pointer<Utf16>, int);
typedef _ReadFileNative =
    Int32 Function(
      IntPtr,
      Pointer<Uint8>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Void>,
    );
typedef _ReadFileDart =
    int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>);
typedef _WriteFileNative =
    Int32 Function(
      IntPtr,
      Pointer<Uint8>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Void>,
    );
typedef _WriteFileDart =
    int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>);
typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);
typedef _CancelIoExNative = Int32 Function(IntPtr, Pointer<Void>);
typedef _CancelIoExDart = int Function(int, Pointer<Void>);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

final _CreateFileWDart _createFile = _kernel32
    .lookupFunction<_CreateFileWNative, _CreateFileWDart>('CreateFileW');
final _WaitNamedPipeWDart _waitNamedPipe = _kernel32
    .lookupFunction<_WaitNamedPipeWNative, _WaitNamedPipeWDart>(
      'WaitNamedPipeW',
    );
final _ReadFileDart _readFile = _kernel32
    .lookupFunction<_ReadFileNative, _ReadFileDart>('ReadFile');
final _WriteFileDart _writeFile = _kernel32
    .lookupFunction<_WriteFileNative, _WriteFileDart>('WriteFile');
final _CloseHandleDart _closeHandleFunction = _kernel32
    .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
final _CancelIoExDart _cancelIoEx = _kernel32
    .lookupFunction<_CancelIoExNative, _CancelIoExDart>('CancelIoEx');
final _GetLastErrorDart _getLastError = _kernel32
    .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');

int _openPipe(String endpoint) {
  final name = endpoint.toNativeUtf16();
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      final handle = _createFile(
        name,
        _genericRead | _genericWrite,
        0,
        nullptr,
        _openExisting,
        _fileFlagOverlapped,
        0,
      );
      if (handle != _invalidHandle) return handle;
      if (_getLastError() != _errorPipeBusy ||
          DateTime.now().isAfter(deadline)) {
        throw const WindowsNamedPipeUnavailable();
      }
      _waitNamedPipe(name, 100);
    }
  } finally {
    malloc.free(name);
  }
}

typedef _CreateEventWNative =
    IntPtr Function(Pointer<Void>, Int32, Int32, Pointer<Utf16>);
typedef _CreateEventWDart =
    int Function(Pointer<Void>, int, int, Pointer<Utf16>);
typedef _GetOverlappedResultNative =
    Int32 Function(IntPtr, Pointer<_Overlapped>, Pointer<Uint32>, Int32);
typedef _GetOverlappedResultDart =
    int Function(int, Pointer<_Overlapped>, Pointer<Uint32>, int);

final _CreateEventWDart _createEvent = _kernel32
    .lookupFunction<_CreateEventWNative, _CreateEventWDart>('CreateEventW');
final _GetOverlappedResultDart _getOverlappedResult = _kernel32
    .lookupFunction<_GetOverlappedResultNative, _GetOverlappedResultDart>(
      'GetOverlappedResult',
    );

Future<int> _completeOperation(
  int handle,
  Pointer<_Overlapped> operation,
  Pointer<Uint32> transferred,
) async {
  while (true) {
    if (_getOverlappedResult(handle, operation, transferred, 0) != 0) {
      return transferred.value;
    }
    final error = _getLastError();
    if (error != _errorIoIncomplete) throw _PipeIoException(error);
    // Poll only pending overlapped I/O; never block the isolate in native read,
    // write or completion waits. The event belongs exclusively to this op.
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<Uint8List> _readPipeBytes(int handle) async {
  final operation = calloc<_Overlapped>();
  final buffer = malloc<Uint8>(64 * 1024);
  final transferred = calloc<Uint32>();
  var event = 0;
  try {
    event = _createEvent(nullptr, 1, 0, nullptr);
    if (event == 0) throw _PipeIoException(_getLastError());
    operation.ref.event = event;
    if (_readFile(handle, buffer, 64 * 1024, nullptr, operation.cast()) == 0) {
      final error = _getLastError();
      if (error != _errorIoPending) throw _PipeIoException(error);
    }
    final count = await _completeOperation(handle, operation, transferred);
    return Uint8List.fromList(buffer.asTypedList(count));
  } on _PipeIoException catch (error) {
    if (error.code == _errorBrokenPipe || error.code == _errorNoData) {
      return Uint8List(0);
    }
    rethrow;
  } finally {
    if (event != 0) _closeHandle(event);
    calloc.free(transferred);
    malloc.free(buffer);
    calloc.free(operation);
  }
}

Future<int> _writePipeBytes(int handle, Uint8List bytes) async {
  final operation = calloc<_Overlapped>();
  final buffer = malloc<Uint8>(bytes.length);
  final transferred = calloc<Uint32>();
  var event = 0;
  try {
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    event = _createEvent(nullptr, 1, 0, nullptr);
    if (event == 0) throw _PipeIoException(_getLastError());
    operation.ref.event = event;
    if (_writeFile(handle, buffer, bytes.length, nullptr, operation.cast()) ==
        0) {
      final error = _getLastError();
      if (error != _errorIoPending) throw _PipeIoException(error);
    }
    final count = await _completeOperation(handle, operation, transferred);
    if (count == 0) throw const _PipeIoException(_errorNoData);
    return count;
  } finally {
    if (event != 0) _closeHandle(event);
    calloc.free(transferred);
    malloc.free(buffer);
    calloc.free(operation);
  }
}

void _closeHandle(int handle) {
  _closeHandleFunction(handle);
}
