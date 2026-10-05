import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/language/lsp/lsp.dart';
import 'package:vityo_app/src/view_ide/language/service/styio_service_capability.dart';
import 'package:vityo_app/src/view_ide/language/service/styio_service_connector.dart';

import 'support/lsp_test_server.dart';

const _documentPath = '/fixture/main.styio';
const _documentUri = 'file:///fixture/main.styio';

StyioServiceDocument _document({
  String text = 'abc',
  int revision = 1,
  String root = '/fixture',
}) {
  return StyioServiceDocument(
    documentId: 'fixture://lsp',
    text: text,
    revision: revision,
    filePath: _documentPath,
    workingDirectory: root,
  );
}

Map<String, Object?> _diagnostic(String message) => <String, Object?>{
  'range': <String, Object?>{
    'start': <String, Object?>{'line': 0, 'character': 0},
    'end': <String, Object?>{'line': 0, 'character': 3},
  },
  'severity': 1,
  'code': message,
  'message': message,
};

void _installEmptyHandshake(LspTestServer server) {
  server.handler = (message) {
    if (message['method'] == 'initialize') {
      server.respond(message['id'], <String, Object?>{
        'capabilities': <String, Object?>{},
      });
    }
  };
}

LspStyioServiceConnector _connector(
  Future<LspByteTransport> Function(String root) transportFactory, {
  Duration diagnosticsTimeout = const Duration(seconds: 1),
}) {
  return LspStyioServiceConnector(
    executablePath: '/fixture/styio_lspd',
    diagnosticsTimeout: diagnosticsTimeout,
    transportFactory: transportFactory,
  );
}

