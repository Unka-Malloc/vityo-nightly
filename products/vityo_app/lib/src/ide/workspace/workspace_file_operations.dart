import '../editor/document_state.dart';
import 'workspace_controller.dart';
import 'workspace_document_store_types.dart';

enum WorkspaceFileOperationKind { create, rename, delete, reveal }

extension WorkspaceFileOperationKindX on WorkspaceFileOperationKind {
  String get wireValue {
    return switch (this) {
      WorkspaceFileOperationKind.create => 'create',
      WorkspaceFileOperationKind.rename => 'rename',
      WorkspaceFileOperationKind.delete => 'delete',
      WorkspaceFileOperationKind.reveal => 'reveal',
    };
  }
}

class WorkspaceFileOperationResult {
  const WorkspaceFileOperationResult({
    required this.kind,
    required this.applied,
    this.path = '',
    this.nextPath = '',
    this.message = '',
  });

  final WorkspaceFileOperationKind kind;
  final bool applied;
  final String path;
  final String nextPath;
  final String message;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'kind': kind.wireValue,
      'applied': applied,
      if (path.isNotEmpty) 'path': path,
      if (nextPath.isNotEmpty) 'nextPath': nextPath,
      if (message.isNotEmpty) 'message': message,
    };
  }
}

class WorkspaceFileOperationService {
  const WorkspaceFileOperationService({
    required this.workspaceController,
    required this.documentStore,
  });

  final WorkspaceController workspaceController;
  final WorkspaceDocumentStore documentStore;

  String resolvePath(String path) {
    return _resolveWorkspaceFilePath(workspaceController, path);
  }

  bool containsPath(String path) {
    final resolvedPath = resolvePath(path);
    return _workspaceContainsPath(workspaceController, resolvedPath);
  }

  Future<WorkspaceFileOperationResult> createFile({
    required String path,
    String text = '',
    bool open = false,
  }) async {
    final normalizedPath = _resolveWorkspaceFilePath(workspaceController, path);
    final pathFailure = _validateWorkspaceFilePath(
      normalizedPath,
      workspaceRoot: workspaceController.activeProject.workspaceRoot,
    );
    if (pathFailure != null) {
      return _blocked(WorkspaceFileOperationKind.create, path, pathFailure);
    }
    if (await documentStore.documentExists(normalizedPath) ||
        _workspaceContainsPath(workspaceController, normalizedPath)) {
      return _blocked(
        WorkspaceFileOperationKind.create,
        normalizedPath,
        'Workspace file already exists.',
      );
    }
    await documentStore.saveDocument(
      DocumentState(documentId: normalizedPath, text: text, revision: 1),
    );
    workspaceController.registerFile(normalizedPath, open: open);
    return WorkspaceFileOperationResult(
      kind: WorkspaceFileOperationKind.create,
      applied: true,
      path: normalizedPath,
      message: 'Workspace file created.',
    );
  }

  Future<WorkspaceFileOperationResult> renameFile({
    required String path,
    required String nextPath,
    bool open = false,
  }) async {
    final normalizedPath = _resolveWorkspaceFilePath(workspaceController, path);
    final normalizedNextPath = _resolveWorkspaceFilePath(
      workspaceController,
      nextPath,
    );
    final pathFailure =
        _validateWorkspaceFilePath(
          normalizedPath,
          workspaceRoot: workspaceController.activeProject.workspaceRoot,
        ) ??
        _validateWorkspaceFilePath(
          normalizedNextPath,
          workspaceRoot: workspaceController.activeProject.workspaceRoot,
        );
    if (pathFailure != null) {
      return _blocked(WorkspaceFileOperationKind.rename, path, pathFailure);
    }
    if (normalizedPath == normalizedNextPath) {
      return WorkspaceFileOperationResult(
        kind: WorkspaceFileOperationKind.rename,
        applied: false,
        path: normalizedPath,
        nextPath: normalizedNextPath,
        message: 'Workspace file rename skipped: path did not change.',
      );
    }
    if (!await documentStore.documentExists(normalizedPath)) {
      return _blocked(
        WorkspaceFileOperationKind.rename,
        normalizedPath,
        'Workspace file does not exist.',
      );
    }
    if (await documentStore.documentExists(normalizedNextPath) ||
        _workspaceContainsPath(workspaceController, normalizedNextPath)) {
      return _blocked(
        WorkspaceFileOperationKind.rename,
        normalizedPath,
        'Target workspace file already exists.',
        nextPath: normalizedNextPath,
      );
    }

    final document = await documentStore.loadDocument(normalizedPath);
    await documentStore.saveDocument(
      DocumentState(
        documentId: normalizedNextPath,
        text: document.text,
        revision: document.revision + 1,
      ),
    );
    await documentStore.deleteDocument(normalizedPath);
    final shouldOpen =
        open || workspaceController.activeFilePath == normalizedPath;
    workspaceController.unregisterFile(normalizedPath);
    workspaceController.registerFile(normalizedNextPath, open: shouldOpen);
    return WorkspaceFileOperationResult(
      kind: WorkspaceFileOperationKind.rename,
      applied: true,
      path: normalizedPath,
      nextPath: normalizedNextPath,
      message: 'Workspace file renamed.',
    );
  }

