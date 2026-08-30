import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/project_graph_contract.dart';
import 'package:vityo_app/src/view_ide/commands/commands.dart';
import 'package:vityo_app/src/ide/editor/document_state.dart';
import 'package:vityo_app/src/view_ide/shell_runtime/controllers/workspace_file_command_controller.dart';
import 'package:vityo_app/src/ide/workspace/workspace.dart';

void main() {
  test('routes immediate create and reveal through owned callbacks', () async {
    const originalPath = 'src/main.styio';
    const createdPath = 'src/new.styio';
    final store = InMemoryWorkspaceDocumentStore(
      seededDocuments: const <String, DocumentState>{
        originalPath: DocumentState(
          documentId: originalPath,
          text: 'main := 1\n',
          revision: 1,
        ),
      },
    );
    final workspace = WorkspaceController(
      projectSnapshot: _projectGraph(<String>[originalPath]),
    );
    addTearDown(workspace.dispose);
    var revealedPath = '';
    var reloadCount = 0;
    var suppressedOperationCount = 0;
    final explorer = WorkspaceFileExplorerController(
      workspaceController: workspace,
      operationService: WorkspaceFileOperationService(
        workspaceController: workspace,
        documentStore: store,
      ),
    );
    addTearDown(explorer.dispose);
    final controller = WorkspaceFileCommandController(
      explorerController: explorer,
      openWorkspaceFile: (path) async {
        revealedPath = path;
        workspace.openFile(path);
        return true;
      },
      reloadActiveDocument: () async {
        reloadCount += 1;
      },
      runWithoutWorkspaceReload: (action) {
        suppressedOperationCount += 1;
        return action();
      },
      isWorkspaceFileDirty: (_) => false,
    );

    final created = await controller.execute(
      commandId: AppCommandId.createWorkspaceFile,
      input: createdPath,
    );
    final revealed = await controller.execute(
      commandId: AppCommandId.revealWorkspaceFile,
      input: originalPath,
    );
    explorer.applyDiscoveryResult(
      const WorkspaceFileExplorerDiscoveryResult(
        source: 'fixture',
        filePaths: <String>[originalPath, createdPath, 'src/discovered.styio'],
      ),
    );
    final discovered = await controller.execute(
      commandId: AppCommandId.revealWorkspaceFile,
      input: 'src/discovered.styio',
    );

    expect(created.applied, isTrue);
    expect(await store.documentExists(createdPath), isTrue);
    expect(workspace.files, contains(createdPath));
    expect(revealed.applied, isTrue);
    expect(discovered.applied, isTrue);
    expect(revealedPath, 'src/discovered.styio');
    expect(workspace.files, contains('src/discovered.styio'));
    expect(reloadCount, 1);
    expect(suppressedOperationCount, 2);
  });

  test('destructive delete stays fail-closed until confirmed', () async {
    const path = 'src/main.styio';
    final store = InMemoryWorkspaceDocumentStore(
      seededDocuments: const <String, DocumentState>{
        path: DocumentState(documentId: path, text: 'main := 1\n', revision: 1),
      },
    );
    final workspace = WorkspaceController(
      projectSnapshot: _projectGraph(<String>[path]),
    );
    addTearDown(workspace.dispose);
    final explorer = WorkspaceFileExplorerController(
      workspaceController: workspace,
      operationService: WorkspaceFileOperationService(
        workspaceController: workspace,
        documentStore: store,
      ),
    );
    addTearDown(explorer.dispose);
    final controller = WorkspaceFileCommandController(
      explorerController: explorer,
      openWorkspaceFile: (_) async => false,
      reloadActiveDocument: () async {},
      runWithoutWorkspaceReload: (action) => action(),
      isWorkspaceFileDirty: (_) => false,
    );

    final staged = await controller.execute(
      commandId: AppCommandId.deleteWorkspaceFile,
      input: path,
    );

    expect(staged.staged, isTrue);
    expect(controller.pendingConfirmation, same(staged));
    expect(await store.documentExists(path), isTrue);

    final cancelled = controller.cancel();
    expect(cancelled?.status, WorkspaceFileCommandRouteStatus.blocked);
    expect(controller.pendingConfirmation, isNull);
    expect(await store.documentExists(path), isTrue);

    await controller.execute(
      commandId: AppCommandId.deleteWorkspaceFile,
      input: path,
    );
    final confirmed = await controller.confirm();
    expect(confirmed?.applied, isTrue);
    expect(controller.pendingConfirmation, isNull);
    expect(await store.documentExists(path), isFalse);
    expect(workspace.files, isNot(contains(path)));
  });

  test('rename refuses to discard unsaved editor content', () async {
    const path = 'src/main.styio';
    final store = InMemoryWorkspaceDocumentStore(
      seededDocuments: const <String, DocumentState>{
        path: DocumentState(documentId: path, text: 'saved\n', revision: 1),
      },
    );
    final workspace = WorkspaceController(
      projectSnapshot: _projectGraph(<String>[path]),
    );
    addTearDown(workspace.dispose);
    final explorer = WorkspaceFileExplorerController(
      workspaceController: workspace,
      operationService: WorkspaceFileOperationService(
        workspaceController: workspace,
        documentStore: store,
      ),
    );
    addTearDown(explorer.dispose);
    final controller = WorkspaceFileCommandController(
      explorerController: explorer,
      openWorkspaceFile: (_) async => false,
      reloadActiveDocument: () async {},
      runWithoutWorkspaceReload: (action) => action(),
      isWorkspaceFileDirty: (candidate) => candidate == path,
    );

    final result = await controller.runExplorerAction(
      const WorkspaceFileExplorerActionRequest(
        kind: WorkspaceFileOperationKind.rename,
        path: path,
        nextPath: 'src/renamed.styio',
      ),
    );

    expect(result.applied, isFalse);
    expect(result.message, contains('unsaved changes'));
    expect(await store.documentExists(path), isTrue);
    expect(await store.documentExists('src/renamed.styio'), isFalse);
    expect(workspace.files, <String>[path]);
  });
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
