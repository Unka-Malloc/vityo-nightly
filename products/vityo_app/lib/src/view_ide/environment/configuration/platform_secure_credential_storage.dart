import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../platform/platform_target.dart';
import 'credential_data_store.dart';

/// Minimal key/value boundary around the platform plugin. Keeping the plugin
/// behind this interface makes credential serialization and selection fully
/// testable without a platform channel.
abstract interface class SecureCredentialKeyValueBackend {
  Future<void> write({required String key, required String value});

  Future<String?> read({required String key});

  Future<bool> containsKey({required String key});

  Future<void> delete({required String key});
}

final class FlutterSecureStorageKeyValueBackend
    implements SecureCredentialKeyValueBackend {
  const FlutterSecureStorageKeyValueBackend({
    this.storage = const FlutterSecureStorage(
      iOptions: IOSOptions(accountName: 'io.vityo.app.credentials'),
      aOptions: AndroidOptions(storageNamespace: 'vityo_credentials'),
      mOptions: MacOsOptions(
        accountName: 'io.vityo.app.credentials',
        usesDataProtectionKeychain: false,
      ),
    ),
  });

  final FlutterSecureStorage storage;

  @override
  Future<void> write({required String key, required String value}) {
    return storage.write(key: key, value: value);
  }

  @override
  Future<String?> read({required String key}) {
    return storage.read(key: key);
  }

  @override
  Future<bool> containsKey({required String key}) {
    return storage.containsKey(key: key);
  }

  @override
  Future<void> delete({required String key}) {
    return storage.delete(key: key);
  }
}

