import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/agent_client/agent_client.dart';
import 'package:vityo_app/src/ide/local_service/vityod_client.dart';
import 'package:vityo_app/src/ide/workbench/agent_collaboration/collaboration_store.dart';
import 'package:vityo_app/src/ide/workbench/agent_collaboration/agent_collaboration_service.dart';
import 'package:vityo_app/src/ide/workspace/workspace_revision_service.dart';
import 'package:vityo_app/src/ide/workspace/workspace_transaction_service.dart';
import 'package:vityo_app/src/presentation/agent_workbench/agent_workbench_surface.dart';
import 'package:vityo_app/src/presentation/agent_workbench/session_view.dart';

void main() {
  testWidgets('session permission card uses supplied option IDs and names', (
    tester,
  ) async {
    final commands = _Commands();
    final revisions = InMemoryWorkspaceRevisionService(
      initialDocuments: const <String, String>{},
    );
    final store = AgentCollaborationStore(
      commands: commands,
      transactions: RevisionedWorkspaceTransactionService(revisions),
      maxTimelineEntriesPerSession: 8,
    );
    await store.apply(_snapshot('permission-session', 'Permission session'));
    await store.addPermission(
      AgentPermissionRequest(
        id: 'permission',
        agentId: 'agent',
        sessionId: 'permission-session',
        toolCallId: 'tool',
        options: const <AgentPermissionOption>[
          AgentPermissionOption(
            optionId: 'allow-first',
            name: 'Allow this operation',
            kind: AgentPermissionOptionKind.allowOnce,
          ),
          AgentPermissionOption(
            optionId: 'allow-second',
            name: 'Allow related operation',
            kind: AgentPermissionOptionKind.allowOnce,
          ),
          AgentPermissionOption(
            optionId: 'allow-always',
            name: 'Always allow',
            kind: AgentPermissionOptionKind.allowAlways,
          ),
          AgentPermissionOption(
            optionId: 'reject-once',
            name: 'Reject once',
            kind: AgentPermissionOptionKind.rejectOnce,
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentSessionView(
            session: store.projection.session('permission-session'),
            commands: commands,
          ),
        ),
      ),
    );

    expect(find.text('Allow this operation'), findsOneWidget);
    expect(find.text('Allow related operation'), findsOneWidget);
    expect(find.text('Always allow'), findsOneWidget);
    expect(find.text('Reject once'), findsOneWidget);
    expect(find.text('Always reject'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('permission-permission-allow-second')),
    );
    await tester.pumpAndSettle();
    expect(commands.resolvedOptionId, 'allow-second');
    await store.close();
  });

  testWidgets(
    'surface cancels stale projection subscriptions on rebind and dispose',
    (tester) async {
      final first = _service('first-agent');
      final second = _service('second-agent');

      await first.store.apply(_snapshot('first-session', 'First session'));
      await second.store.apply(_snapshot('second-session', 'Second session'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AgentWorkbenchSurface(collaboration: first)),
        ),
      );
      expect(find.text('First session'), findsWidgets);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AgentWorkbenchSurface(collaboration: second)),
        ),
      );
      await tester.pump();
      expect(find.text('Second session'), findsWidgets);
      expect(find.text('First session'), findsNothing);

      await first.store.apply(_snapshot('stale-session', 'Stale session'));
      await tester.pump();
      expect(find.text('Stale session'), findsNothing);
      expect(find.text('Second session'), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
      await second.store.apply(_snapshot('post-dispose', 'Disposed session'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await first.close();
        await second.close();
      });
    },
  );
}

final class _Commands implements AgentWorkbenchCommandPort {
  String? resolvedOptionId;

  @override
  Future<void> cancel(String sessionId) async {}

  @override
  Future<void> reconnect(String sessionId) async {}

  @override
  Future<void> resolvePermission({
    required String sessionId,
    required String permissionId,
    required String optionId,
  }) async {
    resolvedOptionId = optionId;
  }

  @override
  Future<void> retry(String sessionId) async {}

  @override
  Future<void> steer(String sessionId, String prompt) async {}
}

AgentCollaborationService _service(String agentId) {
  final revisions = InMemoryWorkspaceRevisionService(
    initialDocuments: const <String, String>{'file': 'text'},
  );
  return AgentCollaborationService(
    registry: AgentClientRegistry(
      descriptors: <String, AgentLaunchDescriptor>{
        agentId: AgentLaunchDescriptor(
          id: agentId,
          executable: 'unused',
          arguments: const <String>[],
          workingDirectory: '.',
        ),
      },
      client: VityodClient(
        transport: MemoryVityodTransport(),
        clientInstanceId: 'surface-$agentId',
      ),
    ),
    transactions: RevisionedWorkspaceTransactionService(revisions),
    workspaceRoot: Uri.directory('/workspace'),
  );
}

AgentSessionSnapshot _snapshot(String sessionId, String title) =>
    AgentSessionSnapshot(
      sessionId: sessionId,
      revision: 1,
      updates: <AgentSessionUpdate>[
        AgentSessionUpdate(
          sessionId: sessionId,
          kind: 'session_state',
          payload: <String, Object?>{
            'id': 'state',
            'title': title,
            'status': 'running',
          },
        ),
      ],
    );
