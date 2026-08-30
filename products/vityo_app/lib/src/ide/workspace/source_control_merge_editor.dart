import '../editor/document/document_state.dart';
import 'source_control_status.dart';
import 'workspace_document_store_types.dart';

/// A bounded, serializable description of one Git index conflict.
///
/// Source text is available to the merge surface at runtime, but [toJson]
/// intentionally records lengths and availability only so source code cannot
/// leak into telemetry or Agent context snapshots.
class SourceControlMergeEditorSnapshot {
  const SourceControlMergeEditorSnapshot({
    required this.providerKind,
    required this.path,
    required this.available,
    this.baseText = '',
    this.currentText = '',
    this.incomingText = '',
    this.workingText = '',
    this.baseAvailable = false,
    this.currentAvailable = false,
    this.incomingAvailable = false,
    this.workingExists = false,
    this.workingRevision,
    this.message = '',
  });

  const SourceControlMergeEditorSnapshot.unavailable({
    required SourceControlProviderKind providerKind,
    required String path,
    required String message,
  }) : this(
         providerKind: providerKind,
         path: path,
         available: false,
         message: message,
       );

  final SourceControlProviderKind providerKind;
  final String path;
  final bool available;
  final String baseText;
  final String currentText;
  final String incomingText;
  final String workingText;
  final bool baseAvailable;
  final bool currentAvailable;
  final bool incomingAvailable;
  final bool workingExists;
  final int? workingRevision;
  final String message;

  bool get hasUnresolvedMarkers =>
      SourceControlConflictMarkerResolver.hasUnresolvedMarkers(workingText);

  String? previewTextFor(SourceControlConflictResolutionKind kind) {
    return switch (kind) {
      SourceControlConflictResolutionKind.acceptCurrent =>
        currentAvailable ? currentText : '',
      SourceControlConflictResolutionKind.acceptIncoming =>
        incomingAvailable ? incomingText : '',
      SourceControlConflictResolutionKind.acceptBoth =>
        SourceControlConflictMarkerResolver.resolve(
          workingText,
          SourceControlConflictResolutionKind.acceptBoth,
        ),
      SourceControlConflictResolutionKind.markResolved => workingText,
      SourceControlConflictResolutionKind.openMergeEditor => workingText,
    };
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'providerKind': providerKind.wireValue,
      'path': path,
      'available': available,
      'baseAvailable': baseAvailable,
      'currentAvailable': currentAvailable,
      'incomingAvailable': incomingAvailable,
      'workingExists': workingExists,
      if (workingRevision != null) 'workingRevision': workingRevision,
      'baseLength': baseText.length,
      'currentLength': currentText.length,
      'incomingLength': incomingText.length,
      'workingLength': workingText.length,
      'hasUnresolvedMarkers': hasUnresolvedMarkers,
      if (message.isNotEmpty) 'message': message,
    };
  }
}

abstract class SourceControlMergeEditorProvider {
  const SourceControlMergeEditorProvider();

  SourceControlProviderKind get providerKind;

  Future<SourceControlMergeEditorSnapshot> openMergeEditor({
    required String workspaceRoot,
    required String path,
  });
}

/// Resolves standard Git conflict markers in one linear pass.
///
/// The resolver deliberately operates on the working-tree conflict markers for
/// "accept both". Concatenating complete stage-2 and stage-3 files would repeat
/// all unchanged context and corrupt the document.
class SourceControlConflictMarkerResolver {
  const SourceControlConflictMarkerResolver._();

  static bool hasUnresolvedMarkers(String source) {
    return RegExp(r'^<{7}(?: .*)?$', multiLine: true).hasMatch(source);
  }

