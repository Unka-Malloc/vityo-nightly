import 'package:vityo_daemon_protocol/vityo_daemon_protocol.dart';

import '../editor/document/document_encoding.dart';
import '../editor/document/document_state.dart';
import '../editor/editor_controller.dart';
import '../local_service/vityod_client.dart';
import 'workspace_document_store_types.dart';

Future<WorkspaceDocumentStore> createPlatformWorkspaceDocumentStore({
  VityodClient? vityodClient,
  String? workspaceId,
  String? workspaceRoot,
}) async {
  if (vityodClient == null) return InMemoryWorkspaceDocumentStore();
  final store = VityodWorkspaceDocumentStore(
    client: vityodClient,
    workspaceId: workspaceId,
    workspaceRoot: workspaceRoot,
  );
  await store.open();
  return store;
}

final class VityodWorkspaceDocumentStore
    implements WorkspaceDocumentOperationStore {
  VityodWorkspaceDocumentStore({
    required VityodClient client,
    this.workspaceId,
    this.workspaceRoot,
  }) : _client = client;

  final VityodClient _client;
  final String? workspaceId;
  final String? workspaceRoot;
  var _sequence = 0;

  Future<void> open() async {
    final id = workspaceId;
    final root = workspaceRoot;
    if (id == null || root == null) return;
    final response = await _client.request(
      method: 'workspace.open',
      idempotencyKey: _nextKey('open'),
      workspaceId: id,
      params: <String, Object?>{'rootPath': root},
    );
    _throwIfError(response);
    final workspaceRevision = response.params['workspaceRevision'];
    if (workspaceRevision is! int) {
      throw const VityodWorkspaceStoreFailure('invalid_workspace_snapshot');
    }
  }

  @override
  Future<DocumentState> loadDocument(String path) async {
    final snapshot = await readWorkspaceSnapshot(path);
    final existing = snapshot.document;
    if (existing != null) return existing;
    final seeded = EditorSessionController.seedDocumentForPath(path);
    final relativePath = snapshot.resourceId;
    final receipt = await saveDocumentsAtomically(
      <DocumentState>[
        DocumentState(
          documentId: relativePath,
          text: seeded.text,
          revision: 0,
          encoding: seeded.encoding,
          workspaceRevision: snapshot.workspaceRevision,
          baseDocumentRevision: 0,
        ),
      ],
      expectedWorkspaceRevision: snapshot.workspaceRevision,
      expectedDocumentRevisions: <String, int>{relativePath: 0},
    );
    final revision = receipt.documentRevisions[relativePath];
    if (revision == null) {
      throw const VityodWorkspaceStoreFailure('invalid_commit_receipt');
    }
    return DocumentState(
      documentId: relativePath,
      text: seeded.text,
      revision: revision,
      encoding: seeded.encoding,
      workspaceRevision: receipt.workspaceRevision,
      baseDocumentRevision: revision,
    );
  }

  /// Reads a document through the workspace owner without creating seeded
  /// content when the requested file does not exist.
  @override
  Future<DocumentState?> readExistingDocument(String path) async {
    return (await readWorkspaceSnapshot(path)).document;
  }

  @override
  Future<WorkspaceDocumentOperationSnapshot> readWorkspaceSnapshot(
    String path,
  ) async {
    final relativePath = _relativePath(path);
    final response = await _client.request(
      method: 'workspace.read',
      idempotencyKey: _nextKey('read'),
      workspaceId: workspaceId,
      params: <String, Object?>{'relativePath': relativePath},
    );
    if (response.method.endsWith('.error')) {
      final code = response.params['errorCode'];
      final workspaceRevision = response.params['workspaceRevision'];
      if (code == 'document_missing' && workspaceRevision is int) {
        final context = response.params['context'];
        final hostResourceId = context is Map ? context['relativePath'] : null;
        if (hostResourceId is! String || hostResourceId != relativePath) {
          throw const VityodWorkspaceStoreFailure('invalid_workspace_snapshot');
        }
        return WorkspaceDocumentOperationSnapshot(
          resourceId: hostResourceId,
          workspaceRevision: workspaceRevision,
          document: null,
        );
      }
      throw VityodWorkspaceStoreFailure(
        code is String ? code : 'workspace_service_error',
      );
    }
    final contents = response.params['contents'];
    final documentRevision = response.params['documentRevision'];
    final workspaceRevision = response.params['workspaceRevision'];
    final canonicalResourceId = response.params['relativePath'];
    final encoding = response.params['encoding'];
    if (contents is! String ||
        documentRevision is! int ||
        workspaceRevision is! int ||
        canonicalResourceId is! String ||
        canonicalResourceId != relativePath) {
      throw const VityodWorkspaceStoreFailure('invalid_workspace_snapshot');
    }
    return WorkspaceDocumentOperationSnapshot(
      resourceId: canonicalResourceId,
      workspaceRevision: workspaceRevision,
      document: DocumentState(
        documentId: canonicalResourceId,
        text: contents,
        revision: documentRevision,
        baseDocumentRevision: documentRevision,
        workspaceRevision: workspaceRevision,
        encoding: encoding is String
            ? DocumentEncoding.fromWireValue(encoding)
            : null,
      ),
    );
  }

  @override
  Future<void> saveDocument(DocumentState document) async {
    final relativePath = _relativePath(document.documentId);
    final workspaceRevision = document.workspaceRevision;
    if (workspaceRevision == null) {
      final snapshot = await readWorkspaceSnapshot(document.documentId);
      if (snapshot.document != null) {
        throw const VityodWorkspaceStoreFailure('document_snapshot_required');
      }
      await saveDocumentsAtomically(
        <DocumentState>[
          DocumentState(
            documentId: relativePath,
            text: document.text,
            revision: document.revision,
            encoding: document.encoding,
            baseDocumentRevision: 0,
            workspaceRevision: snapshot.workspaceRevision,
          ),
        ],
        expectedWorkspaceRevision: snapshot.workspaceRevision,
        expectedDocumentRevisions: <String, int>{relativePath: 0},
      );
      return;
    }
    await saveDocumentsAtomically(
      <DocumentState>[document],
      expectedWorkspaceRevision: workspaceRevision,
      expectedDocumentRevisions: <String, int>{
        document.documentId: document.baseDocumentRevision,
      },
    );
  }

  @override
  Future<WorkspaceDocumentCommitReceipt> saveDocumentsAtomically(
    Iterable<DocumentState> documents, {
    required int expectedWorkspaceRevision,
    required Map<String, int> expectedDocumentRevisions,
  }) async {
    final pending = documents.toList(growable: false);
    if (pending.isEmpty) {
      throw const VityodWorkspaceStoreFailure('empty_workspace_transaction');
    }
    final seen = <String>{};
    final changes = <Map<String, Object?>>[];
    for (final document in pending) {
      final relativePath = _relativePath(document.documentId);
      if (!seen.add(relativePath)) {
        throw const VityodWorkspaceStoreFailure('duplicate_document_change');
      }
      final expectedRevision = expectedDocumentRevisions[document.documentId];
      if (expectedRevision == null || expectedRevision < 0) {
        throw const VityodWorkspaceStoreFailure(
          'invalid_expected_document_revision',
        );
      }
      changes.add(<String, Object?>{
        'relativePath': relativePath,
        'expectedDocumentRevision': expectedRevision,
        'contents': document.text,
        if (document.encoding != null) 'encoding': document.encoding!.wireValue,
      });
    }
    final response = await _client.request(
      method: 'workspace.transaction.commit',
      idempotencyKey: _nextKey('commit'),
      workspaceId: workspaceId,
      params: <String, Object?>{
        'expectedWorkspaceRevision': expectedWorkspaceRevision,
        'changes': changes,
      },
    );
    _throwIfError(response);
    final workspaceRevision = response.params['workspaceRevision'];
    final revisions = response.params['documentRevisions'];
    if (workspaceRevision is! int || revisions is! Map) {
      throw const VityodWorkspaceStoreFailure('invalid_commit_receipt');
    }
    final committed = <String, int>{};
    for (final relativePath in seen) {
      final documentRevision = revisions[relativePath];
      if (documentRevision is! int) {
        throw const VityodWorkspaceStoreFailure('invalid_commit_receipt');
      }
      committed[relativePath] = documentRevision;
    }
    return WorkspaceDocumentCommitReceipt(
      workspaceRevision: workspaceRevision,
      documentRevisions: committed,
    );
  }

  @override
  Future<bool> deleteDocument(String path) async {
    final relativePath = _relativePath(path);
    final snapshot = await readWorkspaceSnapshot(path);
    final document = snapshot.document;
    if (document == null) return false;
    final response = await _client.request(
      method: 'workspace.delete',
      idempotencyKey: _nextKey('delete'),
      workspaceId: workspaceId,
      params: <String, Object?>{
        'relativePath': relativePath,
        'expectedWorkspaceRevision': snapshot.workspaceRevision,
        'expectedDocumentRevision': document.revision,
      },
    );
    _throwIfError(response);
    final deleted = response.params['deleted'];
    final workspaceRevision = response.params['workspaceRevision'];
    if (deleted is! bool || workspaceRevision is! int) {
      throw const VityodWorkspaceStoreFailure('invalid_delete_receipt');
    }
    return deleted;
  }

  @override
  Future<bool> documentExists(String path) async {
    return (await readWorkspaceSnapshot(path)).document != null;
  }

  @override
  String? filePathForDocumentId(String documentId) {
    final root = workspaceRoot;
    if (root == null) return null;
    final separator = root.contains(r'\') ? r'\' : '/';
    final normalizedRoot = root.endsWith(separator)
        ? root.substring(0, root.length - 1)
        : root;
    return '$normalizedRoot$separator'
        '${_relativePath(documentId).replaceAll('/', separator)}';
  }

  String _relativePath(String path) {
    final root = workspaceRoot;
    final normalizedPath = path.replaceAll(r'\', '/');
    if (normalizedPath.split('/').contains('..')) {
      throw const VityodWorkspaceStoreFailure('workspace_root_escape');
    }
    if (root == null) return normalizedPath;
    final normalizedRoot = root
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    final comparePath = normalizedPath.toLowerCase();
    final compareRoot = normalizedRoot.toLowerCase();
    if (comparePath == compareRoot) {
      throw const VityodWorkspaceStoreFailure('workspace_root_is_not_document');
    }
    if (comparePath.startsWith('$compareRoot/')) {
      return normalizedPath.substring(normalizedRoot.length + 1);
    }
    final absolute =
        normalizedPath.startsWith('/') ||
        RegExp(r'^[A-Za-z]:/').hasMatch(normalizedPath);
    if (absolute) {
      throw const VityodWorkspaceStoreFailure('workspace_root_escape');
    }
    return normalizedPath;
  }

  String _nextKey(String operation) =>
      'workspace-$operation-${++_sequence}-${_client.clientInstanceId}';

  /// Resolves an absolute path beneath this workspace to its wire path.
  @override
  String relativeDocumentPath(String path) => _relativePath(path);
}

void _throwIfError(VityodControlEnvelope response) {
  if (!response.method.endsWith('.error')) return;
  final code = response.params['errorCode'];
  throw VityodWorkspaceStoreFailure(
    code is String ? code : 'workspace_service_error',
  );
}
