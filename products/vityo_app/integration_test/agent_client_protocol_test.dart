import 'dart:io';

import 'package:vityo_app/src/ide/agent_client/agent_client.dart';

import '../test/support/vityod_test_harness.dart';

Future<void> main() async {
  if (!VityodTestHarness.isSupported) return;
  final fixture = File.fromUri(
    Platform.script.resolve(
      '../../../tests/acceptance/fixtures/vityo_app/agent_client/'
      'fake_agent.dart',
    ),
  );
  final harness = await VityodTestHarness.start(
    clientId: 'agent-protocol-integration',
  );
  final registry = AgentClientRegistry(
    descriptors: <String, AgentLaunchDescriptor>{
      'fixture': AgentLaunchDescriptor(
        id: 'fixture',
        executable: Platform.resolvedExecutable,
        arguments: <String>['run', fixture.path, 'normal'],
        workingDirectory: Directory.current.path,
      ),
    },
    client: harness.client,
    policy: const AgentClientPolicy(
      // Opening a connection includes spawning the Dart VM fixture, so the
      // handshake gets the production request budget instead of a tight one.
      requestTimeout: Duration(seconds: 30),
      allowedExtensions: <String>{
        '_vityo.dev/test/write',
        '_vityo.dev/test/status',
      },
    ),
  );
  try {
    final connection = await registry.connect('fixture');
    if (connection.protocolVersion != 1 ||
        registry.activeConnectionCount != 1 ||
        connection.metadata.isNotEmpty) {
      throw StateError('daemon-owned ACP negotiation was not retained');
    }
    final session = await registry.newSession(
      agentId: 'fixture',
      cwd: Directory.current.uri,
    );
    final prompt = session.prompt('integration');
    final permission = await registry.permissionRequests.first.timeout(
      const Duration(seconds: 3),
    );
    final allowOnceOptions = permission.options
        .where((option) => option.kind == AgentPermissionOptionKind.allowOnce)
        .toList(growable: false);
    if (allowOnceOptions.length != 2 ||
        allowOnceOptions[0].optionId == allowOnceOptions[1].optionId ||
        !permission.options.any(
          (option) => option.kind == AgentPermissionOptionKind.allowAlways,
        ) ||
        !permission.options.any(
          (option) => option.kind == AgentPermissionOptionKind.rejectAlways,
        )) {
      throw StateError('offered permission options were not preserved');
    }
    final selectedOption = allowOnceOptions[1];
    await registry.resolvePermission(permission.id, selectedOption.optionId);
    if ((await prompt).stopReason != 'end_turn' ||
        !session.snapshot.updates.any(
          (update) => update.text == 'approved:integration',
        )) {
      throw StateError('daemon-owned prompt correlation did not complete');
    }
  } finally {
    await registry.close();
    await harness.close();
  }
}
