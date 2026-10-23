/// Flow Hero's own light/dark preference, kept honest.
///
/// Flow Hero's palette is a binary (`P.dark`), so the persisted contract is
/// binary too: a tiny `theme.json` written through the platform file system
/// manager (vityod-owned where one is wired) under the user's home. The
/// workbench's `VityoThemeOverrideStore` is deliberately not reused here — it
/// speaks colour presets and workspace scope, and mapping "obsidian/parchment"
/// onto Flow Hero's day/night switch would be a story rather than a fact.
///
/// When no home directory or file system is available the store degrades to an
/// in-process one: the choice still works for the session, nothing crashes,
/// and [persistent] says which side of that line the store is on.
library;

import 'dart:convert';

import '../../ide/local_service/vityod_client.dart';
import '../environment/system_compatibility/file_system/file_system_manager.dart';
import '../environment/system_compatibility/platform_manager/platform_manager.dart';
import 'local_services.dart';

/// Relative location of Flow Hero's settings file under the user's home.
const List<String> kFlowHeroThemeStorePathSegments = <String>[
  '.vityo',
  'flow-hero',
  'theme.json',
];

const int _schemaVersion = 1;

/// The persistence boundary the controller talks to.
abstract class FlowHeroThemeStore {
  /// True only when the choice survives a process restart.
  bool get persistent;

  /// The stored choice, or null when nothing was stored yet.
  Future<bool?> loadDark();

  Future<void> saveDark(bool dark);
}

/// Boots the real store, degrading to the in-process one without a failure.
///
/// Never throws: a missing home directory or an unbuildable platform bundle
/// yields a session-scoped store.
class FlowHeroThemeStoreBoot {
  const FlowHeroThemeStoreBoot._();

  static Future<FlowHeroThemeStore> boot({VityodClient? vityodClient}) async {
    try {
      final PlatformManagerBundle managers =
          await createDetectedPlatformManagerBundle(vityodClient: vityodClient);
      final String home = managers.context.resource.homePath?.trim() ?? '';
      if (home.isEmpty) {
        return FlowHeroMemoryThemeStore();
      }
      final String path = managers.fileSystem.joinPath(<String>[
        home,
        ...kFlowHeroThemeStorePathSegments,
      ]);
      return FlowHeroFileThemeStore(
        fileSystem: managers.fileSystem,
        path: path,
      );
    } on Object {
      return FlowHeroMemoryThemeStore();
    }
  }

  /// A store that resolves the real one on first use.
  ///
  /// The packaged entrypoint must build its widget synchronously, so it hands
  /// `FlowHeroApp` this handle: the first load or save boots the platform
  /// bundle and forwards. Nothing is probed until a choice is actually read or
  /// written, and a failed boot degrades to the in-process store.
  ///
  /// [localServices] supplies the shared vityod client the platform
  /// file-system manager needs; without one the "file" store persists nothing.
  static FlowHeroThemeStore deferred({FlowHeroLocalServices? localServices}) =>
      _DeferredFlowHeroThemeStore(localServices);
}

/// Lazily boots the real store; see [FlowHeroThemeStoreBoot.deferred].
class _DeferredFlowHeroThemeStore implements FlowHeroThemeStore {
  _DeferredFlowHeroThemeStore(this._localServices);

  final FlowHeroLocalServices? _localServices;
  Future<FlowHeroThemeStore>? _resolved;
  FlowHeroThemeStore? _store;

  Future<FlowHeroThemeStore> _resolve() async {
    final resolved = _resolved ??= _boot();
    return _store ??= await resolved;
  }

  Future<FlowHeroThemeStore> _boot() async =>
      FlowHeroThemeStoreBoot.boot(vityodClient: await _localServices?.client());

  @override
  bool get persistent => _store?.persistent ?? false;

  @override
  Future<bool?> loadDark() async => (await _resolve()).loadDark();

  @override
  Future<void> saveDark(bool dark) async => (await _resolve()).saveDark(dark);
}

/// `theme.json` under the home directory, read and written through the
/// platform file system manager. Nothing here touches `dart:io` directly.
class FlowHeroFileThemeStore implements FlowHeroThemeStore {
  const FlowHeroFileThemeStore({
    required FileSystemManager fileSystem,
    required String path,
  }) : _fileSystem = fileSystem,
       _path = path;

  final FileSystemManager _fileSystem;
  final String _path;

  @override
  bool get persistent => true;

  @override
  Future<bool?> loadDark() async {
    try {
      if (!await _fileSystem.exists(_path)) {
        return null;
      }
      final Map<String, dynamic>? decoded = _decode(
        await _fileSystem.readText(_path),
      );
      if (decoded == null || decoded['schemaVersion'] != _schemaVersion) {
        return null;
      }
      final Object? dark = decoded['dark'];
      return dark is bool ? dark : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> saveDark(bool dark) async {
    try {
      await _fileSystem.writeText(
        _path,
        '{"schemaVersion": $_schemaVersion, "dark": $dark}\n',
      );
    } on Object {
      // A failed write leaves the choice session-scoped; the UI already shows
      // the applied palette, so there is nothing honest to report here.
    }
  }
}

/// In-process store: remembered for the session, gone after a restart.
class FlowHeroMemoryThemeStore implements FlowHeroThemeStore {
  FlowHeroMemoryThemeStore({bool? dark}) : _dark = dark;

  bool? _dark;

  @override
  bool get persistent => false;

  @override
  Future<bool?> loadDark() async => _dark;

  @override
  Future<void> saveDark(bool dark) async {
    _dark = dark;
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
