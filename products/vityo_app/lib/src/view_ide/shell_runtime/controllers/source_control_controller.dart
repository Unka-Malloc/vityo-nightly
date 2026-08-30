import 'package:flutter/foundation.dart';

import '../../../ide/workspace/workspace.dart';

class SourceControlController extends ChangeNotifier {
  SourceControlController({
    required this.statusController,
    required this.workspaceId,
    required this.dirtyDocumentPaths,
    required this.log,
    this.refreshResolvedDocument,
  });

  final SourceControlStatusController? statusController;
  final String Function() workspaceId;
  final List<String> Function() dirtyDocumentPaths;
  final void Function(String message) log;
  final Future<void> Function(String path)? refreshResolvedDocument;

  SourceControlCommitDraft? _commitDraft;
  bool _commitDialogOpen = false;
  SourceControlConflictResolutionResult? _lastConflictResolutionResult;

  SourceControlStatusSnapshot get statusSnapshot =>
      statusController?.snapshot ?? _localDirtyStatusSnapshot();
  SourceControlDiffSnapshot? get diffPreview => statusController?.diffPreview;
  SourceControlBranchSnapshot? get branchSnapshot =>
      statusController?.branchSnapshot;
  SourceControlHistorySnapshot? get historySnapshot =>
      statusController?.historySnapshot;
  SourceControlPartialPatchResult? get hunkActionResult =>
      statusController?.lastPartialPatchResult;
  SourceControlMergeWorkflowPlan get mergeWorkflowPlan =>
      statusController?.mergeWorkflowPlan ??
      SourceControlMergeWorkflowPlan.fromStatus(statusSnapshot);
  SourceControlMergeEditorSnapshot? get mergeEditorSnapshot =>
      statusController?.mergeEditorSnapshot;
  SourceControlConflictResolutionResult? get lastConflictResolutionResult =>
      _lastConflictResolutionResult ??
      statusController?.lastConflictResolutionResult;
  SourceControlCommitDraft? get commitDraft => _commitDraft;
  SourceControlCommitDialogState? get commitDialogState {
    final draft = _commitDraft;
    if (draft == null) {
      return null;
    }
    return SourceControlCommitDialogState.fromDraft(
      draft: draft,
      open: _commitDialogOpen,
    );
  }

  Future<SourceControlStatusSnapshot> refreshStatus() async {
    final snapshot = statusController == null
        ? _localDirtyStatusSnapshot()
        : await statusController!.refresh();
    log(refreshMessage(snapshot));
    notifyListeners();
    return snapshot;
  }

  Future<SourceControlDiffSnapshot> previewDiff(String path) async {
    final snapshot = statusController == null
        ? SourceControlDiffSnapshot(
            providerKind: SourceControlProviderKind.localDirtyDocuments,
            path: path.trim(),
            available: false,
            message:
                'Source control diff skipped: no source control controller is configured.',
          )
        : await statusController!.previewDiff(path);
    log(diffPreviewMessage(snapshot));
    notifyListeners();
    return snapshot;
  }

  Future<SourceControlActionResult> runAction(
    SourceControlActionRequest request,
  ) async {
    final result = statusController == null
        ? SourceControlActionResult(
            kind: request.kind,
            applied: false,
            paths: request.paths,
            message:
                'Source control action skipped: no source control controller is configured.',
          )
        : await statusController!.runAction(request);
    log(actionMessage(result));
    if (result.applied) {
      await refreshStatus();
    } else {
      notifyListeners();
    }
    return result;
  }

  Future<SourceControlBranchSnapshot> refreshBranches() async {
    final snapshot = statusController == null
        ? const SourceControlBranchSnapshot(
            providerKind: SourceControlProviderKind.localDirtyDocuments,
            available: false,
            message:
                'Source control branches skipped: no source control controller is configured.',
          )
        : await statusController!.refreshBranches();
    log(branchSnapshotMessage(snapshot));
    notifyListeners();
    return snapshot;
  }

  Future<SourceControlMergeEditorSnapshot> openMergeEditor(
    SourceControlConflictResolutionPlan plan,
  ) async {
    final controller = statusController;
    final snapshot = controller == null
        ? SourceControlMergeEditorSnapshot.unavailable(
            providerKind: statusSnapshot.providerKind,
            path: plan.path,
            message:
                'Source control merge editor skipped: no source control controller is configured.',
          )
        : await controller.openMergeEditor(plan);
    log(
      snapshot.available
          ? 'Source control merge editor opened for ${snapshot.path}.'
          : 'Source control merge editor unavailable for ${snapshot.path}: ${snapshot.message}',
    );
    notifyListeners();
    return snapshot;
  }

