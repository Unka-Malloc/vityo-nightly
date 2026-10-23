import 'dart:convert';

import '../environment/system_compatibility/platform_manager/platform_manager.dart';
import '../environment/system_compatibility/process/process.dart';
import 'bundled_toolchain_candidates.dart';
import 'pafio_component_manifest.dart';

const List<String> _defaultPafioSystemCandidatePaths = <String>[
  '/usr/local/bin/pafio',
  '/usr/bin/pafio',
  '/opt/homebrew/bin/pafio',
];

/// The system locations [resolvePafioBinary] probes last. Public so a caller
/// that reports *where* pafio was looked for (the Flow Hero install dialog)
/// names the real list instead of a copy.
const List<String> kDefaultPafioSystemCandidatePaths =
    _defaultPafioSystemCandidatePaths;

List<String>? _debugExecutableCandidates;

/// Replaces the entire default candidate list used by [resolvePafioBinary].
///
/// The bundled component slot is part of the defaults only: when a debug
/// override is active it is the sole source of candidates.
void debugOverridePafioExecutableCandidates(List<String>? candidates) {
  _debugExecutableCandidates = candidates == null
      ? null
      : List<String>.unmodifiable(candidates);
}

/// Resolves the `pafio` CLI, probing candidates in this order:
///
/// 1. `VITYO_PAFIO_BIN` from the injected environment (explicit override).
/// 2. [extraCandidatePaths] — a user-selected binary that takes effect once
///    the environment says nothing, and outranks the bundled component.
/// 3. The app-bundled component named by `pafio-component.json`.
/// 4. System locations.
///
/// [bundledExecutablePath] overrides the app executable the bundled layout is
/// derived from (defaults to the platform executable); [systemCandidatePaths]
/// overrides the system locations list; [extraCandidatePaths] inserts a caller
/// owned slot after the environment override. All three exist so callers (and
/// tests) can exercise ordering hermetically without changing production
/// behavior.
Future<String?> resolvePafioBinary(
  PlatformManagerBundle platformManagers, {
  Map<String, String> environment = const <String, String>{},
  String? bundledExecutablePath,
  Iterable<String> systemCandidatePaths = _defaultPafioSystemCandidatePaths,
  Iterable<String> extraCandidatePaths = const <String>[],
}) async {
  final List<String> candidates;
  if (_debugExecutableCandidates case final debugCandidates?) {
    candidates = debugCandidates;
  } else {
    final isWindows =
        platformManagers.context.fileSystem.operatingSystem == 'windows';
    final bundledCandidate = await _readBundledPafioCandidate(
      executablePath: bundledExecutablePath,
    );
    candidates = <String>[
      if (environment['VITYO_PAFIO_BIN'] case final explicit?
          when explicit.isNotEmpty)
        explicit,
      ...extraCandidatePaths.where((String path) => path.trim().isNotEmpty),
      if (bundledCandidate != null) bundledCandidate,
      if (isWindows)
        r'C:\Program Files\Pafio\pafio.exe'
      else
        ...systemCandidatePaths,
    ];
  }
  for (final candidate in candidates) {
    try {
      final result = await platformManagers.process.run(
        ProcessCommandRequest(
          executablePath: candidate,
          arguments: const <String>['--version'],
          environment: environment,
          serviceKind: ProcessServiceKind.pafio,
        ),
      );
      if (result.succeeded) return candidate;
    } on Object {
      continue;
    }
  }
  return null;
}

Future<String?> _readBundledPafioCandidate({String? executablePath}) async {
  final manifestPath = bundledPafioComponentManifestPath(
    executablePath: executablePath,
  );
  if (manifestPath == null) {
    return null;
  }
  try {
    final contents = await readBundledPafioComponentManifest(manifestPath);
    if (contents == null) {
      return null;
    }
    final decoded = jsonDecode(contents);
    if (decoded is! Map<String, dynamic> ||
        decoded['schema_version'] != 1 ||
        decoded['component'] != 'pafio') {
      return null;
    }
    final relativePath = decoded['package_relative_path'];
    if (relativePath is! String || relativePath.trim().isEmpty) {
      return null;
    }
    final normalized = relativePath.replaceAll('\\', '/');
    final segments = normalized.split('/');
    if (normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
        segments.any(
          (segment) => segment.isEmpty || segment == '.' || segment == '..',
        )) {
      return null;
    }
    final packageRoot = bundledApplicationPackageRoot(
      executablePath: executablePath,
    );
    if (packageRoot == null) {
      return null;
    }
    return '${packageRoot.replaceAll('\\', '/')}/${segments.join('/')}';
  } on Object {
    return null;
  }
}
