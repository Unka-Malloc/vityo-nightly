/// Flow Hero's record of the local tool binaries the user picked.
///
/// The workbench's own `ToolchainCatalog` persists managed downloads and the
/// generic configuration store speaks a much larger schema; Flow Hero needs
/// exactly two facts — "which `pafio` did the user point at, and which `styio`"
/// — so it keeps them in a tiny `toolchain.json` written through the platform
/// file system manager (vityod-owned where one is wired) under the user's home.
///
/// The file is a fact, not a promise: a corrupted file, an unknown schema
/// version, or a field of the wrong type is rejected and reported as "nothing
/// stored" rather than guessed at. Nothing else is ever written here.
///
/// When no home directory or file system is available the store degrades to the
/// in-process one: the selection still works for the session, nothing crashes,
/// and [persistent] says which side of that line the store is on.
library;

import 'dart:convert';

import '../../ide/local_service/vityod_client.dart';
import '../environment/system_compatibility/file_system/file_system_manager.dart';
import '../environment/system_compatibility/platform_manager/platform_manager.dart';
import 'local_services.dart';

/// Relative location of Flow Hero's toolchain file under the user's home.
const List<String> kFlowHeroToolchainStorePathSegments = <String>[
  '.vityo',
  'flow-hero',
  'toolchain.json',
];

/// Schema version written by this store; anything else is rejected.
const int kFlowHeroToolchainSchemaVersion = 1;

/// The two local executables Flow Hero's execution route needs.
enum FlowHeroToolchainKind {
  pafio(
    id: 'pafio',
    environmentVariable: 'VITYO_PAFIO_BIN',
    displayName: 'pafio',
  ),
  styio(
    id: 'styio',
    environmentVariable: 'VITYO_STYIO_BIN',
    displayName: 'styio 编译器',
  );

  const FlowHeroToolchainKind({
    required this.id,
    required this.environmentVariable,
    required this.displayName,
  });

  /// Stable identifier used in `toolchain.json` and widget keys.
  final String id;

  /// The environment variable that outranks a stored selection.
  final String environmentVariable;

  /// Human label for the install dialog.
  final String displayName;
}

/// The user's stored binary choices. Empty strings mean "not overridden".
class FlowHeroToolchainSelection {
  const FlowHeroToolchainSelection({this.pafioPath = '', this.styioPath = ''});

  final String pafioPath;
  final String styioPath;

  bool get isEmpty => pafioPath.isEmpty && styioPath.isEmpty;

  bool get isNotEmpty => !isEmpty;

  String pathFor(FlowHeroToolchainKind kind) => switch (kind) {
    FlowHeroToolchainKind.pafio => pafioPath,
    FlowHeroToolchainKind.styio => styioPath,
  };

  @override
  bool operator ==(Object other) =>
      other is FlowHeroToolchainSelection &&
      other.pafioPath == pafioPath &&
      other.styioPath == styioPath;

  @override
  int get hashCode => Object.hash(pafioPath, styioPath);

  /// A copy with [kind] set to [path]; an empty [path] clears that slot.
  FlowHeroToolchainSelection withPath(FlowHeroToolchainKind kind, String path) {
    final String value = path.trim();
    return switch (kind) {
      FlowHeroToolchainKind.pafio => FlowHeroToolchainSelection(
        pafioPath: value,
        styioPath: styioPath,
      ),
      FlowHeroToolchainKind.styio => FlowHeroToolchainSelection(
        pafioPath: pafioPath,
        styioPath: value,
      ),
    };
  }
}

/// The persistence boundary the controller talks to.
abstract class FlowHeroToolchainStore {
  /// True only when the selection survives a process restart.
  bool get persistent;

  /// The stored selection, or null when nothing usable was stored.
  Future<FlowHeroToolchainSelection?> load();

  /// Stores [path] for [kind], keeping the other slot as it was.
  Future<void> savePath(FlowHeroToolchainKind kind, String path);

  /// Forgets [kind]'s stored path.
  Future<void> clearPath(FlowHeroToolchainKind kind);
}

/// Boots the real store, degrading to the in-process one without a failure.
class FlowHeroToolchainStoreBoot {
  const FlowHeroToolchainStoreBoot._();

  static Future<FlowHeroToolchainStore> boot({
    VityodClient? vityodClient,
    String? homePath,
  }) async {
    try {
      final PlatformManagerBundle managers =
          await createDetectedPlatformManagerBundle(vityodClient: vityodClient);
      final String home = (homePath ?? managers.context.resource.homePath ?? '')
          .trim();
      if (home.isEmpty) {
        return FlowHeroMemoryToolchainStore();
      }
      final String path = managers.fileSystem.joinPath(<String>[
        home,
        ...kFlowHeroToolchainStorePathSegments,
      ]);
      return FlowHeroFileToolchainStore(
        fileSystem: managers.fileSystem,
        path: path,
      );
    } on Object {
      return FlowHeroMemoryToolchainStore();
    }
  }

