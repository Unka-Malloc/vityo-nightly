import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/project_graph_contract.dart';
import 'package:vityo_app/src/ide/editor/editor.dart';
import 'package:vityo_app/src/view_ide/language/service/project_styio_language_service.dart';
import 'package:vityo_app/src/view_ide/language/contract/language_contract.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';
import 'package:vityo_app/src/view_ide/runtime/runtime.dart';
import 'package:vityo_app/src/view_ide/shell_runtime/controllers/workspace_search_controller.dart';
import 'package:vityo_app/src/ide/workspace/workspace.dart';

void main() {
  test('text and symbol search share one document scan', () async {
    const activePath = 'main.styio';
    const helperPath = 'lib/math.styio';
    const unsavedActive = DocumentState(
      documentId: activePath,
      text: 'value = blend(1, 2)\n',
      revision: 2,
    );
    const helper = DocumentState(
      documentId: helperPath,
      text: 'fn blend(left: i32, right: i32): i32 { emit left + right }\n',
      revision: 1,
    );
    final store = InMemoryWorkspaceDocumentStore(
      seededDocuments: const <String, DocumentState>{
        activePath: DocumentState(
          documentId: activePath,
          text: 'disk content\n',
          revision: 1,
        ),
        helperPath: helper,
      },
    );
    final workspace = WorkspaceController(
      projectSnapshot: _projectGraph(const <String>[activePath, helperPath]),
    );
    addTearDown(workspace.dispose);
    final controller = WorkspaceSearchController(
      workspaceController: workspace,
      documentStore: store,
      languageService: const ProjectStyioLanguageService(),
      documentSamples: () => const <DocumentState>[unsavedActive],
      log: (_) {},
      textSearchProvider: const _TestTextSearchProvider(),
    );
    addTearDown(controller.dispose);

    final searched = await controller.search('blend');

    expect(searched, isTrue);
    expect(controller.lastScannedDocumentCount, 2);
    expect(controller.lastTextSearch?.matches.length, 2);
    expect(
      controller.lastSymbolSearch?.matches.map((match) => match.name),
      contains('blend'),
    );
  });

  test('empty search fails closed without publishing stale results', () async {
    final workspace = WorkspaceController(
      projectSnapshot: _projectGraph(const <String>['main.styio']),
    );
    addTearDown(workspace.dispose);
    final controller = WorkspaceSearchController(
      workspaceController: workspace,
      documentStore: InMemoryWorkspaceDocumentStore(),
      languageService: const ProjectStyioLanguageService(),
      documentSamples: () => const <DocumentState>[],
      log: (_) {},
    );
    addTearDown(controller.dispose);

    expect(await controller.search('  '), isFalse);
    expect(controller.lastTextSearch, isNull);
    expect(controller.lastSymbolSearch, isNull);
  });

  test('offline text search uses the in-process workspace service', () async {
    const document = DocumentState(
      documentId: 'main.styio',
      text: 'needle := 1\n',
      revision: 1,
    );
    final workspace = WorkspaceController(
      projectSnapshot: _projectGraph(const <String>['main.styio']),
    );
    addTearDown(workspace.dispose);
    final controller = WorkspaceSearchController(
      workspaceController: workspace,
      documentStore: InMemoryWorkspaceDocumentStore(
        seededDocuments: const <String, DocumentState>{'main.styio': document},
      ),
      languageService: const ProjectStyioLanguageService(),
      documentSamples: () => const <DocumentState>[document],
      log: (_) {},
    );
    addTearDown(controller.dispose);

    expect(await controller.search('needle'), isTrue);
    expect(controller.lastTextSearch?.matches, hasLength(1));
    expect(controller.lastTextSearch?.matches.single.documentId, 'main.styio');
  });

  test('production watcher publishes backpressure to runtime output', () async {
    const document = DocumentState(
      documentId: 'main.styio',
      text: 'value := 1\n',
      revision: 1,
    );
    final workspace = WorkspaceController(
      projectSnapshot: _projectGraph(const <String>['main.styio']),
    );
    addTearDown(workspace.dispose);
    final output = RuntimeOutputLiveBuffer();
    addTearDown(output.dispose);
    final controller = WorkspaceSearchController(
      workspaceController: workspace,
      documentStore: InMemoryWorkspaceDocumentStore(
        seededDocuments: const <String, DocumentState>{'main.styio': document},
      ),
      languageService: const ProjectStyioLanguageService(),
      documentSamples: () => const <DocumentState>[document],
      log: (_) {},
      fileSystemManager: _ControllerSearchFileSystemManager(),
      runtimeOutputBuffer: output,
      watcherPolicy: const WorkspaceSearchWatcherPolicy(
        debounceWindow: Duration.zero,
        overflowRecoveryDelay: Duration.zero,
        maxEventsPerBatch: 1,
      ),
    );
    addTearDown(controller.dispose);
    final stopped = Completer<void>();
    controller.addListener(() {
      if (controller.watcherSnapshot?.status ==
              WorkspaceSearchIndexWatcherStatus.stopped &&
          !stopped.isCompleted) {
        stopped.complete();
      }
    });

    await controller.start();
    await stopped.future.timeout(const Duration(seconds: 1));

    expect(controller.searchIndex?.documentCount, 1);
    expect(controller.watcherSnapshot?.backpressure?.batchCount, 1);
    expect(
      output.snapshot.events.where(
        (event) => event.channelId == 'workspace.search',
      ),
      isNotEmpty,
    );
  });
}

final class _ControllerSearchFileSystemManager
    extends UnsupportedFileSystemManager {
  _ControllerSearchFileSystemManager()
    : super(facts: FileSystemFacts.linuxDebianArm());

  @override
  Stream<FileSystemManagerEvent> watch(String path, {bool recursive = false}) {
    return Stream<FileSystemManagerEvent>.value(
      const FileSystemManagerEvent(
        kind: FileSystemManagerEventKind.modified,
        path: '/workspace/fixture/main.styio',
        normalizedPath: '/workspace/fixture/main.styio',
      ),
    );
  }
}

final class _TestTextSearchProvider implements WorkspaceTextSearchProvider {
  const _TestTextSearchProvider();

  @override
  Future<WorkspaceSearchResult> search({
    required String workspaceId,
    required String query,
    int maxMatches = 1000,
  }) async {
    return const WorkspaceSearchResult(
      matches: <WorkspaceSearchMatch>[
        WorkspaceSearchMatch(
          documentId: 'main.styio',
          range: SourceRange(start: 8, end: 13),
          text: 'blend',
          lineNumber: 1,
          lineText: 'value = blend(1, 2)',
        ),
        WorkspaceSearchMatch(
          documentId: 'lib/math.styio',
          range: SourceRange(start: 3, end: 8),
          text: 'blend',
          lineNumber: 1,
          lineText: 'fn blend(left: i32, right: i32): i32',
        ),
      ],
    );
  }
}

ProjectGraphSnapshot _projectGraph(List<String> editorFiles) {
  return ProjectGraphSnapshot(
    id: 'fixture://project',
    title: 'fixture',
    kind: ProjectKind.package,
    workspaceRoot: '/workspace/fixture',
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
