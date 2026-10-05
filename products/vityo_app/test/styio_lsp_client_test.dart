import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/language/lsp/lsp.dart';

import 'support/lsp_test_server.dart';

void main() {
  late LspTestServer server;

  setUp(() {
    server = LspTestServer();
  });

  tearDown(() async {
    await server.dispose();
  });

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test(
    'initialize performs the LSP handshake and parses capabilities',
    () async {
      server.handler = (message) {
        if (message['method'] == 'initialize') {
          final params = message['params']! as Map;
          expect(params['rootUri'], 'file:///workspace');
          server.respond(message['id'], styioLspdCapabilities());
        }
      };
      final client = StyioLspClient(transport: server.transport);

      final capabilities = await client.initialize(
        rootUri: Uri.parse('file:///workspace'),
        rootPath: '/workspace',
      );

      expect(client.isInitialized, isTrue);
      expect(capabilities.completionProvider, isTrue);
      expect(capabilities.hoverProvider, isTrue);
      expect(capabilities.definitionProvider, isTrue);
      expect(capabilities.referencesProvider, isTrue);
      expect(capabilities.renameProvider, isTrue);
      expect(capabilities.codeActionProvider, isTrue);
      expect(capabilities.inlayHintProvider, isTrue);
      expect(capabilities.documentSymbolProvider, isTrue);
      expect(capabilities.workspaceSymbolProvider, isTrue);
      expect(capabilities.semanticTokensProvider, isTrue);
      expect(capabilities.semanticTokenTypes, hasLength(21));
      expect(capabilities.workspaceFoldersSupported, isFalse);
      expect(capabilities.supportsIncrementalSync, isTrue);
      // styio_lspd never advertises formatting; it must not be invented.
      expect(capabilities.formattingProvider, isFalse);

      await client.sendInitialized();
      await pump();
      expect(server.requestsFor('initialized'), hasLength(1));
      await client.close();
    },
  );

  test('request/response round trips and maps errors', () async {
    server.handler = (message) {
      switch (message['method']) {
        case 'initialize':
          server.respond(message['id'], styioLspdCapabilities());
          break;
        case 'textDocument/completion':
          server.respond(message['id'], <Object?>[
            <String, Object?>{
              'label': 'main',
              'kind': 3,
              'insertText': 'main',
              'detail': 'function',
            },
          ]);
          break;
        case 'textDocument/hover':
          server.respondError(message['id'], -32603, 'hover unavailable');
          break;
        default:
          break;
      }
    };
    final client = StyioLspClient(transport: server.transport);
    await client.initialize(rootUri: Uri.parse('file:///workspace'));
    await client.sendInitialized();

    final completion = await client.completion(
      uri: 'file:///workspace/main.styio',
      position: const LspPosition(line: 0, character: 1),
    );
    expect(completion, isA<List<Object?>>());
    expect((completion! as List).first, containsPair('label', 'main'));

    await expectLater(
      client.hover(
        uri: 'file:///workspace/main.styio',
        position: const LspPosition(line: 0, character: 1),
      ),
      throwsA(
        isA<StyioLspRequestFailure>()
            .having((error) => error.code, 'code', -32603)
            .having((error) => error.message, 'message', 'hover unavailable'),
      ),
    );
    await client.close();
  });

  test(
    'serializes initialized and document writes before later requests',
    () async {
      server.handler = (message) {
        if (message['method'] == 'initialize') {
          server.respond(message['id'], styioLspdCapabilities());
        } else if (message['method'] == 'textDocument/documentSymbol') {
          server.respond(message['id'], <Object?>[]);
        }
      };
      final transport = _WriteGateTransport(server.transport);
      final client = StyioLspClient(transport: transport);
      await client.initialize(rootUri: Uri.parse('file:///workspace'));

      transport.holdNextWrite();
      final initialized = client.sendInitialized();
      final opened = client.didOpen(
        uri: 'file:///workspace/main.styio',
        languageId: 'styio',
        version: 1,
        text: '#main := () => {}\n',
      );
      final symbols = client.documentSymbol(
        uri: 'file:///workspace/main.styio',
      );
      await pump();
      await pump();

      expect(
        server.received.where((message) => message['method'] != 'initialize'),
        isEmpty,
      );
      transport.releaseWrite();
      await Future.wait(<Future<void>>[initialized, opened]);
      expect(await symbols, isEmpty);
      expect(
        server.received
            .where((message) => message['method'] != 'initialize')
            .map((message) => message['method']),
        <Object?>[
          'initialized',
          'textDocument/didOpen',
          'textDocument/documentSymbol',
        ],
      );
      await client.close();
    },
  );

  test('publishDiagnostics notifications stream to the client', () async {
    server.handler = (message) {
      if (message['method'] == 'initialize') {
        server.respond(message['id'], styioLspdCapabilities());
      }
    };
    final client = StyioLspClient(transport: server.transport);
    await client.initialize(rootUri: Uri.parse('file:///workspace'));

    final notification = client.diagnostics.first;
    server.notify('textDocument/publishDiagnostics', <String, Object?>{
      'uri': 'file:///workspace/main.styio',
      'version': 3,
      'diagnostics': <Object?>[
        <String, Object?>{
          'range': <String, Object?>{
            'start': <String, Object?>{'line': 0, 'character': 0},
            'end': <String, Object?>{'line': 0, 'character': 4},
          },
          'severity': 1,
          'code': 'styio.syntax',
          'message': 'bad token',
        },
      ],
    });

    final resolved = await notification;
    expect(resolved.uri, 'file:///workspace/main.styio');
    expect(resolved.version, 3);
    expect(resolved.diagnostics, hasLength(1));
    await client.close();
  });

  test('publishDiagnostics accepts the protocol optional version', () async {
    server.handler = (message) {
      if (message['method'] == 'initialize') {
        server.respond(message['id'], styioLspdCapabilities());
      }
    };
    final client = StyioLspClient(transport: server.transport);
    await client.initialize(rootUri: Uri.parse('file:///workspace'));

    final notification = client.diagnostics.first;
    server.notify('textDocument/publishDiagnostics', <String, Object?>{
      'uri': 'file:///workspace/main.styio',
      'diagnostics': <Object?>[],
    });

    final resolved = await notification;
    expect(resolved.version, isNull);
    await client.close();
  });

  test('decodes a response split across two byte writes', () async {
    server.handler = (message) {
      if (message['method'] == 'initialize') {
        server.respond(message['id'], styioLspdCapabilities());
        return;
      }
      if (message['method'] == 'textDocument/documentSymbol') {
        final bytes = server.codec.encode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <Object?>[
            <String, Object?>{
              'name': 'main',
              'kind': 12,
              'range': <String, Object?>{
                'start': <String, Object?>{'line': 0, 'character': 0},
                'end': <String, Object?>{'line': 0, 'character': 4},
              },
              'selectionRange': <String, Object?>{
                'start': <String, Object?>{'line': 0, 'character': 0},
                'end': <String, Object?>{'line': 0, 'character': 4},
              },
            },
          ],
        });
        final split = bytes.length ~/ 2;
        server.receiveRaw(bytes.sublist(0, split));
        server.receiveRaw(bytes.sublist(split));
      }
    };
    final client = StyioLspClient(transport: server.transport);
    await client.initialize(rootUri: Uri.parse('file:///workspace'));
    await client.sendInitialized();

    final symbols = await client.documentSymbol(
      uri: 'file:///workspace/main.styio',
    );
    expect(symbols, isA<List<Object?>>());
    expect((symbols! as List), hasLength(1));
    await client.close();
  });

  test('cancelRequest emits a \$/cancelRequest notification', () async {
    server.handler = (message) {
      if (message['method'] == 'initialize') {
        server.respond(message['id'], styioLspdCapabilities());
      }
    };
    final client = StyioLspClient(transport: server.transport);
    await client.initialize(rootUri: Uri.parse('file:///workspace'));

    final pending = client.sendCancellableRequest(
      'workspace/symbol',
      <String, Object?>{'query': 'never'},
    );
    final expectation = expectLater(
      pending.result,
      throwsA(isA<StyioLspTransportClosedFailure>()),
    );
    await pump();
    await client.cancelRequest(pending.id);
    await pump();

    final cancellations = server.requestsFor(r'$/cancelRequest');
    expect(cancellations, hasLength(1));
    expect((cancellations.single['params']! as Map)['id'], pending.id);
    await client.close();
    await expectation;
  });

  test('transport close fails pending requests', () async {
    server.handler = (message) {
      if (message['method'] == 'initialize') {
        server.respond(message['id'], styioLspdCapabilities());
      }
    };
    final client = StyioLspClient(transport: server.transport);
    await client.initialize(rootUri: Uri.parse('file:///workspace'));

    final pending = client.sendRequest('workspace/symbol', <String, Object?>{
      'query': 'x',
    });
    final expectation = expectLater(
      pending,
      throwsA(isA<StyioLspTransportClosedFailure>()),
    );
    await server.dispose();

    await expectation;
    await client.close();
  });
}

class _WriteGateTransport implements LspByteTransport {
  _WriteGateTransport(this._delegate);

  final LspMemoryTransport _delegate;
  Completer<void>? _writeGate;
  var _holdNextWrite = false;

  @override
  Stream<List<int>> get input => _delegate.input;

  void holdNextWrite() {
    _writeGate = Completer<void>();
    _holdNextWrite = true;
  }

  void releaseWrite() {
    _writeGate!.complete();
    _writeGate = null;
  }

  @override
  Future<void> write(List<int> bytes) async {
    final gate = _holdNextWrite ? _writeGate : null;
    _holdNextWrite = false;
    if (gate != null) {
      await gate.future;
    }
    await _delegate.write(bytes);
  }

  @override
  Future<void> close() => _delegate.close();
}
