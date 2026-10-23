import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ide/workspace/workspace_search_service.dart';
import '../platform/viewport_profile.dart';
import '../theme/vityo_theme.dart';

/// Real quick-open picker over the workspace file list.
///
/// Ranking and matching reuse the shared [WorkspaceQuickOpenService] so the
/// panel and the command palette agree on what a "quick open" match is. The
/// surface only lists files that exist in the shell's workspace index; it never
/// synthesizes entries.
class QuickOpenSurface extends StatefulWidget {
  const QuickOpenSurface({
    super.key,
    required this.viewportProfile,
    this.workspaceFiles = const <String>[],
    this.recentFilePaths = const <String>[],
    this.activeFilePath,
    this.onOpenFile,
  });

  final ViewportProfile viewportProfile;
  final List<String> workspaceFiles;
  final List<String> recentFilePaths;
  final String? activeFilePath;
  final Future<bool> Function(String filePath)? onOpenFile;

  @override
  State<QuickOpenSurface> createState() => _QuickOpenSurfaceState();
}

class _QuickOpenSurfaceState extends State<QuickOpenSurface> {
  static const _quickOpenService = WorkspaceQuickOpenService();
  static const _maxResults = 50;

  late final TextEditingController _controller;
  var _query = '';
  var _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<String> get _orderedFiles {
    final ordered = <String>[];
    final seen = <String>{};
    for (final file in <String>[
      ...widget.recentFilePaths,
      if (widget.activeFilePath != null) widget.activeFilePath!,
      ...widget.workspaceFiles,
    ]) {
      if (file.trim().isEmpty || !seen.add(file)) {
        continue;
      }
      ordered.add(file);
    }
    return ordered;
  }

  WorkspaceQuickOpenResult get _result => _quickOpenService.searchFiles(
    documentIds: _orderedFiles,
    query: _query,
    maxResults: _maxResults,
  );

  void _moveSelection(int delta) {
    final matches = _result.matches;
    if (matches.isEmpty) {
      return;
    }
    setState(() {
      _selectedIndex = (_selectedIndex + delta).clamp(0, matches.length - 1);
    });
  }

  void _openSelected() {
    final matches = _result.matches;
    if (matches.isEmpty) {
      return;
    }
    _open(matches[_selectedIndex.clamp(0, matches.length - 1)].documentId);
  }

  void _open(String documentId) {
    final open = widget.onOpenFile;
    if (open == null) {
      return;
    }
    open(documentId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);
    final compact = widget.viewportProfile.isMobile;
    final result = _result;
    final matches = result.matches;
    final workspaceFileCount = _orderedFiles.length;

    return Card(
      key: const ValueKey('quick-open-surface'),
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 18),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tight = constraints.maxHeight < 280;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Quick Open',
                  style: tight
                      ? theme.textTheme.titleMedium
                      : theme.textTheme.titleLarge,
                ),
                if (!tight) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Fuzzy file navigation over the workspace index, ranked by '
                    'the shared quick-open scorer with recency and active-file '
                    'boosting.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 10),
                Focus(
                  onKeyEvent: (_, event) {
                    if (event is! KeyDownEvent) {
                      return KeyEventResult.ignored;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                      _moveSelection(1);
                      return KeyEventResult.handled;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                      _moveSelection(-1);
                      return KeyEventResult.handled;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.enter) {
                      _openSelected();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    key: const ValueKey('quick-open-input'),
                    controller: _controller,
                    autofocus: true,
                    enabled: workspaceFileCount > 0,
                    decoration: InputDecoration(
                      labelText: 'File name or path',
                      helperText: tight
                          ? null
                          : workspaceFileCount == 0
                          ? 'The workspace file index is empty.'
                          : 'Type to filter, then press Enter to open.',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.search_rounded),
                    ),
                    onChanged: (value) {
                      setState(() {
                        _query = value;
                        _selectedIndex = 0;
                      });
                    },
                    onSubmitted: (_) => _openSelected(),
                  ),
                ),
                if (!tight) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      Chip(label: Text('workspace-files $workspaceFileCount')),
                      Chip(label: Text('matches ${matches.length}')),
                      if (result.truncated)
                        const Chip(label: Text('limit $_maxResults')),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                Expanded(
                  child: workspaceFileCount == 0
                      ? Text(
                          'No workspace files are indexed yet.',
                          style: theme.textTheme.bodySmall,
                        )
                      : matches.isEmpty
                      ? Text(
                          'No files match "${_query.trim()}".',
                          style: theme.textTheme.bodySmall,
                        )
                      : ListView.builder(
                          key: const ValueKey('quick-open-results'),
                          itemCount: matches.length,
                          itemBuilder: (context, index) {
                            final match = matches[index];
                            final selected = index == _selectedIndex;
                            return ListTile(
                              key: ValueKey(
                                'quick-open-result-${match.documentId}',
                              ),
                              dense: true,
                              selected: selected,
                              selectedTileColor: tokens.hover,
                              leading: const Icon(Icons.description_outlined),
                              title: Text(match.label),
                              subtitle: Text(
                                match.documentId,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => _open(match.documentId),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
