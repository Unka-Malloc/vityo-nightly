import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/project_graph_contract.dart';
import 'package:vityo_app/src/ide/editor/document_state.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';
import 'package:vityo_app/src/ide/workspace/workspace.dart';

void main() {
  test('workspace file explorer builds stable directory tree', () {
    final tree = buildWorkspaceFileExplorerTree(const <String>[
      'README.md',
      'src/main.styio',
      'src/lib/math.styio',
      'test/parser_test.styio',
    ]);

    expect(tree.map((node) => node.name), <String>['src', 'test', 'README.md']);
    expect(tree.first.kind, WorkspaceFileExplorerNodeKind.directory);
    expect(tree.first.fileCount, 2);
    expect(tree.first.children.map((node) => node.path), <String>[
      'src/lib',
      'src/main.styio',
    ]);
    expect(tree.first.toJson()['fileCount'], 2);
  });

  test(
    'workspace file explorer preserves canonical paths while hiding root',
    () {
      final tree = buildWorkspaceFileExplorerTree(const <String>[
        '/workspace/fixture/README.md',
        '/workspace/fixture/src/main.styio',
      ]);
      final alphabetical = buildWorkspaceFileExplorerTree(const <String>[
        '/workspace/fixture/README.md',
        '/workspace/fixture/src/main.styio',
      ], sortMode: WorkspaceFileExplorerSortMode.alphabetical);

      expect(tree.map((node) => node.name), <String>['src', 'README.md']);
      expect(tree.first.path, '/workspace/fixture/src');
      expect(
        tree.first.children.single.path,
        '/workspace/fixture/src/main.styio',
      );
      expect(alphabetical.map((node) => node.name), <String>[
        'README.md',
        'src',
      ]);
    },
  );

  test('workspace file explorer discovery normalizes file system paths', () {
    final discovery = WorkspaceFileExplorerDiscoveryResult.fromPaths(
      seedPaths: const <String>['README.md'],
      discoveredPaths: const <String>[
        'src\\main.styio',
        'src/main.styio',
        'src/lib/math.styio',
        'src/version..styio',
        '../secret.styio',
        '/tmp/outside.styio',
        r'C:\outside\secret.styio',
        '',
      ],
      source: 'fixture-fs',
    );
    final workspaceController = WorkspaceController(
      projectSnapshot: _projectGraph(editorFiles: const <String>['README.md']),
    );
    final controller = WorkspaceFileExplorerController(
      workspaceController: workspaceController,
      operationService: WorkspaceFileOperationService(
        workspaceController: workspaceController,
        documentStore: InMemoryWorkspaceDocumentStore(),
      ),
    );
    addTearDown(controller.dispose);

    final snapshot = controller.snapshotFromDiscovery(discovery);

    expect(discovery.source, 'fixture-fs');
    expect(discovery.filePaths, <String>[
      'README.md',
      'src/lib/math.styio',
      'src/main.styio',
      'src/version..styio',
    ]);
    expect(discovery.ignoredPathCount, 4);
    expect(discovery.truncated, isFalse);
    expect(snapshot.fileCount, 4);
    expect(snapshot.discovery, same(discovery));
    expect(snapshot.roots.map((node) => node.name), <String>[
      'src',
      'README.md',
    ]);
    expect(snapshot.toJson()['discovery'], isA<Map<String, Object?>>());
  });

  test('discovery truncation counts only unique valid paths', () {
    final exact = WorkspaceFileExplorerDiscoveryResult.fromPaths(
      discoveredPaths: const <String>['src/main.styio', 'src/main.styio'],
      maxFiles: 1,
    );
    final overflow = WorkspaceFileExplorerDiscoveryResult.fromPaths(
      discoveredPaths: const <String>[
        'src/main.styio',
        '../outside.styio',
        'src/worker.styio',
      ],
      maxFiles: 1,
    );

    expect(exact.filePaths, <String>['src/main.styio']);
    expect(exact.truncated, isFalse);
    expect(overflow.filePaths, <String>['src/main.styio']);
    expect(overflow.ignoredPaths, <String>['../outside.styio']);
    expect(overflow.truncated, isTrue);
  });

  test(
    'file system discovery lists recursively and filters generated roots',
    () async {
      final manager = _FakeWorkspaceFileExplorerFileSystemManager(
        const Stream<FileSystemManagerEvent>.empty(),
        entries: const <FileSystemEntitySnapshot>[
          FileSystemEntitySnapshot(
            path: '/workspace/fixture/src/main.styio',
            normalizedPath: '/workspace/fixture/src/main.styio',
            type: VityoFileSystemEntityType.file,
          ),
          FileSystemEntitySnapshot(
            path: '/workspace/fixture/.git/config',
            normalizedPath: '/workspace/fixture/.git/config',
            type: VityoFileSystemEntityType.file,
          ),
          FileSystemEntitySnapshot(
            path: '/workspace/fixture/build/cache.bin',
            normalizedPath: '/workspace/fixture/build/cache.bin',
            type: VityoFileSystemEntityType.file,
          ),
          FileSystemEntitySnapshot(
            path: '/workspace/fixture/src',
            normalizedPath: '/workspace/fixture/src',
            type: VityoFileSystemEntityType.directory,
          ),
        ],
      );

      final discovery = await WorkspaceFileExplorerFileSystemDiscoveryBinding(
        fileSystemManager: manager,
        rootPath: '/workspace/fixture',
        seedPaths: const <String>['/workspace/fixture/README.md'],
      ).discover();

      expect(manager.listedPath, '/workspace/fixture');
      expect(manager.listedRecursive, isTrue);
      expect(discovery.filePaths, <String>['README.md', 'src/main.styio']);
      expect(discovery.ignoredPaths, <String>[
        '.git/config',
        'build/cache.bin',
      ]);
    },
  );

  test('controller refresh keeps absolute project paths canonical', () async {
    const mainPath = '/workspace/fixture/src/main.styio';
    final events = StreamController<FileSystemManagerEvent>();
    final manager = _FakeWorkspaceFileExplorerFileSystemManager(
      events.stream,
      entries: const <FileSystemEntitySnapshot>[
        FileSystemEntitySnapshot(
          path: mainPath,
          normalizedPath: mainPath,
          type: VityoFileSystemEntityType.file,
        ),
        FileSystemEntitySnapshot(
          path: '/workspace/fixture/src/worker.styio',
          normalizedPath: '/workspace/fixture/src/worker.styio',
          type: VityoFileSystemEntityType.file,
        ),
      ],
    );
    final workspaceController = WorkspaceController(
      projectSnapshot: _projectGraph(editorFiles: const <String>[mainPath]),
    );
    final controller = WorkspaceFileExplorerController(
      workspaceController: workspaceController,
      operationService: WorkspaceFileOperationService(
        workspaceController: workspaceController,
        documentStore: InMemoryWorkspaceDocumentStore(),
      ),
      fileSystemManager: manager,
    );
    addTearDown(controller.dispose);
    addTearDown(events.close);

    final discovery = await controller.refreshFileSystem(
      rootPath: '/workspace/fixture',
    );
    await Future<void>.delayed(Duration.zero);

    expect(discovery?.filePaths, <String>[
      mainPath,
      '/workspace/fixture/src/worker.styio',
    ]);
    expect(workspaceController.files, <String>[mainPath]);
    expect(controller.snapshot.roots.map((node) => node.name), <String>[
      'main.styio',
      'worker.styio',
    ]);
    expect(
      workspaceController.files.where((path) => path == 'src/worker.styio'),
      isEmpty,
    );

    final registeredPath = controller.registerObservedWorkspacePath(
      '/workspace/fixture/src/worker.styio',
    );

    expect(registeredPath, '/workspace/fixture/src/worker.styio');
    expect(workspaceController.files, <String>[
      mainPath,
      '/workspace/fixture/src/worker.styio',
    ]);
    expect(
      controller.registerObservedWorkspacePath('/tmp/outside.styio'),
      isNull,
    );
  });

  test('workspace file explorer watch snapshot applies file system events', () {
    final plan = const WorkspaceFileExplorerWatchPlan(
      rootPath: '/workspace/fixture',
    ).activate(message: 'watcher attached');
    final watch = WorkspaceFileExplorerWatchSnapshot(
      plan: plan,
      baseFilePaths: const <String>[
        'README.md',
        'build/generated.styio',
        'src/old.styio',
        'src/stale.styio',
      ],
      events: <WorkspaceFileExplorerWatchEvent>[
        WorkspaceFileExplorerWatchEvent(
          kind: WorkspaceFileExplorerWatchEventKind.created,
          path: 'src/new.styio',
          timestamp: DateTime.utc(2026, 5, 20, 12),
        ),
        WorkspaceFileExplorerWatchEvent(
          kind: WorkspaceFileExplorerWatchEventKind.renamed,
          path: 'src/old.styio',
          nextPath: 'src/current.styio',
          timestamp: DateTime.utc(2026, 5, 20, 12, 1),
        ),
        WorkspaceFileExplorerWatchEvent(
          kind: WorkspaceFileExplorerWatchEventKind.deleted,
          path: 'src/stale.styio',
          timestamp: DateTime.utc(2026, 5, 20, 12, 2),
        ),
        WorkspaceFileExplorerWatchEvent(
          kind: WorkspaceFileExplorerWatchEventKind.created,
          path: '../outside.styio',
          timestamp: DateTime.utc(2026, 5, 20, 12, 3),
        ),
        WorkspaceFileExplorerWatchEvent(
          kind: WorkspaceFileExplorerWatchEventKind.created,
          path: '.git/config',
          timestamp: DateTime.utc(2026, 5, 20, 12, 4),
        ),
      ],
    );
    final workspaceController = WorkspaceController(
      projectSnapshot: _projectGraph(editorFiles: const <String>['README.md']),
    );
    final controller = WorkspaceFileExplorerController(
      workspaceController: workspaceController,
      operationService: WorkspaceFileOperationService(
        workspaceController: workspaceController,
        documentStore: InMemoryWorkspaceDocumentStore(),
      ),
    );
    addTearDown(controller.dispose);

    final snapshot = controller.snapshotFromWatch(watch);

    expect(plan.active, isTrue);
    expect(watch.filePaths, <String>[
      'README.md',
      'src/current.styio',
      'src/new.styio',
    ]);
    expect(watch.toJson()['eventCount'], 5);
    expect(watch.toDiscoveryResult().source, 'file-system-manager.watch');
    expect(snapshot.watch, same(watch));
    expect(snapshot.discovery?.fileCount, 3);
    expect(snapshot.fileCount, 3);
    expect(snapshot.toJson()['watch'], isA<Map<String, Object?>>());
  });

  test('workspace file explorer watcher debounce batches events', () {
    const policy = WorkspaceFileExplorerWatchDebouncePolicy(
      window: Duration(milliseconds: 100),
      maxBatchEvents: 3,
    );
    final batcher = WorkspaceFileExplorerWatchEventBatcher(policy: policy);

    final first = batcher.add(
      WorkspaceFileExplorerWatchEvent(
        kind: WorkspaceFileExplorerWatchEventKind.created,
        path: 'src/a.styio',
        timestamp: DateTime.utc(2026, 5, 20, 14),
      ),
    );
    final second = batcher.add(
      WorkspaceFileExplorerWatchEvent(
        kind: WorkspaceFileExplorerWatchEventKind.modified,
        path: 'src/a.styio',
        timestamp: DateTime.utc(2026, 5, 20, 14, 0, 0, 50),
      ),
    );
    final third = batcher.add(
      WorkspaceFileExplorerWatchEvent(
        kind: WorkspaceFileExplorerWatchEventKind.created,
        path: 'src/b.styio',
        timestamp: DateTime.utc(2026, 5, 20, 14, 0, 0, 90),
      ),
    );

    expect(first, isNull);
    expect(second, isNull);
    expect(third?.eventCount, 3);
    expect(batcher.pendingEventCount, 0);
    expect(policy.toJson()['maxBatchEvents'], 3);
    expect(third?.toJson()['eventCount'], 3);
  });

  test(
    'workspace file explorer watcher stream batcher flushes by timer',
    () async {
      final events = StreamController<WorkspaceFileExplorerWatchEvent>();
      final batches = <WorkspaceFileExplorerWatchEventBatch>[];
      final subscription = const WorkspaceFileExplorerWatchStreamBatcher(
        policy: WorkspaceFileExplorerWatchDebouncePolicy(
          window: Duration(milliseconds: 5),
          maxBatchEvents: 10,
        ),
      ).bind(events.stream).listen(batches.add);
      addTearDown(subscription.cancel);
      addTearDown(events.close);

      events
        ..add(
          WorkspaceFileExplorerWatchEvent(
            kind: WorkspaceFileExplorerWatchEventKind.created,
            path: 'src/a.styio',
            timestamp: DateTime.utc(2026, 5, 20, 14),
          ),
        )
        ..add(
          WorkspaceFileExplorerWatchEvent(
            kind: WorkspaceFileExplorerWatchEventKind.modified,
            path: 'src/b.styio',
            timestamp: DateTime.utc(2026, 5, 20, 14, 0, 0, 1),
          ),
        );
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(batches, hasLength(1));
      expect(batches.single.eventCount, 2);
      expect(batches.single.events.map((event) => event.path), <String>[
        'src/a.styio',
        'src/b.styio',
      ]);
      expect(batches.single.toJson()['eventCount'], 2);
    },
  );

  test(
    'workspace file explorer watcher binding consumes file system manager events',
    () async {
      final events = StreamController<FileSystemManagerEvent>();
      final fileSystemManager = _FakeWorkspaceFileExplorerFileSystemManager(
        events.stream,
      );
      final binding = WorkspaceFileExplorerFileSystemWatcherBinding(
        fileSystemManager: fileSystemManager,
        plan: const WorkspaceFileExplorerWatchPlan(
          rootPath: '/workspace/fixture',
        ),
        baseFilePaths: const <String>['README.md'],
        clock: () => DateTime.utc(2026, 5, 20, 13),
      );
      final snapshots = <WorkspaceFileExplorerWatchSnapshot>[];
      final completed = Completer<void>();
      final subscription = binding.watch().listen(
        snapshots.add,
        onDone: completed.complete,
      );
      addTearDown(subscription.cancel);
      addTearDown(events.close);

      await Future<void>.delayed(Duration.zero);
      events.add(
        const FileSystemManagerEvent(
          kind: FileSystemManagerEventKind.created,
          path: '/workspace/fixture/src/new.styio',
          normalizedPath: '/workspace/fixture/src/new.styio',
        ),
      );
      events.add(
        const FileSystemManagerEvent(
          kind: FileSystemManagerEventKind.deleted,
          path: '/workspace/fixture/README.md',
          normalizedPath: '/workspace/fixture/README.md',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await events.close();
      await completed.future;

      expect(fileSystemManager.watchedPath, '/workspace/fixture');
      expect(fileSystemManager.watchedRecursive, isTrue);
      expect(snapshots.first.plan.active, isTrue);
      expect(snapshots.last.filePaths, <String>['src/new.styio']);
      expect(snapshots.last.eventCount, 2);
      expect(snapshots.last.telemetry.totalEventCount, 2);
      expect(snapshots.last.telemetry.batchCount, 1);
      expect(snapshots.last.telemetry.maxBatchEventCount, 2);
      expect(
        snapshots.last.telemetry.toJson()['historyMode'],
        'checkpointed-latest-batch',
      );
      expect(snapshots.last.events.map((event) => event.source).toSet(), {
        'file-system-manager.watch',
      });
      expect(snapshots.last.toDiscoveryResult().filePaths, <String>[
        'src/new.styio',
      ]);
    },
  );

  test('watch stream propagates consumer backpressure', () async {
    final events = StreamController<WorkspaceFileExplorerWatchEvent>();
    final backpressure = <bool>[];
    final batches = WorkspaceFileExplorerWatchStreamBatcher(
      onBackpressureChanged: backpressure.add,
    ).bind(events.stream);
    final subscription = batches.listen((_) {});
    addTearDown(subscription.cancel);
    addTearDown(events.close);

    subscription.pause();
    await Future<void>.delayed(Duration.zero);
    subscription.resume();
    await Future<void>.delayed(Duration.zero);

    expect(backpressure, <bool>[true, false]);
  });

  test(
    'watch overflow blocks incrementally and records dropped events',
    () async {
      final binding = WorkspaceFileExplorerFileSystemWatcherBinding(
        fileSystemManager: _OverflowWorkspaceFileExplorerFileSystemManager(),
        plan: const WorkspaceFileExplorerWatchPlan(
          rootPath: '/workspace/fixture',
        ),
        baseFilePaths: const <String>['README.md'],
      );

      final snapshots = await binding.watch().toList();

      expect(snapshots, hasLength(2));
      expect(snapshots.first.plan.active, isTrue);
      expect(
        snapshots.last.plan.status,
        WorkspaceFileExplorerWatchStatus.blocked,
      );
      expect(snapshots.last.plan.message, contains('refresh the explorer'));
      expect(snapshots.last.telemetry.overflowCount, 1);
      expect(snapshots.last.telemetry.droppedEventCount, 9);
      expect(snapshots.last.telemetry.overflowed, isTrue);
      expect(snapshots.last.filePaths, <String>['README.md']);
    },
  );

  test('workspace file explorer builds confirmation plans for actions', () {
    const deleteRequest = WorkspaceFileExplorerActionRequest(
      kind: WorkspaceFileOperationKind.delete,
      path: 'src/old.styio',
    );
    const revealRequest = WorkspaceFileExplorerActionRequest(
      kind: WorkspaceFileOperationKind.reveal,
      path: 'src/main.styio',
    );
    final workspaceController = WorkspaceController(
      projectSnapshot: _projectGraph(editorFiles: const <String>['README.md']),
    );
    final controller = WorkspaceFileExplorerController(
      workspaceController: workspaceController,
      operationService: WorkspaceFileOperationService(
        workspaceController: workspaceController,
        documentStore: InMemoryWorkspaceDocumentStore(),
      ),
    );
    addTearDown(controller.dispose);

    final deletePlan = controller.confirmationPlanFor(deleteRequest);
    final revealPlan = controller.confirmationPlanFor(revealRequest);

    expect(deletePlan.title, 'Delete workspace file');
    expect(deletePlan.destructive, isTrue);
    expect(deletePlan.risk, WorkspaceFileExplorerActionRisk.destructive);
    expect(deletePlan.requiresConfirmation, isTrue);
    expect(deletePlan.toJson()['canRunWithoutDialog'], isFalse);
    expect(revealPlan.requiresConfirmation, isFalse);
    expect(revealPlan.canRunWithoutDialog, isTrue);
    expect(revealPlan.toJson()['request'], isA<Map<String, Object?>>());
  });

  test('workspace file explorer controller runs file operations', () async {
    final store = InMemoryWorkspaceDocumentStore();
    final workspaceController = WorkspaceController(
      projectSnapshot: _projectGraph(editorFiles: const <String>['main.styio']),
    );
    final controller = WorkspaceFileExplorerController(
      workspaceController: workspaceController,
      operationService: WorkspaceFileOperationService(
        workspaceController: workspaceController,
        documentStore: store,
      ),
    );
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() {
      notifications += 1;
    });

    final created = await controller.run(
      const WorkspaceFileExplorerActionRequest(
        kind: WorkspaceFileOperationKind.create,
        path: 'src/new.styio',
        text: 'value := 1\n',
        open: true,
      ),
    );
    final renamed = await controller.run(
      const WorkspaceFileExplorerActionRequest(
        kind: WorkspaceFileOperationKind.rename,
        path: 'src/new.styio',
        nextPath: 'src/renamed.styio',
      ),
    );
    final revealed = await controller.run(
      const WorkspaceFileExplorerActionRequest(
        kind: WorkspaceFileOperationKind.reveal,
        path: 'main.styio',
      ),
    );
    final snapshot = controller.snapshot;

    expect(created.applied, isTrue);
    expect(renamed.applied, isTrue);
    expect(revealed.applied, isTrue);
    expect(controller.lastResult, same(revealed));
    expect(snapshot.fileCount, 2);
    expect(snapshot.activeFilePath, 'main.styio');
    expect(snapshot.toJson()['fileCount'], 2);
    expect(workspaceController.files, <String>[
      'main.styio',
      'src/renamed.styio',
    ]);
    expect(await store.documentExists('src/new.styio'), isFalse);
    expect(await store.documentExists('src/renamed.styio'), isTrue);
    expect(notifications, greaterThanOrEqualTo(3));
  });

  test('workspace file explorer stages pending dialog actions', () async {
    final store = InMemoryWorkspaceDocumentStore(
      seededDocuments: const <String, DocumentState>{
        'main.styio': DocumentState(
          documentId: 'main.styio',
          text: 'main := 1\n',
          revision: 1,
        ),
      },
    );
    final workspaceController = WorkspaceController(
      projectSnapshot: _projectGraph(editorFiles: const <String>['main.styio']),
    );
    final controller = WorkspaceFileExplorerController(
      workspaceController: workspaceController,
      operationService: WorkspaceFileOperationService(
        workspaceController: workspaceController,
        documentStore: store,
      ),
    );
    addTearDown(controller.dispose);

    final plan = controller.stageAction(
      const WorkspaceFileExplorerActionRequest(
        kind: WorkspaceFileOperationKind.delete,
        path: 'main.styio',
      ),
    );
    final blocked = await controller.runPendingAction(confirmed: false);
    final applied = await controller.runPendingAction(confirmed: true);

    expect(plan.requiresConfirmation, isTrue);
    expect(controller.pendingConfirmationPlan, isNull);
    expect(blocked, isNull);
    expect(applied?.applied, isTrue);
    expect(applied?.kind, WorkspaceFileOperationKind.delete);
    expect(await store.documentExists('main.styio'), isFalse);

    controller.stageAction(
      const WorkspaceFileExplorerActionRequest(
        kind: WorkspaceFileOperationKind.reveal,
        path: 'missing.styio',
      ),
    );
    final reveal = await controller.runPendingAction(confirmed: false);

    expect(reveal?.applied, isFalse);
    expect(reveal?.message, contains('not part of the project'));
  });

  test(
    'workspace file explorer stages batch action confirmation plans',
    () async {
      final store = InMemoryWorkspaceDocumentStore(
        seededDocuments: const <String, DocumentState>{
          'main.styio': DocumentState(
            documentId: 'main.styio',
            text: 'main := 1\n',
            revision: 1,
          ),
          'old.styio': DocumentState(
            documentId: 'old.styio',
            text: 'old := 1\n',
            revision: 1,
          ),
        },
      );
      final workspaceController = WorkspaceController(
        projectSnapshot: _projectGraph(
          editorFiles: const <String>['main.styio', 'old.styio'],
        ),
      );
      final controller = WorkspaceFileExplorerController(
        workspaceController: workspaceController,
        operationService: WorkspaceFileOperationService(
          workspaceController: workspaceController,
          documentStore: store,
        ),
      );
      addTearDown(controller.dispose);

      final plan = controller
          .stageBatchActions(const <WorkspaceFileExplorerActionRequest>[
            WorkspaceFileExplorerActionRequest(
              kind: WorkspaceFileOperationKind.rename,
              path: 'old.styio',
              nextPath: 'src/old.styio',
            ),
            WorkspaceFileExplorerActionRequest(
              kind: WorkspaceFileOperationKind.delete,
              path: 'main.styio',
            ),
          ]);
      final skipped = await controller.runPendingBatchAction(confirmed: false);
      final results = await controller.runPendingBatchAction(confirmed: true);

      expect(plan.actionCount, 2);
      expect(plan.requiresConfirmation, isTrue);
      expect(plan.destructiveActionCount, 1);
      expect(plan.summary, contains('2 action'));
      expect(controller.pendingBatchActionPlan, isNull);
      expect(skipped, isEmpty);
      expect(results.map((result) => result.kind), <WorkspaceFileOperationKind>[
        WorkspaceFileOperationKind.rename,
        WorkspaceFileOperationKind.delete,
      ]);
      expect(await store.documentExists('old.styio'), isFalse);
      expect(await store.documentExists('src/old.styio'), isTrue);
      expect(await store.documentExists('main.styio'), isFalse);
    },
  );

  test('workspace file explorer contains provider failures', () async {
    final workspaceController = WorkspaceController(
      projectSnapshot: _projectGraph(editorFiles: const <String>[]),
    );
    final controller = WorkspaceFileExplorerController(
      workspaceController: workspaceController,
      operationService: WorkspaceFileOperationService(
        workspaceController: workspaceController,
        documentStore: _FailingWorkspaceFileExplorerDocumentStore(),
      ),
    );
    addTearDown(controller.dispose);

    final result = await controller.run(
      const WorkspaceFileExplorerActionRequest(
        kind: WorkspaceFileOperationKind.create,
        path: 'src/new.styio',
      ),
    );

    expect(result.applied, isFalse);
    expect(result.message, contains('provider'));
    expect(workspaceController.files, isEmpty);
  });

  test(
    'workspace file explorer resets state when project identity changes',
    () {
      final workspaceController = WorkspaceController(
        projectSnapshot: _projectGraph(
          editorFiles: const <String>['/workspace/fixture/main.styio'],
        ),
      );
      final controller = WorkspaceFileExplorerController(
        workspaceController: workspaceController,
        operationService: WorkspaceFileOperationService(
          workspaceController: workspaceController,
          documentStore: InMemoryWorkspaceDocumentStore(),
        ),
      );
      addTearDown(controller.dispose);

      workspaceController.replaceProject(
        _projectGraph(
          id: 'fixture://second-project',
          rootPath: '/workspace/second',
          editorFiles: const <String>['/workspace/second/src/main.styio'],
        ),
      );

      expect(controller.state.workspaceId, 'fixture://second-project');
      expect(controller.snapshot.fileCount, 1);
      expect(
        controller.snapshot.roots.single.path,
        '/workspace/second/src/main.styio',
      );
    },
  );
}

ProjectGraphSnapshot _projectGraph({
  required List<String> editorFiles,
  String id = 'fixture://project',
  String rootPath = '/workspace/fixture',
}) {
  return ProjectGraphSnapshot(
    id: id,
    title: 'fixture',
    kind: ProjectKind.package,
    workspaceRoot: rootPath,
    workspaceMembers: const <String>[],
    packages: const <ProjectPackageSnapshot>[],
    dependencies: const <ProjectDependencySnapshot>[],
    targets: const <ProjectTargetDescriptor>[],
    editorFiles: editorFiles,
    toolchain: const ToolchainStatusSnapshot(
      source: ToolchainResolutionSource.environment,
      detail: 'fixture',
    ),
    lockState: ProjectLockState.unknown,
    vendorState: ProjectVendorState.unknown,
    notes: const <String>[],
  );
}

class _FakeWorkspaceFileExplorerFileSystemManager
    extends UnsupportedFileSystemManager {
  _FakeWorkspaceFileExplorerFileSystemManager(
    this.events, {
    this.entries = const <FileSystemEntitySnapshot>[],
  }) : super(facts: FileSystemFacts.linuxDebianArm());

  final Stream<FileSystemManagerEvent> events;
  final List<FileSystemEntitySnapshot> entries;
  String watchedPath = '';
  bool watchedRecursive = false;
  String listedPath = '';
  bool listedRecursive = false;

  @override
  Future<List<FileSystemEntitySnapshot>> list(
    String path, {
    bool recursive = false,
  }) async {
    listedPath = path;
    listedRecursive = recursive;
    return entries;
  }

  @override
  Stream<FileSystemManagerEvent> watch(String path, {bool recursive = false}) {
    watchedPath = path;
    watchedRecursive = recursive;
    return events;
  }
}

class _OverflowWorkspaceFileExplorerFileSystemManager
    extends UnsupportedFileSystemManager {
  _OverflowWorkspaceFileExplorerFileSystemManager()
    : super(facts: FileSystemFacts.linuxDebianArm());

  @override
  Stream<FileSystemManagerEvent> watch(
    String path, {
    bool recursive = false,
  }) async* {
    throw const FileSystemWatchOverflowException(
      operation: 'workspace.file-explorer.watch',
      droppedEventCount: 9,
    );
  }
}

class _FailingWorkspaceFileExplorerDocumentStore
    implements WorkspaceDocumentStore {
  @override
  Future<bool> deleteDocument(String path) => throw StateError('unavailable');

  @override
  Future<bool> documentExists(String path) => throw StateError('unavailable');

  @override
  String? filePathForDocumentId(String documentId) => null;

  @override
  Future<DocumentState> loadDocument(String path) =>
      throw StateError('unavailable');

  @override
  Future<void> saveDocument(DocumentState document) =>
      throw StateError('unavailable');
}