  Future<WorkspaceFileOperationResult> deleteFile(String path) async {
    final normalizedPath = _resolveWorkspaceFilePath(workspaceController, path);
    final pathFailure = _validateWorkspaceFilePath(
      normalizedPath,
      workspaceRoot: workspaceController.activeProject.workspaceRoot,
    );
    if (pathFailure != null) {
      return _blocked(WorkspaceFileOperationKind.delete, path, pathFailure);
    }
    if (!await documentStore.documentExists(normalizedPath) &&
        !_workspaceContainsPath(workspaceController, normalizedPath)) {
      return _blocked(
        WorkspaceFileOperationKind.delete,
        normalizedPath,
        'Workspace file does not exist.',
      );
    }
    await documentStore.deleteDocument(normalizedPath);
    workspaceController.unregisterFile(normalizedPath);
    return WorkspaceFileOperationResult(
      kind: WorkspaceFileOperationKind.delete,
      applied: true,
      path: normalizedPath,
      message: 'Workspace file deleted.',
    );
  }

  WorkspaceFileOperationResult revealFile(String path) {
    final normalizedPath = _resolveWorkspaceFilePath(workspaceController, path);
    final pathFailure = _validateWorkspaceFilePath(
      normalizedPath,
      workspaceRoot: workspaceController.activeProject.workspaceRoot,
    );
    if (pathFailure != null) {
      return _blocked(WorkspaceFileOperationKind.reveal, path, pathFailure);
    }
    if (!_workspaceContainsPath(workspaceController, normalizedPath)) {
      return _blocked(
        WorkspaceFileOperationKind.reveal,
        normalizedPath,
        'Workspace file is not part of the project file list.',
      );
    }
    workspaceController.openFile(normalizedPath);
    return WorkspaceFileOperationResult(
      kind: WorkspaceFileOperationKind.reveal,
      applied: true,
      path: normalizedPath,
      message: 'Workspace file revealed.',
    );
  }

  WorkspaceFileOperationResult _blocked(
    WorkspaceFileOperationKind kind,
    String path,
    String message, {
    String nextPath = '',
  }) {
    return WorkspaceFileOperationResult(
      kind: kind,
      applied: false,
      path: path,
      nextPath: nextPath,
      message: message,
    );
  }
}

String _normalizeWorkspaceFilePath(String path) {
  return path.trim().replaceAll('\\', '/');
}

