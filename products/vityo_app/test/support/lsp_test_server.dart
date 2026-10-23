import 'dart:async';

import 'package:vityo_app/src/view_ide/language/lsp/lsp_memory_transport.dart';
import 'package:vityo_app/src/view_ide/language/lsp/lsp_protocol.dart';

/// In-process fake `styio_lspd` peer speaking LSP framing over an in-memory
/// transport. Tests install a [handler] to answer requests.
class LspTestServer {
  LspTestServer() {
    _subscription = transport.output.listen(_ingest);
  }

  final LspMemoryTransport transport = LspMemoryTransport();
  final LspContentFrameCodec codec = const LspContentFrameCodec();
  final List<Map<String, Object?>> received = <Map<String, Object?>>[];
  final List<int> _buffer = <int>[];
  StreamSubscription<List<int>>? _subscription;

  void Function(Map<String, Object?> message)? handler;

  void _ingest(List<int> bytes) {
    _buffer.addAll(bytes);
    while (true) {
      final frame = codec.decodeFirst(_buffer);
      if (frame == null) {
        return;
      }
      _buffer.removeRange(0, frame.consumedBytes);
      received.add(frame.message);
      handler?.call(frame.message);
    }
  }

  List<Map<String, Object?>> requestsFor(String method) {
    return received
        .where((message) => message['method'] == method)
        .toList(growable: false);
  }

  void respond(Object? id, Object? result) {
    if (id == null) {
      return;
    }
    transport.receive(
      codec.encode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      }),
    );
  }

  void respondError(Object? id, int code, String message) {
    if (id == null) {
      return;
    }
    transport.receive(
      codec.encode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, Object?>{'code': code, 'message': message},
      }),
    );
  }

  void notify(String method, Map<String, Object?> params) {
    transport.receive(
      codec.encode(<String, Object?>{
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
      }),
    );
  }

  /// Sends a raw byte slice, used to exercise clients across split frames.
  void receiveRaw(List<int> bytes) => transport.receive(bytes);

  Future<void> dispose() async {
    await _subscription?.cancel();
    await transport.close();
  }
}

/// Capability document matching the real `styio_lspd` initialize result.
Map<String, Object?> styioLspdCapabilities({bool formatting = false}) {
  return <String, Object?>{
    'capabilities': <String, Object?>{
      'textDocumentSync': <String, Object?>{'openClose': true, 'change': 2},
      'completionProvider': <String, Object?>{},
      'hoverProvider': true,
      'codeActionProvider': true,
      'definitionProvider': true,
      'referencesProvider': true,
      'renameProvider': true,
      'inlayHintProvider': true,
      'documentSymbolProvider': true,
      'workspaceSymbolProvider': true,
      if (formatting) 'documentFormattingProvider': true,
      'workspace': <String, Object?>{
        'workspaceFolders': <String, Object?>{'supported': false},
      },
      'semanticTokensProvider': <String, Object?>{
        'legend': <String, Object?>{
          'tokenTypes': <String>[
            'namespace',
            'type',
            'class',
            'enum',
            'interface',
            'struct',
            'typeParameter',
            'parameter',
            'variable',
            'property',
            'enumMember',
            'event',
            'function',
            'method',
            'macro',
            'keyword',
            'modifier',
            'comment',
            'string',
            'number',
            'operator',
          ],
          'tokenModifiers': <String>[],
        },
        'full': true,
      },
    },
    'experimental': <String, Object?>{
      'styio': <String, Object?>{
        'workspaceState': <String, Object?>{'root': '/workspace'},
      },
    },
  };
}