/// Stores one versioned JSON envelope per credential. The envelope is handed
/// directly to the OS-backed plugin and is never routed through preferences,
/// FoundationDataStore, logs, snapshots, or ordinary configuration state.
final class PlatformSecureJsonCredentialStorageAdapter
    extends PlatformSecureCredentialStorageAdapter {
  PlatformSecureJsonCredentialStorageAdapter({
    required this.adapterId,
    required this.backendId,
    required this.backend,
    required this.productionSupported,
    this.platformLabel = 'platform',
  });

  static const int schemaVersion = 1;
  static const String _keyPrefix = 'vityo_credentials_v1_';
  static const String _probeValue = 'vityo-secure-storage-probe-v1';
  static const String indexStorageKey = 'vityo_credentials_v1_index';

  @override
  final String adapterId;
  final String backendId;
  final SecureCredentialKeyValueBackend backend;
  final bool productionSupported;
  final String platformLabel;

  Future<CredentialDataStoreHealth>? _healthProbe;
  Future<void> _operationTail = Future<void>.value();

  @override
  Future<void> write(CredentialSecretRecord record) {
    return _serialized(() async {
      final storageKey = storageKeyFor(record.key);
      final indexedKeys = await _readIndex();
      final indexChanged = indexedKeys.add(storageKey);
      if (indexChanged) await _writeIndex(indexedKeys);
      try {
        await backend.write(
          key: storageKey,
          value: jsonEncode(<String, Object?>{
            'schemaVersion': schemaVersion,
            'record': record.toJson(),
          }),
        );
      } on Object {
        if (indexChanged) {
          indexedKeys.remove(storageKey);
          try {
            await _writeIndex(indexedKeys);
          } on Object {
            // The failed entry is ignored during the next indexed read.
          }
        }
        rethrow;
      }
    });
  }

  @override
  Future<CredentialSecretRecord?> read(CredentialDataStoreKey key) async {
    final encoded = await backend.read(key: storageKeyFor(key));
    if (encoded == null) return null;
    final record = decodeRecord(encoded);
    if (record == null || record.key.stableId != key.stableId) return null;
    return record.isExpired ? null : record;
  }

  @override
  Future<bool> delete(CredentialDataStoreKey key) {
    return _serialized(() async {
      final storageKey = storageKeyFor(key);
      if (!await backend.containsKey(key: storageKey)) return false;
      await backend.delete(key: storageKey);
      final indexedKeys = await _readIndex();
      if (indexedKeys.remove(storageKey)) {
        try {
          await _writeIndex(indexedKeys);
        } on Object {
          // A stale index entry is harmless and pruned by list().
        }
      }
      return true;
    });
  }

  @override
  Future<List<CredentialSecretRecord>> list({CredentialScope? scope}) {
    return _serialized(() async {
      final indexedKeys = await _readIndex();
      final keys = indexedKeys.toList(growable: false)..sort();
      final loaded = await Future.wait(keys.map(_readRecordForStorageKey));
      final records = <CredentialSecretRecord>[];
      final liveKeys = <String>{};
      for (var index = 0; index < keys.length; index += 1) {
        final record = loaded[index];
        if (record == null) continue;
        liveKeys.add(keys[index]);
        if (scope == null || record.key.scope == scope) {
          records.add(record);
        }
      }
      if (liveKeys.length != indexedKeys.length) {
        try {
          await _writeIndex(liveKeys);
        } on Object {
          // Listing remains valid even if stale-index cleanup is unavailable.
        }
      }
      records.sort(
        (left, right) => left.key.stableId.compareTo(right.key.stableId),
      );
      return records;
    });
  }

  @override
  Future<CredentialDataStoreHealth> health() {
    return _healthProbe ??= _probeHealth();
  }

  String storageKeyFor(CredentialDataStoreKey key) {
    final encoded = base64Url.encode(utf8.encode(key.stableId));
    return '$_keyPrefix${encoded.replaceAll('=', '')}';
  }

  CredentialSecretRecord? decodeRecord(String encoded) {
    try {
      final envelope = _stringObjectMap(jsonDecode(encoded));
      if (envelope == null || envelope['schemaVersion'] != schemaVersion) {
        return null;
      }
      final record = _stringObjectMap(envelope['record']);
      return record == null ? null : CredentialSecretRecord.fromJson(record);
    } on Object {
      return null;
    }
  }

  Future<CredentialSecretRecord?> _readRecordForStorageKey(
    String storageKey,
  ) async {
    final encoded = await backend.read(key: storageKey);
    if (encoded == null) return null;
    final record = decodeRecord(encoded);
    if (record == null || storageKeyFor(record.key) != storageKey) return null;
    return record;
  }

  Future<Set<String>> _readIndex() async {
    final encoded = await backend.read(key: indexStorageKey);
    if (encoded == null) return <String>{};
    try {
      final json = _stringObjectMap(jsonDecode(encoded));
      if (json == null || json['schemaVersion'] != schemaVersion) {
        return <String>{};
      }
      final keys = json['keys'];
      if (keys is! List) return <String>{};
      return keys
          .whereType<String>()
          .where((key) => key.startsWith(_keyPrefix) && key != indexStorageKey)
          .toSet();
    } on Object {
      return <String>{};
    }
  }

  Future<void> _writeIndex(Set<String> keys) {
    if (keys.isEmpty) return backend.delete(key: indexStorageKey);
    final sortedKeys = keys.toList(growable: false)..sort();
    return backend.write(
      key: indexStorageKey,
      value: jsonEncode(<String, Object?>{
        'schemaVersion': schemaVersion,
        'keys': sortedKeys,
      }),
    );
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        result.complete(await operation());
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  Future<CredentialDataStoreHealth> _probeHealth() async {
    if (!productionSupported) {
      return CredentialDataStoreHealth(
        protection: CredentialStorageProtection.platformSecureStorage,
        persistent: true,
        safeForLongLivedSecrets: false,
        adapterId: adapterId,
        backendId: backendId,
        productionReady: false,
        message:
            '$platformLabel secure storage is not approved for persistent production credentials.',
      );
    }

    final probeKey =
        '${_keyPrefix}health_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    var verified = false;
    try {
      await backend.write(key: probeKey, value: _probeValue);
      verified = await backend.read(key: probeKey) == _probeValue;
    } on Object {
      verified = false;
    } finally {
      try {
        await backend.delete(key: probeKey);
      } on Object {
        verified = false;
      }
    }

    return CredentialDataStoreHealth(
      protection: CredentialStorageProtection.platformSecureStorage,
      persistent: verified,
      safeForLongLivedSecrets: verified,
      adapterId: adapterId,
      backendId: backendId,
      productionReady: verified,
      message: verified
          ? '$platformLabel secure credential storage passed an isolated write/read/delete check.'
          : '$platformLabel secure credential storage is unavailable; credentials remain session-only.',
    );
  }
}

final class PlatformCredentialDataStoreBootstrap {
  const PlatformCredentialDataStoreBootstrap({
    required this.platformTarget,
    required this.registry,
    required this.selection,
    required this.dataStore,
    required this.backendHealth,
    required this.activeHealth,
  });

  final PlatformTarget platformTarget;
  final PlatformSecureCredentialStorageAdapterRegistry registry;
  final PlatformSecureCredentialStorageSelection selection;
  final CredentialDataStore dataStore;
  final CredentialDataStoreHealth backendHealth;
  final CredentialDataStoreHealth activeHealth;

  bool get usingProductionBackend => selection.selected;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'platform': platformTarget.wireValue,
      'usingProductionBackend': usingProductionBackend,
      'selection': selection.toJson(),
      'backendHealth': backendHealth.toJson(),
      'activeHealth': activeHealth.toJson(),
      'registry': registry.toJson(),
    };
  }
}

