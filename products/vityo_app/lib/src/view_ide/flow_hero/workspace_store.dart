/// Flow Hero's record of the workspace root the user chose at runtime.
///
/// The build-time `VITYO_WORKSPACE` (`AgentBridge.workspaceDir`) is a compile
/// fact and cannot change while the app runs; the user's choice can. Flow Hero
/// stores exactly one fact — the selected absolute directory — in a tiny
/// `workspace.json` written through the platform file system manager
/// (vityod-owned where one is wired) under the user's home. Nothing else is
/// ever written here.
///
/// The file is a fact, not a promise: a corrupted file, an unknown schema
/// version, or a field of the wrong type is rejected and reported as "nothing
/// stored" rather than guessed at.
///
/// When no home directory or file system is available the store degrades to the
/// in-process one: the choice still works for the session, nothing crashes, and
/// [persistent] says which side of that line the store is on.
library;

import 'dart:convert';

import '../../ide/local_service/vityod_client.dart';
import '../environment/system_compatibility/file_system/file_system_manager.dart';
import '../environment/system_compatibility/platform_manager/platform_manager.dart';
import 'local_services.dart';

/// Relative location of Flow Hero's workspace file under the user's home.
const List<String> kFlowHeroWorkspaceStorePathSegments = <String>[
  '.vityo',
  'flow-hero',
  'workspace.json',
];

/// Schema version written by this store; anything else is rejected.
const int kFlowHeroWorkspaceSchemaVersion = 1;

/// The persistence boundary the controller talks to.
abstract class FlowHeroWorkspaceStore {
  /// True only when the choice survives a process restart.
  bool get persistent;

  /// The stored root path, or null when nothing usable was stored.
  Future<String?> load();

  /// Stores [path] as the selected workspace root.
  Future<void> save(String path);
}

/// Boots the real store, degrading to the in-process one without a failure.
class FlowHeroWorkspaceStoreBoot {
  const FlowHeroWorkspaceStoreBoot._();

  static Future<FlowHeroWorkspaceStore> boot({
    VityodClient? vityodClient,
  }) async {
    try {
      final PlatformManagerBundle managers =
          await createDetectedPlatformManagerBundle(vityodClient: vityodClient);
      final String home = managers.context.resource.homePath?.trim() ?? '';
      if (home.isEmpty) {
        return FlowHeroMemoryWorkspaceStore();
      }
      final String path = managers.fileSystem.joinPath(<String>[
        home,
        ...kFlowHeroWorkspaceStorePathSegments,
      ]);
      return FlowHeroFileWorkspaceStore(
        fileSystem: managers.fileSystem,
        path: path,
      );
    } on Object {
      return FlowHeroMemoryWorkspaceStore();
    }
  }

  /// A store that resolves the real one on first use.
  ///
  /// The packaged entrypoint must build its widget synchronously, so it hands
  /// the controller this handle: the first load or save boots the platform
  /// bundle and forwards. Nothing is probed until a choice is actually read or
  /// written, and a failed boot degrades to the in-process store.
  ///
  /// [localServices] supplies the shared vityod client the platform file-system
  /// manager needs; without one the "file" store persists nothing.
  static FlowHeroWorkspaceStore deferred({
    FlowHeroLocalServices? localServices,
  }) => _DeferredFlowHeroWorkspaceStore(localServices);
}

/// Lazily boots the real store; see [FlowHeroWorkspaceStoreBoot.deferred].
class _DeferredFlowHeroWorkspaceStore implements FlowHeroWorkspaceStore {
  _DeferredFlowHeroWorkspaceStore(this._localServices);

  final FlowHeroLocalServices? _localServices;
  Future<FlowHeroWorkspaceStore>? _resolved;
  FlowHeroWorkspaceStore? _store;

  Future<FlowHeroWorkspaceStore> _resolve() async {
    final resolved = _resolved ??= _boot();
    return _store ??= await resolved;
  }

  Future<FlowHeroWorkspaceStore> _boot() async =>
      FlowHeroWorkspaceStoreBoot.boot(
        vityodClient: await _localServices?.client(),
      );

  @override
  bool get persistent => _store?.persistent ?? false;

  @override
  Future<String?> load() async => (await _resolve()).load();

  @override
  Future<void> save(String path) async => (await _resolve()).save(path);
}

/// `workspace.json` under the home directory, read and written through the
/// platform file system manager. Nothing here touches `dart:io` directly.
class FlowHeroFileWorkspaceStore implements FlowHeroWorkspaceStore {
  const FlowHeroFileWorkspaceStore({
    required FileSystemManager fileSystem,
    required String path,
  }) : _fileSystem = fileSystem,
       _path = path;

  final FileSystemManager _fileSystem;
  final String _path;

  @override
  bool get persistent => true;

  @override
  Future<String?> load() async {
    try {
      if (!await _fileSystem.exists(_path)) {
        return null;
      }
      final Map<String, dynamic>? decoded = _decode(
        await _fileSystem.readText(_path),
      );
      if (decoded == null ||
          decoded['version'] != kFlowHeroWorkspaceSchemaVersion) {
        return null;
      }
      final Object? rootPath = decoded['rootPath'];
      if (rootPath is! String) return null;
      final String trimmed = rootPath.trim();
      return trimmed.isEmpty ? null : trimmed;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> save(String path) async {
    final String trimmed = path.trim();
    if (trimmed.isEmpty) return;
    try {
      await _fileSystem.writeText(
        _path,
        '${jsonEncode(<String, Object?>{'version': kFlowHeroWorkspaceSchemaVersion, 'rootPath': trimmed})}\n',
      );
    } on Object {
      // A failed write leaves the choice session-scoped; the UI already shows
      // the applied root, so there is nothing honest to claim here.
    }
  }
}

/// In-process store: remembered for the session, gone after a restart.
class FlowHeroMemoryWorkspaceStore implements FlowHeroWorkspaceStore {
  FlowHeroMemoryWorkspaceStore([this._rootPath]);

  String? _rootPath;

  @override
  bool get persistent => false;

  @override
  Future<String?> load() async => _rootPath;

  @override
  Future<void> save(String path) async {
    final String trimmed = path.trim();
    if (trimmed.isEmpty) return;
    _rootPath = trimmed;
  }
}

Map<String, dynamic>? _decode(String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty || !trimmed.startsWith('{')) {
    return null;
  }
  try {
    final Object? decoded = jsonDecode(trimmed);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on Object {
    return null;
  }
}
