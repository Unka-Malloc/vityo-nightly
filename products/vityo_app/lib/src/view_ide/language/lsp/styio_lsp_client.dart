import 'dart:async';

import 'lsp_protocol.dart';
import 'lsp_transport.dart';
import 'styio_lsp_capabilities.dart';

class StyioLspProtocolFailure implements Exception {
  const StyioLspProtocolFailure(this.message);

  final String message;

  @override
  String toString() => 'StyioLspProtocolFailure($message)';
}

class StyioLspRequestFailure implements Exception {
  const StyioLspRequestFailure({
    required this.method,
    required this.code,
    required this.message,
    this.data,
  });

  final String method;
  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => 'StyioLspRequestFailure($method: $code $message)';
}

class StyioLspTimeoutFailure implements Exception {
  const StyioLspTimeoutFailure({required this.method, required this.timeout});

  final String method;
  final Duration timeout;

  @override
  String toString() =>
      'StyioLspTimeoutFailure($method did not answer within $timeout)';
}

class StyioLspTransportClosedFailure implements Exception {
  const StyioLspTransportClosedFailure();

  @override
  String toString() => 'StyioLspTransportClosedFailure()';
}

class StyioLspDiagnosticNotification {
  const StyioLspDiagnosticNotification({
    required this.uri,
    required this.diagnostics,
    this.version,
  });

  final String uri;
  final List<Object?> diagnostics;
  final int? version;
}

class StyioLspPendingRequest {
  const StyioLspPendingRequest({required this.id, required this.result});

  final int id;
  final Future<Object?> result;
}

/// Content-Length framed JSON-RPC client for `styio_lspd`.
///
/// The client is transport-agnostic: it reads and writes raw bytes through an
/// [LspByteTransport], so the same client drives a direct child process, a
/// vityod-owned byte process, or an in-memory test fixture.
class StyioLspClient {
  StyioLspClient({
    required LspByteTransport transport,
    this.requestTimeout = const Duration(seconds: 15),
    LspContentFrameCodec codec = const LspContentFrameCodec(),
  }) : _transport = transport,
       _codec = codec {
    _inputSubscription = _transport.input.listen(
      _onBytes,
      onError: _onTransportError,
      onDone: _onTransportDone,
    );
  }

  final LspByteTransport _transport;
  final LspContentFrameCodec _codec;
  final Duration requestTimeout;
  final LspRequestIdGenerator _ids = LspRequestIdGenerator();
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  final Map<int, String> _pendingMethods = <int, String>{};
  final List<int> _buffer = <int>[];
  final StreamController<StyioLspDiagnosticNotification> _diagnostics =
      StreamController<StyioLspDiagnosticNotification>.broadcast();
  final StreamController<Map<String, Object?>> _notifications =
      StreamController<Map<String, Object?>>.broadcast();
  final StreamController<LspProtocolError> _protocolErrors =
      StreamController<LspProtocolError>.broadcast();
  StreamSubscription<List<int>>? _inputSubscription;
  var _closed = false;

  StyioLspCapabilities? _capabilities;
  StyioLspCapabilities? get capabilities => _capabilities;
  bool get isInitialized => _capabilities != null;
  bool get isClosed => _closed;

  Stream<StyioLspDiagnosticNotification> get diagnostics => _diagnostics.stream;
  Stream<Map<String, Object?>> get serverNotifications => _notifications.stream;
  Stream<LspProtocolError> get protocolErrors => _protocolErrors.stream;

  Future<StyioLspCapabilities> initialize({
    required Uri rootUri,
    String? rootPath,
    String clientName = 'Vityo',
    String? clientVersion,
    Map<String, Object?>? initializationOptions,
  }) async {
    final result = await sendRequest('initialize', <String, Object?>{
      'processId': null,
      'clientInfo': <String, Object?>{
        'name': clientName,
        if (clientVersion != null) 'version': clientVersion,
      },
      'rootUri': rootUri.toString(),
      'rootPath': rootPath,
      'capabilities': <String, Object?>{
        'workspace': <String, Object?>{
          'workspaceFolders': false,
          'configuration': false,
        },
        'textDocument': <String, Object?>{
          'publishDiagnostics': <String, Object?>{
            'versionSupport': true,
            'relatedInformation': false,
          },
          'synchronization': <String, Object?>{
            'dynamicRegistration': false,
            'didSave': false,
            'willSave': false,
          },
          'completion': <String, Object?>{
            'completionItem': <String, Object?>{
              'snippetSupport': false,
              'documentationFormat': <String>['markdown', 'plaintext'],
            },
          },
          'hover': <String, Object?>{
            'contentFormat': <String>['markdown', 'plaintext'],
          },
          'semanticTokens': <String, Object?>{
            'requests': <String, Object?>{'full': true},
            'tokenTypes': <String>[],
            'tokenModifiers': <String>[],
            'formats': <String>['relative'],
          },
        },
        'window': <String, Object?>{'workDoneProgress': false},
        'general': <String, Object?>{
          'positionEncodings': <String>['utf-16'],
        },
      },
      if (initializationOptions != null)
        'initializationOptions': initializationOptions,
      'workspaceFolders': null,
    });
    if (result is! Map) {
      throw const StyioLspProtocolFailure(
        'initialize result must be a JSON object',
      );
    }
    final capabilities = StyioLspCapabilities.fromInitializeResult(
      result.map((key, value) => MapEntry(key.toString(), value)),
    );
    _capabilities = capabilities;
    return capabilities;
  }

