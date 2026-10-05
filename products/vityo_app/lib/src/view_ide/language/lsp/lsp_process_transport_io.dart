import 'dart:async';
import 'dart:io';

import 'lsp_transport.dart';

/// Starts [executable] as a direct child process and exposes its stdio as an
/// [LspByteTransport]. Used for tests and no-daemon scenarios; the desktop
/// production path routes the same bytes through vityod instead.
Future<LspByteTransport> startProcessLspTransport({
  required String executable,
  List<String> arguments = const <String>[],
  String? workingDirectory,
  Map<String, String> environment = const <String, String>{},
}) async {
  if (executable.trim().isEmpty) {
    throw ArgumentError.value(executable, 'executable', 'must not be empty');
  }
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment.isEmpty ? null : environment,
  );
  return _ProcessLspTransport(process);
}

class _ProcessLspTransport implements LspByteTransport {
  _ProcessLspTransport(this._process) {
    _exitSubscription = _process.exitCode.then((code) {
      _exitCode = code;
      if (!_closed) {
        _closed = true;
        unawaited(_input.close());
      }
    });
  }

  final Process _process;
  late final Future<void> _exitSubscription;
  final StreamController<List<int>> _input =
      StreamController<List<int>>.broadcast();
  StreamSubscription<List<int>>? _stdoutSubscription;
  var _closed = false;
  int? _exitCode;

  int? get exitCode => _exitCode;

  @override
  Stream<List<int>> get input {
    _stdoutSubscription ??= _process.stdout.listen(
      _input.add,
      onError: _input.addError,
    );
    return _input.stream;
  }

  @override
  Future<void> write(List<int> bytes) async {
    if (_closed) {
      throw StateError('LSP process transport is closed.');
    }
    if (bytes.isEmpty) {
      return;
    }
    _process.stdin.add(bytes);
    await _process.stdin.flush();
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _stdoutSubscription?.cancel();
    try {
      await _process.stdin.close();
    } on Object {
      // The process may already have closed its stdin.
    }
    _process.kill();
    await _exitSubscription;
    await _input.close();
  }
}
