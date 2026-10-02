import 'package:shared_preferences/shared_preferences.dart';

import '../editor/document_state.dart';
import '../editor/editor_controller.dart';

abstract class WorkspaceDocumentStore {
  Future<DocumentState> loadDocument(String path);

  Future<void> saveDocument(DocumentState document);

  Future<bool> deleteDocument(String path);

  Future<bool> documentExists(String path);

  String? filePathForDocumentId(String documentId);
}

abstract interface class AtomicWorkspaceDocumentStore
    implements WorkspaceDocumentStore {
  /// Atomically commits the supplied source snapshots only when every current
  /// document revision still matches the value observed by the caller. A
  /// revision of `0` represents a document that did not exist at read time.
  Future<WorkspaceDocumentCommitReceipt> saveDocumentsAtomically(
    Iterable<DocumentState> documents, {
    required int expectedWorkspaceRevision,
    required Map<String, int> expectedDocumentRevisions,
  });
}

final class WorkspaceDocumentCommitReceipt {
  WorkspaceDocumentCommitReceipt({
    required this.workspaceRevision,
    required Map<String, int> documentRevisions,
  }) : documentRevisions = Map<String, int>.unmodifiable(documentRevisions);

  final int workspaceRevision;
  final Map<String, int> documentRevisions;
}

final class WorkspaceDocumentOperationSnapshot {
  const WorkspaceDocumentOperationSnapshot({
    required this.resourceId,
    required this.workspaceRevision,
    required this.document,
  });

  /// Workspace-relative identity resolved by the workspace operation owner.
  final String resourceId;
  final int workspaceRevision;
  final DocumentState? document;
}

/// Workspace store surface required by standard Agent file callbacks.
/// Implementations resolve paths within an owned workspace, expose existing
/// documents without seeding them, and persist edits atomically.
abstract interface class WorkspaceDocumentOperationStore
    implements AtomicWorkspaceDocumentStore {
  String relativeDocumentPath(String path);

  Future<WorkspaceDocumentOperationSnapshot> readWorkspaceSnapshot(String path);

  Future<DocumentState?> readExistingDocument(String path);
}

Future<void> saveWorkspaceDocuments(
  WorkspaceDocumentStore store,
  Iterable<DocumentState> documents, {
  required int expectedWorkspaceRevision,
  required Map<String, int> expectedDocumentRevisions,
}) async {
  final pending = documents.toList(growable: false);
  if (pending.isEmpty) return;
  if (store is! AtomicWorkspaceDocumentStore) {
    throw StateError(
      'Workspace edits require an atomic compare-and-set document store.',
    );
  }
  await store.saveDocumentsAtomically(
    pending,
    expectedWorkspaceRevision: expectedWorkspaceRevision,
    expectedDocumentRevisions: expectedDocumentRevisions,
  );
}

int expectedWorkspaceRevisionForDocuments(Iterable<DocumentState> documents) {
  final revisions = documents
      .map((document) => document.workspaceRevision)
      .toSet();
  if (revisions.length != 1 || revisions.single == null) {
    throw StateError(
      'Workspace edits require one observed workspace snapshot.',
    );
  }
  return revisions.single!;
}

abstract class WatchableWorkspaceDocumentStore
    implements WorkspaceDocumentStore {
  Stream<DocumentState> watchDocument(String documentId);
}

class SharedPreferencesWorkspaceDocumentStore
    implements WorkspaceDocumentStore {
  /// SharedPreferences is limited to non-sensitive metadata. Document text may
  /// contain source, credentials, or user data and must use a filesystem or
  /// hosted workspace store.
  SharedPreferencesWorkspaceDocumentStore(
    this._preferences, {
    this.keyPrefix = 'vityo.document',
  });

  final SharedPreferences _preferences;
  final String keyPrefix;

  @override
  Future<DocumentState> loadDocument(String path) async {
    final revision = _preferences.getInt(_revisionKey(path));
    final seeded = EditorSessionController.seedDocumentForPath(path);

    return DocumentState(
      documentId: path,
      text: seeded.text,
      revision: revision ?? seeded.revision,
    );
  }

  @override
  Future<void> saveDocument(DocumentState document) async {
    await _preferences.remove(_textKey(document.documentId));
    await _preferences.setInt(
      _revisionKey(document.documentId),
      document.revision,
    );
  }

  @override
  Future<bool> deleteDocument(String path) async {
    final removedText = await _preferences.remove(_textKey(path));
    final removedRevision = await _preferences.remove(_revisionKey(path));
    return removedText || removedRevision;
  }

  @override
  Future<bool> documentExists(String path) async {
    return _preferences.getInt(_revisionKey(path)) != null;
  }

  @override
  String? filePathForDocumentId(String documentId) => null;

  String _textKey(String path) => '$keyPrefix.$path.text';

  String _revisionKey(String path) => '$keyPrefix.$path.revision';
}

class InMemoryWorkspaceDocumentStore implements AtomicWorkspaceDocumentStore {
  InMemoryWorkspaceDocumentStore({Map<String, DocumentState>? seededDocuments})
    : _documents = Map<String, DocumentState>.from(seededDocuments ?? const {});

  final Map<String, DocumentState> _documents;
  var _workspaceRevision = 0;

  @override
  Future<DocumentState> loadDocument(String path) async {
    final document = _documents[path];
    if (document == null) {
      return EditorSessionController.seedDocumentForPath(path);
    }
    return _withWorkspaceRevision(document, _workspaceRevision);
  }

  @override
  Future<void> saveDocument(DocumentState document) async {
    _workspaceRevision++;
    _documents[document.documentId] = _withWorkspaceRevision(
      document,
      _workspaceRevision,
    );
  }

  @override
  Future<WorkspaceDocumentCommitReceipt> saveDocumentsAtomically(
    Iterable<DocumentState> documents, {
    required int expectedWorkspaceRevision,
    required Map<String, int> expectedDocumentRevisions,
  }) async {
    if (_workspaceRevision != expectedWorkspaceRevision) {
      throw StateError('workspace_revision_conflict');
    }
    final pending = documents.toList(growable: false);
    final seen = <String>{};
    for (final document in pending) {
      if (!seen.add(document.documentId)) {
        throw StateError('duplicate_document_change');
      }
      final expectedRevision = expectedDocumentRevisions[document.documentId];
      if (expectedRevision == null || expectedRevision < 0) {
        throw StateError('invalid_expected_document_revision');
      }
      if ((_documents[document.documentId]?.revision ?? 0) !=
          expectedRevision) {
        throw StateError('document_revision_conflict');
      }
    }

    final revisions = <String, int>{};
    final nextWorkspaceRevision = _workspaceRevision + 1;
    for (final document in pending) {
      _documents[document.documentId] = _withWorkspaceRevision(
        document,
        nextWorkspaceRevision,
      );
      revisions[document.documentId] = document.revision;
    }
    _workspaceRevision = nextWorkspaceRevision;
    return WorkspaceDocumentCommitReceipt(
      workspaceRevision: nextWorkspaceRevision,
      documentRevisions: revisions,
    );
  }

  @override
  Future<bool> deleteDocument(String path) async {
    final removed = _documents.remove(path) != null;
    if (removed) _workspaceRevision++;
    return removed;
  }

  @override
  Future<bool> documentExists(String path) async =>
      _documents.containsKey(path);

  @override
  String? filePathForDocumentId(String documentId) => null;

  DocumentState _withWorkspaceRevision(DocumentState document, int revision) =>
      DocumentState(
        documentId: document.documentId,
        text: document.text,
        revision: document.revision,
        encoding: document.encoding,
        workspaceRevision: revision,
      );
}
