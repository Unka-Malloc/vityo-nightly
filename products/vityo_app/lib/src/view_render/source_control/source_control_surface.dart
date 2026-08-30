import 'package:flutter/material.dart';

import '../../ide/workspace/source_control_commit_draft_store.dart';
import '../../ide/workspace/source_control_merge_editor.dart';
import '../../ide/workspace/source_control_status.dart';
import '../platform/viewport_profile.dart';

class SourceControlSurface extends StatelessWidget {
  const SourceControlSurface({
    super.key,
    required this.viewportProfile,
    required this.workspaceFileCount,
    required this.changedDocumentIds,
    this.status,
    this.diffPreview,
    this.diffWindowBinding,
    this.commitDraft,
    this.commitDialogState,
    this.branchSnapshot,
    this.historySnapshot,
    this.adapterRegistry,
    this.lastHunkActionResult,
    this.pendingHunkDiscardConfirmation,
    this.mergeWorkflowPlan,
    this.mergeEditorSnapshot,
    this.lastConflictResolutionResult,
    this.onOpenFile,
    this.onSaveAll,
    this.onRefresh,
    this.onPreviewDiff,
    this.onStagePaths,
    this.onUnstagePaths,
    this.onSwitchBranch,
    this.onOpenCommit,
    this.onConfirmDiffAction,
    this.onSelectHunkAction,
    this.onConfirmHunkDiscard,
    this.onOpenMergeEditor,
    this.onApplyConflictResolution,
    this.onCloseMergeEditor,
  });

  final ViewportProfile viewportProfile;
  final int workspaceFileCount;
  final List<String> changedDocumentIds;
  final SourceControlStatusSnapshot? status;
  final SourceControlDiffSnapshot? diffPreview;
  final SourceControlDiffWindowBinding? diffWindowBinding;
  final SourceControlCommitDraft? commitDraft;
  final SourceControlCommitDialogState? commitDialogState;
  final SourceControlBranchSnapshot? branchSnapshot;
  final SourceControlHistorySnapshot? historySnapshot;
  final SourceControlProviderAdapterRegistry? adapterRegistry;
  final SourceControlPartialPatchResult? lastHunkActionResult;
  final SourceControlHunkDiscardConfirmationPlan?
  pendingHunkDiscardConfirmation;
  final SourceControlMergeWorkflowPlan? mergeWorkflowPlan;
  final SourceControlMergeEditorSnapshot? mergeEditorSnapshot;
  final SourceControlConflictResolutionResult? lastConflictResolutionResult;
  final Future<void> Function(String documentId)? onOpenFile;
  final Future<void> Function()? onSaveAll;
  final Future<void> Function()? onRefresh;
  final Future<void> Function(String documentId)? onPreviewDiff;
  final Future<void> Function(List<String> paths)? onStagePaths;
  final Future<void> Function(List<String> paths)? onUnstagePaths;
  final Future<void> Function(SourceControlBranchSwitchPlan plan)?
  onSwitchBranch;
  final Future<void> Function()? onOpenCommit;
  final Future<void> Function(SourceControlDiffConfirmationPlan plan)?
  onConfirmDiffAction;
  final Future<void> Function(SourceControlDiffHunkActionPlan plan)?
  onSelectHunkAction;
  final Future<void> Function()? onConfirmHunkDiscard;
  final Future<void> Function(SourceControlConflictResolutionPlan plan)?
  onOpenMergeEditor;
  final Future<void> Function(
    SourceControlConflictResolutionPlan plan,
    SourceControlConflictResolutionKind kind,
    String? resultText,
    int? expectedWorkingRevision,
  )?
  onApplyConflictResolution;
  final VoidCallback? onCloseMergeEditor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = viewportProfile.isMobile;
    final providerKind =
        status?.providerKind.wireValue ?? 'local-dirty-documents';
    final gitChanges = status?.changes ?? const <SourceControlFileChange>[];
    final statusAvailable = status?.available ?? true;
    final stagedPaths = gitChanges
        .where((change) => change.staged)
        .map((change) => change.path)
        .toList(growable: false);
    final unstagedPaths = gitChanges
        .where((change) => change.unstaged)
        .map((change) => change.path)
        .toList(growable: false);
    final providerAdapters =
        adapterRegistry?.adapters ??
        const <SourceControlProviderAdapterDescriptor>[];
    final activeDiffWindowBinding =
        diffWindowBinding ??
        (diffPreview == null
            ? null
            : SourceControlDiffWindowBinding(snapshot: diffPreview!));
    final activeDiffWindow = activeDiffWindowBinding?.window;
    final activeMergeWorkflow =
        mergeWorkflowPlan ??
        (status == null
            ? null
            : SourceControlMergeWorkflowPlan.fromStatus(status!));