  static String? resolve(
    String source,
    SourceControlConflictResolutionKind kind,
  ) {
    if (kind != SourceControlConflictResolutionKind.acceptCurrent &&
        kind != SourceControlConflictResolutionKind.acceptIncoming &&
        kind != SourceControlConflictResolutionKind.acceptBoth) {
      return null;
    }
    final output = StringBuffer();
    final current = StringBuffer();
    final incoming = StringBuffer();
    var state = _ConflictMarkerState.outside;
    var foundConflict = false;

    for (final line in _linesWithEndings(source)) {
      final marker = line.replaceFirst(RegExp(r'(?:\r\n|\r|\n)$'), '');
      if (_isLabeledMarker(marker, '<<<<<<<')) {
        if (state != _ConflictMarkerState.outside) return null;
        state = _ConflictMarkerState.current;
        foundConflict = true;
        current.clear();
        incoming.clear();
        continue;
      }
      if (_isLabeledMarker(marker, '|||||||')) {
        if (state != _ConflictMarkerState.current) return null;
        state = _ConflictMarkerState.base;
        continue;
      }
      if (marker == '=======') {
        if (state != _ConflictMarkerState.current &&
            state != _ConflictMarkerState.base) {
          return null;
        }
        state = _ConflictMarkerState.incoming;
        continue;
      }
      if (_isLabeledMarker(marker, '>>>>>>>')) {
        if (state != _ConflictMarkerState.incoming) return null;
        final currentText = current.toString();
        final incomingText = incoming.toString();
        if (kind == SourceControlConflictResolutionKind.acceptCurrent) {
          output.write(currentText);
        } else if (kind == SourceControlConflictResolutionKind.acceptIncoming) {
          output.write(incomingText);
        } else if (kind == SourceControlConflictResolutionKind.acceptBoth) {
          output.write(currentText);
          if (incomingText != currentText) output.write(incomingText);
        } else {
          return null;
        }
        state = _ConflictMarkerState.outside;
        continue;
      }

      if (state == _ConflictMarkerState.outside) {
        output.write(line);
      } else if (state == _ConflictMarkerState.current) {
        current.write(line);
      } else if (state == _ConflictMarkerState.incoming) {
        incoming.write(line);
      }
    }
    if (state != _ConflictMarkerState.outside || !foundConflict) return null;
    return output.toString();
  }

  static Iterable<String> _linesWithEndings(String source) sync* {
    final matches = RegExp(
      r'[^\r\n]*(?:\r\n|\r|\n)|[^\r\n]+$',
    ).allMatches(source);
    for (final match in matches) {
      final line = match.group(0);
      if (line != null && line.isNotEmpty) yield line;
    }
  }

  static bool _isLabeledMarker(String line, String marker) {
    return line == marker || line.startsWith('$marker ');
  }
}

enum _ConflictMarkerState { outside, current, base, incoming }

