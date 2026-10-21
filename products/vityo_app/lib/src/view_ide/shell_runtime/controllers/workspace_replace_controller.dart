import 'package:flutter/foundation.dart';

import '../../../ide/editor/editor.dart';
import '../../../ide/workspace/workspace.dart';
import 'editor_workspace_state_controller.dart';

/// Owns reviewed workspace replace previews and their application lifecycle.
final class WorkspaceReplaceController extends ChangeNotifier {
  WorkspaceReplaceController({
    required this.workspaceController,
    required this.documentStore,
    required this.editorController,
    required this.editorWorkspaceState,
    required this.log,
    this.textSearchProvider,
  });

  final WorkspaceController workspaceController;
  final WorkspaceDocumentStore documentStore;
  final EditorSessionController editorController;
  final EditorWorkspaceStateController editorWorkspaceState;
  final void Function(String message) log;
  final WorkspaceTextSearchProvider? textSearchProvider;

  WorkspaceReplacePreview? _lastPreview;

  WorkspaceReplacePreview? get lastPreview => _lastPreview;

  Future<WorkspaceReplacePreview?> preview({
    required String query,
    required String replacement,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      log('Workspace replace preview skipped: missing search query.');
      return null;
    }
    final provider = textSearchProvider;
    final preview = provider == null
        ? await WorkspaceSearchService(
            documentStore: documentStore,
          ).previewReplaceAll(
            documentIds: workspaceController.files,
            query: normalizedQuery,
            replacement: replacement,
          )
        : await _previewFromProvider(
            provider: provider,
            query: normalizedQuery,
            replacement: replacement,
          );
    _lastPreview = preview;
    log(
      'Workspace replace preview found ${preview.replacementCount} '
      'replacement(s) across ${preview.documents.length} document(s).',
    );
    notifyListeners();
    return preview;
  }

  Future<WorkspaceReplaceResult?> apply(WorkspaceReplacePreview preview) async {
    if (preview.documents.isEmpty) {
      log('Workspace replace apply skipped: no preview changes.');
      return null;
    }
    final store = documentStore;
    final result = store is AtomicWorkspaceDocumentStore
        ? await _applyAtomically(preview, store)
        : await WorkspaceSearchService(
            documentStore: documentStore,
          ).applyReplacePreview(preview);
    for (final document in result.documents) {
      editorWorkspaceState
        ..removeDocument(document.documentId)
        ..markDirty(document.documentId);
    }
    final activePath = workspaceController.activeFilePath;
    WorkspaceReplacePreviewDocument? activePreviewDocument;
    final appliedRevisions = <String, int>{
      for (final document in result.documents)
        document.documentId: document.revision,
    };
    for (final document in preview.documents) {
      if (document.documentId == activePath &&
          result.documents.any(
            (applied) => applied.documentId == document.documentId,
          )) {
        activePreviewDocument = document;
        break;
      }
    }
    if (activePreviewDocument != null) {
      editorController.loadDocument(
        DocumentState(
          documentId: activePreviewDocument.documentId,
          text: activePreviewDocument.afterText,
          revision:
              appliedRevisions[activePreviewDocument.documentId] ??
              activePreviewDocument.revision,
          workspaceRevision: result.workspaceRevision,
          baseDocumentRevision:
              appliedRevisions[activePreviewDocument.documentId] ??
              activePreviewDocument.revision,
        ),
      );
    }
    if (result.failures.isEmpty) {
      _lastPreview = null;
    }
    log(
      'Workspace replace apply changed ${result.replacementCount} '
      'replacement(s) across ${result.documents.length} document(s), '
      '${result.failures.length} failure(s).',
    );
    notifyListeners();
    return result;
  }

  Future<WorkspaceReplacePreview> _previewFromProvider({
    required WorkspaceTextSearchProvider provider,
    required String query,
    required String replacement,
  }) async {
    final search = await provider.search(
      workspaceId: workspaceController.activeProject.id,
      query: query,
      maxMatches: 1000,
    );
    final byDocument = <String, List<WorkspaceSearchMatch>>{};
    for (final match in search.matches) {
      (byDocument[match.documentId] ??= <WorkspaceSearchMatch>[]).add(match);
    }
    final documents = <WorkspaceReplacePreviewDocument>[];
    final failures = <WorkspaceSearchFailure>[...search.failures];
    for (final entry in byDocument.entries) {
      try {
        final document = await documentStore.loadDocument(entry.key);
        final workspaceRevision = document.workspaceRevision;
        if (workspaceRevision == null) {
          failures.add(
            WorkspaceSearchFailure(
              documentId: entry.key,
              message: 'document_snapshot_required',
            ),
          );
          continue;
        }
        final matches =
            entry.value
                .where(
                  (match) =>
                      match.range.start >= 0 &&
                      match.range.end <= document.text.length &&
                      match.range.start <= match.range.end &&
                      document.text.substring(
                            match.range.start,
                            match.range.end,
                          ) ==
                          match.text &&
                      match.text != replacement,
                )
                .toList(growable: false)
              ..sort(
                (left, right) => left.range.start.compareTo(right.range.start),
              );
        if (matches.isEmpty) continue;
        if (_hasOverlappingMatches(matches)) {
          failures.add(
            WorkspaceSearchFailure(
              documentId: entry.key,
              message: 'workspace search returned overlapping match ranges',
            ),
          );
          continue;
        }
        documents.add(
          WorkspaceReplacePreviewDocument(
            documentId: document.documentId,
            beforeText: document.text,
            afterText: _replaceMatches(document.text, matches, replacement),
            replacementCount: matches.length,
            revision: document.revision,
            workspaceRevision: workspaceRevision,
          ),
        );
      } on Object catch (error) {
        failures.add(
          WorkspaceSearchFailure(
            documentId: entry.key,
            message: error.toString(),
          ),
        );
      }
    }
    documents.sort(
      (left, right) => left.documentId.compareTo(right.documentId),
    );
    return WorkspaceReplacePreview(
      documents: List<WorkspaceReplacePreviewDocument>.unmodifiable(documents),
      failures: List<WorkspaceSearchFailure>.unmodifiable(failures),
      truncated: search.truncated,
    );
  }

