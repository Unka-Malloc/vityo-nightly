import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/editor/document_state.dart';
import 'package:vityo_app/src/ide/workspace/workspace.dart';
import 'package:vityo_app/src/view_ide/shell_runtime/controllers/source_control_controller.dart';

void main() {
  const conflictText =
      'before\n'
      '<<<<<<< HEAD\n'
      'current\n'
      '||||||| base\n'
      'base\n'
      '=======\n'
      'incoming\n'
      '>>>>>>> feature\n'
      'after\n';

  test('conflict marker resolver keeps context and resolves each strategy', () {
    expect(
      SourceControlConflictMarkerResolver.resolve(
        conflictText,
        SourceControlConflictResolutionKind.acceptCurrent,
      ),
      'before\ncurrent\nafter\n',
    );
    expect(
      SourceControlConflictMarkerResolver.resolve(
        conflictText,
        SourceControlConflictResolutionKind.acceptIncoming,
      ),
      'before\nincoming\nafter\n',
    );
    expect(
      SourceControlConflictMarkerResolver.resolve(
        conflictText,
        SourceControlConflictResolutionKind.acceptBoth,
      ),
      'before\ncurrent\nincoming\nafter\n',
    );
    expect(
      SourceControlConflictMarkerResolver.hasUnresolvedMarkers(conflictText),
      isTrue,
    );
    expect(
      SourceControlConflictMarkerResolver.resolve(
        'plain\n',
        SourceControlConflictResolutionKind.acceptBoth,
      ),
      isNull,
    );
  });

  test('merge snapshot serialization never includes source text', () {
    const snapshot = SourceControlMergeEditorSnapshot(
      providerKind: SourceControlProviderKind.git,
      path: 'src/conflict.styio',
      available: true,
      baseText: 'private base',
      currentText: 'private current',
      incomingText: 'private incoming',
      workingText: conflictText,
      baseAvailable: true,
      currentAvailable: true,
      incomingAvailable: true,
      workingExists: true,
      workingRevision: 7,
    );

    final encoded = snapshot.toJson().toString();

    expect(encoded, isNot(contains('private base')));
    expect(encoded, isNot(contains('private current')));
    expect(encoded, isNot(contains('private incoming')));
    expect(snapshot.toJson()['workingLength'], conflictText.length);
    expect(snapshot.toJson()['hasUnresolvedMarkers'], isTrue);
  });

  test(
    'Git merge provider loads stages, writes result, and stages one path',
    () async {
      final requests = <SourceControlCommandRequest>[];
      final store = InMemoryWorkspaceDocumentStore(
        seededDocuments: const <String, DocumentState>{
          'src/conflict.styio': DocumentState(
            documentId: 'src/conflict.styio',
            text: conflictText,
            revision: 7,
          ),
        },
      );
      final provider = GitSourceControlMergeProvider(
        workspaceRoot: '/workspace/vityo',
        documentStore: store,
        runner: (request) async {
          requests.add(request);
          return switch (request.arguments) {
            ['show', ':1:src/conflict.styio'] =>
              const SourceControlCommandResult(exitCode: 0, stdout: 'base\n'),
            ['show', ':2:src/conflict.styio'] =>
              const SourceControlCommandResult(
                exitCode: 0,
                stdout: 'current\n',
              ),
            ['show', ':3:src/conflict.styio'] =>
              const SourceControlCommandResult(
                exitCode: 0,
                stdout: 'incoming\n',
              ),
            ['add', '--', 'src/conflict.styio'] =>
              const SourceControlCommandResult(exitCode: 0),
            _ => const SourceControlCommandResult(exitCode: 126),
          };
        },
      );
      final workflow = SourceControlMergeWorkflowPlan.fromStatus(
        _conflictedStatus,
      );
      final opened = await provider.openMergeEditor(
        workspaceRoot: '/workspace/vityo',
        path: 'src/conflict.styio',
      );
      final request = SourceControlConflictResolutionRequest.fromPlan(
        workflowPlan: workflow,
        conflictPlan: workflow.conflictPlans.single,
        kind: SourceControlConflictResolutionKind.markResolved,
        resultText: 'resolved\n',
        expectedWorkingRevision: opened.workingRevision,
      );

      final result = await provider.resolve(request);
      final saved = await store.loadDocument('src/conflict.styio');

      expect(opened.available, isTrue);
      expect(opened.baseText, 'base\n');
      expect(opened.currentText, 'current\n');
      expect(opened.incomingText, 'incoming\n');
      expect(opened.workingRevision, 7);
      expect(result.accepted, isTrue);
      expect(saved.text, 'resolved\n');
      expect(saved.revision, 8);
      expect(requests.last.arguments, <String>[
        'add',
        '--',
        'src/conflict.styio',
      ]);
      expect(request.toJson(), isNot(containsPair('resultText', 'resolved\n')));
      expect(request.toJson()['resultTextLength'], 9);
    },
  );

  test(
    'Git merge provider rejects a stale working revision before writing',
    () async {
      var stageCalls = 0;
      final store = InMemoryWorkspaceDocumentStore(
        seededDocuments: const <String, DocumentState>{
          'src/conflict.styio': DocumentState(
            documentId: 'src/conflict.styio',
            text: conflictText,
            revision: 9,
          ),
        },
      );
      final provider = GitSourceControlMergeProvider(
        workspaceRoot: '/workspace/vityo',
        documentStore: store,
        runner: (request) async {
          if (request.arguments.first == 'add') stageCalls += 1;
          return const SourceControlCommandResult(
            exitCode: 0,
            stdout: 'stage\n',
          );
        },
      );
      final workflow = SourceControlMergeWorkflowPlan.fromStatus(
        _conflictedStatus,
      );
      final request = SourceControlConflictResolutionRequest.fromPlan(
        workflowPlan: workflow,
        conflictPlan: workflow.conflictPlans.single,
        kind: SourceControlConflictResolutionKind.markResolved,
        resultText: 'resolved\n',
        expectedWorkingRevision: 8,
      );

      final result = await provider.resolve(request);

      expect(result.accepted, isFalse);
      expect(result.message, contains('changed after the merge editor opened'));
      expect(stageCalls, 0);
      expect(
        (await store.loadDocument('src/conflict.styio')).text,
        conflictText,
      );
    },
  );

  test('Git merge provider applies accept-both per conflict region', () async {
    final store = InMemoryWorkspaceDocumentStore(
      seededDocuments: const <String, DocumentState>{
        'src/conflict.styio': DocumentState(
          documentId: 'src/conflict.styio',
          text: conflictText,
          revision: 4,
        ),
      },
    );
    final provider = GitSourceControlMergeProvider(
      workspaceRoot: '/workspace/vityo',
      documentStore: store,
      runner: (request) async {
        return switch (request.arguments) {
          ['show', ':1:src/conflict.styio'] => const SourceControlCommandResult(
            exitCode: 0,
            stdout: 'base\n',
          ),
          ['show', ':2:src/conflict.styio'] => const SourceControlCommandResult(
            exitCode: 0,
            stdout: 'current\n',
          ),
          ['show', ':3:src/conflict.styio'] => const SourceControlCommandResult(
            exitCode: 0,
            stdout: 'incoming\n',
          ),
          ['add', '--', 'src/conflict.styio'] =>
            const SourceControlCommandResult(exitCode: 0),
          _ => const SourceControlCommandResult(exitCode: 126),
        };
      },
    );
    final workflow = SourceControlMergeWorkflowPlan.fromStatus(
      _conflictedStatus,
    );
    final request = SourceControlConflictResolutionRequest.fromPlan(
      workflowPlan: workflow,
      conflictPlan: workflow.conflictPlans.single,
      kind: SourceControlConflictResolutionKind.acceptBoth,
      expectedWorkingRevision: 4,
    );

    final result = await provider.resolve(request);

    expect(result.accepted, isTrue);
    expect(
      (await store.loadDocument('src/conflict.styio')).text,
      'before\ncurrent\nincoming\nafter\n',
    );
  });

  test(
    'status controller closes merge editor after accepted resolution',
    () async {
      var conflicted = true;
      final statusProvider = _MutableConflictStatusProvider(
        snapshot: () => conflicted ? _conflictedStatus : _resolvedStatus,
      );
      final store = InMemoryWorkspaceDocumentStore(
        seededDocuments: const <String, DocumentState>{
          'src/conflict.styio': DocumentState(
            documentId: 'src/conflict.styio',
            text: conflictText,
            revision: 2,
          ),
        },
      );
      late final GitSourceControlMergeProvider mergeProvider;
      mergeProvider = GitSourceControlMergeProvider(
        workspaceRoot: '/workspace/vityo',
        documentStore: store,
        runner: (request) async {
          if (request.arguments.first == 'add') conflicted = false;
          return const SourceControlCommandResult(
            exitCode: 0,
            stdout: 'stage\n',
          );
        },
      );
      final controller = SourceControlStatusController(
        provider: statusProvider,
        workspaceRoot: '/workspace/vityo',
        mergeEditorProvider: mergeProvider,
        conflictResolutionProviderRegistry:
            SourceControlConflictResolutionProviderRegistry(
              providers: <SourceControlConflictResolutionProvider>[
                mergeProvider,
              ],
            ),
      );
      addTearDown(controller.dispose);

      await controller.refresh();
      final conflictPlan = controller.mergeWorkflowPlan.conflictPlans.single;
      final editor = await controller.openMergeEditor(conflictPlan);
      final result = await controller.resolveConflict(
        conflictPlan: conflictPlan,
        kind: SourceControlConflictResolutionKind.markResolved,
        resultText: 'resolved\n',
        expectedWorkingRevision: editor.workingRevision,
      );

      expect(result.accepted, isTrue);
      expect(controller.mergeWorkflowPlan.conflictCount, 0);
      expect(controller.mergeEditorSnapshot, isNull);
      expect(controller.lastConflictResolutionResult, same(result));
    },
  );

  test('shell blocks merge writes over an unsaved editor buffer', () async {
    var stageCalls = 0;
    final store = InMemoryWorkspaceDocumentStore(
      seededDocuments: const <String, DocumentState>{
        'src/conflict.styio': DocumentState(
          documentId: 'src/conflict.styio',
          text: conflictText,
          revision: 3,
        ),
      },
    );
    final mergeProvider = GitSourceControlMergeProvider(
      workspaceRoot: '/workspace/vityo',
      documentStore: store,
      runner: (request) async {
        if (request.arguments.first == 'add') stageCalls += 1;
        return const SourceControlCommandResult(exitCode: 0, stdout: 'stage\n');
      },
    );
    final statusController = SourceControlStatusController(
      provider: const StaticSourceControlStatusProvider(_conflictedStatus),
      workspaceRoot: '/workspace/vityo',
      mergeEditorProvider: mergeProvider,
      conflictResolutionProviderRegistry:
          SourceControlConflictResolutionProviderRegistry(
            providers: <SourceControlConflictResolutionProvider>[mergeProvider],
          ),
    );
    final shellController = SourceControlController(
      statusController: statusController,
      workspaceId: () => '/workspace/vityo',
      dirtyDocumentPaths: () => <String>['src/conflict.styio'],
      log: (_) {},
    );
    addTearDown(statusController.dispose);
    addTearDown(shellController.dispose);
    await statusController.refresh();

    final result = await shellController.resolveConflict(
      plan: statusController.mergeWorkflowPlan.conflictPlans.single,
      kind: SourceControlConflictResolutionKind.markResolved,
      resultText: 'resolved\n',
      expectedWorkingRevision: 3,
    );

    expect(result.accepted, isFalse);
    expect(result.message, contains('unsaved editor buffer'));
    expect(result.metadata['reason'], 'dirty-editor-buffer');
    expect(stageCalls, 0);
    expect((await store.loadDocument('src/conflict.styio')).text, conflictText);
  });
}

const _conflictedStatus = SourceControlStatusSnapshot(
  providerKind: SourceControlProviderKind.git,
  branchName: 'current',
  changes: <SourceControlFileChange>[
    SourceControlFileChange(
      path: 'src/conflict.styio',
      unstagedStatus: SourceControlFileStatus.conflicted,
    ),
  ],
);

const _resolvedStatus = SourceControlStatusSnapshot(
  providerKind: SourceControlProviderKind.git,
  branchName: 'current',
  changes: <SourceControlFileChange>[
    SourceControlFileChange(
      path: 'src/conflict.styio',
      stagedStatus: SourceControlFileStatus.modified,
    ),
  ],
);

class _MutableConflictStatusProvider extends SourceControlStatusProvider {
  const _MutableConflictStatusProvider({required this.snapshot});

  final SourceControlStatusSnapshot Function() snapshot;

  @override
  SourceControlProviderKind get providerKind => SourceControlProviderKind.git;

  @override
  Future<SourceControlStatusSnapshot> status({
    required String workspaceRoot,
  }) async {
    return snapshot();
  }
}