/// Production Git merge provider backed by the daemon's constrained command
/// bridge and the workspace document transaction store.
class GitSourceControlMergeProvider
    extends SourceControlConflictResolutionProvider
    implements SourceControlMergeEditorProvider {
  const GitSourceControlMergeProvider({
    required this.runner,
    required this.documentStore,
    required this.workspaceRoot,
    this.executable = 'git',
  });

  final SourceControlCommandRunner runner;
  final WorkspaceDocumentStore documentStore;
  final String workspaceRoot;
  final String executable;

  @override
  SourceControlProviderKind get providerKind => SourceControlProviderKind.git;

  static List<String> conflictStageArgumentsFor({
    required int stage,
    required String path,
  }) {
    return <String>['show', ':$stage:$path'];
  }

  @override
  bool supports(SourceControlConflictResolutionRequest request) {
    return request.providerKind == SourceControlProviderKind.git &&
        _normalizedConflictPath(request.path) != null;
  }

  @override
  Future<SourceControlMergeEditorSnapshot> openMergeEditor({
    required String workspaceRoot,
    required String path,
  }) async {
    return (await _loadConflict(
      workspaceRoot: workspaceRoot,
      path: path,
    )).snapshot;
  }

  @override
  Future<SourceControlConflictResolutionResult> resolve(
    SourceControlConflictResolutionRequest request,
  ) async {
    final path = _normalizedConflictPath(request.path);
    if (!request.canRun || path == null || !supports(request)) {
      return SourceControlConflictResolutionResult.rejected(
        path: request.path,
        kind: request.kind,
        message: request.blockedReason.isNotEmpty
            ? request.blockedReason
            : 'Source control conflict resolution requires a safe relative path.',
        metadata: const <String, Object?>{'reason': 'invalid-request'},
      );
    }

    final loaded = await _loadConflict(
      workspaceRoot: workspaceRoot,
      path: path,
    );
    final snapshot = loaded.snapshot;
    if (!snapshot.available) {
      return SourceControlConflictResolutionResult.rejected(
        path: path,
        kind: request.kind,
        message: snapshot.message,
        metadata: const <String, Object?>{'reason': 'conflict-unavailable'},
      );
    }
    if (request.expectedWorkingRevision != null &&
        request.expectedWorkingRevision != snapshot.workingRevision) {
      return SourceControlConflictResolutionResult.rejected(
        path: path,
        kind: request.kind,
        message:
            'The working document changed after the merge editor opened. Reload the conflict before applying a resolution.',
        metadata: const <String, Object?>{'reason': 'stale-document'},
      );
    }
    if (request.kind == SourceControlConflictResolutionKind.openMergeEditor) {
      return SourceControlConflictResolutionResult.accepted(
        path: path,
        kind: request.kind,
        message: 'Git merge editor content loaded for $path.',
      );
    }

    final resolution = _resolutionFor(request, loaded);
    if (resolution == null) {
      return SourceControlConflictResolutionResult.rejected(
        path: path,
        kind: request.kind,
        message:
            'The requested conflict resolution is incomplete or still contains conflict markers.',
        metadata: const <String, Object?>{'reason': 'unresolved-content'},
      );
    }

    try {
      if (resolution.deleteDocument) {
        await documentStore.deleteDocument(path);
      } else {
        final currentDocument = loaded.workingDocument;
        await documentStore.saveDocument(
          DocumentState(
            documentId: path,
            text: resolution.text,
            revision: (currentDocument?.revision ?? -1) + 1,
            encoding: currentDocument?.encoding,
          ),
        );
      }
    } on Object {
      return SourceControlConflictResolutionResult.rejected(
        path: path,
        kind: request.kind,
        message: 'The resolved document could not be saved.',
        metadata: const <String, Object?>{'reason': 'document-save-failed'},
      );
    }

    late final SourceControlCommandResult stageResult;
    try {
      stageResult = await runner(
        SourceControlCommandRequest(
          executable: executable,
          arguments: <String>['add', '--', path],
          workingDirectory: workspaceRoot,
        ),
      );
    } on Object {
      return SourceControlConflictResolutionResult.rejected(
        path: path,
        kind: request.kind,
        message:
            'The resolved document was saved, but the Git provider became unavailable before staging.',
        metadata: const <String, Object?>{
          'reason': 'git-stage-unavailable',
          'documentSaved': true,
        },
      );
    }
    if (stageResult.exitCode != 0) {
      return SourceControlConflictResolutionResult.rejected(
        path: path,
        kind: request.kind,
        message:
            'The resolved document was saved, but Git could not mark it resolved (exit ${stageResult.exitCode}).',
        metadata: const <String, Object?>{
          'reason': 'git-stage-failed',
          'documentSaved': true,
        },
      );
    }
    return SourceControlConflictResolutionResult.accepted(
      path: path,
      kind: request.kind,
      message: 'Resolved and staged $path.',
      metadata: <String, Object?>{
        'deleted': resolution.deleteDocument,
        'resultLength': resolution.text.length,
      },
    );
  }

  _MergeResolution? _resolutionFor(
    SourceControlConflictResolutionRequest request,
    _LoadedMergeConflict loaded,
  ) {
    final snapshot = loaded.snapshot;
    switch (request.kind) {
      case SourceControlConflictResolutionKind.openMergeEditor:
        return null;
      case SourceControlConflictResolutionKind.acceptCurrent:
        return snapshot.currentAvailable
            ? _MergeResolution.text(snapshot.currentText)
            : const _MergeResolution.delete();
      case SourceControlConflictResolutionKind.acceptIncoming:
        return snapshot.incomingAvailable
            ? _MergeResolution.text(snapshot.incomingText)
            : const _MergeResolution.delete();
      case SourceControlConflictResolutionKind.acceptBoth:
        final text = SourceControlConflictMarkerResolver.resolve(
          snapshot.workingText,
          SourceControlConflictResolutionKind.acceptBoth,
        );
        return text == null ? null : _MergeResolution.text(text);
      case SourceControlConflictResolutionKind.markResolved:
        final text =
            request.resultText ??
            (snapshot.workingExists ? snapshot.workingText : null);
        if (text == null ||
            SourceControlConflictMarkerResolver.hasUnresolvedMarkers(text)) {
          return null;
        }
        return _MergeResolution.text(text);
    }
  }

  Future<_LoadedMergeConflict> _loadConflict({
    required String workspaceRoot,
    required String path,
  }) async {
    final normalizedPath = _normalizedConflictPath(path);
    if (normalizedPath == null) {
      return _LoadedMergeConflict(
        snapshot: SourceControlMergeEditorSnapshot.unavailable(
          providerKind: providerKind,
          path: path.trim(),
          message: 'Git merge editor requires a safe relative path.',
        ),
      );
    }
    try {
      final stages = await Future.wait(<Future<_GitConflictStage>>[
        _readStage(workspaceRoot, normalizedPath, 1),
        _readStage(workspaceRoot, normalizedPath, 2),
        _readStage(workspaceRoot, normalizedPath, 3),
      ]);
      if (stages.any((stage) => stage.truncated)) {
        return _LoadedMergeConflict(
          snapshot: SourceControlMergeEditorSnapshot.unavailable(
            providerKind: providerKind,
            path: normalizedPath,
            message:
                'Git merge editor content exceeds the local service output limit.',
          ),
        );
      }
      if (!stages.any((stage) => stage.available)) {
        return _LoadedMergeConflict(
          snapshot: SourceControlMergeEditorSnapshot.unavailable(
            providerKind: providerKind,
            path: normalizedPath,
            message:
                'Git index conflict stages are unavailable for $normalizedPath.',
          ),
        );
      }
      final workingExists = await documentStore.documentExists(normalizedPath);
      final workingDocument = workingExists
          ? await documentStore.loadDocument(normalizedPath)
          : null;
      return _LoadedMergeConflict(
        workingDocument: workingDocument,
        snapshot: SourceControlMergeEditorSnapshot(
          providerKind: providerKind,
          path: normalizedPath,
          available: true,
          baseText: stages[0].text,
          currentText: stages[1].text,
          incomingText: stages[2].text,
          workingText: workingDocument?.text ?? '',
          baseAvailable: stages[0].available,
          currentAvailable: stages[1].available,
          incomingAvailable: stages[2].available,
          workingExists: workingExists,
          workingRevision: workingDocument?.revision,
          message:
              'Loaded Git base, current, incoming, and working-tree facts.',
        ),
      );
    } on Object {
      return _LoadedMergeConflict(
        snapshot: SourceControlMergeEditorSnapshot.unavailable(
          providerKind: providerKind,
          path: normalizedPath,
          message: 'Git merge editor content could not be loaded.',
        ),
      );
    }
  }

  Future<_GitConflictStage> _readStage(
    String workspaceRoot,
    String path,
    int stage,
  ) async {
    final result = await runner(
      SourceControlCommandRequest(
        executable: executable,
        arguments: conflictStageArgumentsFor(stage: stage, path: path),
        workingDirectory: workspaceRoot,
      ),
    );
    return _GitConflictStage(
      available: result.exitCode == 0 && !result.stdoutTruncated,
      truncated: result.stdoutTruncated,
      text: result.exitCode == 0 && !result.stdoutTruncated
          ? result.stdout
          : '',
    );
  }
}

class _LoadedMergeConflict {
  const _LoadedMergeConflict({required this.snapshot, this.workingDocument});

  final SourceControlMergeEditorSnapshot snapshot;
  final DocumentState? workingDocument;
}

class _GitConflictStage {
  const _GitConflictStage({
    required this.available,
    required this.truncated,
    required this.text,
  });

  final bool available;
  final bool truncated;
  final String text;
}

class _MergeResolution {
  const _MergeResolution.text(this.text) : deleteDocument = false;

  const _MergeResolution.delete() : text = '', deleteDocument = true;

  final String text;
  final bool deleteDocument;
}

String? _normalizedConflictPath(String path) {
  final normalized = path.trim().replaceAll(r'\', '/');
  if (normalized.isEmpty ||
      normalized.startsWith('-') ||
      normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:/').hasMatch(normalized) ||
      normalized.contains('\u0000') ||
      normalized.contains('\r') ||
      normalized.contains('\n') ||
      normalized.split('/').contains('..')) {
    return null;
  }
  return normalized;
}
