import 'dart:async';

import 'lsp_transport.dart';

/// In-memory duplex [LspByteTransport] for tests and in-process fixtures.
///
/// Server bytes are injected with [receive]; client bytes written by the LSP
/// client are emitted on [output] for assertions.
class LspMemoryTransport implements LspByteTransport {
  final StreamController<List<int>> _input =
      StreamController<List<int>>.broadcast();
  final StreamController<List<int>> _output =
      StreamController<List<int>>.broadcast();
  var _closed = false;

  @override
  Stream<List<int>> get input => _input.stream;

  Stream<List<int>> get output => _output.stream;

  bool get isClosed => _closed;

  void receive(List<int> bytes) {
    if (_closed || bytes.isEmpty) {
      return;
    }
    _input.add(List<int>.unmodifiable(bytes));
  }

  @override
  Future<void> write(List<int> bytes) async {
    if (_closed) {
      throw StateError('LSP memory transport is closed.');
    }
    if (bytes.isEmpty) {
      return;
    }
    _output.add(List<int>.unmodifiable(bytes));
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _input.close();
    await _output.close();
  }
}
