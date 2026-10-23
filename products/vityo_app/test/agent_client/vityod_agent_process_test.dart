import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/agent_client/agent_client.dart';

import '../support/vityod_test_harness.dart';

void main() {
  test(
    'vityod supervises the packaged Rust Coding Agent ACP handshake',
    () async {
      final daemonExecutable = _findDaemonExecutable();
      final codingAgentExecutable = _findCodingAgentExecutable();
      expect(daemonExecutable.existsSync(), isTrue);
      expect(codingAgentExecutable.existsSync(), isTrue);

      final runtimeDirectory = await Directory.systemTemp.createTemp(
        'vityo-rust-agent-process-',
      );
      addTearDown(() async {
        if (runtimeDirectory.existsSync()) {
          await runtimeDirectory.delete(recursive: true);
        }
      });
      final providerConfig = File(
        '${runtimeDirectory.path}${Platform.pathSeparator}provider.json',
      );
      await providerConfig.writeAsString(
        jsonEncode(<String, Object?>{
          'adapter': 'openai_compatible_chat',
          'endpointBase': 'https://api.example.test/v1',
          'model': 'fixture-model',
          'capabilities': <String, Object?>{
            'contextTokens': 8192,
            'outputTokens': 512,
            'supportsTools': true,
            'maxConcurrency': 1,
          },
          'limits': <String, Object?>{'maxTotalTokens': 9216},
          'auth': <String, Object?>{'mode': 'none'},
        }),
      );
      final sessionDirectory = Directory(
        '${runtimeDirectory.path}${Platform.pathSeparator}sessions',
      );

      final harness = await VityodTestHarness.start(
        clientId: 'agent-supervision-test',
      );
      addTearDown(harness.close);
      final registry = AgentClientRegistry(
        descriptors: <String, AgentLaunchDescriptor>{
          'coding-agent': AgentLaunchDescriptor(
            id: 'coding-agent',
            executable: codingAgentExecutable.path,
            arguments: <String>[
              '--stdio-agent',
              '--provider-config',
              providerConfig.path,
              '--session-dir',
              sessionDirectory.path,
            ],
            workingDirectory: runtimeDirectory.path,
          ),
        },
        client: harness.client,
      );
      addTearDown(() async {
        await registry.close();
      });

      final connection = await registry.connect('coding-agent');

      expect(connection.agentId, 'coding-agent');
      expect(connection.protocolVersion, 1);
      expect(connection.capabilities, contains('loadSession'));
      expect(registry.activeConnectionCount, 1);

      final session = await registry.newSession(
        agentId: 'coding-agent',
        cwd: runtimeDirectory.uri,
      );
      expect(session.id, isNotEmpty);
      expect(session.agentId, 'coding-agent');
    },
    skip: !(Platform.isMacOS || Platform.isLinux)
        ? 'Unix local-service transport only.'
        : false,
  );
}

File _findDaemonExecutable() {
  final app = _findAppDirectory();
  return File('${app.path}/native/vityod/target/debug/vityod');
}

File _findCodingAgentExecutable() {
  final app = _findAppDirectory();
  final executable = Platform.isWindows
      ? 'vityo-coding-agent.exe'
      : 'vityo-coding-agent';
  final targetRoot = '${app.parent.path}${Platform.pathSeparator}'
      'vityo_coding_agent${Platform.pathSeparator}target${Platform.pathSeparator}';
  // Delivery builds the packaged Agent with `--release`, while a local debug
  // build lands in `target/debug`. Accept either so the test runs against
  // whichever build the invoking entrypoint produced instead of depending on a
  // profile it cannot control.
  for (final profile in const <String>['release', 'debug']) {
    final candidate = File('$targetRoot$profile${Platform.pathSeparator}$executable');
    if (candidate.existsSync()) {
      return candidate;
    }
  }
  return File('${targetRoot}release${Platform.pathSeparator}$executable');
}

Directory _findAppDirectory() {
  var directory = Directory.current.absolute;
  for (var depth = 0; depth < 12; depth += 1) {
    if (File('${directory.path}/pubspec.yaml').existsSync() &&
        directory.path.endsWith('vityo_app')) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return Directory.current.absolute;
}