  Future<void> sendInitialized() async {
    _sendNotification('initialized', const <String, Object?>{});
  }

  void didOpen({
    required String uri,
    required String languageId,
    required int version,
    required String text,
  }) {
    _sendNotification('textDocument/didOpen', <String, Object?>{
      'textDocument': <String, Object?>{
        'uri': uri,
        'languageId': languageId,
        'version': version,
        'text': text,
      },
    });
  }

  void didChange({
    required String uri,
    required int version,
    required List<Map<String, Object?>> contentChanges,
  }) {
    _sendNotification('textDocument/didChange', <String, Object?>{
      'textDocument': <String, Object?>{'uri': uri, 'version': version},
      'contentChanges': contentChanges,
    });
  }

  void didClose({required String uri}) {
    _sendNotification('textDocument/didClose', <String, Object?>{
      'textDocument': <String, Object?>{'uri': uri},
    });
  }

  Future<void> cancelRequest(int id) async {
    _sendNotification(r'$/cancelRequest', <String, Object?>{'id': id});
  }

  StyioLspPendingRequest sendCancellableRequest(
    String method, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) {
    if (_closed) {
      throw const StyioLspTransportClosedFailure();
    }
    final id = _ids.next();
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _pendingMethods[id] = method;
    _write(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    final timeout = requestTimeout;
    final result = completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        _pendingMethods.remove(id);
        throw StyioLspTimeoutFailure(method: method, timeout: timeout);
      },
    );
    return StyioLspPendingRequest(id: id, result: result);
  }

  Future<Object?> sendRequest(
    String method, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) {
    return sendCancellableRequest(method, params).result;
  }

  Future<Object?> completion({
    required String uri,
    required LspPosition position,
  }) {
    return sendRequest('textDocument/completion', <String, Object?>{
      'textDocument': <String, Object?>{'uri': uri},
      'position': position.toJson(),
    });
  }

  Future<Object?> hover({required String uri, required LspPosition position}) {
    return sendRequest('textDocument/hover', <String, Object?>{
      'textDocument': <String, Object?>{'uri': uri},
      'position': position.toJson(),
    });
  }

  Future<Object?> definition({
    required String uri,
    required LspPosition position,
  }) {
    return sendRequest('textDocument/definition', <String, Object?>{
      'textDocument': <String, Object?>{'uri': uri},
      'position': position.toJson(),
    });
  }

  Future<Object?> references({
    required String uri,
    required LspPosition position,
    bool includeDeclaration = true,
  }) {
    return sendRequest('textDocument/references', <String, Object?>{
      'textDocument': <String, Object?>{'uri': uri},
      'position': position.toJson(),
      'context': <String, Object?>{'includeDeclaration': includeDeclaration},
    });
  }

  Future<Object?> rename({
    required String uri,
    required LspPosition position,
    required String newName,
  }) {
    return sendRequest('textDocument/rename', <String, Object?>{
      'textDocument': <String, Object?>{'uri': uri},
      'position': position.toJson(),
      'newName': newName,
    });
  }

  Future<Object?> codeAction({
    required String uri,
    required LspRange range,
    List<Object?> diagnostics = const <Object?>[],
  }) {
    return sendRequest('textDocument/codeAction', <String, Object?>{
      'textDocument': <String, Object?>{'uri': uri},
      'range': range.toJson(),
      'context': <String, Object?>{'diagnostics': diagnostics},
    });
  }

  Future<Object?> inlayHint({required String uri, required LspRange range}) {
    return sendRequest('textDocument/inlayHint', <String, Object?>{
      'textDocument': <String, Object?>{'uri': uri},
      'range': range.toJson(),
    });
  }

  Future<Object?> documentSymbol({required String uri}) {
    return sendRequest('textDocument/documentSymbol', <String, Object?>{
      'textDocument': <String, Object?>{'uri': uri},
    });
  }

  Future<Object?> workspaceSymbol({required String query}) {
    return sendRequest('workspace/symbol', <String, Object?>{'query': query});
  }

  Future<Object?> semanticTokensFull({required String uri}) {
    return sendRequest('textDocument/semanticTokens/full', <String, Object?>{
      'textDocument': <String, Object?>{'uri': uri},
    });
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _inputSubscription?.cancel();
    final failure = const StyioLspTransportClosedFailure();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(failure);
      }
    }
    _pending.clear();
    _pendingMethods.clear();
    await _transport.close();
    await _diagnostics.close();
    await _notifications.close();
    await _protocolErrors.close();
  }

  void _onBytes(List<int> bytes) {
    if (_closed) {
      return;
    }
    _buffer.addAll(bytes);
    while (true) {
      LspContentFrame? frame;
      try {
        frame = _codec.decodeFirst(_buffer);
      } on LspProtocolError catch (error) {
        _protocolErrors.add(error);
        _buffer.clear();
        return;
      } on Object catch (error) {
        _protocolErrors.add(LspProtocolError(error.toString()));
        _buffer.clear();
        return;
      }
      if (frame == null) {
        return;
      }
      _buffer.removeRange(0, frame.consumedBytes);
      _dispatch(frame.message);
    }
  }

  void _dispatch(Map<String, Object?> message) {
    final idValue = message['id'];
    final hasId = idValue != null;
    final method = message['method'];
    if (method == null && hasId) {
      _completeResponse(idValue, message);
      return;
    }
    if (method == 'textDocument/publishDiagnostics') {
      _acceptDiagnostics(message['params']);
      return;
    }
    if (hasId && method != null) {
      _write(<String, Object?>{
        'jsonrpc': '2.0',
        'id': idValue,
        'error': <String, Object?>{
          'code': -32601,
          'message': 'Unsupported server request: $method',
        },
      });
      return;
    }
    if (!_notifications.isClosed) {
      _notifications.add(message);
    }
  }

  void _completeResponse(Object idValue, Map<String, Object?> message) {
    final id = idValue is int ? idValue : int.tryParse(idValue.toString());
    if (id == null) {
      _protocolErrors.add(
        LspProtocolError('Response with non-numeric id: $idValue'),
      );
      return;
    }
    final completer = _pending.remove(id);
    final requestMethod = _pendingMethods.remove(id) ?? '';
    if (completer == null || completer.isCompleted) {
      return;
    }
    if (message.containsKey('error')) {
      final error = message['error'];
      final errorMap = error is Map
          ? error.map((key, value) => MapEntry(key.toString(), value))
          : const <String, Object?>{};
      final rawCode = errorMap['code'];
      completer.completeError(
        StyioLspRequestFailure(
          method: requestMethod,
          code: rawCode is int ? rawCode : -32603,
          message: errorMap['message']?.toString() ?? 'Unknown LSP error',
          data: errorMap['data'],
        ),
      );
      return;
    }
    completer.complete(message['result']);
  }

  void _acceptDiagnostics(Object? params) {
    if (params is! Map) {
      return;
    }
    final uri = params['uri']?.toString() ?? '';
    final rawDiagnostics = params['diagnostics'];
    final diagnostics = rawDiagnostics is List
        ? rawDiagnostics.toList(growable: false)
        : const <Object?>[];
    final version = params['version'];
    if (_diagnostics.isClosed) {
      return;
    }
    _diagnostics.add(
      StyioLspDiagnosticNotification(
        uri: uri,
        diagnostics: diagnostics,
        version: version is int ? version : null,
      ),
    );
  }

  void _onTransportError(Object error, StackTrace stackTrace) {
    if (_closed) {
      return;
    }
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }
    _pending.clear();
    _pendingMethods.clear();
  }

  void _onTransportDone() {
    if (_closed) {
      return;
    }
    _closed = true;
    const failure = StyioLspTransportClosedFailure();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(failure);
      }
    }
    _pending.clear();
    _pendingMethods.clear();
    if (!_diagnostics.isClosed) {
      _diagnostics.close();
    }
    if (!_notifications.isClosed) {
      _notifications.close();
    }
    if (!_protocolErrors.isClosed) {
      _protocolErrors.close();
    }
  }

  void _sendNotification(String method, Map<String, Object?> params) {
    _write(<String, Object?>{
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
  }

  void _write(Map<String, Object?> message) {
    if (_closed) {
      throw const StyioLspTransportClosedFailure();
    }
    final bytes = _codec.encode(message);
    unawaited(
      _transport.write(bytes).catchError((Object error, StackTrace stackTrace) {
        _onTransportError(error, stackTrace);
      }),
    );
  }
}
