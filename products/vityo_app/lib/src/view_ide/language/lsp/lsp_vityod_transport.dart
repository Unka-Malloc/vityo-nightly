import 'dart:async';

import '../../../ide/local_service/vityod_lsp_gateway.dart';
import 'lsp_transport.dart';

/// [LspByteTransport] over a vityod-owned byte process.
///
/// vityod exposes the daemon as write/poll/stop requests rather than a live
/// socket, so this transport drains stdout on a background poll loop and
/// forwards client bytes through `lsp.request` writes. This is the desktop
/// production path: the language daemon stays a vityod child, never a direct
/// child of the Flutter client.
class VityodLspTransport implements LspByteTransport {
  VityodLspTransport({
    required VityodLspSession session,
    this.pollInterval = const Duration(milliseconds: 10),
    this.maximumBytesPerPoll = 64 * 1024,
  }) : _session = session {
    _pollLoop = _runPollLoop();
  }

  final VityodLspSession _session;
  final Duration pollInterval;
  final int maximumBytesPerPoll;
  final StreamController<List<int>> _input =
      StreamController<List<int>>.broadcast();
  final StreamController<List<int>> _stderr =
      StreamController<List<int>>.broadcast();
  late final Future<void> _pollLoop;
  var _closed = false;
  int? _exitCode;

  @override
  Stream<List<int>> get input => _input.stream;

  Stream<List<int>> get stderr => _stderr.stream;

  Object? get exitCode => _exitCode;

  @override
  Future<void> write(List<int> bytes) async {
    if (_closed) {
      throw StateError('LSP vityod transport is closed.');
    }
    if (bytes.isEmpty) {
      return;
    }
    await _session.write(bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      await _session.stop();
    } on Object {
      // The daemon may already be gone; stopping is best effort.
    }
    await _pollLoop;
    await _input.close();
    await _stderr.close();
  }

  Future<void> _runPollLoop() async {
    Object? failure;
    while (!_closed) {
      VityodLspPoll polled;
      try {
        polled = await _session.poll(maximumBytes: maximumBytesPerPoll);
      } on Object catch (error) {
        failure = error;
        break;
      }
      if (polled.stderr.isNotEmpty && !_stderr.isClosed) {
        _stderr.add(polled.stderr);
      }
      if (polled.stdout.isNotEmpty && !_input.isClosed) {
        _input.add(polled.stdout);
      }
      if (polled.exitCode != null) {
        _exitCode = polled.exitCode;
        break;
      }
      await Future<void>.delayed(pollInterval);
    }
    if (failure != null && !_input.isClosed) {
      _input.addError(failure);
    }
    if (!_input.isClosed) {
      await _input.close();
    }
  }
}
