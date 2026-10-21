// ignore_for_file: annotate_overrides

part of '../shell_runtime_model.dart';

/// Public workspace-document lifecycle facade backed by focused controllers.
mixin ShellRuntimeWorkspaceDocumentFacade on ShellRuntimeFacadeHost {
  WorkspaceFileCommandRouteResult?
  get pendingWorkspaceFileCommandConfirmation =>
      _workspaceFileCommandController.pendingConfirmation;
  WorkspaceFileExplorerSnapshot get workspaceFileExplorerSnapshot =>
      _workspaceFileExplorerController.snapshot;
  WorkspaceFileExplorerBatchActionPlan?
  get pendingWorkspaceFileBatchActionPlan =>
      _workspaceFileExplorerController.pendingBatchActionPlan;

  List<String> get cachedDocumentPaths =>
      _editorWorkspaceStateController.cachedDocumentPaths;
  List<String> get dirtyDocumentPaths =>
      _editorWorkspaceStateController.dirtyDocumentPaths;
  DocumentResourceBindingSnapshot get editorFileBindingSnapshot =>
      _editorFileBinding.snapshot;
  WorkspaceFileCloseRequestResult? get lastCloseRequestResult =>
      _workspaceDocumentController.lastCloseRequest;

  EditorCloseRequestSurface? get closeRequestSurface {
    final result = _workspaceDocumentController.lastCloseRequest;
    if (result == null) {
      return null;
    }
    if (result.requiresUserChoice &&
        !_editorWorkspaceStateController.isDirty(result.filePath)) {
      return null;
    }
    return EditorCloseRequestSurface(
      status: switch (result.status) {
        WorkspaceFileCloseRequestStatus.closed =>
          EditorCloseRequestSurfaceStatus.closed,
        WorkspaceFileCloseRequestStatus.blockedUnsavedChanges =>
          EditorCloseRequestSurfaceStatus.blockedUnsavedChanges,
        WorkspaceFileCloseRequestStatus.notOpen =>
          EditorCloseRequestSurfaceStatus.notOpen,
      },
      filePath: result.filePath,
      message: result.message,
      canSave: result.canSave,
      canDiscard: result.canDiscard,
      canSwitchToFile: result.canSwitchToFile,
    );
  }

  DocumentResourceBindingSnapshot markEditorResourceExternalChanged(
    DocumentState externalDocument,
  ) => _workspaceDocumentController.markExternalChanged(externalDocument);

  DocumentResourceBindingSnapshot acceptEditorExternalChange() =>
      _workspaceDocumentController.acceptExternalChange();

  WorkspaceFileCloseRequestResult requestCloseWorkspaceFile(String filePath) =>
      _workspaceDocumentController.requestClose(filePath);

  void clearCloseRequestResult() =>
      _workspaceDocumentController.clearCloseRequest();

  void switchToCloseRequestFile() =>
      _workspaceDocumentController.switchToCloseRequestFile();

  Future<DocumentResourceBindingSnapshot> saveActiveWorkspaceFileChanges() =>
      _workspacePersistenceController.saveActive();

  Future<WorkspaceSaveAllResult> saveAllWorkspaceFileChanges() =>
      _workspacePersistenceController.saveAll();

  Future<WorkspaceFileCloseRequestResult?>
  saveAndCloseRequestedWorkspaceFile() =>
      _workspacePersistenceController.saveAndCloseRequested();

  Future<DocumentResourceBindingSnapshot> discardActiveWorkspaceFileChanges() =>
      _workspaceDocumentController.discardActiveChanges();

  Future<WorkspaceFileCloseRequestResult?>
  discardAndCloseRequestedWorkspaceFile() =>
      _workspaceDocumentController.discardAndCloseRequested();

  Future<WorkspaceFileCommandRouteResult?>
  confirmPendingWorkspaceFileCommand() =>
      _workspaceFileConfirmationController.confirm();

  WorkspaceFileCommandRouteResult? cancelPendingWorkspaceFileCommand() =>
      _workspaceFileConfirmationController.cancel();

  Future<void> toggleWorkspaceExplorerDirectory(String path) =>
      _workspaceFileExplorerController.toggleDirectory(path);

  Future<void> selectWorkspaceExplorerPath(String path) =>
      _workspaceFileExplorerController.selectPath(path);

  Future<void> setWorkspaceExplorerSortMode(
    WorkspaceFileExplorerSortMode sortMode,
  ) => _workspaceFileExplorerController.setSortMode(sortMode);

  Future<WorkspaceFileExplorerDiscoveryResult?> refreshWorkspaceFileExplorer() {
    return _workspaceFileExplorerController.refreshFileSystem(
      rootPath: workspaceController.activeProject.workspaceRoot,
    );
  }

  Future<bool> openWorkspaceFileFromExplorer(String path) async {
    await _workspaceFileExplorerController.selectPath(path);
    final resolvedPath = _workspaceFileExplorerController.resolveWorkspacePath(
      path,
    );
    final registered = _workspaceFileExplorerController.containsWorkspacePath(
      resolvedPath,
    );
    if (!registered &&
        !_workspaceFileExplorerController.observesWorkspacePath(path)) {
      appendLog('Explorer could not open $path.');
      _notifyShellListeners();
      return false;
    }
    if (!registered) {
      final registeredPath = await _workspaceDocumentController
          .runWithoutWorkspaceLoad(
            () async => _workspaceFileExplorerController
                .registerObservedWorkspacePath(path),
          );
      if (registeredPath == null) {
        appendLog('Explorer could not open $path.');
        _notifyShellListeners();
        return false;
      }
    }
    final opened = await _workspaceDocumentController.openWorkspaceFile(
      resolvedPath,
    );
    if (opened) {
      await _workspaceFileExplorerController.revealPath(resolvedPath);
      appendLog('Explorer opened $resolvedPath.');
    } else {
      appendLog('Explorer could not open $resolvedPath.');
    }
    _notifyShellListeners();
    return opened;
  }

  Future<WorkspaceFileOperationResult> runWorkspaceFileExplorerAction(
    WorkspaceFileExplorerActionRequest request,
  ) async {
    final result = await _workspaceFileCommandController.runExplorerAction(
      request,
    );
    appendLog(result.message);
    _notifyShellListeners();
    return result;
  }

  WorkspaceFileExplorerBatchActionPlan stageWorkspaceFileBatchActions(
    List<WorkspaceFileExplorerActionRequest> requests,
  ) => _workspaceFileExplorerController.stageBatchActions(requests);

  Future<List<WorkspaceFileOperationResult>>
  confirmPendingWorkspaceFileBatchAction() async {
    final activePathBefore = workspaceController.activeFilePath;
    Future<List<WorkspaceFileOperationResult>> runBatch() async {
      final List<WorkspaceFileOperationResult> results =
          await _workspaceFileExplorerController.runPendingBatchAction(
            confirmed: true,
          );
      return results;
    }

    final results = await _workspaceDocumentController.runWithoutWorkspaceLoad(
      runBatch,
    );
    if (results.any((result) => result.applied) &&
        (results.any((result) => result.path == activePathBefore) ||
            workspaceController.activeFilePath != activePathBefore)) {
      await _workspaceDocumentController.loadActiveDocument();
    }
    if (results.isNotEmpty) {
      final appliedCount = results.where((result) => result.applied).length;
      appendLog(
        'Workspace file batch completed: $appliedCount/${results.length} applied.',
      );
    }
    _notifyShellListeners();
    return results;
  }

  void cancelPendingWorkspaceFileBatchAction() =>
      _workspaceFileExplorerController.cancelPendingAction();

  Future<void> persistEditorSession({String key = 'default'}) =>
      _workspaceDocumentController.persistSession(key: key);

  Future<EditorSessionSnapshot?> restoreEditorSession({
    String key = 'default',
  }) => _workspaceDocumentController.restoreSession(key: key);
}
