/// Read-only, bounded discovery of local toolchain choices.
library;

import 'dart:async';
import 'dart:convert';

import '../environment/system_compatibility/file_system/file_system_adapter.dart';
import '../environment/system_compatibility/file_system/file_system_facts.dart';
import '../environment/system_compatibility/file_system/file_system_manager.dart';

import '../../ide/local_service/vityod_client.dart';
import '../backend_toolchain/bundled_toolchain_candidates.dart';
import '../environment/configuration/host_environment.dart';
import '../environment/system_compatibility/platform_manager/platform_manager.dart';
import 'toolchain_store.dart';

import 'toolchain_install_contract.dart';
export 'toolchain_install_contract.dart'
    show
        FlowHeroToolchainCandidate,
        FlowHeroToolchainCandidateDiscovery,
        FlowHeroToolchainCandidateCatalog;

/// Offers choices without selecting, saving, or running any discovered binary.
/// The explicit selection is retained even when missing; it is never replaced
/// by an available bundle or system candidate. Other missing paths are omitted.
/// Only known locations and at most 96 unique PATH entries are inspected.
/// Empty/relative PATH entries are ignored to avoid searching a project folder.
Future<FlowHeroToolchainCandidateCatalog> discoverFlowHeroToolchainCandidates({
  required FlowHeroToolchainKind kind,
  PlatformManagerBundle? platformManagers,
  VityodClient? vityodClient,
  Map<String, String>? environment,
  String? bundledExecutablePath,
  String? operatingSystem,
  String? selectedPath,
  bool Function()? isCancelled,
  Future<bool> Function(String path)? fileExists,
  Future<String?> Function(String path)? readManifest,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final watch = Stopwatch()..start();
  bool stopped() => (isCancelled?.call() ?? false) || watch.elapsed >= timeout;
  if (stopped()) {
    return FlowHeroToolchainCandidateCatalog(
      [],
      isPartial: true,
      isCancelled: isCancelled?.call() ?? false,
    );
  }
  var partial = false;
  final env = environment ?? readHostEnvironment();
  var managers = platformManagers;
  if (fileExists == null && managers == null) {
    try {
      managers = await createDetectedPlatformManagerBundle(
        workspaceRoot: '.',
        vityodClient: vityodClient,
      ).timeout(timeout);
    } on Object {
      return FlowHeroToolchainCandidateCatalog(<FlowHeroToolchainCandidate>[
        if (selectedPath != null && selectedPath.trim().isNotEmpty)
          FlowHeroToolchainCandidate(
            path: selectedPath.trim(),
            sourceLabel: 'Saved user selection',
            exists: false,
          ),
      ], isPartial: true);
    }
  }
  final os =
      (operatingSystem ??
              managers?.context.fileSystem.operatingSystem ??
              'linux')
          .toLowerCase();
  final windows = os == 'windows';
  final context = FileSystemCompatibility(
    targetId: 'candidate-discovery',
    compatibilityTarget: os,
    pathStyle: windows
        ? FileSystemPathStyle.windows
        : FileSystemPathStyle.posix,
    pathSeparator: windows ? r'\' : '/',
    caseSensitive: !windows,
    providerKind: FileSystemProviderKind.local,
    watchSupport: FileSystemWatchSupport.none,
    supportsFileUri: true,
    supportsSymbolicLinks: false,
    supportsAtomicWrite: false,
  );
  final pending = <({String path, String source, bool explicit})>[];
  final seen = <String>{};
  void add(String? path, String source, {bool explicit = false}) {
    if (path == null || path.trim().isEmpty) return;
    final value = context.normalizePath(path.trim());
    final key = windows ? value.toLowerCase() : value;
    if (seen.add(key)) {
      pending.add((path: value, source: source, explicit: explicit));
    } else if (source.startsWith('Environment override')) {
      final index = pending.indexWhere(
        (entry) => (windows ? entry.path.toLowerCase() : entry.path) == key,
      );
      final prior = pending[index];
      pending[index] = (
        path: prior.path,
        source: '${prior.source} · $source',
        explicit: true,
      );
    }
  }

  add(selectedPath, 'Saved user selection', explicit: true);
  add(
    env[kind.environmentVariable],
    'Environment override ${kind.environmentVariable}',
    explicit: true,
  );
  if (kind == FlowHeroToolchainKind.pafio) {
    final manifestPath = bundledPafioComponentManifestPath(
      executablePath: bundledExecutablePath,
      operatingSystem: os,
    );
    final root = bundledApplicationPackageRoot(
      executablePath: bundledExecutablePath,
      operatingSystem: os,
    );
    if (manifestPath != null && root != null && !stopped()) {
      try {
        final read = readManifest != null
            ? readManifest(manifestPath)
            : managers != null
            ? managers.fileSystem.readText(manifestPath)
            : Future<String?>.value(null);
        final remaining = timeout - watch.elapsed;
        final contents = await read.timeout(
          remaining < const Duration(milliseconds: 200)
              ? remaining
              : const Duration(milliseconds: 200),
        );
        final decoded = contents == null ? null : jsonDecode(contents);
        if (decoded is Map<String, dynamic> &&
            decoded['schema_version'] == 1 &&
            decoded['component'] == 'pafio') {
          final relative = decoded['package_relative_path'];
          if (relative is String && relative.trim().isNotEmpty) {
            final normalized = relative.replaceAll(r'\', '/');
            final segments = normalized.split('/');
            if (!normalized.startsWith('/') &&
                !RegExp(r'^[A-Za-z]:').hasMatch(normalized) &&
                !segments.any(
                  (part) => part.isEmpty || part == '.' || part == '..',
                )) {
              add(context.joinPath([root, ...segments]), 'App bundle');
            }
          }
        }
      } on TimeoutException {
        partial = true;
      } on Object {
        // Invalid or unavailable manifests do not create guessed candidates.
      }
    }
  } else {
    for (final path in bundledToolchainCandidatePaths(
      kind.id,
      executablePath: bundledExecutablePath,
      operatingSystem: os,
    )) {
      add(path, 'App bundle');
    }
  }
  final executable = windows ? '${kind.id}.exe' : kind.id;
  if (windows) {
    add(
      kind == FlowHeroToolchainKind.pafio
          ? r'C:\Program Files\Pafio\pafio.exe'
          : r'C:\Program Files\Styio\styio.exe',
      'Standard system location',
    );
  } else {
    for (final directory in const [
      '/usr/local/bin',
      '/usr/bin',
      '/opt/homebrew/bin',
    ]) {
      add(
        context.joinPath(<String>[directory, executable]),
        'Standard system location',
      );
    }
  }
  final pathValue = windows
      ? env.entries
            .where((entry) => entry.key.toUpperCase() == 'PATH')
            .map((entry) => entry.value)
            .firstOrNull
      : env['PATH'];
  var count = 0;
  final directories = <String>{};
  // Windows caps environment values at 32K; use the same finite budget on
  // other platforms so pathological PATH contents cannot stall the dialog.
  if ((pathValue ?? '').length > 32768) partial = true;
  final boundedPath = (pathValue ?? '').length > 32768
      ? pathValue!.substring(0, 32768)
      : (pathValue ?? '');
  for (var directory in boundedPath.split(windows ? ';' : ':')) {
    directory = directory.trim();
    if (windows &&
        directory.startsWith('"') &&
        directory.endsWith('"') &&
        directory.length > 1) {
      directory = directory.substring(1, directory.length - 1);
    }
    if (!context.isAbsolutePath(directory)) continue;
    directory = context.normalizePath(directory);
    if (!directories.add(windows ? directory.toLowerCase() : directory)) {
      continue;
    }
    if (count++ >= 96) {
      partial = true;
      break;
    }
    add(context.joinPath(<String>[directory, executable]), 'System PATH');
  }
  final result = <FlowHeroToolchainCandidate>[];
  for (final candidate in pending) {
    if (stopped()) {
      partial = true;
      break;
    }
    bool exists = false;
    try {
      // stat checks files, not directories, without executing external tools.
      final check = fileExists != null
          ? fileExists(candidate.path)
          : managers!.fileSystem.stat(candidate.path).then((entry) async {
              if (entry.isFile) return true;
              // Homebrew commonly installs executable symlinks. The
              // native metadata check follows an allowed link and rejects
              // directories/broken links without launching the binary.
              return entry.type == VityoFileSystemEntityType.link &&
                  await managers!.fileSystem.isExecutable(candidate.path);
            });
      final remaining = timeout - watch.elapsed;
      exists = await check.timeout(
        remaining < const Duration(milliseconds: 200)
            ? remaining
            : const Duration(milliseconds: 200),
      );
    } on TimeoutException {
      partial = true;
    } on Object {
      partial = true;
      // An inaccessible/missing location is not a usable automatic suggestion.
    }
    if (isCancelled?.call() ?? false) {
      partial = true;
      break;
    }
    if (exists || candidate.explicit) {
      result.add(
        FlowHeroToolchainCandidate(
          path: candidate.path,
          sourceLabel: candidate.source,
          exists: exists,
        ),
      );
    }
  }
  return FlowHeroToolchainCandidateCatalog(
    result,
    isPartial: partial,
    isCancelled: isCancelled?.call() ?? false,
  );
}
