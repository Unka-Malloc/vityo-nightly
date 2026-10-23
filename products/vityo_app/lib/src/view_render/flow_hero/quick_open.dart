/// Flow Hero's quick-open overlay: a real fuzzy filter over the workspace file
/// index the drawer walks.
///
/// Ranking reuses the shared [WorkspaceQuickOpenService], so Flow Hero's picker
/// and the shell's command palette agree on what a match is. The overlay never
/// invents entries: an unlistable root or an empty tree shows an honest empty
/// state, and opening a match runs the same buffer-open path the drawer uses.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ide/workspace/workspace_search_service.dart';
import 'controller.dart';
import 'palette.dart';

class FlowHeroQuickOpen extends StatefulWidget {
  const FlowHeroQuickOpen({super.key, required this.controller});

  final FlowHeroController controller;

  static const int maxResults = 60;

  @override
  State<FlowHeroQuickOpen> createState() => _FlowHeroQuickOpenState();
}

class _FlowHeroQuickOpenState extends State<FlowHeroQuickOpen> {
  static const WorkspaceQuickOpenService _service = WorkspaceQuickOpenService();
  final TextEditingController _input = TextEditingController();

  List<String> _files = const <String>[];
  bool _loading = true;
  String _query = '';
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    List<String> files = const <String>[];
    try {
      files = await widget.controller.workspaceFileIndex.listFiles();
    } on Object {
      files = const <String>[];
    }
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  WorkspaceQuickOpenResult get _result => _service.searchFiles(
    documentIds: _files,
    query: _query,
    maxResults: FlowHeroQuickOpen.maxResults,
  );

  void _move(int delta) {
    final List<WorkspaceQuickOpenMatch> matches = _result.matches;
    if (matches.isEmpty) return;
    setState(() {
      _selected = (_selected + delta).clamp(0, matches.length - 1);
    });
  }

  void _openSelected() {
    final List<WorkspaceQuickOpenMatch> matches = _result.matches;
    if (matches.isEmpty) return;
    _open(matches[_selected.clamp(0, matches.length - 1)].documentId);
  }

  void _open(String path) {
    final String name = path.split('/').last;
    widget.controller.pickFile(name, path: path);
    widget.controller.closeQuickOpen();
  }

  @override
  Widget build(BuildContext context) {
    final WorkspaceQuickOpenResult result = _result;
    final List<WorkspaceQuickOpenMatch> matches = result.matches;
    return Stack(
      key: const ValueKey('flow-hero-quick-open'),
      fit: StackFit.expand,
      children: <Widget>[
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.controller.closeQuickOpen,
          child: ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
        ),
        Align(
          alignment: const Alignment(0, -0.6),
          child: Focus(
            onKeyEvent: (FocusNode node, KeyEvent event) {
              if (event is! KeyDownEvent || _files.isEmpty) {
                return KeyEventResult.ignored;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                _move(1);
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                _move(-1);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Container(
              width: 560,
              margin: const EdgeInsets.all(24),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: P.panel,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: P.seamLo),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Colors.black87,
                    blurRadius: 34,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: TextField(
                      key: const ValueKey('flow-hero-quick-open-input'),
                      controller: _input,
                      autofocus: true,
                      enabled: _files.isNotEmpty,
                      style: P.monoStyle(size: 12),
                      onChanged: (String value) => setState(() {
                        _query = value;
                        _selected = 0;
                      }),
                      onSubmitted: (_) => _openSelected(),
                      decoration: InputDecoration(
                        hintText: _files.isEmpty ? '工作区没有可打开的文件' : '搜索工作区文件…',
                        hintStyle: P.silkStyle(dim: true),
                        isDense: true,
                        border: InputBorder.none,
                        icon: Icon(Icons.search, size: 15, color: P.silkDim),
                      ),
                    ),
                  ),
                  Container(height: 1, color: P.seamLo),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: _buildBody(matches, result.truncated),
                  ),
                  Container(height: 1, color: P.seamLo),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Row(
                      children: <Widget>[
                        Text(
                          _loading
                              ? '正在索引工作区文件…'
                              : '${_files.length} 个文件 · 匹配 ${matches.length}',
                          style: P.silkStyle(dim: true),
                        ),
                        const Spacer(),
                        Text(
                          '↑↓ 选择 · ↵ 打开 · Esc 关闭',
                          style: P.silkStyle(dim: true),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(List<WorkspaceQuickOpenMatch> matches, bool truncated) {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('正在索引工作区文件…', style: P.silkStyle(dim: true)),
      );
    }
    if (_files.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '工作区没有可打开的文件。',
          key: const ValueKey('flow-hero-quick-open-empty'),
          style: P.silkStyle(dim: true),
        ),
      );
    }
    if (matches.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('没有匹配 "$_query" 的文件。', style: P.silkStyle(dim: true)),
      );
    }
    return ListView.builder(
      key: const ValueKey('flow-hero-quick-open-results'),
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: matches.length,
      itemBuilder: (BuildContext context, int index) {
        final WorkspaceQuickOpenMatch match = matches[index];
        final bool selected = index == _selected;
        return InkWell(
          key: ValueKey<String>(
            'flow-hero-quick-open-result-${match.documentId}',
          ),
          onTap: () => _open(match.documentId),
          hoverColor: P.well.withValues(alpha: 0.45),
          child: Container(
            color: selected ? P.panelHi : null,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.insert_drive_file_outlined,
                  size: 13,
                  color: selected ? P.orange : P.silkDim,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    match.label,
                    style: P.monoStyle(color: P.paperLow, size: 11.5),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (truncated && index == matches.length - 1)
                  Text(
                    '仅显示前 ${FlowHeroQuickOpen.maxResults} 项',
                    style: P.silkStyle(dim: true),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