  Future<SourceControlConflictResolutionResult> resolveConflict({
    required SourceControlConflictResolutionPlan plan,
    required SourceControlConflictResolutionKind kind,
    String? resultText,
    int? expectedWorkingRevision,
  }) async {
    final dirtyPaths = dirtyDocumentPaths().toSet();
    if (dirtyPaths.contains(plan.path)) {
      final result = SourceControlConflictResolutionResult.rejected(
        path: plan.path,
        kind: kind,
        message:
            'Save or discard the unsaved editor buffer for ${plan.path} before applying a merge resolution.',
        metadata: const <String, Object?>{'reason': 'dirty-editor-buffer'},
      );
      _lastConflictResolutionResult = result;
      log(conflictResolutionMessage(result));
      notifyListeners();
      return result;
    }
    final controller = statusController;
    final result = controller == null
        ? SourceControlConflictResolutionResult.rejected(
            path: plan.path,
            kind: kind,
            message:
                'Source control conflict resolution skipped: no source control controller is configured.',
          )
        : await controller.resolveConflict(
            conflictPlan: plan,
            kind: kind,
            resultText: resultText,
            expectedWorkingRevision: expectedWorkingRevision,
          );
    _lastConflictResolutionResult = result;
    if (result.accepted) {
      try {
        await refreshResolvedDocument?.call(plan.path);
      } on Object {
        log(
          'Source control resolved ${plan.path}, but the editor view could not be refreshed.',
        );
      }
    }
    log(conflictResolutionMessage(result));
    notifyListeners();
    return result;
  }

  void closeMergeEditor() {
    statusController?.closeMergeEditor();
    notifyListeners();
  }

  Future<SourceControlBranchSwitchPlan> planBranchSwitch(
    String targetBranch,
  ) async {
    final controller = statusController;
    if (controller == null) {
      final plan = SourceControlBranchSwitchPlan.fromSnapshot(
        snapshot: const SourceControlBranchSnapshot(
          providerKind: SourceControlProviderKind.localDirtyDocuments,
          available: false,
          message:
              'Source control branch switch skipped: no source control controller is configured.',
        ),
        targetBranch: targetBranch,
      );
      log(branchSwitchPlanMessage(plan));
      notifyListeners();
      return plan;
    }
    if (controller.branchSnapshot == null) {
      await controller.refreshBranches();
    }
    final plan = controller.planBranchSwitch(targetBranch);
    log(branchSwitchPlanMessage(plan));
    notifyListeners();
    return plan;
  }

  SourceControlCommitDraft planCommitDraft({
    required String message,
    List<String>? selectedPaths,
    bool openDialog = true,
  }) {
    final stagedPaths = statusSnapshot.changes
        .where((change) => change.staged)
        .map((change) => change.path)
        .toList(growable: false);
    final draft = SourceControlCommitDraft(
      workspaceId: workspaceId(),
      message: message.trim(),
      selectedPaths: selectedPaths ?? stagedPaths,
    );
    final plan = draft.toCommitActionPlan();
    _commitDraft = draft;
    _commitDialogOpen = openDialog;
    log(
      plan.canRun
          ? 'Source control commit draft planned: ${plan.summary}.'
          : 'Source control commit draft blocked: ${plan.blockedReason}',
    );
    notifyListeners();
    return draft;
  }

  Future<SourceControlActionResult> confirmDiffAction(
    SourceControlDiffConfirmationPlan plan,
  ) {
    if (!plan.canRun) {
      final result = SourceControlActionResult(
        kind: plan.kind,
        applied: false,
        paths: <String>[plan.path],
        message: plan.blockedReason,
      );
      log(actionMessage(result));
      notifyListeners();
      return Future<SourceControlActionResult>.value(result);
    }
    return runAction(plan.toActionRequest());
  }

  Future<SourceControlPartialPatchResult> confirmHunkAction(
    SourceControlDiffHunkActionPlan plan,
  ) async {
    final result = statusController == null
        ? SourceControlPartialPatchResult(
            kind: plan.kind,
            path: plan.path,
            selectedHunkIndexes: plan.selectedHunkIndexes,
            applied: false,
            message:
                'Source control hunk action skipped: no source control controller is configured.',
          )
        : await statusController!.runHunkAction(plan);
    log(hunkActionMessage(result));
    if (result.applied) {
      await refreshStatus();
    } else {
      notifyListeners();
    }
    return result;
  }