void main() {
  test('same-root session startup is shared and idempotent', () async {
    final server = LspTestServer();
    final transport = _CountingTransport(server.transport);
    final factoryCalled = Completer<void>();
    final pendingTransport = Completer<LspByteTransport>();
    _installEmptyHandshake(server);
    var factoryCalls = 0;
    final connector = _connector((_) {
      factoryCalls += 1;
      factoryCalled.complete();
      return pendingTransport.future;
    });

    final first = connector.startSession(workingDirectory: '/fixture');
    await factoryCalled.future;
    final second = connector.startSession(workingDirectory: '/fixture');
    expect(factoryCalls, 1);
    expect(connector.isSessionActive, isFalse);

    pendingTransport.complete(transport);
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(server.requestsFor('initialize'), hasLength(1));
    expect(connector.isSessionActive, isTrue);

    await connector.close();
    expect(transport.closeCount, 1);
    await server.dispose();
  });

  test('failed initialization releases its transport exactly once', () async {
    final server = LspTestServer();
    final transport = _CountingTransport(server.transport);
    server.handler = (message) {
      if (message['method'] == 'initialize') {
        server.respondError(message['id'], -32603, 'fixture refusal');
      }
    };
    final connector = _connector((_) async => transport);

    expect(await connector.startSession(workingDirectory: '/fixture'), isFalse);
    expect(transport.closeCount, 1);
    expect(connector.isSessionActive, isFalse);
    expect(connector.status, StyioLspConnectorStatus.failed);

    await connector.close();
    expect(transport.closeCount, 1);
    await server.dispose();
  });

  test(
    'close during transport creation releases the late transport once',
    () async {
      final server = LspTestServer();
      final transport = _CountingTransport(server.transport);
      final factoryCalled = Completer<void>();
      final pendingTransport = Completer<LspByteTransport>();
      final connector = _connector((_) {
        factoryCalled.complete();
        return pendingTransport.future;
      });

      final starting = connector.startSession(workingDirectory: '/fixture');
      await factoryCalled.future;
      await connector.close();
      pendingTransport.complete(transport);

      expect(await starting, isFalse);
      expect(transport.closeCount, 1);
      expect(server.requestsFor('initialize'), isEmpty);
      expect(connector.status, StyioLspConnectorStatus.dormant);
      expect(connector.isSessionActive, isFalse);
      await server.dispose();
    },
  );

  test(
    'close during initialize releases the client-owned transport once',
    () async {
      final server = LspTestServer();
      final transport = _CountingTransport(server.transport);
      final initializeSeen = Completer<void>();
      server.handler = (message) {
        if (message['method'] == 'initialize' && !initializeSeen.isCompleted) {
          initializeSeen.complete();
        }
      };
      final connector = _connector((_) async => transport);

      final starting = connector.startSession(workingDirectory: '/fixture');
      await initializeSeen.future;
      await connector.close();

      expect(await starting, isFalse);
      expect(transport.closeCount, 1);
      expect(connector.status, StyioLspConnectorStatus.dormant);
      expect(connector.isSessionActive, isFalse);
      await server.dispose();
    },
  );

  test('a superseded startup cannot replace the newer root session', () async {
    final oldServer = LspTestServer();
    final newServer = LspTestServer();
    final oldTransport = _CountingTransport(oldServer.transport);
    final newTransport = _CountingTransport(newServer.transport);
    final oldFactoryCalled = Completer<void>();
    final pendingOldTransport = Completer<LspByteTransport>();
    _installEmptyHandshake(newServer);
    final connector = _connector((root) {
      if (root == '/fixture/old') {
        oldFactoryCalled.complete();
        return pendingOldTransport.future;
      }
      return Future<LspByteTransport>.value(newTransport);
    });

    final oldStart = connector.startSession(workingDirectory: '/fixture/old');
    await oldFactoryCalled.future;
    expect(
      await connector.startSession(workingDirectory: '/fixture/new'),
      isTrue,
    );
    expect(connector.isSessionActive, isTrue);
    expect(connector.status, StyioLspConnectorStatus.active);

    pendingOldTransport.complete(oldTransport);
    expect(await oldStart, isFalse);
    expect(oldTransport.closeCount, 1);
    expect(oldServer.requestsFor('initialize'), isEmpty);
    expect(connector.isSessionActive, isTrue);
    expect(connector.capabilities, isNotNull);

    await connector.close();
    expect(newTransport.closeCount, 1);
    await oldServer.dispose();
    await newServer.dispose();
  });

  test(
    'transport completion makes session health inactive and is released',
    () async {
      final server = LspTestServer();
      final transport = _CountingTransport(server.transport);
      _installEmptyHandshake(server);
      final connector = _connector((_) async => transport);

      expect(
        await connector.startSession(workingDirectory: '/fixture'),
        isTrue,
      );
      expect(connector.isSessionActive, isTrue);
      await server.transport.close();
      expect(connector.isSessionActive, isFalse);
      expect(connector.status, StyioLspConnectorStatus.failed);
      expect(connector.capabilities, isNull);

      await connector.close();
      expect(transport.closeCount, 1);
      await server.dispose();
    },
  );

  test(
    'nonmatching explicit diagnostic versions are not promoted to the request',
    () async {
      final server = LspTestServer();
      server.handler = (message) {
        final method = message['method'];
        if (method == 'initialize') {
          server.respond(message['id'], <String, Object?>{
            'capabilities': <String, Object?>{},
          });
        } else if (method == 'textDocument/didOpen') {
          for (final version in <int>[0, 2]) {
            server.notify('textDocument/publishDiagnostics', <String, Object?>{
              'uri': _documentUri,
              'version': version,
              'diagnostics': <Object?>[_diagnostic('stale-revision-$version')],
            });
          }
        }
      };
      final connector = _connector(
        (_) async => server.transport,
        diagnosticsTimeout: Duration.zero,
      );

      final response = await connector.analyzeDocument(_document());

      expect(response.status, StyioServiceStatus.succeeded);
      expect(response.diagnostics, isEmpty);
      expect(
        response.capabilityStates[StyioServiceCapability.diagnostics.wireValue],
        'unavailable',
      );
      expect(connector.isSessionActive, isTrue);
      await connector.close();
      await server.dispose();
    },
  );

  test(
    'versionless diagnostics keep the session healthy but are not fresh',
    () async {
      final server = LspTestServer();
      server.handler = (message) {
        final method = message['method'];
        if (method == 'initialize') {
          server.respond(message['id'], <String, Object?>{
            'capabilities': <String, Object?>{},
          });
        } else if (method == 'textDocument/didOpen') {
          server.notify('textDocument/publishDiagnostics', <String, Object?>{
            'uri': _documentUri,
            'diagnostics': <Object?>[_diagnostic('unversioned')],
          });
        }
      };
      final connector = _connector(
        (_) async => server.transport,
        diagnosticsTimeout: Duration.zero,
      );

      final response = await connector.analyzeDocument(_document());

      expect(response.status, StyioServiceStatus.succeeded);
      expect(response.diagnostics, isEmpty);
      expect(
        response.capabilityStates[StyioServiceCapability.diagnostics.wireValue],
        'unavailable',
      );
      expect(connector.isSessionActive, isTrue);
      await connector.close();
      await server.dispose();
    },
  );

  test(
    'same-document analysis requests serialize and keep diagnostics bound',
    () async {
      final server = LspTestServer();
      final opened = Completer<void>();
      final changed = Completer<void>();
      server.handler = (message) {
        final method = message['method'];
        if (method == 'initialize') {
          server.respond(message['id'], <String, Object?>{
            'capabilities': <String, Object?>{},
          });
        } else if (method == 'textDocument/didOpen') {
          if (!opened.isCompleted) opened.complete();
        } else if (method == 'textDocument/didChange') {
          final params = message['params']! as Map;
          final document = params['textDocument']! as Map;
          final version = document['version'] as int;
          if (!changed.isCompleted) changed.complete();
          server.notify('textDocument/publishDiagnostics', <String, Object?>{
            'uri': _documentUri,
            'version': version,
            'diagnostics': <Object?>[_diagnostic('revision-$version')],
          });
        }
      };
      final connector = _connector((_) async => server.transport);

      final first = connector.analyzeDocument(_document(revision: 1));
      await opened.future;
      final second = connector.analyzeDocument(
        _document(text: 'abcd', revision: 2),
      );
      expect(server.requestsFor('textDocument/didChange'), isEmpty);

      server.notify('textDocument/publishDiagnostics', <String, Object?>{
        'uri': _documentUri,
        'version': 1,
        'diagnostics': <Object?>[_diagnostic('revision-1')],
      });
      final firstResponse = await first;
      await changed.future;
      final secondResponse = await second;

      expect(firstResponse.revision, 1);
      expect(firstResponse.diagnostics.single.code, 'revision-1');
      expect(secondResponse.revision, 2);
      expect(secondResponse.diagnostics.single.code, 'revision-2');
      expect(server.requestsFor('textDocument/didChange'), hasLength(1));
      await connector.close();
      await server.dispose();
    },
  );

  test(
    'diagnostics match the emitted LSP version when source revisions rewind',
    () async {
      final server = LspTestServer();
      server.handler = (message) {
        final method = message['method'];
        if (method == 'initialize') {
          server.respond(message['id'], <String, Object?>{
            'capabilities': <String, Object?>{},
          });
        } else if (method == 'textDocument/didOpen') {
          server.notify('textDocument/publishDiagnostics', <String, Object?>{
            'uri': _documentUri,
            'version': 10,
            'diagnostics': <Object?>[_diagnostic('lsp-version-10')],
          });
        } else if (method == 'textDocument/didChange') {
          final params = message['params']! as Map;
          final document = params['textDocument']! as Map;
          final int emittedVersion = document['version'] as int;
          expect(emittedVersion, 11);
          server.notify('textDocument/publishDiagnostics', <String, Object?>{
            'uri': _documentUri,
            'version': 10,
            'diagnostics': <Object?>[_diagnostic('stale-lsp-version-10')],
          });
          server.notify('textDocument/publishDiagnostics', <String, Object?>{
            'uri': _documentUri,
            'version': emittedVersion,
            'diagnostics': <Object?>[
              _diagnostic('lsp-version-$emittedVersion'),
            ],
          });
        }
      };
      final connector = _connector((_) async => server.transport);

      final first = await connector.analyzeDocument(_document(revision: 10));
      final second = await connector.analyzeDocument(
        _document(text: 'changed', revision: 1),
      );

      expect(first.revision, 10);
      expect(first.diagnostics.single.code, 'lsp-version-10');
      expect(second.revision, 1);
      expect(second.diagnostics.single.code, 'lsp-version-11');
      await connector.close();
      await server.dispose();
    },
  );

  test(
    'timeout never reuses diagnostics from an older document revision',
    () async {
      final server = LspTestServer();
      server.handler = (message) {
        final method = message['method'];
        if (method == 'initialize') {
          server.respond(message['id'], <String, Object?>{
            'capabilities': <String, Object?>{},
          });
        } else if (method == 'textDocument/didOpen') {
          server.notify('textDocument/publishDiagnostics', <String, Object?>{
            'uri': _documentUri,
            'version': 1,
            'diagnostics': <Object?>[_diagnostic('revision-1')],
          });
        } else if (method == 'textDocument/didChange') {
          server.notify('textDocument/publishDiagnostics', <String, Object?>{
            'uri': _documentUri,
            'version': 1,
            'diagnostics': <Object?>[_diagnostic('stale-revision-1')],
          });
        }
      };
      final connector = _connector(
        (_) async => server.transport,
        diagnosticsTimeout: const Duration(milliseconds: 10),
      );

      final first = await connector.analyzeDocument(_document(revision: 1));
      final second = await connector.analyzeDocument(
        _document(text: 'abcd', revision: 2),
      );

      expect(first.diagnostics.single.code, 'revision-1');
      expect(second.status, StyioServiceStatus.succeeded);
      expect(second.diagnostics, isEmpty);
      expect(
        second.capabilityStates[StyioServiceCapability.diagnostics.wireValue],
        'unavailable',
      );
      await connector.close();
      await server.dispose();
    },
  );
}

class _CountingTransport implements LspByteTransport {
  _CountingTransport(this._delegate);

  final LspByteTransport _delegate;
  var closeCount = 0;

  @override
  Stream<List<int>> get input => _delegate.input;

  @override
  Future<void> write(List<int> bytes) => _delegate.write(bytes);

  @override
  Future<void> close() {
    closeCount += 1;
    return _delegate.close();
  }
}
