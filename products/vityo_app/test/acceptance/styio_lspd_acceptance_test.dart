import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/local_service/vityod_lsp_gateway.dart';
import 'package:vityo_app/src/view_ide/language/lsp/lsp.dart';
import 'package:vityo_app/src/view_ide/language/service/styio_service_connector.dart';

import '../support/vityod_test_harness.dart';

/// End-to-end acceptance against a real `styio_lspd`.
///
/// Skips when no daemon binary is installed. Discover it through
/// `VITYO_STYIO_LSPD_BIN` or one of the standard bin directories.
void main() {
  final binaryPath = _findStyioLspd();

  test(
    'real styio_lspd completes a handshake and answers document requests',
    () async {
      final binary = binaryPath!;
      final workspace = await Directory.systemTemp.createTemp(
        'vityo_lspd_acceptance_',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final sourcePath = '${workspace.path}/main.styio';
      await File(sourcePath).writeAsString('#main := () => {}\n');

      final transport = await startProcessLspTransport(
        executable: binary,
        workingDirectory: workspace.path,
      );
      final client = StyioLspClient(transport: transport);
      addTearDown(client.close);

      final capabilities = await client.initialize(
        rootUri: Uri.directory(workspace.path),
        rootPath: workspace.path,
      );
      expect(capabilities.documentSymbolProvider, isTrue);
      expect(capabilities.semanticTokensProvider, isTrue);
      expect(capabilities.semanticTokenTypes, isNotEmpty);
      // The daemon does not implement formatting; the client must not invent it.
      expect(capabilities.formattingProvider, isFalse);

      await client.sendInitialized();
      final diagnostics = client.diagnostics.first;
      client.didOpen(
        uri: Uri.file(sourcePath).toString(),
        languageId: 'styio',
        version: 1,
        text: await File(sourcePath).readAsString(),
      );

      final published = await diagnostics.timeout(const Duration(seconds: 10));
      expect(published.uri, Uri.file(sourcePath).toString());

      final symbols = await client.documentSymbol(
        uri: Uri.file(sourcePath).toString(),
      );
      expect(symbols, isA<List<Object?>>());

      final tokens = await client.semanticTokensFull(
        uri: Uri.file(sourcePath).toString(),
      );
      expect(tokens, isA<Map>());
      expect((tokens! as Map)['data'], isA<List<Object?>>());

      final hints = await client.inlayHint(
        uri: Uri.file(sourcePath).toString(),
        range: const LspRange(
          start: LspPosition(line: 0, character: 0),
          end: LspPosition(line: 0, character: 0),
        ),
      );
      expect(hints, isA<List<Object?>>());
    },
    skip: binaryPath == null
        ? 'styio_lspd is not installed on this machine.'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'the LSP StyioService connector analyzes a document through styio_lspd',
    () async {
      final binary = binaryPath!;
      final workspace = await Directory.systemTemp.createTemp(
        'vityo_lspd_connector_acceptance_',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final sourcePath = '${workspace.path}/main.styio';
      const source = '#main := () => {}\n';
      await File(sourcePath).writeAsString(source);

      final connector = LspStyioServiceConnector(
        executablePath: binary,
        transportFactory: (String workingDirectory) => startProcessLspTransport(
          executable: binary,
          workingDirectory: workingDirectory,
        ),
      );
      addTearDown(connector.close);

      final response = await connector.analyzeDocument(
        StyioServiceDocument(
          documentId: 'acceptance://lspd',
          text: source,
          revision: 1,
          filePath: sourcePath,
          workingDirectory: workspace.path,
        ),
      );

      expect(response.status, StyioServiceStatus.succeeded);
      expect(response.protocolVersion, 'styio-lsp-3.17');
      expect(response.toolchainId, 'local-styio-lsp-daemon');
      // Handshake-driven capability truth: formatting stays unavailable.
      expect(response.capabilityStates['formatting'], 'unavailable');
      expect(response.formattingEdits, isEmpty);
      expect(connector.capabilities?.semanticTokensProvider, isTrue);
    },
    skip: binaryPath == null
        ? 'styio_lspd is not installed on this machine.'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'the vityod-backed transport drives a styio_lspd session',
    () async {
      final binary = binaryPath!;
      final workspace = await Directory.systemTemp.createTemp(
        'vityo_lspd_vityod_acceptance_',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final sourcePath = '${workspace.path}/main.styio';
      const source = '#main := () => {}\n';
      await File(sourcePath).writeAsString(source);

      final harness = await VityodTestHarness.start(clientId: 'lspd-vityod');
      addTearDown(harness.close);
      final session = await VityodLspGateway(
        client: harness.client,
      ).start(executable: binary, workingDirectory: workspace.path);
      final client = StyioLspClient(
        transport: VityodLspTransport(session: session),
      );
      addTearDown(client.close);

      final capabilities = await client.initialize(
        rootUri: Uri.directory(workspace.path),
        rootPath: workspace.path,
      );
      expect(capabilities.documentSymbolProvider, isTrue);
      await client.sendInitialized();

      final diagnostics = client.diagnostics.first;
      client.didOpen(
        uri: Uri.file(sourcePath).toString(),
        languageId: 'styio',
        version: 1,
        text: source,
      );
      final published = await diagnostics.timeout(const Duration(seconds: 15));
      expect(published.uri, Uri.file(sourcePath).toString());
    },
    skip: binaryPath == null
        ? 'styio_lspd is not installed on this machine.'
        : (!VityodTestHarness.isSupported
              ? 'The vityod test harness is unsupported on this platform.'
              : false),
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

String? _findStyioLspd() {
  final override = Platform.environment['VITYO_STYIO_LSPD_BIN'];
  final candidates = <String>[
    if (override != null && override.isNotEmpty) override,
    '/usr/local/bin/styio_lspd',
    '/usr/bin/styio_lspd',
    '/opt/homebrew/bin/styio_lspd',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return null;
}