  Future<void> planHunkAction(SourceControlDiffHunkActionPlan plan) async {
    if (plan.kind != SourceControlActionKind.discard ||
        statusController == null) {
      await confirmHunkAction(plan);
      return;
    }
    final confirmation = statusController!.planHunkDiscardConfirmation(plan);
    log(
      confirmation.readyForDialog
          ? 'Source control hunk discard confirmation planned: ${confirmation.confirmLabel} in ${confirmation.path}.'
          : 'Source control hunk discard confirmation blocked: ${confirmation.blockedReason}',
    );
    notifyListeners();
  }

  Future<SourceControlPartialPatchResult> confirmPendingHunkDiscard() async {
    final result = statusController == null
        ? const SourceControlPartialPatchResult(
            kind: SourceControlActionKind.discard,
            path: '',
            selectedHunkIndexes: <int>[],
            applied: false,
            message:
                'Source control hunk discard skipped: no source control controller is configured.',
          )
        : await statusController!.confirmPendingHunkDiscard();
    log(hunkActionMessage(result));
    if (result.applied) {
      await refreshStatus();
    } else {
      notifyListeners();
    }
    return result;
  }

  String refreshMessage(SourceControlStatusSnapshot snapshot) {
    if (!snapshot.available) {
      return snapshot.message.isEmpty
          ? 'Source control refresh failed.'
          : 'Source control refresh failed: ${snapshot.message}';
    }
    return 'Source control refreshed: ${snapshot.changes.length} change(s).';
  }

  String actionMessage(SourceControlActionResult result) {
    final action = result.kind.wireValue;
    if (!result.applied) {
      return result.message.isEmpty
          ? 'Source control $action failed.'
          : 'Source control $action failed: ${result.message}';
    }
    return result.message.isEmpty
        ? 'Source control $action applied to ${result.paths.length} path(s).'
        : 'Source control $action applied: ${result.message}';
  }

  String diffPreviewMessage(SourceControlDiffSnapshot snapshot) {
    if (!snapshot.available) {
      return snapshot.message.isEmpty
          ? 'Source control diff preview failed for ${snapshot.path}.'
          : 'Source control diff preview failed for ${snapshot.path}: ${snapshot.message}';
    }
    return 'Source control diff previewed for ${snapshot.path}: ${snapshot.lineCount} line(s).';
  }

  String branchSnapshotMessage(SourceControlBranchSnapshot snapshot) {
    if (!snapshot.available) {
      return snapshot.message.isEmpty
          ? 'Source control branches unavailable.'
          : 'Source control branches unavailable: ${snapshot.message}';
    }
    return 'Source control branches loaded: ${snapshot.branches.length} branch(es).';
  }

  String branchSwitchPlanMessage(SourceControlBranchSwitchPlan plan) {
    if (!plan.canRun) {
      return plan.blockedReason.isEmpty
          ? 'Source control branch switch plan blocked.'
          : 'Source control branch switch plan blocked: ${plan.blockedReason}';
    }
    return 'Source control branch switch planned: ${plan.summary}.';
  }

  String hunkActionMessage(SourceControlPartialPatchResult result) {
    if (result.message.isNotEmpty) {
      return result.message;
    }
    return result.applied
        ? 'Source control hunk action applied: ${result.kind.wireValue} ${result.selectedHunkIndexes.length} hunk(s).'
        : 'Source control hunk action failed: ${result.kind.wireValue} ${result.selectedHunkIndexes.length} hunk(s).';
  }

  String conflictResolutionMessage(
    SourceControlConflictResolutionResult result,
  ) {
    if (result.message.isNotEmpty) return result.message;
    return result.accepted
        ? 'Source control conflict resolved for ${result.path}.'
        : 'Source control conflict resolution failed for ${result.path}.';
  }

  SourceControlStatusSnapshot _localDirtyStatusSnapshot() {
    final changes = dirtyDocumentPaths()
        .map(
          (documentId) => SourceControlFileChange(
            path: documentId,
            unstagedStatus: SourceControlFileStatus.modified,
          ),
        )
        .toList(growable: false);
    return SourceControlStatusSnapshot(
      providerKind: SourceControlProviderKind.localDirtyDocuments,
      changes: List<SourceControlFileChange>.unmodifiable(changes),
      message: changes.isEmpty
          ? 'No dirty editor documents.'
          : 'Dirty editor documents.',
    );
  }
}