Future<PlatformCredentialDataStoreBootstrap>
createPlatformCredentialDataStoreBootstrap({
  required PlatformTarget platformTarget,
  SecureCredentialKeyValueBackend? backend,
}) async {
  final registry = PlatformSecureCredentialStorageAdapterRegistry();
  final spec = _PlatformCredentialBackendSpec.forTarget(platformTarget);
  if (spec == null) {
    final selection = registry.select(
      requireProductionReady: true,
      platformId: platformTarget.wireValue,
    );
    final fallback = CredentialStoragePolicyEnforcingDataStore(
      delegate: InMemoryCredentialDataStore(),
    );
    final activeHealth = await fallback.health();
    return PlatformCredentialDataStoreBootstrap(
      platformTarget: platformTarget,
      registry: registry,
      selection: selection,
      dataStore: fallback,
      backendHealth: const CredentialDataStoreHealth(
        protection: CredentialStorageProtection.unknown,
        persistent: false,
        safeForLongLivedSecrets: false,
        message:
            'No system secure credential backend is supported on this platform.',
      ),
      activeHealth: activeHealth,
    );
  }

  final adapter = PlatformSecureJsonCredentialStorageAdapter(
    adapterId: spec.adapterId,
    backendId: spec.backendId,
    backend: backend ?? const FlutterSecureStorageKeyValueBackend(),
    productionSupported: spec.productionSupported,
    platformLabel: spec.label,
  );
  final backendHealth = await adapter.health();
  registry.register(
    PlatformSecureCredentialStorageAdapterRegistration(
      descriptor: PlatformSecureCredentialBackendDescriptor(
        backendId: spec.backendId,
        label: spec.label,
        kind: spec.kind,
        available: spec.productionSupported
            ? backendHealth.productionReady
            : true,
        productionReady: backendHealth.productionReady,
        platformId: platformTarget.wireValue,
        message: backendHealth.message,
      ),
      adapter: adapter,
    ),
  );
  final selection = registry.select(
    requireProductionReady: true,
    platformId: platformTarget.wireValue,
  );
  final delegate = selection.toDataStore() ?? InMemoryCredentialDataStore();
  final dataStore = CredentialStoragePolicyEnforcingDataStore(
    delegate: delegate,
  );
  final activeHealth = await dataStore.health();
  return PlatformCredentialDataStoreBootstrap(
    platformTarget: platformTarget,
    registry: registry,
    selection: selection,
    dataStore: dataStore,
    backendHealth: backendHealth,
    activeHealth: activeHealth,
  );
}

