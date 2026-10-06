import 'package:test/test.dart';
import 'package:vityo_app/src/ide/agent_client/agent_client.dart';
import 'package:vityo_app/src/ide/local_service/vityod_client.dart';

void main() {
  test(
    'permission option preserves ACP identity and supplied presentation',
    () {
      final option = AgentPermissionOption.fromJson(<String, Object?>{
        'optionId': 'opaque-option-id',
        'name': 'Use this tool once',
        'kind': 'allow_once',
      });

      expect(option.optionId, 'opaque-option-id');
      expect(option.name, 'Use this tool once');
      expect(option.kind, AgentPermissionOptionKind.allowOnce);
      expect(
        () => AgentPermissionOption.fromJson(<String, Object?>{
          'optionId': 'unsupported',
          'name': 'Not a standard option',
          'kind': 'allow_temporarily',
        }),
        throwsFormatException,
      );
    },
  );

  test('session reducer keeps one bounded immutable projection', () async {
    final reducer = AgentSessionReducer(
      sessionId: 'session-1',
      maxBufferedUpdates: 2,
      backpressurePolicy: const AgentEventBackpressurePolicy(
        maxQueuedEvents: 3,
        maxQueuedBytes: 1024 * 1024,
        maxHotHistoryEvents: 2,
        maxHotHistoryBytes: 1024 * 1024,
      ),
    );
    for (final text in const <String>['one', 'two', 'three']) {
      await reducer.reduce(
        AgentSessionUpdate(
          sessionId: 'session-1',
          kind: 'chunk',
          text: text,
          payload: const <String, Object?>{},
        ),
      );
    }

    expect(reducer.snapshot.revision, 3);
    expect(reducer.snapshot.updates.map((update) => update.text), <String?>[
      'two',
      'three',
    ]);
    await reducer.close();
  });

  test('registry validates and snapshots daemon gateway policy', () {
    final client = VityodClient(
      transport: MemoryVityodTransport(),
      clientInstanceId: 'agent-contract',
    );
    addTearDown(client.dispose);
    expect(
      () => AgentClientRegistry(
        descriptors: <String, AgentLaunchDescriptor>{'agent': _descriptor()},
        client: client,
        policy: const AgentClientPolicy(allowedExtensions: <String>{'unsafe'}),
      ),
      throwsArgumentError,
    );

    final extensions = <String>{'_vityo.dev/test'};
    final registry = AgentClientRegistry(
      descriptors: <String, AgentLaunchDescriptor>{'agent': _descriptor()},
      client: client,
      policy: AgentClientPolicy(allowedExtensions: extensions),
    );
    addTearDown(registry.close);
    extensions.clear();
    expect(registry.policy.allowedExtensions, <String>{'_vityo.dev/test'});
  });

  test('permission delivery remains a bounded UI projection', () async {
    final permissions = PermissionRequestQueue(maxItems: 1);
    final first = AgentPermissionRequest(
      id: 'permission-1',
      agentId: 'agent',
      sessionId: 'session',
      toolCallId: 'tool-1',
      options: const <AgentPermissionOption>[
        AgentPermissionOption(
          optionId: 'allow-id',
          name: 'Allow once',
          kind: AgentPermissionOptionKind.allowOnce,
        ),
      ],
    );
    expect(permissions.add(first), isTrue);
    expect(
      permissions.add(
        AgentPermissionRequest(
          id: 'permission-2',
          agentId: 'agent',
          sessionId: 'session',
          toolCallId: 'tool-2',
          options: const <AgentPermissionOption>[
            AgentPermissionOption(
              optionId: 'reject-id',
              name: 'Reject',
              kind: AgentPermissionOptionKind.rejectOnce,
            ),
          ],
        ),
      ),
      isFalse,
    );
    expect(await permissions.stream().first, same(first));
    permissions.close();
  });

  test(
    'priority lifecycle update survives saturated projection queue',
    () async {
      final reducer = AgentSessionReducer(
        sessionId: 'session-1',
        maxBufferedUpdates: 1,
        backpressurePolicy: const AgentEventBackpressurePolicy(
          maxQueuedEvents: 1,
          maxQueuedBytes: 1024,
          maxHotHistoryEvents: 1,
          maxHotHistoryBytes: 1024,
        ),
      );
      final ordinary = reducer.reduce(
        const AgentSessionUpdate(
          sessionId: 'session-1',
          kind: 'chunk',
          text: 'ordinary',
          payload: <String, Object?>{},
        ),
      );
      await reducer.reducePriority(
        const AgentSessionUpdate(
          sessionId: 'session-1',
          kind: 'session_state',
          payload: <String, Object?>{'status': 'failed'},
        ),
      );
      await ordinary;

      expect(reducer.snapshot.updates.single.kind, 'session_state');
      await reducer.close();
    },
  );
}

AgentLaunchDescriptor _descriptor() => AgentLaunchDescriptor(
  id: 'agent',
  executable: '/agent',
  arguments: const <String>[],
  workingDirectory: '/workspace',
);
