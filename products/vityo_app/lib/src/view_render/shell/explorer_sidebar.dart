part of 'vityo_shell_scaffold.dart';

enum _ExplorerFileAction { rename, delete }

class _ExplorerSidebar extends StatefulWidget {
  const _ExplorerSidebar({required this.shell});

  final ShellModel shell;

  @override
  State<_ExplorerSidebar> createState() => _ExplorerSidebarState();
}

class _ExplorerSidebarState extends State<_ExplorerSidebar> {
  final TextEditingController _filterController = TextEditingController();
  final FocusNode _filterFocusNode = FocusNode(debugLabel: 'Explorer filter');
  final Set<String> _selectedPaths = <String>{};
  bool _multiSelect = false;

  ShellModel get shell => widget.shell;

  @override
  void dispose() {
    _filterController.dispose();
    _filterFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = shell.workspaceFileExplorerSnapshot;
    final state =
        snapshot.state ??
        WorkspaceFileExplorerState(
          workspaceId: shell.workspaceController.activeProject.id,
        );
    final query = _filterController.text.trim().toLowerCase();
    final roots = query.isEmpty
        ? snapshot.roots
        : snapshot.roots
              .map((node) => _filteredNode(node, query))
              .whereType<WorkspaceFileExplorerNode>()
              .toList(growable: false);

    return Material(
      key: const ValueKey('workspace-explorer'),
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context, snapshot, state),
          _buildFilter(context),
          if (_multiSelect) _buildSelectionBar(context),
          if (snapshot.watch?.plan.status ==
              WorkspaceFileExplorerWatchStatus.blocked)
            _ExplorerWatchAlert(
              message: snapshot.watch!.plan.message,
              onRefresh: _refresh,
            ),
          const Divider(height: 1, thickness: 1),
          Expanded(
            child: roots.isEmpty
                ? _ExplorerEmptyState(
                    filtered: query.isNotEmpty,
                    onCreate: _promptCreate,
                    onClearFilter: () {
                      _filterController.clear();
                      setState(() {});
                    },
                  )
                : ListView(
                    key: const ValueKey('explorer-tree-scroll'),
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    children: [
                      for (final node in roots)
                        _buildNode(
                          context,
                          node,
                          state: state,
                          depth: 0,
                          filtering: query.isNotEmpty,
                        ),
                    ],
                  ),
          ),
          if (shell.pendingWorkspaceFileCommandConfirmation != null) ...[
            const Divider(height: 1, thickness: 1),
            Padding(
              padding: const EdgeInsets.all(10),
              child: _WorkspaceFileCommandConfirmationCard(
                pending: shell.pendingWorkspaceFileCommandConfirmation!,
                onConfirm: () {
                  shell.confirmPendingWorkspaceFileCommand();
                },
                onCancel: shell.cancelPendingWorkspaceFileCommand,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    WorkspaceFileExplorerSnapshot snapshot,
    WorkspaceFileExplorerState state,
  ) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);
    final watch = snapshot.watch;
    final telemetry = watch?.telemetry;
    final statusColor = switch (watch?.plan.status) {
      WorkspaceFileExplorerWatchStatus.active => tokens.success,
      WorkspaceFileExplorerWatchStatus.blocked => tokens.error,
      WorkspaceFileExplorerWatchStatus.pending => tokens.warning,
      null => tokens.muted,
    };
    final statusLabel = switch (watch?.plan.status) {
      WorkspaceFileExplorerWatchStatus.active => 'watching',
      WorkspaceFileExplorerWatchStatus.blocked => 'refresh needed',
      WorkspaceFileExplorerWatchStatus.pending => 'connecting',
      null => 'workspace index',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 9, 6, 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  shell.workspaceController.activeProject.title,
                  key: const ValueKey('explorer-workspace-title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              _ExplorerToolbarButton(
                key: const ValueKey('explorer-create-file'),
                tooltip: 'New file',
                icon: Icons.note_add_outlined,
                onPressed: _promptCreate,
              ),
              _ExplorerToolbarButton(
                key: const ValueKey('explorer-refresh'),
                tooltip: 'Refresh file tree',
                icon: Icons.refresh_rounded,
                onPressed: _refresh,
              ),
              _ExplorerToolbarButton(
                key: const ValueKey('explorer-sort'),
                tooltip:
                    state.sortMode == WorkspaceFileExplorerSortMode.foldersFirst
                    ? 'Sort alphabetically'
                    : 'Keep folders first',
                icon:
                    state.sortMode == WorkspaceFileExplorerSortMode.foldersFirst
                    ? Icons.sort_by_alpha_rounded
                    : Icons.folder_copy_outlined,
                onPressed: () {
                  shell.setWorkspaceExplorerSortMode(
                    state.sortMode == WorkspaceFileExplorerSortMode.foldersFirst
                        ? WorkspaceFileExplorerSortMode.alphabetical
                        : WorkspaceFileExplorerSortMode.foldersFirst,
                  );
                },
              ),
              _ExplorerToolbarButton(
                key: const ValueKey('explorer-multi-select'),
                tooltip: _multiSelect
                    ? 'Leave multi-select mode'
                    : 'Select multiple files',
                icon: _multiSelect
                    ? Icons.checklist_rtl_rounded
                    : Icons.library_add_check_outlined,
                selected: _multiSelect,
                onPressed: _toggleMultiSelect,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${snapshot.fileCount} files · $statusLabel'
                  '${telemetry == null || telemetry.totalEventCount == 0 ? '' : ' · ${telemetry.totalEventCount} events'}',
                  key: const ValueKey('explorer-watch-status'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilter(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      child: SizedBox(
        height: 32,
        child: TextField(
          key: const ValueKey('explorer-filter'),
          controller: _filterController,
          focusNode: _filterFocusNode,
          onChanged: (_) => setState(() {}),
          style: theme.textTheme.bodySmall,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Filter files',
            prefixIcon: const Icon(Icons.search_rounded, size: 16),
            suffixIcon: _filterController.text.isEmpty
                ? null
                : IconButton(
                    key: const ValueKey('explorer-filter-clear'),
                    tooltip: 'Clear filter',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      _filterController.clear();
                      setState(() {});
                    },
                    icon: const Icon(Icons.close_rounded, size: 15),
                  ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 7,
            ),
            isDense: true,
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.45,
            ),
            border: const OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(5)),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSelectionBar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('explorer-selection-bar'),
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.45),
      padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${_selectedPaths.length} selected',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          TextButton.icon(
            key: const ValueKey('explorer-delete-selected'),
            onPressed: _selectedPaths.isEmpty
                ? null
                : () => _confirmDelete(_selectedPaths),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
              visualDensity: VisualDensity.compact,
            ),
            icon: const Icon(Icons.delete_outline_rounded, size: 16),
            label: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Widget _buildNode(
    BuildContext context,
    WorkspaceFileExplorerNode node, {
    required WorkspaceFileExplorerState state,
    required int depth,
    required bool filtering,
  }) {
    final isDirectory = node.kind == WorkspaceFileExplorerNodeKind.directory;
    if (isDirectory) {
      final expanded = filtering || state.expandedPaths.contains(node.path);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ExplorerRow(
            key: ValueKey('explorer-directory-${node.path}'),
            depth: depth,
            active: state.selectedPath == node.path,
            selected: false,
            onTap: filtering
                ? null
                : () => shell.toggleWorkspaceExplorerDirectory(node.path),
            leading: Icon(
              expanded
                  ? Icons.keyboard_arrow_down_rounded
                  : Icons.keyboard_arrow_right_rounded,
              size: 17,
            ),
            icon: Icon(
              expanded ? Icons.folder_open_rounded : Icons.folder_outlined,
              size: 17,
              color: VityoWorkbenchTokens.of(context).accent,
            ),
            label: node.name,
          ),
          if (expanded)
            for (final child in node.children)
              _buildNode(
                context,
                child,
                state: state,
                depth: depth + 1,
                filtering: filtering,
              ),
        ],
      );
    }

    final active = _sameExplorerPath(
      node.path,
      shell.workspaceFileExplorerSnapshot.activeFilePath,
    );
    final selected = _selectedPaths.contains(node.path);
    final dirty = shell.dirtyDocumentPaths.any(
      (path) => _sameExplorerPath(path, node.path),
    );
    final opened = shell.workspaceController.openFilePaths.any(
      (path) => _sameExplorerPath(path, node.path),
    );
    return _ExplorerRow(
      key: ValueKey('explorer-file-${node.path}'),
      depth: depth,
      active: active,
      selected: selected || state.selectedPath == node.path,
      onTap: () => _handleFileTap(node.path),
      onLongPress: () => _selectForBatch(node.path),
      leading: _multiSelect
          ? Checkbox(
              key: ValueKey('explorer-checkbox-${node.path}'),
              value: selected,
              visualDensity: VisualDensity.compact,
              onChanged: (_) => _toggleSelectedPath(node.path),
            )
          : const SizedBox(width: 17),
      icon: Icon(
        active ? Icons.description_rounded : Icons.description_outlined,
        size: 16,
        color: active
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      label: node.name,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dirty)
            Container(
              key: ValueKey('explorer-dirty-${node.path}'),
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.tertiary,
                shape: BoxShape.circle,
              ),
            )
          else if (opened)
            Icon(
              Icons.circle,
              size: 5,
              color: Theme.of(context).colorScheme.outline,
            ),
          if (!_multiSelect)
            PopupMenuButton<_ExplorerFileAction>(
              key: ValueKey('explorer-menu-${node.path}'),
              tooltip: 'File actions',
              padding: EdgeInsets.zero,
              iconSize: 15,
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (action) => _handleFileAction(action, node.path),
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: _ExplorerFileAction.rename,
                  child: Text('Rename…'),
                ),
                PopupMenuItem(
                  value: _ExplorerFileAction.delete,
                  child: Text('Delete…'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  WorkspaceFileExplorerNode? _filteredNode(
    WorkspaceFileExplorerNode node,
    String query,
  ) {
    final matches =
        node.name.toLowerCase().contains(query) ||
        node.path.toLowerCase().contains(query);
    if (node.kind == WorkspaceFileExplorerNodeKind.file) {
      return matches ? node : null;
    }
    final children = node.children
        .map((child) => _filteredNode(child, query))
        .whereType<WorkspaceFileExplorerNode>()
        .toList(growable: false);
    if (!matches && children.isEmpty) {
      return null;
    }
    return WorkspaceFileExplorerNode(
      name: node.name,
      path: node.path,
      kind: node.kind,
      children: matches ? node.children : children,
    );
  }

  Future<void> _refresh() async {
    await shell.refreshWorkspaceFileExplorer();
  }

  void _toggleMultiSelect() {
    setState(() {
      _multiSelect = !_multiSelect;
      if (!_multiSelect) {
        _selectedPaths.clear();
      }
    });
  }

  void _selectForBatch(String path) {
    setState(() {
      _multiSelect = true;
      _selectedPaths.add(path);
    });
  }

  void _toggleSelectedPath(String path) {
    setState(() {
      if (!_selectedPaths.remove(path)) {
        _selectedPaths.add(path);
      }
    });
  }

  Future<void> _handleFileTap(String path) async {
    if (_multiSelect) {
      _toggleSelectedPath(path);
      return;
    }
    await shell.openWorkspaceFileFromExplorer(path);
  }

  Future<void> _handleFileAction(
    _ExplorerFileAction action,
    String path,
  ) async {
    switch (action) {
      case _ExplorerFileAction.rename:
        await _promptRename(path);
      case _ExplorerFileAction.delete:
        await _confirmDelete(<String>{path});
    }
  }

  Future<void> _promptCreate() async {
    final path = await showDialog<String>(
      context: context,
      builder: (context) => const _WorkspacePathInputDialog(
        title: 'New file',
        actionLabel: 'Create',
        initialValue: 'src/new_file.styio',
        icon: Icons.note_add_outlined,
      ),
    );
    if (!mounted || path == null) {
      return;
    }
    final result = await shell.runWorkspaceFileExplorerAction(
      WorkspaceFileExplorerActionRequest(
        kind: WorkspaceFileOperationKind.create,
        path: path,
        open: true,
      ),
    );
    _presentOperationFailure(result);
  }

  Future<void> _promptRename(String sourcePath) async {
    if (_isDirtyPath(sourcePath)) {
      _presentUnsavedFileWarning();
      return;
    }
    final displayPath = _workspaceDisplayPath(
      workspaceRoot: shell.workspaceController.activeProject.workspaceRoot,
      filePath: sourcePath,
    );
    final path = await showDialog<String>(
      context: context,
      builder: (context) => _WorkspacePathInputDialog(
        title: 'Rename file',
        actionLabel: 'Rename',
        initialValue: displayPath,
        disallowedValue: displayPath,
        icon: Icons.drive_file_rename_outline_rounded,
      ),
    );
    if (!mounted || path == null) {
      return;
    }
    final snapshot = shell.workspaceFileExplorerSnapshot;
    final result = await shell.runWorkspaceFileExplorerAction(
      WorkspaceFileExplorerActionRequest(
        kind: WorkspaceFileOperationKind.rename,
        path: sourcePath,
        nextPath: path,
        open: snapshot.openFilePaths.any(
          (path) => _sameExplorerPath(path, sourcePath),
        ),
      ),
    );
    _presentOperationFailure(result);
  }

  Future<void> _confirmDelete(Iterable<String> rawPaths) async {
    final paths = rawPaths.toSet().toList(growable: false)..sort();
    if (paths.isEmpty) {
      return;
    }
    if (paths.any(_isDirtyPath)) {
      _presentUnsavedFileWarning();
      return;
    }
    final plan = shell.stageWorkspaceFileBatchActions(
      paths
          .map(
            (path) => WorkspaceFileExplorerActionRequest(
              kind: WorkspaceFileOperationKind.delete,
              path: path,
            ),
          )
          .toList(growable: false),
    );
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _WorkspaceFileBatchConfirmationDialog(
        plan: plan,
        workspaceRoot: shell.workspaceController.activeProject.workspaceRoot,
      ),
    );
    if (!mounted) {
      return;
    }
    if (confirmed ?? false) {
      final results = await shell.confirmPendingWorkspaceFileBatchAction();
      if (!mounted) {
        return;
      }
      setState(() {
        _selectedPaths.clear();
        _multiSelect = false;
      });
      final failedCount = results.where((result) => !result.applied).length;
      if (failedCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$failedCount of ${results.length} file operations failed. Check Output for details.',
            ),
          ),
        );
      }
    } else {
      shell.cancelPendingWorkspaceFileBatchAction();
    }
  }

