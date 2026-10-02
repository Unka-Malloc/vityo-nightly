/// Workspace drawer: a full-height file tree that EXPANDS as a layout column
/// between the rail and the canvas — opening it narrows the board, it never
/// overlays anything.
///
/// The tree is real: it lists the app's own package root (resolved from the
/// running executable, falling back to the process working directory),
/// lazily, one directory at a time.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'controller.dart';
import 'palette.dart';

class WorkspaceDrawer extends StatefulWidget {
  const WorkspaceDrawer({super.key, required this.controller});

  final FlowHeroController controller;

  @override
  State<WorkspaceDrawer> createState() => _WorkspaceDrawerState();
}

class _WorkspaceDrawerState extends State<WorkspaceDrawer> {
  static const int _maxDepth = 12;

  static const Set<String> _noise = <String>{
    'build',
    '.dart_tool',
    '.git',
    '.idea',
    'node_modules',
    'coverage',
    'DerivedData',
  };

  late final String _rootPath = _resolveRoot();
  final Map<String, List<FileSystemEntity>> _cache = <String, List<FileSystemEntity>>{};
  final Set<String> _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    unawaitedLoad(_rootPath);
  }

  /// Debug layout: build/macos/Build/Products/Debug/Vityo.app/Contents/
  /// MacOS/Vityo — walking up nine parents lands on the package root.
  static String _resolveRoot() {
    Directory dir = File(Platform.resolvedExecutable).parent;
    for (int i = 0; i < 9; i++) {
      dir = dir.parent;
    }
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir.path;
    if (File('${Directory.current.path}/pubspec.yaml').existsSync()) {
      return Directory.current.path;
    }
    return Platform.environment['HOME'] ?? Directory.current.path;
  }

  static String _name(FileSystemEntity e) => e.path.split('/').last;

  String get _rootName => _rootPath.split('/').last;

  Future<void> unawaitedLoad(String path) async {
    _cache[path] = await _list(path);
    if (mounted) setState(() {});
  }

  Future<List<FileSystemEntity>> _list(String path) async {
    try {
      final List<FileSystemEntity> entries = await Directory(path)
          .list(followLinks: false)
          .where((FileSystemEntity e) {
            final String name = _name(e);
            return !name.startsWith('.') && !_noise.contains(name);
          })
          .toList();
      entries.sort((FileSystemEntity a, FileSystemEntity b) {
        final int dirs = (a is Directory ? 0 : 1) - (b is Directory ? 0 : 1);
        if (dirs != 0) return dirs;
        return _name(a).toLowerCase().compareTo(_name(b).toLowerCase());
      });
      return entries;
    } on FileSystemException {
      return const <FileSystemEntity>[];
    }
  }

  Future<void> _toggle(String path) async {
    if (_expanded.contains(path)) {
      setState(() => _expanded.remove(path));
      return;
    }
    setState(() => _expanded.add(path));
    if (!_cache.containsKey(path)) {
      _cache[path] = await _list(path);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final FlowHeroController c = widget.controller;
    // A layout child, not an overlay: the drawer takes a real column between
    // the rail and the canvas, so opening it narrows the board instead of
    // covering it. The OverflowBox keeps the tree at full width while the
    // reveal animates; ClipRect trims it. While the sash is dragged the width
    // tracks the pointer exactly — the reveal curve would lag behind it.
    return ClipRect(
      child: AnimatedContainer(
        duration: c.treeDragging ? Duration.zero : const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        width: c.treeVisible ? c.treeWidth : 0,
        height: double.infinity,
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 0,
          maxWidth: c.treeWidth,
          child: SizedBox(
            width: c.treeWidth,
            child: Container(
              decoration: BoxDecoration(
                color: P.panel,
                border: Border(right: BorderSide(color: P.seamLo)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _buildHeader(c),
                  Container(height: 1, color: P.seamLo),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      children: _rows(_rootPath, 0),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(FlowHeroController c) {
    return SizedBox(
      height: 34,
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 6),
        child: Row(
          children: <Widget>[
            Text('工作区', style: P.silkStyle()),
            const SizedBox(width: 8),
            Expanded(
              child: Tooltip(
                message: _rootPath,
                child: Text(
                  _rootName,
                  style: P.monoStyle(color: P.silkDim, size: 10.5),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            InkWell(
              onTap: c.toggleTree,
              borderRadius: BorderRadius.circular(3),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.keyboard_double_arrow_left, size: 14, color: P.silkDim),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _rows(String dirPath, int depth) {
    if (depth > _maxDepth) return const <Widget>[];
    final List<FileSystemEntity>? entries = _cache[dirPath];
    if (entries == null) {
      return <Widget>[_metaRow(depth, '…')];
    }
    if (entries.isEmpty) {
      return <Widget>[_metaRow(depth, '（空）')];
    }
    final List<Widget> rows = <Widget>[];
    for (final FileSystemEntity e in entries) {
      rows.add(_row(e, depth));
      if (e is Directory && _expanded.contains(e.path)) {
        rows.addAll(_rows(e.path, depth + 1));
      }
    }
    return rows;
  }

  Widget _metaRow(int depth, String text) {
    return Padding(
      padding: EdgeInsets.only(left: 12 + depth * 14.0, top: 5, bottom: 5),
      child: Text(text, style: P.silkStyle(dim: true)),
    );
  }

  Widget _row(FileSystemEntity e, int depth) {
    final bool isDir = e is Directory;
    final String name = _name(e);
    final FlowHeroController c = widget.controller;
    final bool active = !isDir && name == c.activeFile;
    return InkWell(
      onTap: () => isDir ? _toggle(e.path) : c.pickFile(name, path: e.path),
      hoverColor: P.well.withValues(alpha: 0.45),
      child: Container(
        color: active ? P.panelHi : null,
        padding: EdgeInsets.only(left: 12 + depth * 14.0, right: 8, top: 5, bottom: 5),
        child: Row(
          children: <Widget>[
            if (isDir)
              Icon(
                _expanded.contains(e.path) ? Icons.expand_more : Icons.chevron_right,
                size: 12,
                color: P.silkDim,
              )
            else
              const SizedBox(width: 12),
            const SizedBox(width: 4),
            Icon(_iconFor(e), size: 13, color: active ? P.orange : P.silkDim),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                name,
                style: P.monoStyle(color: active ? P.paper : P.paperLow, size: 11),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(FileSystemEntity e) {
    if (e is Directory) {
      return _expanded.contains(e.path) ? Icons.folder_open : Icons.folder_outlined;
    }
    final String name = _name(e);
    final int dot = name.lastIndexOf('.');
    final String ext = dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
    return switch (ext) {
      'sty' => Icons.bolt,
      'dart' => Icons.code,
      'md' => Icons.article_outlined,
      'yaml' || 'yml' || 'toml' || 'json' => Icons.settings_suggest_outlined,
      'png' || 'svg' || 'ttf' || 'otf' => Icons.image_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}
