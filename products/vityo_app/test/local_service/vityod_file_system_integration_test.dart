import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/editor/document_state.dart';
import 'package:vityo_app/src/ide/local_service/vityod_workspace_search_provider.dart';
import 'package:vityo_app/src/ide/workspace/workspace_document_store_io.dart';
import 'package:vityo_app/src/ide/workspace/workspace_document_store_types.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/file_system/file_system.dart';

import '../support/vityod_test_harness.dart';

void main() {
  test(
    'desktop file operations, watch, and paged search stay behind vityod',
    () async {
      final harness = await VityodTestHarness.start(
        clientId: 'file-service-test',
      );
      final root = await Directory.systemTemp.createTemp('vityod-fs-test-');
      final secondRoot = await Directory.systemTemp.createTemp(
        'vityod-fs-second-test-',
      );
      addTearDown(() async {
        await harness.close();
        if (await root.exists()) await root.delete(recursive: true);
        if (await secondRoot.exists()) await secondRoot.delete(recursive: true);
      });
      final manager = await VityodFileSystemManager.open(
        facts: await const LocalFileSystemProber().probe(),
        client: harness.client,
        allowedRoots: <String>[root.path],
      );

      final source = manager.joinPath(<String>[root.path, 'src', 'main.styio']);
      final copy = manager.joinPath(<String>[root.path, 'src', 'copy.styio']);
      final moved = manager.joinPath(<String>[root.path, 'src', 'moved.styio']);
      await manager.writeText(source, 'needle\nneedle');
      expect(await manager.readText(source), 'needle\nneedle');
      expect((await manager.stat(source)).isFile, isTrue);
      await manager.copy(source, copy);
      await manager.move(copy, moved);
      expect(await manager.exists(copy), isFalse);
      expect(await manager.exists(moved), isTrue);
      expect(
        (await manager.list(
          root.path,
          recursive: true,
        )).where((entry) => entry.isFile),
        hasLength(2),
      );

      final eventFuture = manager
          .watch(root.path, recursive: true)
          .first
          .timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final watched = manager.joinPath(<String>[root.path, 'watched.styio']);
      await manager.writeText(watched, 'watched');
      final event = await eventFuture;
      expect(event.kind, FileSystemManagerEventKind.created);
      expect(event.normalizedPath, manager.normalizePath(watched));

      final opened = await harness.client.request(
        method: 'workspace.open',
        idempotencyKey: 'workspace-open',
        workspaceId: 'search-workspace',
        params: <String, Object?>{'rootPath': root.path},
      );
      expect(opened.method, 'workspace.open.result');
      final firstPage = await harness.client.request(
        method: 'workspace.search',
        idempotencyKey: 'search-page-1',
        workspaceId: 'search-workspace',
        params: const <String, Object?>{
          'query': 'needle',
          'cursor': 0,
          'limit': 1,
        },
      );
      expect(firstPage.params['matches'], hasLength(1));
      expect(firstPage.params['nextCursor'], 1);
      final secondPage = await harness.client.request(
        method: 'workspace.search',
        idempotencyKey: 'search-page-2',
        workspaceId: 'search-workspace',
        params: const <String, Object?>{
          'query': 'needle',
          'cursor': 1,
          'limit': 1,
        },
      );
      expect(secondPage.params['matches'], hasLength(1));
      final typedSearch = await VityodWorkspaceTextSearchProvider(
        client: harness.client,
      ).search(workspaceId: 'search-workspace', query: 'needle', maxMatches: 2);
      expect(typedSearch.matches, hasLength(2));
      expect(typedSearch.matches.first.documentId, 'src/main.styio');
      expect(typedSearch.matches.first.lineText, 'needle');
      expect(typedSearch.matches.first.range.start, 0);

      final escaped = await harness.client.request(
        method: 'fs.read',
        idempotencyKey: 'escape-rejected',
        params: const <String, Object?>{
          'scopeId': 'search-workspace',
          'relativePath': '../outside',
        },
      );
      expect(escaped.method, 'fs.read.error');
      expect(escaped.params['errorCode'], 'workspace_root_escape');

      final documentStore = VityodWorkspaceDocumentStore(
        client: harness.client,
        workspaceId: 'document-workspace',
        workspaceRoot: root.path,
      );
      await documentStore.open();
      final loaded = await documentStore.loadDocument(source);
      expect(loaded.documentId, 'src/main.styio');
      expect(loaded.text, 'needle\nneedle');
      await documentStore.saveDocument(
        DocumentState(
          documentId: loaded.documentId,
          text: 'saved through workspace transaction',
          revision: loaded.revision + 1,
          workspaceRevision: loaded.workspaceRevision,
          baseDocumentRevision: loaded.revision,
        ),
      );
      expect(
        await manager.readText(source),
        'saved through workspace transaction',
      );
      final helper = manager.joinPath(<String>[
        root.path,
        'src',
        'helper.styio',
      ]);
      await manager.writeText(helper, 'helper before');
      final currentMain = await documentStore.loadDocument(source);
      final currentHelper = await documentStore.loadDocument(helper);
      final atomicReceipt = await documentStore.saveDocumentsAtomically(
        <DocumentState>[
          DocumentState(
            documentId: currentMain.documentId,
            text: 'main atomic after',
            revision: currentMain.revision + 1,
          ),
          DocumentState(
            documentId: currentHelper.documentId,
            text: 'helper atomic after',
            revision: currentHelper.revision + 1,
          ),
        ],
        expectedWorkspaceRevision: currentMain.workspaceRevision!,
        expectedDocumentRevisions: <String, int>{
          currentMain.documentId: currentMain.revision,
          currentHelper.documentId: currentHelper.revision,
        },
      );
      expect(atomicReceipt.documentRevisions.keys.toSet(), <String>{
        'src/main.styio',
        'src/helper.styio',
      });
      expect(await manager.readText(source), 'main atomic after');
      expect(await manager.readText(helper), 'helper atomic after');
      await expectLater(
        documentStore.saveDocumentsAtomically(
          <DocumentState>[
            DocumentState(
              documentId: currentMain.documentId,
              text: 'stale atomic overwrite',
              revision: currentMain.revision + 1,
            ),
          ],
          expectedWorkspaceRevision: currentMain.workspaceRevision!,
          expectedDocumentRevisions: <String, int>{
            currentMain.documentId: currentMain.revision,
          },
        ),
        throwsA(
          isA<VityodWorkspaceStoreFailure>().having(
            (failure) => failure.code,
            'code',
            'workspace_revision_conflict',
          ),
        ),
      );
      expect(await manager.readText(source), 'main atomic after');

      final missingPath = manager.joinPath(<String>[
        root.path,
        'created.styio',
      ]);
      final missing = await documentStore.readWorkspaceSnapshot(missingPath);
      expect(missing.resourceId, 'created.styio');
      expect(missing.document, isNull);
      final creationReceipt = await documentStore.saveDocumentsAtomically(
        <DocumentState>[
          const DocumentState(
            documentId: 'created.styio',
            text: 'created from an observed absence',
            revision: 1,
          ),
        ],
        expectedWorkspaceRevision: missing.workspaceRevision,
        expectedDocumentRevisions: const <String, int>{'created.styio': 0},
      );
      expect(creationReceipt.workspaceRevision, missing.workspaceRevision + 1);
      expect(
        await manager.readText(missingPath),
        'created from an observed absence',
      );
      await expectLater(
        documentStore.saveDocumentsAtomically(
          <DocumentState>[
            const DocumentState(
              documentId: 'created.styio',
              text: 'stale create overwrite',
              revision: 1,
            ),
          ],
          expectedWorkspaceRevision: missing.workspaceRevision,
          expectedDocumentRevisions: const <String, int>{'created.styio': 0},
        ),
        throwsA(
          isA<VityodWorkspaceStoreFailure>().having(
            (failure) => failure.code,
            'code',
            'workspace_revision_conflict',
          ),
        ),
      );
      expect(
        await manager.readText(missingPath),
        'created from an observed absence',
      );

      final outside = await Directory.systemTemp.createTemp(
        'vityod-fs-outside-',
      );
      addTearDown(() async {
        if (await outside.exists()) await outside.delete(recursive: true);
      });
      final outsideFile = File('${outside.path}/private.styio')
        ..writeAsStringSync('outside source');
      final linkPath = '${root.path}${Platform.pathSeparator}escape.styio';
      final inScopeLinkTarget = File(linkPath)
        ..writeAsStringSync('in-scope source');
      await documentStore.readWorkspaceSnapshot(linkPath);
      await inScopeLinkTarget.delete();
      final link = Link(linkPath)..createSync(outsideFile.path);
      expect(await link.exists(), isTrue);
      await expectLater(
        documentStore.readWorkspaceSnapshot(linkPath),
        throwsA(
          isA<VityodWorkspaceStoreFailure>().having(
            (failure) => failure.code,
            'code',
            'workspace_root_escape',
          ),
        ),
      );
      final safeSnapshot = await documentStore.readWorkspaceSnapshot(source);
      await expectLater(
        documentStore.saveDocumentsAtomically(
          <DocumentState>[
            const DocumentState(
              documentId: 'escape.styio',
              text: 'must not follow symlink',
              revision: 1,
            ),
          ],
          expectedWorkspaceRevision: safeSnapshot.workspaceRevision,
          expectedDocumentRevisions: const <String, int>{'escape.styio': 0},
        ),
        throwsA(
          isA<VityodWorkspaceStoreFailure>().having(
            (failure) => failure.code,
            'code',
            'workspace_root_escape',
          ),
        ),
      );
      expect(outsideFile.readAsStringSync(), 'outside source');

      final secondSource = File(
        '${secondRoot.path}${Platform.pathSeparator}src'
        '${Platform.pathSeparator}main.styio',
      );
      await secondSource.parent.create(recursive: true);
      await secondSource.writeAsString('second workspace');
      final secondStore = VityodWorkspaceDocumentStore(
        client: harness.client,
        workspaceId: 'second-document-workspace',
        workspaceRoot: secondRoot.path,
      );
      await secondStore.open();
      expect(
        (await secondStore.loadDocument(secondSource.path)).text,
        'second workspace',
      );
      expect(
        (await documentStore.loadDocument(source)).text,
        'main atomic after',
      );

      await manager.delete(moved);
      expect(await manager.exists(moved), isFalse);
    },
    skip: !VityodTestHarness.isSupported
        ? 'Native vityod transport is unavailable.'
        : false,
  );
}