final class CredentialStorageSettingsSurface {
  const CredentialStorageSettingsSurface({
    required this.platformLabel,
    required this.backendLabel,
    required this.productionReady,
    required this.persistent,
    required this.safeForLongLivedSecrets,
    required this.message,
  });

  factory CredentialStorageSettingsSurface.fromBootstrap(
    PlatformCredentialDataStoreBootstrap bootstrap,
  ) {
    final descriptor = bootstrap.selection.registration?.descriptor;
    return CredentialStorageSettingsSurface(
      platformLabel: bootstrap.platformTarget.label,
      backendLabel: descriptor?.label ?? 'Session-only credential memory',
      productionReady: bootstrap.usingProductionBackend,
      persistent: bootstrap.activeHealth.persistent,
      safeForLongLivedSecrets: bootstrap.activeHealth.safeForLongLivedSecrets,
      message: bootstrap.usingProductionBackend
          ? bootstrap.backendHealth.message
          : '${bootstrap.selection.message} ${bootstrap.backendHealth.message}',
    );
  }

  final String platformLabel;
  final String backendLabel;
  final bool productionReady;
  final bool persistent;
  final bool safeForLongLivedSecrets;
  final String message;
}

final class _PlatformCredentialBackendSpec {
  const _PlatformCredentialBackendSpec({
    required this.adapterId,
    required this.backendId,
    required this.label,
    required this.kind,
    this.productionSupported = true,
  });

  final String adapterId;
  final String backendId;
  final String label;
  final PlatformSecureCredentialBackendKind kind;
  final bool productionSupported;

  static _PlatformCredentialBackendSpec? forTarget(PlatformTarget target) {
    return switch (target) {
      PlatformTarget.macos => const _PlatformCredentialBackendSpec(
        adapterId: 'flutter-secure-storage-macos',
        backendId: 'macos-keychain',
        label: 'macOS Keychain',
        kind: PlatformSecureCredentialBackendKind.macosKeychain,
      ),
      PlatformTarget.ios => const _PlatformCredentialBackendSpec(
        adapterId: 'flutter-secure-storage-ios',
        backendId: 'ios-keychain',
        label: 'iOS Keychain',
        kind: PlatformSecureCredentialBackendKind.iosKeychain,
      ),
      PlatformTarget.android => const _PlatformCredentialBackendSpec(
        adapterId: 'flutter-secure-storage-android',
        backendId: 'android-encrypted-storage',
        label: 'Android encrypted storage',
        kind: PlatformSecureCredentialBackendKind.androidEncryptedStorage,
      ),
      PlatformTarget.windows => const _PlatformCredentialBackendSpec(
        adapterId: 'flutter-secure-storage-windows',
        backendId: 'windows-credential-manager',
        label: 'Windows secure credential storage',
        kind: PlatformSecureCredentialBackendKind.windowsCredentialManager,
      ),
      PlatformTarget.linux => const _PlatformCredentialBackendSpec(
        adapterId: 'flutter-secure-storage-linux',
        backendId: 'linux-libsecret',
        label: 'Linux libsecret',
        kind: PlatformSecureCredentialBackendKind.linuxLibsecret,
      ),
      PlatformTarget.web => const _PlatformCredentialBackendSpec(
        adapterId: 'flutter-secure-storage-web',
        backendId: 'web-crypto',
        label: 'Browser WebCrypto storage',
        kind: PlatformSecureCredentialBackendKind.webCrypto,
        productionSupported: false,
      ),
      PlatformTarget.unknown => null,
    };
  }
}

Map<String, Object?>? _stringObjectMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is! Map) return null;
  return value.map(
    (key, value) => MapEntry<String, Object?>(key.toString(), value),
  );
}