  Future<WorkspaceReplaceResult> _applyAtomically(
    WorkspaceReplacePreview preview,
    AtomicWorkspaceDocumentStore store,
  ) async {
    final pending = <DocumentState>[];
    final expectedDocumentRevisions = <String, int>{};
    final failures = <WorkspaceSearchFailure>[];
    final expectedWorkspaceRevisions = preview.documents
        .map((document) => document.workspaceRevision)
        .toSet();
    if (expectedWorkspaceRevisions.length != 1) {
      return WorkspaceReplaceResult(
        documents: const <WorkspaceReplaceDocumentResult>[],
        failures: const <WorkspaceSearchFailure>[
          WorkspaceSearchFailure(
            documentId: '',
            message: 'workspace_revision_conflict',
          ),
        ],
        truncated: preview.truncated,
      );
    }
    for (final candidate in preview.documents) {
      try {
        final current = await documentStore.loadDocument(candidate.documentId);
        if (current.revision != candidate.revision ||
            current.workspaceRevision != candidate.workspaceRevision ||
            current.text != candidate.beforeText) {
          failures.add(
            WorkspaceSearchFailure(
              documentId: candidate.documentId,
              message:
                  'document changed since replace preview revision ${candidate.revision}',
            ),
          );
          continue;
        }
        pending.add(
          DocumentState(
            documentId: candidate.documentId,
            text: candidate.afterText,
            revision: current.revision + 1,
            encoding: current.encoding,
            workspaceRevision: candidate.workspaceRevision,
            baseDocumentRevision: candidate.revision,
          ),
        );
        expectedDocumentRevisions[candidate.documentId] = current.revision;
      } on Object catch (error) {
        failures.add(
          WorkspaceSearchFailure(
            documentId: candidate.documentId,
            message: error.toString(),
          ),
        );
      }
    }
    if (failures.isNotEmpty) {
      return WorkspaceReplaceResult(
        documents: const <WorkspaceReplaceDocumentResult>[],
        failures: List<WorkspaceSearchFailure>.unmodifiable(failures),
        truncated: preview.truncated,
      );
    }
    try {
      final receipt = await store.saveDocumentsAtomically(
        pending,
        expectedWorkspaceRevision: expectedWorkspaceRevisions.single,
        expectedDocumentRevisions: expectedDocumentRevisions,
      );
      return WorkspaceReplaceResult(
        documents: <WorkspaceReplaceDocumentResult>[
          for (final candidate in preview.documents)
            WorkspaceReplaceDocumentResult(
              documentId: candidate.documentId,
              replacementCount: candidate.replacementCount,
              revision:
                  receipt.documentRevisions[candidate.documentId] ??
                  candidate.revision,
            ),
        ],
        truncated: preview.truncated,
        workspaceRevision: receipt.workspaceRevision,
      );
    } on Object catch (error) {
      return WorkspaceReplaceResult(
        documents: const <WorkspaceReplaceDocumentResult>[],
        failures: <WorkspaceSearchFailure>[
          for (final candidate in preview.documents)
            WorkspaceSearchFailure(
              documentId: candidate.documentId,
              message: error.toString(),
            ),
        ],
        truncated: preview.truncated,
      );
    }
  }
}

bool _hasOverlappingMatches(List<WorkspaceSearchMatch> matches) {
  for (var index = 1; index < matches.length; index += 1) {
    if (matches[index].range.start < matches[index - 1].range.end) return true;
  }
  return false;
}

String _replaceMatches(
  String text,
  List<WorkspaceSearchMatch> matches,
  String replacement,
) {
  final buffer = StringBuffer();
  var cursor = 0;
  for (final match in matches) {
    buffer
      ..write(text.substring(cursor, match.range.start))
      ..write(replacement);
    cursor = match.range.end;
  }
  buffer.write(text.substring(cursor));
  return buffer.toString();
}
