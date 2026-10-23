import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/language/contract/language_contract.dart';
import 'package:vityo_app/src/view_ide/language/lsp/lsp.dart';
import 'package:vityo_app/src/view_ide/language/service/styio_service_capability.dart';
import 'package:vityo_app/src/view_ide/language/service/styio_service_connector.dart';

import 'support/lsp_test_server.dart';

void main() {
  const mapper = LspStyioServiceResponseMapper();
  const text = 'abc def';
  const uri = 'file:///workspace/main.styio';

  group('LspStyioServiceResponseMapper', () {
    test('maps diagnostics with severity, code and UTF-16 ranges', () {
      final diagnostics = mapper.diagnosticsFrom(<Object?>[
        <String, Object?>{
          'range': <String, Object?>{
            'start': <String, Object?>{'line': 0, 'character': 0},
            'end': <String, Object?>{'line': 0, 'character': 3},
          },
          'severity': 1,
          'code': 'styio.syntax',
          'message': 'bad token',
        },
        <String, Object?>{
          'range': <String, Object?>{
            'start': <String, Object?>{'line': 0, 'character': 4},
            'end': <String, Object?>{'line': 0, 'character': 7},
          },
          'severity': 2,
          'message': 'unused',
        },
      ], text);

      expect(diagnostics, hasLength(2));
      expect(diagnostics.first.severity, DiagnosticSeverity.error);
      expect(diagnostics.first.code, 'styio.syntax');
      expect(diagnostics.first.range.start, 0);
      expect(diagnostics.first.range.end, 3);
      expect(diagnostics[1].severity, DiagnosticSeverity.warning);
    });

    test('maps completion items and resolves textEdit ranges', () {
      final completions = mapper.completionsFrom(<Object?>[
        <String, Object?>{
          'label': 'main',
          'kind': 3,
          'insertText': 'main',
          'detail': 'function',
        },
        <String, Object?>{
          'label': 'snippet',
          'kind': 15,
          'textEdit': <String, Object?>{
            'range': <String, Object?>{
              'start': <String, Object?>{'line': 0, 'character': 0},
              'end': <String, Object?>{'line': 0, 'character': 3},
            },
            'newText': 'snippet',
          },
        },
      ], text);

      expect(completions, hasLength(2));
      expect(completions.first.kind, CompletionItemKind.function);
      expect(completions.first.insertText, 'main');
      expect(completions[1].kind, CompletionItemKind.snippet);
      expect(completions[1].replacementRange?.start, 0);
      expect(completions[1].replacementRange?.end, 3);
    });

    test('maps hover markdown with a fallback range', () {
      final hover = mapper.hoverFrom(
        <String, Object?>{
          'contents': <String, Object?>{'kind': 'markdown', 'value': '**fn**'},
        },
        text,
        fallbackOffset: 2,
      );

      expect(hover, isNotNull);
      expect(hover!.markdown, '**fn**');
      expect(hover.range.start, 2);
      expect(hover.range.end, 2);
    });

    test('decodes semantic tokens against the handshake legend', () {
      final capabilities = StyioLspCapabilities.fromInitializeResult(
        styioLspdCapabilities(),
      );
      final spans = mapper.semanticSpansFrom(
        <String, Object?>{
          'data': <Object?>[0, 0, 3, 12, 0, 0, 4, 3, 8, 0, 0, 0, 3, 17, 0],
        },
        text,
        capabilities,
      );

      expect(spans, hasLength(2));
      expect(spans.first.kind, SemanticKind.function);
      expect(spans.first.range.start, 0);
      expect(spans.first.range.end, 3);
      expect(spans[1].kind, SemanticKind.variable);
      expect(spans[1].range.start, 4);
      expect(spans[1].range.end, 7);
      // The trailing `comment` token has no faithful SemanticKind and is
      // intentionally dropped rather than mislabelled.
    });

    test('maps inlay hints to parameter hints', () {
      final hints = mapper.inlayHintsFrom(<Object?>[
        <String, Object?>{
          'position': <String, Object?>{'line': 0, 'character': 4},
          'label': 'x:',
          'kind': 2,
          'paddingRight': true,
        },
      ], text);

      expect(hints, hasLength(1));
      expect(hints.single.label, 'x:');
      expect(hints.single.kind, InlayHintKind.parameter);
      expect(hints.single.position, 4);
    });

    test('maps document symbols with selection and declaration ranges', () {
      final symbols = mapper.documentSymbolsFrom(<Object?>[
        <String, Object?>{
          'name': 'main',
          'kind': 12,
          'detail': 'function',
          'range': <String, Object?>{
            'start': <String, Object?>{'line': 0, 'character': 0},
            'end': <String, Object?>{'line': 0, 'character': 3},
          },
          'selectionRange': <String, Object?>{
            'start': <String, Object?>{'line': 0, 'character': 0},
            'end': <String, Object?>{'line': 0, 'character': 3},
          },
        },
      ], text);

      expect(symbols, hasLength(1));
      expect(symbols.single.name, 'main');
      expect(symbols.single.kind, SymbolKind.function);
      expect(symbols.single.nameRange.start, 0);
      expect(symbols.single.declarationRange.end, 3);
    });

    test('maps definition locations into definition targets', () {
      final targets = mapper.definitionTargetsFrom(
        <Object?>[
          <String, Object?>{
            'uri': uri,
            'range': <String, Object?>{
              'start': <String, Object?>{'line': 0, 'character': 0},
              'end': <String, Object?>{'line': 0, 'character': 3},
            },
          },
        ],
        text,
        originOffset: 4,
      );

      expect(targets, hasLength(1));
      expect(targets.single.symbol.name, 'abc');
      expect(targets.single.originRange.start, 4);
    });

    test('maps references with a declaration target', () {
      final symbols = mapper.documentSymbolsFrom(<Object?>[
        <String, Object?>{
          'name': 'abc',
          'kind': 12,
          'range': <String, Object?>{
            'start': <String, Object?>{'line': 0, 'character': 0},
            'end': <String, Object?>{'line': 0, 'character': 3},
          },
          'selectionRange': <String, Object?>{
            'start': <String, Object?>{'line': 0, 'character': 0},
            'end': <String, Object?>{'line': 0, 'character': 3},
          },
        },
      ], text);
      final references = mapper.referenceSpansFrom(
        <Object?>[
          <String, Object?>{
            'uri': uri,
            'range': <String, Object?>{
              'start': <String, Object?>{'line': 0, 'character': 0},
              'end': <String, Object?>{'line': 0, 'character': 3},
            },
          },
          <String, Object?>{
            'uri': uri,
            'range': <String, Object?>{
              'start': <String, Object?>{'line': 0, 'character': 4},
              'end': <String, Object?>{'line': 0, 'character': 7},
            },
          },
        ],
        text,
        symbols: symbols,
      );

      expect(references, hasLength(2));
      expect(references.first.isDeclaration, isTrue);
      expect(references.first.kind, SymbolKind.function);
      expect(references.last.isDeclaration, isFalse);
      expect(references.last.targetRange.start, 0);
    });

    test('maps code actions into quick fixes for the request document', () {
      final fixes = mapper.codeActionsFrom(
        <Object?>[
          <String, Object?>{
            'title': 'Close string literal',
            'kind': 'quickfix',
            'edit': <String, Object?>{
              'changes': <String, Object?>{
                uri: <Object?>[
                  <String, Object?>{
                    'range': <String, Object?>{
                      'start': <String, Object?>{'line': 0, 'character': 3},
                      'end': <String, Object?>{'line': 0, 'character': 3},
                    },
                    'newText': '"',
                  },
                ],
                'file:///workspace/other.styio': <Object?>[],
              },
            },
          },
        ],
        uri: uri,
        text: text,
      );

      expect(fixes, hasLength(1));
      expect(fixes.single.label, 'Close string literal');
      expect(fixes.single.edits.single.newText, '"');
      expect(fixes.single.edits.single.range.start, 3);
    });

    test('maps a rename workspace edit into a plan', () {
      final plan = mapper.renamePlanFrom(
        <String, Object?>{
          'changes': <String, Object?>{
            uri: <Object?>[
              <String, Object?>{
                'range': <String, Object?>{
                  'start': <String, Object?>{'line': 0, 'character': 0},
                  'end': <String, Object?>{'line': 0, 'character': 3},
                },
                'newText': 'xyz',
              },
            ],
            'file:///workspace/other.styio': <Object?>[
              <String, Object?>{
                'range': <String, Object?>{
                  'start': <String, Object?>{'line': 0, 'character': 0},
                  'end': <String, Object?>{'line': 0, 'character': 3},
                },
                'newText': 'xyz',
              },
            ],
          },
        },
        uri: uri,
        text: text,
        newName: 'xyz',
        originOffset: 0,
      );

      expect(plan, isNotNull);
      expect(plan!.newName, 'xyz');
      expect(plan.edits.single.newText, 'xyz');
      expect(plan.hasConflicts, isTrue);
      expect(plan.conflicts.single.message, contains('other document'));
    });
  });

  group('LspStyioServiceConnector', () {
    late LspTestServer server;

    setUp(() {
      server = LspTestServer();
    });

    tearDown(() async {
      await server.dispose();
    });

    LspStyioServiceConnector createConnector() {
      return LspStyioServiceConnector(
        executablePath: '/fake/styio_lspd',
        diagnosticsTimeout: const Duration(seconds: 1),
        transportFactory: (String workingDirectory) async => server.transport,
      );
    }

    void installStyioHandler({bool failSymbols = false}) {
      server.handler = (message) {
        final method = message['method'];
        switch (method) {
          case 'initialize':
            server.respond(message['id'], styioLspdCapabilities());
            break;
          case 'initialized':
            break;
          case 'textDocument/didOpen':
          case 'textDocument/didChange':
            final params = message['params']! as Map;
            final document = params['textDocument']! as Map;
            server.notify('textDocument/publishDiagnostics', <String, Object?>{
              'uri': document['uri'],
              'version': document['version'],
              'diagnostics': <Object?>[
                <String, Object?>{
                  'range': <String, Object?>{
                    'start': <String, Object?>{'line': 0, 'character': 0},
                    'end': <String, Object?>{'line': 0, 'character': 3},
                  },
                  'severity': 1,
                  'code': 'styio.syntax',
                  'message': 'bad token',
                },
              ],
            });
            break;
          case 'textDocument/semanticTokens/full':
            server.respond(message['id'], <String, Object?>{
              'data': <Object?>[0, 0, 3, 12, 0, 0, 4, 3, 8, 0],
            });
            break;
          case 'textDocument/documentSymbol':
            if (failSymbols) {
              server.respondError(message['id'], -32603, 'index busy');
            } else {
              server.respond(message['id'], <Object?>[
                <String, Object?>{
                  'name': 'abc',
                  'kind': 12,
                  'range': <String, Object?>{
                    'start': <String, Object?>{'line': 0, 'character': 0},
                    'end': <String, Object?>{'line': 0, 'character': 3},
                  },
                  'selectionRange': <String, Object?>{
                    'start': <String, Object?>{'line': 0, 'character': 0},
                    'end': <String, Object?>{'line': 0, 'character': 3},
                  },
                },
              ]);
            }
            break;
          case 'textDocument/inlayHint':
            server.respond(message['id'], <Object?>[
              <String, Object?>{
                'position': <String, Object?>{'line': 0, 'character': 4},
                'label': 'x:',
                'kind': 2,
              },
            ]);
            break;
          default:
            break;
        }
      };
    }

    StyioServiceDocument document({String text = 'abc def', int revision = 1}) {
      return StyioServiceDocument(
        documentId: 'fixture://lsp',
        text: text,
        revision: revision,
        filePath: '/workspace/main.styio',
        workingDirectory: '/workspace',
      );
    }

    test(
      'analyzeDocument maps document-level LSP facts into a response',
      () async {
        installStyioHandler();
        final connector = createConnector();

        final response = await connector.analyzeDocument(document());

        expect(response.status, StyioServiceStatus.succeeded);
        expect(response.protocolVersion, 'styio-lsp-3.17');
        expect(response.toolchainId, 'local-styio-lsp-daemon');
        expect(response.parserEngine, 'styio-lspd');
        expect(response.diagnostics.single.code, 'styio.syntax');
        expect(response.diagnostics.single.severity, DiagnosticSeverity.error);
        expect(response.semanticSpans, hasLength(2));
        expect(response.documentSymbols.single.name, 'abc');
        expect(response.inlayHints.single.label, 'x:');
        expect(response.formattingEdits, isEmpty);
        expect(
          response.capabilityStates[StyioServiceCapability
              .diagnostics
              .wireValue],
          'available',
        );
        expect(
          response.capabilityStates[StyioServiceCapability
              .formatting
              .wireValue],
          'unavailable',
        );
        expect(
          response.capabilityMessages[StyioServiceCapability
              .formatting
              .wireValue],
          contains('formatting'),
        );
        expect(
          response.capabilityStates[StyioServiceCapability
              .completion
              .wireValue],
          'unavailable',
        );
        expect(server.requestsFor('textDocument/didOpen'), hasLength(1));
        await connector.close();
      },
    );

    test('document changes reuse the session with didChange', () async {
      installStyioHandler();
      final connector = createConnector();

      await connector.analyzeDocument(document());
      await connector.analyzeDocument(document());
      expect(server.requestsFor('textDocument/didChange'), isEmpty);

      await connector.analyzeDocument(document(text: 'abc defg', revision: 2));
      expect(server.requestsFor('textDocument/didChange'), hasLength(1));
      expect(server.requestsFor('initialize'), hasLength(1));
      await connector.close();
    });

    test('a failing optional request degrades only that capability', () async {
      installStyioHandler(failSymbols: true);
      final connector = createConnector();

      final response = await connector.analyzeDocument(document());

      expect(response.status, StyioServiceStatus.succeeded);
      expect(response.documentSymbols, isEmpty);
      expect(
        response.capabilityStates[StyioServiceCapability
            .documentSymbols
            .wireValue],
        'unavailable',
      );
      await connector.close();
    });

    test(
      'analyzeDocument without a file path is honestly unavailable',
      () async {
        installStyioHandler();
        final connector = createConnector();

        final response = await connector.analyzeDocument(
          const StyioServiceDocument(
            documentId: 'fixture://memory',
            text: 'abc',
            revision: 1,
          ),
        );

        expect(response.status, StyioServiceStatus.unavailable);
        expect(response.message, contains('file path'));
        await connector.close();
      },
    );

    test('position-scoped queries use the same session', () async {
      server.handler = (message) {
        switch (message['method']) {
          case 'initialize':
            server.respond(message['id'], styioLspdCapabilities());
            break;
          case 'textDocument/completion':
            server.respond(message['id'], <Object?>[
              <String, Object?>{'label': 'abc', 'kind': 6},
            ]);
            break;
          case 'textDocument/hover':
            server.respond(message['id'], <String, Object?>{
              'contents': <String, Object?>{
                'kind': 'markdown',
                'value': '**abc**',
              },
            });
            break;
          default:
            break;
        }
      };
      final connector = createConnector();

      final completions = await connector.completeAt(document(), 4);
      expect(completions.single.label, 'abc');
      expect(completions.single.kind, CompletionItemKind.variable);

      final hover = await connector.hoverAt(document(), 1);
      expect(hover?.markdown, '**abc**');
      expect(server.requestsFor('textDocument/didOpen'), hasLength(1));
      await connector.close();
    });
  });
}