    return Card(
      key: const ValueKey('source-control-surface'),
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 18),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Source Control', style: theme.textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(
                'Review working-tree changes, stage precise hunks, inspect history, switch branches, and resolve Git conflicts without leaving the IDE.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  Chip(label: Text('workspace-files $workspaceFileCount')),
                  Chip(label: Text('changed ${changedDocumentIds.length}')),
                  Chip(label: Text('provider $providerKind')),
                  if (!statusAvailable)
                    const Chip(label: Text('provider unavailable')),
                  if (status?.branchName.isNotEmpty == true)
                    Chip(label: Text('branch ${status!.branchName}')),
                  if (branchSnapshot != null)
                    Chip(
                      label: Text(
                        'branches ${branchSnapshot!.branches.length}',
                      ),
                    ),
                  if (historySnapshot != null)
                    Chip(
                      label: Text('history ${historySnapshot!.entries.length}'),
                    ),
                  if (providerAdapters.isNotEmpty)
                    Chip(label: Text('providers ${providerAdapters.length}')),
                  if (commitDraft != null)
                    Chip(
                      label: Text(
                        commitDraft!.hasMessage
                            ? 'draft ready'
                            : 'draft pending',
                      ),
                    ),
                  if (commitDialogState != null)
                    Chip(
                      label: Text(
                        'commit-dialog ${commitDialogState!.status.wireValue}',
                      ),
                    ),
                  if (status != null)
                    Chip(label: Text('git ${gitChanges.length}')),
                  if (status != null)
                    Chip(label: Text('staged ${stagedPaths.length}')),
                  if (status != null)
                    Chip(label: Text('unstaged ${unstagedPaths.length}')),
                  if ((activeMergeWorkflow?.conflictCount ?? 0) > 0)
                    Chip(
                      label: Text(
                        'conflicts ${activeMergeWorkflow!.conflictCount}',
                      ),
                    ),
                ],
              ),
              if (commitDraft != null ||
                  branchSnapshot != null ||
                  historySnapshot != null ||
                  providerAdapters.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    if (commitDraft != null)
                      _CommitDraftCard(
                        draft: commitDraft!,
                        dialogState: commitDialogState,
                      ),
                    if (branchSnapshot != null)
                      _BranchPickerSummary(
                        snapshot: branchSnapshot!,
                        onSwitchBranch: onSwitchBranch,
                      ),
                    if (historySnapshot != null)
                      _HistorySummary(snapshot: historySnapshot!),
                    if (providerAdapters.isNotEmpty)
                      _ProviderAdapterSummary(adapters: providerAdapters),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              if (!statusAvailable && status?.message.isNotEmpty == true) ...[
                Text(
                  status!.message,
                  key: const ValueKey('source-control-provider-message'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('source-control-save-all'),
                    onPressed: changedDocumentIds.isEmpty ? null : onSaveAll,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save All'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('source-control-refresh'),
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Refresh'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('source-control-stage-all'),
                    onPressed: unstagedPaths.isEmpty || onStagePaths == null
                        ? null
                        : () {
                            onStagePaths!(unstagedPaths);
                          },
                    icon: const Icon(Icons.add_task_rounded),
                    label: const Text('Stage All'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('source-control-unstage-all'),
                    onPressed: stagedPaths.isEmpty || onUnstagePaths == null
                        ? null
                        : () {
                            onUnstagePaths!(stagedPaths);
                          },
                    icon: const Icon(Icons.remove_done_rounded),
                    label: const Text('Unstage All'),
                  ),
                  FilledButton.tonalIcon(
                    key: const ValueKey('source-control-open-commit'),
                    onPressed: stagedPaths.isEmpty ? null : onOpenCommit,
                    icon: const Icon(Icons.commit_rounded),
                    label: const Text('Commit...'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (activeMergeWorkflow?.canOpenMergeWorkflow == true) ...[
                _SourceControlMergeWorkflow(
                  viewportProfile: viewportProfile,
                  workflowPlan: activeMergeWorkflow!,
                  editorSnapshot: mergeEditorSnapshot,
                  lastResult: lastConflictResolutionResult,
                  dirtyDocumentPaths: changedDocumentIds,
                  onOpenMergeEditor: onOpenMergeEditor,
                  onApplyResolution: onApplyConflictResolution,
                  onCloseMergeEditor: onCloseMergeEditor,
                ),
                const SizedBox(height: 12),
              ],
              if (gitChanges.isNotEmpty) ...[
                Text('Git Changes', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                SizedBox(
                  height: compact ? 160 : 220,
                  child: ListView.separated(
                    key: const ValueKey('source-control-git-change-list'),
                    itemCount: gitChanges.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final change = gitChanges[index];
                      return ListTile(
                        key: ValueKey(
                          'source-control-git-change-${change.path}',
                        ),
                        dense: true,
                        leading: const Icon(Icons.account_tree_outlined),
                        title: Text(change.path),
                        subtitle: Text(change.summary),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (change.originalPath.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Text('from ${change.originalPath}'),
                              ),
                            IconButton(
                              key: ValueKey(
                                'source-control-preview-diff-${change.path}',
                              ),
                              tooltip: 'Preview diff',
                              onPressed: onPreviewDiff == null
                                  ? null
                                  : () {
                                      onPreviewDiff!(change.path);
                                    },
                              icon: const Icon(Icons.difference_outlined),
                            ),
                          ],
                        ),
                        onTap: onOpenFile == null
                            ? null
                            : () {
                                onOpenFile!(change.path);
                              },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (diffPreview != null) ...[
                Text('Diff Preview', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  key: const ValueKey('source-control-diff-review-summary'),
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    Chip(
                      label: Text(
                        'hunks ${diffPreview!.reviewSummary.hunkCount}',
                      ),
                    ),
                    Chip(
                      label: Text(
                        '+${diffPreview!.reviewSummary.additionCount} -${diffPreview!.reviewSummary.deletionCount}',
                      ),
                    ),
                    Chip(
                      label: Text(
                        'diff-lines ${diffPreview!.reviewSummary.lineCount}',
                      ),
                    ),
                    Chip(
                      label: Text(
                        'virtual-window ${activeDiffWindow!.startLine}-${activeDiffWindow.endLine}/${activeDiffWindow.totalLineCount}',
                      ),
                    ),
                    if (activeDiffWindow.hasPrevious)
                      const Chip(label: Text('has previous window')),
                    if (activeDiffWindow.hasNext)
                      const Chip(label: Text('has next window')),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  key: const ValueKey('source-control-diff-preview'),
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 180),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      activeDiffWindowBinding!.visibleText,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _DiffConfirmationControls(
                  snapshot: diffPreview!,
                  onConfirmDiffAction: onConfirmDiffAction,
                ),
                const SizedBox(height: 8),
                _DiffHunkActionSelection(
                  snapshot: diffPreview!,
                  lastHunkActionResult: lastHunkActionResult,
                  pendingHunkDiscardConfirmation:
                      pendingHunkDiscardConfirmation,
                  onSelectHunkAction: onSelectHunkAction,
                  onConfirmHunkDiscard: onConfirmHunkDiscard,
                ),
                const SizedBox(height: 12),
              ],
              Text('Changes', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              if (changedDocumentIds.isEmpty)
                Text(
                  'No dirty editor documents are currently tracked.',
                  style: theme.textTheme.bodySmall,
                )
              else
                SizedBox(
                  height: compact ? 160 : 220,
                  child: ListView.separated(
                    key: const ValueKey('source-control-change-list'),
                    itemCount: changedDocumentIds.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final documentId = changedDocumentIds[index];
                      return ListTile(
                        key: ValueKey('source-control-change-$documentId'),
                        dense: true,
                        leading: const Icon(Icons.edit_note_rounded),
                        title: Text(documentId),
                        subtitle: const Text('modified in editor buffer'),
                        trailing: const Icon(Icons.open_in_new_rounded),
                        onTap: onOpenFile == null
                            ? null
                            : () {
                                onOpenFile!(documentId);
                              },
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceControlMergeWorkflow extends StatefulWidget {
  const _SourceControlMergeWorkflow({
    required this.viewportProfile,
    required this.workflowPlan,
    required this.editorSnapshot,
    required this.lastResult,
    required this.dirtyDocumentPaths,
    required this.onOpenMergeEditor,
    required this.onApplyResolution,
    required this.onCloseMergeEditor,
  });

  final ViewportProfile viewportProfile;
  final SourceControlMergeWorkflowPlan workflowPlan;
  final SourceControlMergeEditorSnapshot? editorSnapshot;
  final SourceControlConflictResolutionResult? lastResult;
  final List<String> dirtyDocumentPaths;
  final Future<void> Function(SourceControlConflictResolutionPlan plan)?
  onOpenMergeEditor;
  final Future<void> Function(
    SourceControlConflictResolutionPlan plan,
    SourceControlConflictResolutionKind kind,
    String? resultText,
    int? expectedWorkingRevision,
  )?
  onApplyResolution;
  final VoidCallback? onCloseMergeEditor;

  @override
  State<_SourceControlMergeWorkflow> createState() =>
      _SourceControlMergeWorkflowState();
}

class _SourceControlMergeWorkflowState
    extends State<_SourceControlMergeWorkflow> {
  late final TextEditingController _resultController;
  SourceControlConflictResolutionKind _selectedKind =
      SourceControlConflictResolutionKind.markResolved;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _resultController = TextEditingController(
      text: widget.editorSnapshot?.workingText ?? '',
    );
  }

  @override
  void didUpdateWidget(covariant _SourceControlMergeWorkflow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.editorSnapshot;
    final next = widget.editorSnapshot;
    if (previous?.path != next?.path ||
        previous?.workingRevision != next?.workingRevision ||
        previous?.workingText != next?.workingText) {
      _selectedKind = SourceControlConflictResolutionKind.markResolved;
      _resultController.value = TextEditingValue(
        text: next?.workingText ?? '',
        selection: TextSelection.collapsed(
          offset: next?.workingText.length ?? 0,
        ),
      );
    }
  }

  @override
  void dispose() {
    _resultController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = widget.editorSnapshot;
    final activePlan = snapshot == null ? null : _planForPath(snapshot.path);
    final dirtyEditor =
        activePlan != null &&
        widget.dirtyDocumentPaths.contains(activePlan.path);
    final resultHasMarkers =
        SourceControlConflictMarkerResolver.hasUnresolvedMarkers(
          _resultController.text,
        );
    final canApply =
        !_applying &&
        snapshot?.available == true &&
        activePlan != null &&
        !dirtyEditor &&
        widget.onApplyResolution != null &&
        (_selectedKind != SourceControlConflictResolutionKind.markResolved ||
            !resultHasMarkers);

    return Container(
      key: const ValueKey('source-control-merge-workflow'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.13),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.34),
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.merge_type_rounded, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Merge Conflicts',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Chip(label: Text('${widget.workflowPlan.conflictCount} files')),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Inspect base, current, and incoming content. Every write is confirmed per file, revision-checked, then staged only after the workspace save succeeds.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView.separated(
              key: const ValueKey('source-control-conflict-list'),
              shrinkWrap: true,
              itemCount: widget.workflowPlan.conflictPlans.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final plan = widget.workflowPlan.conflictPlans[index];
                final isActive = snapshot?.path == plan.path;
                final hasDirtyEditor = widget.dirtyDocumentPaths.contains(
                  plan.path,
                );
                return Material(
                  color: isActive
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(10),
                  child: ListTile(
                    key: ValueKey('source-control-conflict-${plan.path}'),
                    dense: true,
                    leading: Icon(
                      isActive
                          ? Icons.merge_rounded
                          : Icons.warning_amber_rounded,
                    ),
                    title: Text(plan.path),
                    subtitle: Text(
                      hasDirtyEditor
                          ? 'Unsaved editor buffer must be handled first.'
                          : 'Three-way merge is ready for review.',
                    ),
                    trailing: OutlinedButton.icon(
                      key: ValueKey(
                        'source-control-open-merge-editor-${plan.path}',
                      ),
                      onPressed:
                          plan.canResolve && widget.onOpenMergeEditor != null
                          ? () => widget.onOpenMergeEditor!(plan)
                          : null,
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: Text(isActive ? 'Reload' : 'Open'),
                    ),
                  ),
                );
              },
            ),
          ),
          if (snapshot != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Merge Editor · ${snapshot.path}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  key: const ValueKey('source-control-close-merge-editor'),
                  tooltip: 'Close merge editor',
                  onPressed: widget.onCloseMergeEditor,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            if (!snapshot.available)
              Text(
                snapshot.message,
                key: const ValueKey('source-control-merge-editor-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              )
            else ...[
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  Chip(
                    label: Text(
                      snapshot.workingRevision == null
                          ? 'working deleted'
                          : 'revision ${snapshot.workingRevision}',
                    ),
                  ),
                  if (snapshot.hasUnresolvedMarkers)
                    const Chip(label: Text('working tree has markers')),
                  if (!snapshot.baseAvailable)
                    const Chip(label: Text('base unavailable')),
                  if (!snapshot.currentAvailable)
                    const Chip(label: Text('current deletes file')),
                  if (!snapshot.incomingAvailable)
                    const Chip(label: Text('incoming deletes file')),
                ],
              ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, constraints) {
                  final paneWidth = constraints.maxWidth >= 900
                      ? (constraints.maxWidth - 16) / 3
                      : constraints.maxWidth;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SizedBox(
                        width: paneWidth,
                        child: _MergeSourcePane(
                          title: 'Base',
                          text: snapshot.baseText,
                          available: snapshot.baseAvailable,
                        ),
                      ),
                      SizedBox(
                        width: paneWidth,
                        child: _MergeSourcePane(
                          title: 'Current',
                          text: snapshot.currentText,
                          available: snapshot.currentAvailable,
                        ),
                      ),
                      SizedBox(
                        width: paneWidth,
                        child: _MergeSourcePane(
                          title: 'Incoming',
                          text: snapshot.incomingText,
                          available: snapshot.incomingAvailable,
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('source-control-use-current'),
                    onPressed: () => _selectResolution(
                      SourceControlConflictResolutionKind.acceptCurrent,
                    ),
                    icon: const Icon(Icons.arrow_downward_rounded),
                    label: Text(
                      snapshot.currentAvailable
                          ? 'Use Current'
                          : 'Accept Current Deletion',
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('source-control-use-incoming'),
                    onPressed: () => _selectResolution(
                      SourceControlConflictResolutionKind.acceptIncoming,
                    ),
                    icon: const Icon(Icons.arrow_downward_rounded),
                    label: Text(
                      snapshot.incomingAvailable
                          ? 'Use Incoming'
                          : 'Accept Incoming Deletion',
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('source-control-use-both'),
                    onPressed:
                        snapshot.previewTextFor(
                              SourceControlConflictResolutionKind.acceptBoth,
                            ) ==
                            null
                        ? null
                        : () => _selectResolution(
                            SourceControlConflictResolutionKind.acceptBoth,
                          ),
                    icon: const Icon(Icons.call_merge_rounded),
                    label: const Text('Use Both'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('source-control-merge-result'),
                controller: _resultController,
                minLines: widget.viewportProfile.isMobile ? 6 : 8,
                maxLines: widget.viewportProfile.isMobile ? 10 : 14,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
                decoration: const InputDecoration(
                  labelText: 'Resolved result',
                  helperText:
                      'Editing this result switches to a custom resolution.',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
                onChanged: (_) {
                  if (_selectedKind !=
                      SourceControlConflictResolutionKind.markResolved) {
                    setState(() {
                      _selectedKind =
                          SourceControlConflictResolutionKind.markResolved;
                    });
                  } else {
                    setState(() {});
                  }
                },
              ),
              const SizedBox(height: 8),
              if (dirtyEditor)
                Text(
                  'Save or discard the unsaved editor buffer before applying this resolution.',
                  key: const ValueKey('source-control-merge-dirty-block'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                )
              else if (_selectedKind ==
                      SourceControlConflictResolutionKind.markResolved &&
                  resultHasMarkers)
                Text(
                  'Remove every remaining conflict marker before applying a custom result.',
                  key: const ValueKey('source-control-merge-marker-block'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              const SizedBox(height: 6),
              FilledButton.icon(
                key: const ValueKey('source-control-apply-merge-result'),
                onPressed: canApply ? () => _confirmApply(activePlan) : null,
                icon: _applying
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.task_alt_rounded),
                label: Text(
                  _applying ? 'Applying...' : 'Apply Resolution & Stage',
                ),
              ),
            ],
          ],
          if (widget.lastResult case final result?) ...[
            const SizedBox(height: 10),
            Container(
              key: const ValueKey('source-control-conflict-result'),
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: result.accepted
                    ? theme.colorScheme.secondaryContainer
                    : theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(result.message, style: theme.textTheme.bodySmall),
            ),
          ],
        ],
      ),
    );
  }

  SourceControlConflictResolutionPlan? _planForPath(String path) {
    for (final plan in widget.workflowPlan.conflictPlans) {
      if (plan.path == path) return plan;
    }
    return null;
  }

  void _selectResolution(SourceControlConflictResolutionKind kind) {
    final snapshot = widget.editorSnapshot;
    if (snapshot == null) return;
    final preview = snapshot.previewTextFor(kind);
    if (preview == null) return;
    setState(() {
      _selectedKind = kind;
      _resultController.value = TextEditingValue(
        text: preview,
        selection: TextSelection.collapsed(offset: preview.length),
      );
    });
  }

  Future<void> _confirmApply(SourceControlConflictResolutionPlan plan) async {
    final snapshot = widget.editorSnapshot;
    if (snapshot == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          key: const ValueKey('source-control-merge-confirmation-dialog'),
          title: const Text('Apply merge resolution?'),
          content: Text(
            '${plan.path}\n\nThis writes the reviewed result and stages only this file. The working revision is checked before the write.',
          ),
          actions: [
            TextButton(
              key: const ValueKey('source-control-cancel-merge-result'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('source-control-confirm-merge-result'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Apply & Stage'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    setState(() => _applying = true);
    try {
      await widget.onApplyResolution?.call(
        plan,
        _selectedKind,
        _selectedKind == SourceControlConflictResolutionKind.markResolved
            ? _resultController.text
            : null,
        snapshot.workingRevision,
      );
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }
}

class _MergeSourcePane extends StatelessWidget {
  const _MergeSourcePane({
    required this.title,
    required this.text,
    required this.available,
  });

  final String title;
  final String text;
  final bool available;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 150,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Expanded(
            child: SingleChildScrollView(
              child: SelectableText(
                available ? text : 'File is deleted on this side.',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: available ? null : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiffConfirmationControls extends StatelessWidget {
  const _DiffConfirmationControls({
    required this.snapshot,
    this.onConfirmDiffAction,
  });

  final SourceControlDiffSnapshot snapshot;
  final Future<void> Function(SourceControlDiffConfirmationPlan plan)?
  onConfirmDiffAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stagePlan = SourceControlDiffConfirmationPlan.fromDiff(
      snapshot: snapshot,
      kind: SourceControlActionKind.stage,
    );
    final discardPlan = SourceControlDiffConfirmationPlan.fromDiff(
      snapshot: snapshot,
      kind: SourceControlActionKind.discard,
    );
    return Container(
      key: const ValueKey('source-control-diff-confirmation'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Diff confirmation', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Apply a whole-file action here, or use the hunk controls below for a narrower change.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(
                label: Text(
                  '+${stagePlan.reviewSummary.additionCount} -${stagePlan.reviewSummary.deletionCount}',
                ),
              ),
              Chip(label: Text('stage risk ${stagePlan.risk.wireValue}')),
              Chip(label: Text('discard risk ${discardPlan.risk.wireValue}')),
              if (discardPlan.requiresConfirmation)
                const Chip(label: Text('discard requires confirmation')),
              if (!stagePlan.canRun) Chip(label: Text(stagePlan.blockedReason)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const ValueKey('source-control-confirm-diff-stage'),
                onPressed: stagePlan.canRun && onConfirmDiffAction != null
                    ? () {
                        onConfirmDiffAction!(stagePlan);
                      }
                    : null,
                icon: const Icon(Icons.add_task_rounded),
                label: const Text('Stage Reviewed Diff'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('source-control-confirm-diff-discard'),
                onPressed: discardPlan.canRun && onConfirmDiffAction != null
                    ? () {
                        onConfirmDiffAction!(discardPlan);
                      }
                    : null,
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Discard Reviewed Diff'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DiffHunkActionSelection extends StatelessWidget {
  const _DiffHunkActionSelection({
    required this.snapshot,
    this.lastHunkActionResult,
    this.pendingHunkDiscardConfirmation,
    this.onSelectHunkAction,
    this.onConfirmHunkDiscard,
  });

  final SourceControlDiffSnapshot snapshot;
  final SourceControlPartialPatchResult? lastHunkActionResult;
  final SourceControlHunkDiscardConfirmationPlan?
  pendingHunkDiscardConfirmation;
  final Future<void> Function(SourceControlDiffHunkActionPlan plan)?
  onSelectHunkAction;
  final Future<void> Function()? onConfirmHunkDiscard;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hunks = snapshot.hunks;
    return Container(
      key: const ValueKey('source-control-hunk-action-selection'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Hunk action selection', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Select hunk-level stage/discard plans and route them through the configured SCM partial patch provider.',
            style: theme.textTheme.bodySmall,
          ),
          if (lastHunkActionResult != null) ...[
            const SizedBox(height: 8),
            _HunkActionResultRow(result: lastHunkActionResult!),
          ],
          if (pendingHunkDiscardConfirmation != null) ...[
            const SizedBox(height: 8),
            _HunkDiscardConfirmationCard(
              plan: pendingHunkDiscardConfirmation!,
              onConfirmHunkDiscard: onConfirmHunkDiscard,
            ),
          ],
          const SizedBox(height: 8),
          if (hunks.isEmpty)
            Text(
              'No parsed diff hunks are available.',
              style: theme.textTheme.bodySmall,
            )
          else
            for (final hunk in hunks.take(6))
              Card(
                key: ValueKey('source-control-hunk-${hunk.hunkIndex}'),
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(hunk.summary, style: theme.textTheme.labelLarge),
                      const SizedBox(height: 2),
                      Text(hunk.header, style: theme.textTheme.bodySmall),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          OutlinedButton.icon(
                            key: ValueKey(
                              'source-control-hunk-stage-${hunk.hunkIndex}',
                            ),
                            onPressed: onSelectHunkAction == null
                                ? null
                                : () {
                                    onSelectHunkAction!(
                                      SourceControlDiffHunkActionPlan.fromDiff(
                                        snapshot: snapshot,
                                        kind: SourceControlActionKind.stage,
                                        selectedHunkIndexes: <int>[
                                          hunk.hunkIndex,
                                        ],
                                      ),
                                    );
                                  },
                            icon: const Icon(Icons.add_task_rounded),
                            label: const Text('Stage Hunk'),
                          ),
                          OutlinedButton.icon(
                            key: ValueKey(
                              'source-control-hunk-discard-${hunk.hunkIndex}',
                            ),
                            onPressed: onSelectHunkAction == null
                                ? null
                                : () {
                                    onSelectHunkAction!(
                                      SourceControlDiffHunkActionPlan.fromDiff(
                                        snapshot: snapshot,
                                        kind: SourceControlActionKind.discard,
                                        selectedHunkIndexes: <int>[
                                          hunk.hunkIndex,
                                        ],
                                      ),
                                    );
                                  },
                            icon: const Icon(Icons.delete_sweep_outlined),
                            label: const Text('Discard Hunk'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          if (hunks.length > 6)
            Text(
              'Showing the first 6 of ${hunks.length} hunks.',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class _HunkDiscardConfirmationCard extends StatelessWidget {
  const _HunkDiscardConfirmationCard({
    required this.plan,
    this.onConfirmHunkDiscard,
  });

  final SourceControlHunkDiscardConfirmationPlan plan;
  final Future<void> Function()? onConfirmHunkDiscard;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('source-control-hunk-discard-confirmation'),
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.18),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.4),
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(plan.dialogTitle, style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(plan.warning, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              Chip(label: Text('path ${plan.path}')),
              Chip(label: Text('selected ${plan.selectedHunkIndexes.length}')),
              if (!plan.readyForDialog) Chip(label: Text(plan.blockedReason)),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const ValueKey('source-control-review-hunk-discard'),
            onPressed: plan.readyForDialog && onConfirmHunkDiscard != null
                ? () => _showDiscardDialog(context)
                : null,
            icon: const Icon(Icons.warning_amber_rounded),
            label: Text(plan.confirmLabel),
          ),
        ],
      ),
    );
  }

  Future<void> _showDiscardDialog(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          key: const ValueKey('source-control-hunk-discard-dialog'),
          title: Text(plan.dialogTitle),
          content: Text(plan.warning),
          actions: [
            TextButton(
              key: const ValueKey('source-control-cancel-hunk-discard'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('source-control-confirm-hunk-discard'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(plan.confirmLabel),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      await onConfirmHunkDiscard?.call();
    }
  }
}

class _HunkActionResultRow extends StatelessWidget {
  const _HunkActionResultRow({required this.result});

  final SourceControlPartialPatchResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('source-control-hunk-action-result'),
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: result.applied
            ? theme.colorScheme.secondaryContainer
            : theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Chip(
            label: Text(
              result.applied ? 'hunk action applied' : 'hunk action failed',
            ),
          ),
          Chip(label: Text(result.kind.wireValue)),
          Chip(label: Text('${result.selectedHunkIndexes.length} hunk(s)')),
          if (result.exitCode != null)
            Chip(label: Text('exit ${result.exitCode}')),
          if (result.message.isNotEmpty) Text(result.message),
        ],
      ),
    );
  }
}

class _ProviderAdapterSummary extends StatelessWidget {
  const _ProviderAdapterSummary({required this.adapters});

  final List<SourceControlProviderAdapterDescriptor> adapters;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _SourceControlSummaryCard(
      key: const ValueKey('source-control-provider-adapter-summary'),
      title: 'SCM Providers',
      lines: adapters
          .map(
            (adapter) =>
                '${adapter.label}: ${adapter.capabilities.take(4).map((capability) => capability.wireValue).join(', ')}',
          )
          .toList(growable: false),
      icon: Icons.extension_rounded,
      color: theme.colorScheme.primaryContainer,
    );
  }
}

class _CommitDraftCard extends StatelessWidget {
  const _CommitDraftCard({required this.draft, this.dialogState});

  final SourceControlCommitDraft draft;
  final SourceControlCommitDialogState? dialogState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plan = draft.toCommitActionPlan();
    return _SourceControlSummaryCard(
      key: const ValueKey('source-control-commit-draft-card'),
      title: 'Commit Draft',
      lines: <String>[
        draft.hasMessage ? draft.message.trim() : 'Missing commit message',
        'selected ${draft.selectedPaths.length} · risk ${plan.risk.wireValue}',
        plan.canRun ? 'ready to commit' : plan.blockedReason,
        if (dialogState != null)
          dialogState!.canSubmit
              ? 'dialog ready'
              : 'dialog ${dialogState!.status.wireValue}',
        if (dialogState?.validationMessage.isNotEmpty == true)
          dialogState!.validationMessage,
      ],
      icon: Icons.commit_rounded,
      color: theme.colorScheme.tertiaryContainer,
    );
  }
}

class _BranchPickerSummary extends StatelessWidget {
  const _BranchPickerSummary({required this.snapshot, this.onSwitchBranch});

  final SourceControlBranchSnapshot snapshot;
  final Future<void> Function(SourceControlBranchSwitchPlan plan)?
  onSwitchBranch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('source-control-branch-picker-summary'),
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 340),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_tree_rounded, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Branches', style: theme.textTheme.titleSmall),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            snapshot.available
                ? 'current ${snapshot.currentBranch}'
                : snapshot.message,
            style: theme.textTheme.bodySmall,
          ),
          Text(
            'available ${snapshot.branches.length}',
            style: theme.textTheme.bodySmall,
          ),
          if (snapshot.branches.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final branch in snapshot.branches.take(6))
                  _BranchSwitchButton(
                    snapshot: snapshot,
                    branch: branch,
                    onSwitchBranch: onSwitchBranch,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _BranchSwitchButton extends StatelessWidget {
  const _BranchSwitchButton({
    required this.snapshot,
    required this.branch,
    required this.onSwitchBranch,
  });

  final SourceControlBranchSnapshot snapshot;
  final String branch;
  final Future<void> Function(SourceControlBranchSwitchPlan plan)?
  onSwitchBranch;

  @override
  Widget build(BuildContext context) {
    final plan = SourceControlBranchSwitchPlan.fromSnapshot(
      snapshot: snapshot,
      targetBranch: branch,
    );
    return OutlinedButton(
      key: ValueKey('source-control-switch-branch-$branch'),
      onPressed: plan.canRun && onSwitchBranch != null
          ? () {
              onSwitchBranch!(plan);
            }
          : null,
      child: Text(branch),
    );
  }
}

class _HistorySummary extends StatelessWidget {
  const _HistorySummary({required this.snapshot});

  final SourceControlHistorySnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latest = snapshot.entries.isEmpty ? null : snapshot.entries.first;
    return Container(
      key: const ValueKey('source-control-history-summary'),
      width: 320,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history_rounded, size: 18),
              const SizedBox(width: 6),
              Text('History', style: theme.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            snapshot.available
                ? 'entries ${snapshot.entries.length}'
                : snapshot.message,
            style: theme.textTheme.bodySmall,
          ),
          if (latest != null)
            Text(
              'latest ${latest.shortRevision} · ${latest.summary}',
              style: theme.textTheme.bodySmall,
            ),
          for (final entry in snapshot.entries.take(5))
            _HistoryEntryTile(entry: entry),
          if (snapshot.entries.length > 5)
            Text(
              'Showing the latest 5 of ${snapshot.entries.length} entries.',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class _HistoryEntryTile extends StatelessWidget {
  const _HistoryEntryTile({required this.entry});

  final SourceControlHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detailLines = <String>[
      'revision ${entry.revision}',
      if (entry.author.isNotEmpty) 'author ${entry.author}',
      if (entry.authoredAt.isNotEmpty) 'authored ${entry.authoredAt}',
    ];
    // Material localizes ink/splash so ExpansionTile's ListTile is not
    // obscured by the parent history card's colored DecoratedBox.
    return Material(
      type: MaterialType.transparency,
      child: ExpansionTile(
        key: ValueKey('source-control-history-entry-${entry.shortRevision}'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: 8, bottom: 6),
        title: Text(
          '${entry.shortRevision} · ${entry.summary}',
          style: theme.textTheme.bodySmall,
        ),
        children: [
          for (final line in detailLines)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(line, style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

class _SourceControlSummaryCard extends StatelessWidget {
  const _SourceControlSummaryCard({
    super.key,
    required this.title,
    required this.lines,
    required this.icon,
    required this.color,
  });

  final String title;
  final List<String> lines;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 260,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 6),
              Text(title, style: theme.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 6),
          for (final line in lines.where((line) => line.trim().isNotEmpty))
            Text(line, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
