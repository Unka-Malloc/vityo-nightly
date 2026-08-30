import '../../commands/commands.dart';
import '../../../ide/workspace/workspace.dart';

/// Owns workspace-file command routing, destructive confirmation, and I/O.
final class WorkspaceFileCommandController {
  WorkspaceFileCommandController({
    required this.explorerController,
    required this.openWorkspaceFile,
    required this.reloadActiveDocument,
    required this.runWithoutWorkspaceReload,
    required this.isWorkspaceFileDirty,
  });

  final WorkspaceFileExplorerController explorerController;
  final Future<bool> Function(String filePath) openWorkspaceFile;
  final Future<void> Function() reloadActiveDocument;
  final Future<WorkspaceFileOperationResult> Function(
    Future<WorkspaceFileOperationResult> Function() action,
  )
  runWithoutWorkspaceReload;
  final bool Function(String filePath) isWorkspaceFileDirty;

  WorkspaceController get workspaceController =>
      explorerController.workspaceController;

  WorkspaceFileCommandRouteResult? _pendingConfirmation;

  WorkspaceFileCommandRouteResult? get pendingConfirmation =>
      _pendingConfirmation;

  Future<WorkspaceFileCommandRouteResult> execute({
    required AppCommandId commandId,
    required String input,
  }) async {
    final routed = const WorkspaceFileCommandRouter().route(
      commandId: commandId,
      input: input,
      context: WorkspaceFileCommandRouteContext(
        activeFilePath: workspaceController.activeFilePath,
        selectedFilePath: workspaceController.activeFilePath,
        openCreatedFiles: true,
      ),
    );
    final request = routed.request;
    if (request == null) {
      return routed;
    }
    if (routed.confirmationPlan?.destructive ?? false) {
      final staged = WorkspaceFileCommandRouteResult(
        commandId: commandId,
        status: WorkspaceFileCommandRouteStatus.routed,
        input: input,
        request: request,
        confirmationPlan: routed.confirmationPlan,
        message:
            '${routed.confirmationPlan!.title} staged for confirmation. Use the workspace file confirmation controls to apply or cancel it.',
      );
      _pendingConfirmation = staged;
      return staged;
    }
    final operationResult = await _run(request);
    return routed.withOperationResult(operationResult);
  }

  Future<WorkspaceFileCommandRouteResult?> confirm() async {
    final pending = _pendingConfirmation;
    final request = pending?.request;
    if (pending == null || request == null) {
      return null;
    }
    _pendingConfirmation = null;
    return pending.withOperationResult(await _run(request));
  }

  WorkspaceFileCommandRouteResult? cancel() {
    final pending = _pendingConfirmation;
    if (pending == null) {
      return null;
    }
    _pendingConfirmation = null;
    return WorkspaceFileCommandRouteResult(
      commandId: pending.commandId,
      status: WorkspaceFileCommandRouteStatus.blocked,
      input: pending.input,
      request: pending.request,
      confirmationPlan: pending.confirmationPlan,
      message:
          '${pending.confirmationPlan?.title ?? 'Workspace file command'} cancelled.',
    );
  }

  Future<WorkspaceFileOperationResult> runExplorerAction(
    WorkspaceFileExplorerActionRequest request,
  ) {
    return _run(request);
  }

  Future<WorkspaceFileOperationResult> _run(
    WorkspaceFileExplorerActionRequest request,
  ) async {
    if (request.kind == WorkspaceFileOperationKind.reveal) {
      final resolvedPath = explorerController.resolveWorkspacePath(
        request.path,
      );
      var registered = explorerController.containsWorkspacePath(resolvedPath);
      if (!registered &&
          explorerController.observesWorkspacePath(request.path)) {
        final registration = await runWithoutWorkspaceReload(() async {
          final registeredPath = explorerController
              .registerObservedWorkspacePath(request.path);
          return WorkspaceFileOperationResult(
            kind: WorkspaceFileOperationKind.reveal,
            applied: registeredPath != null,
            path: registeredPath ?? resolvedPath,
          );
        });
        registered = registration.applied;
      }
      if (!registered) {
        return WorkspaceFileOperationResult(
          kind: WorkspaceFileOperationKind.reveal,
          applied: false,
          path: resolvedPath,
          message: 'Workspace file is not part of the project file list.',
        );
      }
      final opened = await openWorkspaceFile(resolvedPath);
      if (opened) {
        await explorerController.revealPath(resolvedPath);
      }
      return WorkspaceFileOperationResult(
        kind: WorkspaceFileOperationKind.reveal,
        applied: opened,
        path: resolvedPath,
        message: opened
            ? 'Workspace file revealed.'
            : 'Workspace file reveal failed.',
      );
    }
    final resolvedPath = explorerController.resolveWorkspacePath(request.path);
    if ((request.kind == WorkspaceFileOperationKind.rename ||
            request.kind == WorkspaceFileOperationKind.delete) &&
        isWorkspaceFileDirty(resolvedPath)) {
      return WorkspaceFileOperationResult(
        kind: request.kind,
        applied: false,
        path: resolvedPath,
        nextPath: request.nextPath,
        message:
            'Save or discard unsaved changes before ${request.kind.wireValue}.',
      );
    }
    final activePathBefore = workspaceController.activeFilePath;
    final result = await runWithoutWorkspaceReload(
      () => explorerController.run(request),
    );
    if (result.applied &&
        (activePathBefore == result.path ||
            workspaceController.activeFilePath == result.nextPath ||
            (request.open &&
                workspaceController.activeFilePath == result.path))) {
      await reloadActiveDocument();
    }
    return result;
  }
}
