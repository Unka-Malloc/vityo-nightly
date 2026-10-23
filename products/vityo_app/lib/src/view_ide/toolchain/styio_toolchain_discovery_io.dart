import '../backend_toolchain/bundled_toolchain_candidates.dart';
import '../environment/environment.dart';
import 'toolchain_catalog.dart';

/// Catalog id for the discovered `styio_lspd` language server.
const String styioLspDaemonToolchainId = 'local-styio-lsp-daemon';

const List<String> _defaultStyioExecutableCandidates = <String>[
  '/usr/local/bin/styio',
  '/usr/bin/styio',
  '/opt/homebrew/bin/styio',
];

const List<String> _defaultStyioLspDaemonDirectories = <String>[
  '/usr/local/bin',
  '/usr/bin',
  '/opt/homebrew/bin',
];

Future<ToolchainCatalog> createPlatformStyioLanguageToolchainCatalog({
  required PlatformManagerBundle platformManagers,
  Map<String, String> environment = const <String, String>{},
  Iterable<String> candidatePaths = _defaultStyioExecutableCandidates,
  String? bundledExecutablePath,
}) async {
  final catalog = ToolchainCatalog();
  final executablePath = await _discoverManagedStyioExecutablePath(
    platformManagers,
    environment: environment,
    candidatePaths: candidatePaths,
    bundledExecutablePath: bundledExecutablePath,
  );

  final lspDaemonPath = await _discoverManagedStyioLspDaemonPath(
    platformManagers,
    environment: environment,
    candidatePaths: candidatePaths,
    bundledExecutablePath: bundledExecutablePath,
    styioExecutablePath: executablePath,
  );

  if (executablePath == null && lspDaemonPath == null) {
    return catalog;
  }

  if (executablePath != null) {
    catalog.register(
      ToolchainDescriptor(
        id: 'local-styio-language-service',
        kind: ToolchainKind.languageService,
        displayName: 'Local Styio Language Service',
        executablePath: executablePath,
        metadata: const <String, Object?>{
          'source': 'platform-discovery',
          'contract': 'styio-cli-jsonl-v1',
        },
      ),
      activate: true,
    );
  }

  if (lspDaemonPath != null) {
    // Registered as an alternative language-service asset, never activated:
    // `styio_lspd` is not a drop-in replacement for the `styio` CLI.
    catalog.register(
      ToolchainDescriptor(
        id: styioLspDaemonToolchainId,
        kind: ToolchainKind.languageService,
        displayName: 'Local Styio LSP Daemon',
        executablePath: lspDaemonPath,
        metadata: const <String, Object?>{
          'source': 'platform-discovery',
          'contract': 'styio-lsp-3.17',
          'transport': 'lsp-stdio',
        },
      ),
    );
  }
  return catalog;
}

Future<String?> _discoverManagedStyioExecutablePath(
  PlatformManagerBundle platformManagers, {
  required Map<String, String> environment,
  required Iterable<String> candidatePaths,
  String? bundledExecutablePath,
}) async {
  final isWindows =
      platformManagers.context.fileSystem.operatingSystem.toLowerCase() ==
      'windows';
  final override = environment['VITYO_STYIO_BIN'];
  for (final candidate in _executablePathCandidates(override, isWindows)) {
    if (await _isExecutablePath(platformManagers, candidate)) {
      return candidate;
    }
  }

  for (final candidate in bundledToolchainCandidatePaths(
    'styio',
    executablePath: bundledExecutablePath,
  )) {
    for (final executable in _executablePathCandidates(candidate, isWindows)) {
      if (await _isExecutablePath(platformManagers, executable)) {
        return executable;
      }
    }
  }

  for (final candidate in candidatePaths) {
    for (final executable in _executablePathCandidates(candidate, isWindows)) {
      if (await _isExecutablePath(platformManagers, executable)) {
        return executable;
      }
    }
  }

  return null;
}

Future<String?> _discoverManagedStyioLspDaemonPath(
  PlatformManagerBundle platformManagers, {
  required Map<String, String> environment,
  required Iterable<String> candidatePaths,
  String? bundledExecutablePath,
  required String? styioExecutablePath,
}) async {
  final isWindows =
      platformManagers.context.fileSystem.operatingSystem.toLowerCase() ==
      'windows';
  final override = environment['VITYO_STYIO_LSPD_BIN'];
  for (final candidate in _executablePathCandidates(override, isWindows)) {
    if (await _isExecutablePath(platformManagers, candidate)) {
      return candidate;
    }
  }

  // A daemon bundled beside the app executable, including the copy shipped
  // next to an app-bundled `styio` (same `Helpers`/`components` directory).
  for (final candidate in bundledToolchainCandidatePaths(
    'styio_lspd',
    executablePath: bundledExecutablePath,
  )) {
    for (final executable in _executablePathCandidates(candidate, isWindows)) {
      if (await _isExecutablePath(platformManagers, executable)) {
        return executable;
      }
    }
  }

  final directories = <String>{..._defaultStyioLspDaemonDirectories};
  for (final candidate in candidatePaths) {
    final directory = _directoryOf(candidate);
    if (directory.isNotEmpty) {
      directories.add(directory);
    }
  }
  final styioDirectory = _directoryOf(styioExecutablePath ?? '');
  if (styioDirectory.isNotEmpty) {
    directories.add(styioDirectory);
  }

  for (final directory in directories) {
    final base = platformManagers.fileSystem.joinPath(<String>[
      directory,
      'styio_lspd',
    ]);
    for (final candidate in _executablePathCandidates(base, isWindows)) {
      if (await _isExecutablePath(platformManagers, candidate)) {
        return candidate;
      }
    }
  }

  return null;
}

Iterable<String> _executablePathCandidates(String? path, bool isWindows) sync* {
  if (path == null || path.isEmpty) {
    return;
  }
  if (isWindows && !_hasWindowsExecutableExtension(path)) {
    yield '$path.exe';
    yield '$path.cmd';
    yield '$path.bat';
  }
  yield path;
}

String _directoryOf(String path) {
  final normalized = path.replaceAll('\\', '/');
  final separator = normalized.lastIndexOf('/');
  if (separator < 0) {
    return '';
  }
  if (separator == 0) {
    return '/';
  }
  return normalized.substring(0, separator);
}

bool _hasWindowsExecutableExtension(String path) {
  return RegExp(r'\.(bat|cmd|com|exe)$', caseSensitive: false).hasMatch(path);
}

Future<bool> _isExecutablePath(
  PlatformManagerBundle platformManagers,
  String? path,
) async {
  if (path == null || path.isEmpty) {
    return false;
  }
  try {
    if (!await platformManagers.fileSystem.exists(path)) {
      return false;
    }
    return await platformManagers.fileSystem.isExecutable(path);
  } on Object {
    return false;
  }
}