  void _presentOperationFailure(WorkspaceFileOperationResult result) {
    if (!mounted || result.applied) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(result.message)));
  }

  bool _isDirtyPath(String path) {
    return shell.dirtyDocumentPaths.any(
      (dirtyPath) => _sameExplorerPath(dirtyPath, path),
    );
  }

  void _presentUnsavedFileWarning() {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Save or discard unsaved changes before renaming or deleting this file.',
        ),
      ),
    );
  }
}

class _ExplorerToolbarButton extends StatelessWidget {
  const _ExplorerToolbarButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 30, height: 30),
        style: IconButton.styleFrom(
          backgroundColor: selected
              ? theme.colorScheme.secondaryContainer
              : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
      ),
    );
  }
}

class _ExplorerRow extends StatelessWidget {
  const _ExplorerRow({
    super.key,
    required this.depth,
    required this.active,
    required this.selected,
    required this.onTap,
    required this.leading,
    required this.icon,
    required this.label,
    this.onLongPress,
    this.trailing,
  });

  final int depth;
  final bool active;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget leading;
  final Widget icon;
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);
    final selectedColor = active
        ? tokens.hover
        : selected
        ? tokens.hover.withValues(alpha: 0.03)
        : Colors.transparent;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      hoverColor: tokens.hover.withValues(alpha: 0.6),
      child: Ink(
        height: 29,
        padding: EdgeInsets.only(left: 4 + depth * 12, right: 3),
        color: selectedColor,
        child: Row(
          children: [
            SizedBox(width: 20, child: Center(child: leading)),
            const SizedBox(width: 1),
            SizedBox(width: 18, child: Center(child: icon)),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active ? tokens.ink : null,
                ),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

class _ExplorerWatchAlert extends StatelessWidget {
  const _ExplorerWatchAlert({required this.message, required this.onRefresh});

  final String message;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);
    return Container(
      key: const ValueKey('explorer-watch-alert'),
      decoration: BoxDecoration(
        color: tokens.error.withValues(alpha: 0.06),
        border: Border(
          bottom: BorderSide(color: tokens.error.withValues(alpha: 0.18)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 13,
            color: tokens.error.withValues(alpha: 0.9),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: tokens.ink.withValues(alpha: 0.78),
                letterSpacing: 0,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('explorer-watch-alert-refresh'),
            tooltip: 'Rebuild file snapshot',
            visualDensity: VisualDensity.compact,
            hoverColor: tokens.hover,
            onPressed: onRefresh,
            icon: Icon(
              Icons.refresh_rounded,
              size: 14,
              color: tokens.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExplorerEmptyState extends StatelessWidget {
  const _ExplorerEmptyState({
    required this.filtered,
    required this.onCreate,
    required this.onClearFilter,
  });

  final bool filtered;
  final VoidCallback onCreate;
  final VoidCallback onClearFilter;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              filtered ? Icons.filter_alt_off_outlined : Icons.note_outlined,
              size: 28,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 8),
            Text(
              filtered ? 'No matching files' : 'This workspace is empty',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: filtered ? onClearFilter : onCreate,
              child: Text(filtered ? 'Clear filter' : 'Create a file'),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkspacePathInputDialog extends StatefulWidget {
  const _WorkspacePathInputDialog({
    required this.title,
    required this.actionLabel,
    required this.initialValue,
    required this.icon,
    this.disallowedValue = '',
  });

  final String title;
  final String actionLabel;
  final String initialValue;
  final String disallowedValue;
  final IconData icon;

  @override
  State<_WorkspacePathInputDialog> createState() =>
      _WorkspacePathInputDialogState();
}

class _WorkspacePathInputDialogState extends State<_WorkspacePathInputDialog> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.initialValue.length,
      );
    _focusNode = FocusNode(debugLabel: 'Workspace path input');
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool get _valid {
    final value = _controller.text.trim().replaceAll('\\', '/');
    return value.isNotEmpty &&
        value != widget.disallowedValue &&
        !value.startsWith('/') &&
        !RegExp(r'^[A-Za-z]:/').hasMatch(value) &&
        !value.split('/').contains('..');
  }

  void _submit() {
    if (!_valid) {
      return;
    }
    Navigator.of(context).pop(_controller.text.trim().replaceAll('\\', '/'));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('workspace-path-dialog'),
      icon: Icon(widget.icon),
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: TextField(
          key: const ValueKey('workspace-path-input'),
          controller: _controller,
          focusNode: _focusNode,
          autofocus: true,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Workspace-relative path',
            hintText: 'src/example.styio',
            helperText: 'Use a path inside the current workspace.',
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('workspace-path-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('workspace-path-apply'),
          onPressed: _valid ? _submit : null,
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}

class _WorkspaceFileBatchConfirmationDialog extends StatelessWidget {
  const _WorkspaceFileBatchConfirmationDialog({
    required this.plan,
    required this.workspaceRoot,
  });

  final WorkspaceFileExplorerBatchActionPlan plan;
  final String workspaceRoot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paths = plan.requests
        .map(
          (request) => _workspaceDisplayPath(
            workspaceRoot: workspaceRoot,
            filePath: request.path,
          ),
        )
        .toList(growable: false);
    return AlertDialog(
      key: const ValueKey('workspace-file-batch-dialog'),
      icon: Icon(Icons.delete_forever_outlined, color: theme.colorScheme.error),
      title: Text(
        plan.actionCount == 1
            ? 'Delete workspace file?'
            : 'Delete ${plan.actionCount} workspace files?',
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This removes the selected ${plan.actionCount == 1 ? 'file' : 'files'} from the workspace and cannot be undone here.',
            ),
            const SizedBox(height: 12),
            Container(
              constraints: const BoxConstraints(maxHeight: 180),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: paths.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Text(
                    paths[index],
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('workspace-file-batch-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const ValueKey('workspace-file-batch-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: plan.canRun ? () => Navigator.of(context).pop(true) : null,
          icon: const Icon(Icons.delete_outline_rounded),
          label: Text(plan.actionCount == 1 ? 'Delete file' : 'Delete files'),
        ),
      ],
    );
  }
}

bool _sameExplorerPath(String left, String right) {
  final normalizedLeft = left.replaceAll('\\', '/');
  final normalizedRight = right.replaceAll('\\', '/');
  final windowsPath =
      RegExp(r'^[A-Za-z]:/').hasMatch(normalizedLeft) ||
      RegExp(r'^[A-Za-z]:/').hasMatch(normalizedRight);
  return windowsPath
      ? normalizedLeft.toLowerCase() == normalizedRight.toLowerCase()
      : normalizedLeft == normalizedRight;
}