  /// A store that resolves the real one on first use.
  ///
  /// The packaged entrypoint must build its widget synchronously, so it hands
  /// the controller this handle: the first load or save boots the platform
  /// bundle and forwards. Nothing is probed until a selection is actually read
  /// or written, and a failed boot degrades to the in-process store.
  ///
  /// [localServices] supplies the shared vityod client. Without it the platform
  /// file-system manager is the unsupported variant, so the "file" store would
  /// claim persistence while silently storing nothing.
  static FlowHeroToolchainStore deferred({
    FlowHeroLocalServices? localServices,
    String? homePath,
  }) => _DeferredFlowHeroToolchainStore(localServices, homePath);
}

/// Lazily boots the real store; see [FlowHeroToolchainStoreBoot.deferred].
class _DeferredFlowHeroToolchainStore implements FlowHeroToolchainStore {
  _DeferredFlowHeroToolchainStore(this._localServices, this._homePath);

  final FlowHeroLocalServices? _localServices;
  final String? _homePath;
  Future<FlowHeroToolchainStore>? _resolved;
  FlowHeroToolchainStore? _store;

  Future<FlowHeroToolchainStore> _resolve() async {
    final resolved = _resolved ??= _boot();
    return _store ??= await resolved;
  }

  Future<FlowHeroToolchainStore> _boot() async =>
      FlowHeroToolchainStoreBoot.boot(
        vityodClient: await _localServices?.client(),
        homePath: _homePath,
      );

  @override
  bool get persistent => _store?.persistent ?? false;

  @override
  Future<FlowHeroToolchainSelection?> load() async => (await _resolve()).load();

  @override
  Future<void> savePath(FlowHeroToolchainKind kind, String path) async =>
      (await _resolve()).savePath(kind, path);

  @override
  Future<void> clearPath(FlowHeroToolchainKind kind) async =>
      (await _resolve()).clearPath(kind);
}

/// `toolchain.json` under the home directory, read and written through the
/// platform file system manager. Nothing here touches `dart:io` directly.
class FlowHeroFileToolchainStore implements FlowHeroToolchainStore {
  const FlowHeroFileToolchainStore({
    required FileSystemManager fileSystem,
    required String path,
  }) : _fileSystem = fileSystem,
       _path = path;

  final FileSystemManager _fileSystem;
  final String _path;

  @override
  bool get persistent => true;

  @override
  Future<FlowHeroToolchainSelection?> load() async {
    try {
      if (!await _fileSystem.exists(_path)) {
        return null;
      }
      final Map<String, dynamic>? decoded = _decode(
        await _fileSystem.readText(_path),
      );
      if (decoded == null ||
          decoded['version'] != kFlowHeroToolchainSchemaVersion) {
        return null;
      }
      final Object? pafio = decoded['pafioPath'];
      final Object? styio = decoded['styioPath'];
      // A present-but-wrong type is a corrupted file, not a partial one.
      if (pafio != null && pafio is! String) return null;
      if (styio != null && styio is! String) return null;
      return FlowHeroToolchainSelection(
        pafioPath: (pafio as String? ?? '').trim(),
        styioPath: (styio as String? ?? '').trim(),
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<void> savePath(FlowHeroToolchainKind kind, String path) async {
    final FlowHeroToolchainSelection current =
        await load() ?? const FlowHeroToolchainSelection();
    try {
      await _fileSystem.writeText(_path, _encode(current.withPath(kind, path)));
    } on Object {
      // A failed write leaves the selection session-scoped; the UI reports the
      // route's real state afterwards, so there is nothing to claim here.
    }
  }

  @override
  Future<void> clearPath(FlowHeroToolchainKind kind) async {
    await savePath(kind, '');
  }
}

/// In-process store: remembered for the session, gone after a restart.
class FlowHeroMemoryToolchainStore implements FlowHeroToolchainStore {
  FlowHeroMemoryToolchainStore([
    this._selection = const FlowHeroToolchainSelection(),
  ]);

  FlowHeroToolchainSelection _selection;

  @override
  bool get persistent => false;

  @override
  Future<FlowHeroToolchainSelection?> load() async => _selection;

  @override
  Future<void> savePath(FlowHeroToolchainKind kind, String path) async {
    _selection = _selection.withPath(kind, path);
  }

  @override
  Future<void> clearPath(FlowHeroToolchainKind kind) async {
    _selection = _selection.withPath(kind, '');
  }
}

String _encode(FlowHeroToolchainSelection selection) {
  final Map<String, Object?> payload = <String, Object?>{
    'version': kFlowHeroToolchainSchemaVersion,
    if (selection.pafioPath.isNotEmpty) 'pafioPath': selection.pafioPath,
    if (selection.styioPath.isNotEmpty) 'styioPath': selection.styioPath,
  };
  return '${jsonEncode(payload)}\n';
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
