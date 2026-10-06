/// Flow Hero's real workspace file index, shared by the quick-open overlay.
///
/// The index is the same tree the workspace drawer walks: the configured Agent
/// workspace when one is set, otherwise the running package root. It never
/// synthesizes entries — when the root cannot be listed or holds no visible
/// files the list is empty and the overlay shows an honest empty state.
///
/// The production implementation is the only place in Flow Hero that reads the
/// host filesystem directly, matching the drawer's existing behaviour; tests
/// inject their own [FlowHeroWorkspaceFileIndex].
library;

import 'dart:io';

/// Directories the drawer and the index both hide.
const Set<String> kFlowHeroWorkspaceNoise = <String>{
  'build',
  '.dart_tool',
  '.git',
  '.idea',
  'node_modules',
  'coverage',
  'DerivedData',
};

/// The real workspace root Flow Hero opens.
///
/// The configured Agent workspace wins; otherwise the running package root is
/// used (resolved the same way as the workspace drawer), so quick-open and the
/// tree agree on what "the workspace" is.
/// Resolve the package root when no workspace was supplied by the view layer.
/// Runtime workspace selection itself remains owned by Flow Hero's controller.
String _packageRoot() {
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

/// The configured workspace, or the package root for an unconfigured launch.
String flowHeroWorkspaceRoot([String configured = '']) {
  final String trimmed = configured.trim();
  return trimmed.isNotEmpty ? trimmed : _packageRoot();
}

/// The file list the quick-open overlay ranks. Real paths only.
abstract class FlowHeroWorkspaceFileIndex {
  Future<List<String>> listFiles();
}

typedef FlowHeroWorkspaceFileIndexFactory =
    FlowHeroWorkspaceFileIndex Function(String root);

/// Walks the real workspace tree once, flattening it into file paths.
class FlowHeroWorkspaceFileIndexIO implements FlowHeroWorkspaceFileIndex {
  FlowHeroWorkspaceFileIndexIO({
    String? root,
    this.maxDepth = 8,
    this.maxFiles = 4000,
  }) : root = flowHeroWorkspaceRoot(root ?? '');

  final String root;
  final int maxDepth;
  final int maxFiles;

  @override
  Future<List<String>> listFiles() async {
    final List<String> files = <String>[];
    final Directory directory = Directory(root);
    if (!await directory.exists()) return files;
    await _walk(directory, 0, files);
    files.sort(
      (String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()),
    );
    return files;
  }

  Future<void> _walk(Directory directory, int depth, List<String> files) async {
    if (depth > maxDepth || files.length >= maxFiles) return;
    final List<FileSystemEntity> entries;
    try {
      entries = await directory.list(followLinks: false).toList();
    } on FileSystemException {
      return;
    }
    for (final FileSystemEntity entity in entries) {
      if (files.length >= maxFiles) return;
      final String name = entity.path.split(Platform.pathSeparator).last;
      if (name.isEmpty ||
          name.startsWith('.') ||
          kFlowHeroWorkspaceNoise.contains(name)) {
        continue;
      }
      if (entity is File) {
        files.add(entity.path);
      } else if (entity is Directory) {
        await _walk(entity, depth + 1, files);
      }
    }
  }
}
