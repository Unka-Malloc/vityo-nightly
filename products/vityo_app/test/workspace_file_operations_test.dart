import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/project_graph_contract.dart';
import 'package:vityo_app/src/ide/editor/document_state.dart';
import 'package:vityo_app/src/ide/workspace/workspace.dart';

void main() {
  test('workspace file operations create and reveal files', () async {
    final store = InMemoryWorkspaceDocumentStore();
    final controller = WorkspaceController(
      projectSnapshot: _projectGraph(editorFiles: const <String>['main.styio']),
    );
    final service = WorkspaceFileOperationService(
      workspaceController: controller,
      documentStore: store,
    );

    final created = await service.createFile(
      path: 'src/generated.styio',
      text: 'value := 1\n',
      open: true,
    );
    final document = await store.loadDocument('src/generated.styio');
    final revealed = service.revealFile('main.styio');

    expect(created.applied, isTrue);
    expect(created.kind, WorkspaceFileOperationKind.create);
    expect(document.text, 'value := 1\n');
    expect(controller.files, <String>['main.styio', 'src/generated.styio']);
    expect(controller.activeFilePath, 'main.styio');
    expect(revealed.applied, isTrue);
    expect(revealed.toJson()['kind'], 'reveal');
  });

  test('workspace file operations rename active file and preserve contents', () async {
    final store = InMemoryWorkspaceDocumentStore(
      seededDocuments: const <String, DocumentState>{
        'main.styio': DocumentState(
          documentId: 'main.styio',
          text: 'main := 1\n',
          revision: 2,
        ),
      },
    );
    final controller = WorkspaceController(
      projectSnapshot: _projectGraph(editorFiles: const <String>['main.styio']),
    );
    final service = WorkspaceFileOperationService(
      workspaceController: controller,
      documentStore: store,
    );

    final renamed = await service.renameFile(
      path: 'main.styio',
      nextPath: 'src/main.styio',
    );
    final nextDocument = await store.loadDocument('src/main.styio');

    expect(renamed.applied, isTrue);
    expect(renamed.kind, WorkspaceFileOperationKind.rename);
    expect(renamed.nextPath, 'src/main.styio');
    expect(nextDocument.text, 'main := 1\n');
    expect(nextDocument.revision, 3);
    expect(await store.documentExists('main.styio'), isFalse);
    expect(controller.files, <String>['src/main.styio']);
    expect(controller.activeFilePath, 'src/main.styio');
  });

  test('workspace file operations delete inactive files', () async {
    final store = InMemoryWorkspaceDocumentStore(
      seededDocuments: const <String, DocumentState>{
        'main.styio': DocumentState(
          documentId: 'main.styio',
          text: 'main := 1\n',
          revision: 1,
        ),
        'lib.styio': DocumentState(
          documentId: 'lib.styio',
          text: 'lib := 1\n',
          revision: 1,
        ),
      },
    );
    final controller = WorkspaceController(
      projectSnapshot: _projectGraph(
        editorFiles: const <String>['main.styio', 'lib.styio'],
      ),
    )..openFile('lib.styio');
    final service = WorkspaceFileOperationService(
      workspaceController: controller,
      documentStore: store,
    );

    final deleted = await service.deleteFile('main.styio');

    expect(deleted.applied, isTrue);
    expect(await store.documentExists('main.styio'), isFalse);
    expect(controller.files, <String>['lib.styio']);
    expect(controller.activeFilePath, 'lib.styio');
  });

  test('workspace file operations block unsafe or conflicting paths', () async {
    final store = InMemoryWorkspaceDocumentStore(
      seededDocuments: const <String, DocumentState>{
        'main.styio': DocumentState(
          documentId: 'main.styio',
          text: 'main := 1\n',
          revision: 1,
        ),
      },
    );
    final controller = WorkspaceController(
      projectSnapshot: _projectGraph(editorFiles: const <String>['main.styio']),
    );
    final service = WorkspaceFileOperationService(
      workspaceController: controller,
      documentStore: store,
    );

    final unsafe = await service.createFile(path: '../escape.styio');
    final conflict = await service.renameFile(
      path: 'main.styio',
      nextPath: 'main.styio',
    );
    final missingReveal = service.revealFile('missing.styio');

    expect(unsafe.applied, isFalse);
    expect(unsafe.message, contains('inside the workspace'));
    expect(conflict.applied, isFalse);
    expect(conflict.message, contains('path did not change'));
    expect(missingReveal.applied, isFalse);
    expect(missingReveal.message, contains('not part of the project'));
  });

  test(
    'absolute workspace projects keep one canonical path convention',
    () async {
      const activePath = '/workspace/fixture/src/main.styio';
      final store = InMemoryWorkspaceDocumentStore(
        seededDocuments: const <String, DocumentState>{
          activePath: DocumentState(
            documentId: activePath,
            text: 'main := 1\n',
            revision: 1,
          ),
        },
      );
      final controller = WorkspaceController(
        projectSnapshot: _projectGraph(editorFiles: const <String>[activePath]),
      );
      final service = WorkspaceFileOperationService(
        workspaceController: controller,
        documentStore: store,
      );

      final created = await service.createFile(
        path: 'src/generated.styio',
        open: true,
      );
      final renamed = await service.renameFile(
        path: 'src/generated.styio',
        nextPath: 'src/renamed.styio',
      );
      final outside = await service.deleteFile('/tmp/outside.styio');

      expect(created.path, '/workspace/fixture/src/generated.styio');
      expect(renamed.nextPath, '/workspace/fixture/src/renamed.styio');
      expect(controller.files, <String>[
        activePath,
        '/workspace/fixture/src/renamed.styio',
      ]);
      expect(outside.applied, isFalse);
      expect(outside.message, contains('inside the workspace'));
    },
  );

  test(
    'relative workspace projects canonicalize contained absolute input',
    () async {
      const relativePath = 'src/main.styio';
      final store = InMemoryWorkspaceDocumentStore(
        seededDocuments: const <String, DocumentState>{
          relativePath: DocumentState(
            documentId: relativePath,
            text: 'main := 1\n',
            revision: 1,
          ),
        },
      );
      final controller = WorkspaceController(
        projectSnapshot: _projectGraph(
          editorFiles: const <String>[relativePath],
        ),
      );
      final service = WorkspaceFileOperationService(
        workspaceController: controller,
        documentStore: store,
      );

      final revealed = service.revealFile('/workspace/fixture/src/main.styio');

      expect(revealed.applied, isTrue);
      expect(revealed.path, relativePath);
      expect(controller.files, <String>[relativePath]);
    },
  );

  test(
    'Windows projects preserve native storage paths behind the tree',
    () async {
      const root = r'C:\workspace\fixture';
      const activePath = r'C:\workspace\fixture\src\main.styio';
      const generatedPath = r'C:\workspace\fixture\src\generated.styio';
      const renamedPath = r'C:\workspace\fixture\src\renamed.styio';
      final store = InMemoryWorkspaceDocumentStore(
        seededDocuments: const <String, DocumentState>{
          activePath: DocumentState(
            documentId: activePath,
            text: 'main := 1\n',
            revision: 1,
          ),
        },
      );
      final controller = WorkspaceController(
        projectSnapshot: _projectGraph(
          workspaceRoot: root,
          editorFiles: const <String>[activePath],
        ),
      );
      final service = WorkspaceFileOperationService(
        workspaceController: controller,
        documentStore: store,
      );

      final revealed = service.revealFile(
        'c:/WORKSPACE/FIXTURE/src/main.styio',
      );
      final created = await service.createFile(path: 'src/generated.styio');
      final renamed = await service.renameFile(
        path: 'C:/workspace/fixture/src/generated.styio',
        nextPath: 'src/renamed.styio',
      );
      final outside = await service.createFile(path: r'D:\outside.styio');

      expect(revealed.path, activePath);
      expect(created.path, generatedPath);
      expect(renamed.nextPath, renamedPath);
      expect(controller.files, <String>[activePath, renamedPath]);
      expect(await store.documentExists(generatedPath), isFalse);
      expect(await store.documentExists(renamedPath), isTrue);
      expect(outside.applied, isFalse);
    },
  );
}

ProjectGraphSnapshot _projectGraph({
  required List<String> editorFiles,
  String workspaceRoot = '/workspace/fixture',
}) {
  return ProjectGraphSnapshot(
    id: 'fixture://project',
    title: 'fixture',
    kind: ProjectKind.package,
    workspaceRoot: workspaceRoot,
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