String _resolveWorkspaceFilePath(
  WorkspaceController workspaceController,
  String path,
) {
  final normalizedPath = _normalizeWorkspaceFilePath(path);
  final workspaceUsesAbsolutePaths = workspaceController.files.any(
    (filePath) =>
        _isAbsoluteWorkspaceFilePath(_normalizeWorkspaceFilePath(filePath)),
  );
  final rawWorkspaceRoot = workspaceController.activeProject.workspaceRoot;
  final workspaceRoot = _normalizeWorkspaceFilePath(
    rawWorkspaceRoot,
  ).replaceFirst(RegExp(r'/+$'), '');
  late final String resolvedPath;
  if (_isAbsoluteWorkspaceFilePath(normalizedPath)) {
    if (workspaceUsesAbsolutePaths || workspaceRoot.isEmpty) {
      resolvedPath = normalizedPath;
    } else if (_workspacePathStartsWithRoot(normalizedPath, workspaceRoot)) {
      resolvedPath = normalizedPath.substring(workspaceRoot.length + 1);
    } else {
      resolvedPath = normalizedPath;
    }
  } else if (!workspaceUsesAbsolutePaths || workspaceRoot.isEmpty) {
    resolvedPath = normalizedPath;
  } else {
    resolvedPath = '$workspaceRoot/$normalizedPath';
  }
  for (final existingPath in workspaceController.files) {
    if (_workspacePathsEqual(
      existingPath,
      resolvedPath,
      workspaceRoot: rawWorkspaceRoot,
    )) {
      return existingPath;
    }
  }
  return _applyWorkspacePathStyle(
    resolvedPath,
    workspaceRoot: rawWorkspaceRoot,
    existingPaths: workspaceController.files,
  );
}

String? _validateWorkspaceFilePath(
  String path, {
  required String workspaceRoot,
}) {
  final normalizedPath = _normalizeWorkspaceFilePath(path);
  final normalizedRoot = _normalizeWorkspaceFilePath(
    workspaceRoot,
  ).replaceFirst(RegExp(r'/+$'), '');
  if (normalizedPath.isEmpty) {
    return 'Workspace file path is empty.';
  }
  if (normalizedPath.split('/').contains('..')) {
    return 'Workspace file path must stay inside the workspace.';
  }
  if (_isAbsoluteWorkspaceFilePath(normalizedPath)) {
    if (normalizedRoot.isEmpty ||
        _workspacePathsEqual(
          normalizedPath,
          normalizedRoot,
          workspaceRoot: normalizedRoot,
        ) ||
        !_workspacePathStartsWithRoot(normalizedPath, normalizedRoot)) {
      return 'Workspace file path must stay inside the workspace.';
    }
  }
  return null;
}

bool _isAbsoluteWorkspaceFilePath(String path) {
  final normalizedPath = _normalizeWorkspaceFilePath(path);
  return normalizedPath.startsWith('/') ||
      RegExp(r'^[A-Za-z]:/').hasMatch(normalizedPath);
}

bool _workspaceContainsPath(
  WorkspaceController workspaceController,
  String path,
) {
  return workspaceController.files.any(
    (candidate) => _workspacePathsEqual(
      candidate,
      path,
      workspaceRoot: workspaceController.activeProject.workspaceRoot,
    ),
  );
}

bool _workspacePathsEqual(
  String left,
  String right, {
  required String workspaceRoot,
}) {
  final normalizedLeft = _normalizeWorkspaceFilePath(left);
  final normalizedRight = _normalizeWorkspaceFilePath(right);
  if (_usesCaseInsensitiveWorkspacePaths(workspaceRoot)) {
    return normalizedLeft.toLowerCase() == normalizedRight.toLowerCase();
  }
  return normalizedLeft == normalizedRight;
}

bool _workspacePathStartsWithRoot(String path, String root) {
  final normalizedPath = _normalizeWorkspaceFilePath(path);
  final normalizedRoot = _normalizeWorkspaceFilePath(
    root,
  ).replaceFirst(RegExp(r'/+$'), '');
  final prefix = '$normalizedRoot/';
  if (_usesCaseInsensitiveWorkspacePaths(root)) {
    return normalizedPath.toLowerCase().startsWith(prefix.toLowerCase());
  }
  return normalizedPath.startsWith(prefix);
}

bool _usesCaseInsensitiveWorkspacePaths(String root) {
  final normalizedRoot = _normalizeWorkspaceFilePath(root);
  return RegExp(r'^[A-Za-z]:').hasMatch(normalizedRoot) ||
      normalizedRoot.startsWith('//');
}

String _applyWorkspacePathStyle(
  String path, {
  required String workspaceRoot,
  required Iterable<String> existingPaths,
}) {
  final prefersBackslash =
      workspaceRoot.contains('\\') ||
      existingPaths.any((existingPath) => existingPath.contains('\\'));
  return prefersBackslash ? path.replaceAll('/', '\\') : path;
}
