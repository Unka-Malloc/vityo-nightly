import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/agent_client/agent_client_models.dart';
import 'package:vityo_app/src/ide/agent_client/agent_client_registry.dart';
import 'package:vityo_app/src/ide/local_service/vityod_client.dart';

/// Out-of-app probe for the Flow Hero agent bridge: same wiring path as
/// agent_bridge.dart, but with console output at every step so failures are
/// diagnosable. Run:
///   flutter test test/flow_hero_agent_attach_test.dart
void main() {
  const bool enabled = bool.fromEnvironment('VITYO_LIVE_AGENT_ACCEPTANCE');
  const String socketPath = String.fromEnvironment('VITYO_ACCEPTANCE_SOCKET');
  const String workspace = String.fromEnvironment('VITYO_ACCEPTANCE_WORKSPACE');
  const String agentExecutable = String.fromEnvironment(
    'VITYO_ACCEPTANCE_AGENT_EXECUTABLE',
  );
  const String providerConfig = String.fromEnvironment(
    'VITYO_ACCEPTANCE_PROVIDER_CONFIG',
  );
  const String sessionDirectory = String.fromEnvironment(
    'VITYO_ACCEPTANCE_SESSION_DIRECTORY',
  );
  test(
    'agent bridge attaches against the live local service',
    () async {
      expect(socketPath, isNotEmpty);
      expect(workspace, isNotEmpty);
      expect(agentExecutable, isNotEmpty);
      expect(providerConfig, isNotEmpty);
      expect(sessionDirectory, isNotEmpty);
      // Direct socket construction: the probe targets the already-running
      // daemon, bypassing the path_provider/plugin and platform-policy gates
      // that only make sense inside the real app process.
      final client = VityodClient(
        transport: SocketVityodTransport(endpointPath: socketPath),
        clientInstanceId: 'probe-${DateTime.now().microsecondsSinceEpoch}',
      );
      await client.connect();
      // ignore: avoid_print
      print('vityodClient: OK (direct socket)');

      final registry = AgentClientRegistry(
        descriptors: <String, AgentLaunchDescriptor>{
          'vityo-coding-agent': AgentLaunchDescriptor(
            id: 'vityo-coding-agent',
            executable: agentExecutable,
            arguments: const <String>[
              '--stdio-agent',
              '--provider-config',
              providerConfig,
              '--session-dir',
              sessionDirectory,
            ],
            workingDirectory: workspace,
          ),
        },
        client: client,
      );

      // ignore: avoid_print
      print('connecting…');
      try {
        await registry.disconnect('vityo-coding-agent');
        // ignore: avoid_print
        print('closed a stale agent connection');
      } catch (_) {
        // ignore: avoid_print
        print('no stale connection to close');
      }
      late final AgentConnectionSnapshot snapshot;
      try {
        snapshot = await registry.connect('vityo-coding-agent');
        // ignore: avoid_print
        expect(snapshot.agentId, 'vityo-coding-agent');

        // session.new needs a workspace projection: open it first, same call the
        // IDE's document store makes. File requests first need an fs scope grant,
        // same call the IDE's file-system manager makes.
        await client.request(
          method: 'fs.scope.open',
          idempotencyKey:
              'probe-fs-scope-${DateTime.now().microsecondsSinceEpoch}',
          params: const <String, Object?>{
            'scopeId': 'probe',
            'rootPath': workspace,
          },
        );
        // ignore: avoid_print
        print('file scope opened');

        const workspaceUri = 'flow-hero-probe';
        await client.request(
          method: 'workspace.open',
          idempotencyKey: 'probe-open-${DateTime.now().microsecondsSinceEpoch}',
          workspaceId: workspaceUri,
          params: const <String, Object?>{'rootPath': workspace},
        );
        // ignore: avoid_print
        print('workspace opened');

        final session = await registry.newSession(
          agentId: 'vityo-coding-agent',
          cwd: Uri.directory(workspace),
        );
        // ignore: avoid_print
        print('agent session established');
        expect(session.id, isNotEmpty);
      } finally {
        await registry.close();
      }
    },
    skip: !enabled
        ? 'Requires an explicitly assigned live acceptance task and configuration.'
        : false,
  );
}
