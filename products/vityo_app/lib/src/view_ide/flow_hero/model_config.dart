/// Flow Hero's model provider configuration — the non-secret half the
/// workbench owns, and the launch-contract file the Rust coding agent reads.
///
/// The contract has three parts and they are deliberately kept apart:
///
/// * [FlowHeroModelConfig] — the user's provider facts, validated client-side
///   against exactly the rules `ProviderConfig::validate` enforces in
///   `products/vityo_coding_agent/src/providers/config.rs`.
/// * [FlowHeroProviderConfigWriter] — materializes `provider.json` at the path
///   the launch descriptor hands the executable. Nothing secret is ever in it:
///   the bearer token lives in the OS keychain under a fixed
///   `service`/`account` pair that the file only *names*.
/// * [FlowHeroAgentSecretStore] — write-only keychain access for that token.
///   The workbench can store and delete it, never read it back into the UI.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../ide/agent_client/agent_launch_paths.dart';
import '../../ide/local_service/vityod_client.dart';
import '../environment/configuration/platform_secure_credential_storage.dart';
import '../environment/system_compatibility/file_system/file_system_manager.dart';
import '../environment/system_compatibility/platform_manager/platform_manager.dart';
import 'local_services.dart';

/// The only adapter the first-party runtime accepts.
const String kFlowHeroProviderAdapter = 'openai_compatible_chat';

/// Keychain identity the runtime resolves through the `keyring` crate. The
/// Rust side calls `Entry::new(service, account)`; on macOS that is a generic
/// password item whose `kSecAttrService` is [kFlowHeroAgentProviderService] and
/// whose `kSecAttrAccount` is [kFlowHeroAgentProviderAccount].
const String kFlowHeroAgentProviderService = 'land.vityo.flow-hero.agent';
const String kFlowHeroAgentProviderAccount = 'openai-compatible';

/// Relative location of Flow Hero's non-secret model configuration under home.
const List<String> kFlowHeroModelConfigStorePathSegments = <String>[
  '.vityo',
  'flow-hero',
  'model-config.json',
];

const int kFlowHeroModelConfigSchemaVersion = 1;

/// DeepSeek's OpenAI-compatible route. The endpoint stays editable, because a
/// proxy endpoint is a normal case. The model list is fixed to the two IDs the
/// service serves today: `deepseek-flash` (DeepSeek-V4.1-Flash, vision-capable)
/// and `deepseek-v4-pro` (DeepSeek-V4-Pro-0813). `deepseek-chat` and
/// `deepseek-reasoner` are the retired V3 IDs and are deliberately absent.
const String kFlowHeroDeepSeekEndpointBase = 'https://api.deepseek.com/v1';
const List<String> kFlowHeroDeepSeekModels = <String>[
  'deepseek-flash',
  'deepseek-v4-pro',
];
const String kFlowHeroDeepSeekDefaultModel = 'deepseek-flash';

/// Both official models carry a 1M-token context window.
const int kFlowHeroDeepSeekContextTokens = 1000000;

/// The provider the user picked. It only drives the panel's defaults and
/// candidates — every route still materializes as `openai_compatible_chat`,
/// and the choice never reaches `provider.json`.
enum FlowHeroModelProvider {
  /// No defaults: the user types the endpoint and model themselves.
  custom('custom'),

  /// [kFlowHeroDeepSeekEndpointBase] and its candidate models.
  deepSeek('deepseek');

  const FlowHeroModelProvider(this.wireValue);

  final String wireValue;

  /// Field label the panel shows in its selector.
  String get label => switch (this) {
    FlowHeroModelProvider.custom => '自定义',
    FlowHeroModelProvider.deepSeek => 'DeepSeek',
  };

  /// The models the picker offers. A provider without candidates lets the user
  /// type any name.
  List<String> get modelCandidates => switch (this) {
    FlowHeroModelProvider.custom => const <String>[],
    FlowHeroModelProvider.deepSeek => kFlowHeroDeepSeekModels,
  };

  /// The model the picker falls back to. Empty for a provider that types its
  /// own name and therefore has no fixed default.
  String get defaultModel => switch (this) {
    FlowHeroModelProvider.custom => '',
    FlowHeroModelProvider.deepSeek => kFlowHeroDeepSeekDefaultModel,
  };

  /// True when [model] is one this provider serves. A provider without a fixed
  /// list accepts any name.
  bool offersModel(String model) =>
      modelCandidates.isEmpty || modelCandidates.contains(model);

  /// An absent or unrecognized value reads as [custom], so a configuration
  /// written before the selector existed still opens.
  static FlowHeroModelProvider fromWireValue(Object? value) {
    for (final FlowHeroModelProvider provider in values) {
      if (provider.wireValue == value) return provider;
    }
    return FlowHeroModelProvider.custom;
  }
}

/// Which `auth.mode` the provider config materializes.
enum FlowHeroModelAuthMode {
  /// No credential at all; `auth.secretRef` is omitted.
  none('none'),

  /// Bearer token resolved from the OS keychain through `auth.secretRef`.
  bearerToken('bearer_token');

  const FlowHeroModelAuthMode(this.wireValue);

  final String wireValue;

  static FlowHeroModelAuthMode? fromWireValue(String? value) {
    for (final FlowHeroModelAuthMode mode in FlowHeroModelAuthMode.values) {
      if (mode.wireValue == value) return mode;
    }
    return null;
  }
}

/// The provider facts a user configures. Immutable; [validate] speaks the same
/// rules the Rust runtime enforces, keyed by field for inline display.
class FlowHeroModelConfig {
  const FlowHeroModelConfig({
    this.endpointBase = '',
    this.model = '',
    this.contextTokens = 128000,
    this.supportsTools = true,
    this.maxConcurrency = 2,
    this.authMode = FlowHeroModelAuthMode.bearerToken,
    this.provider = FlowHeroModelProvider.custom,
  });

  /// Base URL of the OpenAI-compatible endpoint, e.g. `https://host/v1`.
  final String endpointBase;
  final String model;
  final int contextTokens;
  final bool supportsTools;
  final int maxConcurrency;
  final FlowHeroModelAuthMode authMode;

  /// Which provider the panel seeded the fields from. Local to the workbench:
  /// it never reaches `provider.json`.
  final FlowHeroModelProvider provider;

  FlowHeroModelConfig copyWith({
    String? endpointBase,
    String? model,
    int? contextTokens,
    bool? supportsTools,
    int? maxConcurrency,
    FlowHeroModelAuthMode? authMode,
    FlowHeroModelProvider? provider,
  }) => FlowHeroModelConfig(
    endpointBase: endpointBase ?? this.endpointBase,
    model: model ?? this.model,
    contextTokens: contextTokens ?? this.contextTokens,
    supportsTools: supportsTools ?? this.supportsTools,
    maxConcurrency: maxConcurrency ?? this.maxConcurrency,
    authMode: authMode ?? this.authMode,
    provider: provider ?? this.provider,
  );

  /// The exact rules `ProviderConfig::validate` applies, keyed by the field
  /// the settings panel shows the message under. Empty means valid.
  Map<String, String> validate() {
    final Map<String, String> errors = <String, String>{};
    final String endpoint = endpointBase.trim();
    if (endpoint.isEmpty) {
      errors['endpointBase'] = '服务端点不能为空';
    } else {
      final String? endpointError = _endpointError(endpoint);
      if (endpointError != null) errors['endpointBase'] = endpointError;
    }
    if (model.trim().isEmpty) {
      errors['model'] = '模型名不能为空';
    }
    if (contextTokens <= 0) {
      errors['contextTokens'] = '上下文窗口必须是大于 0 的整数';
    }
    if (maxConcurrency <= 0) {
      errors['maxConcurrency'] = '并发上限必须是大于 0 的整数';
    }
    return errors;
  }

  /// [validate] plus the one rule the Rust schema cannot state: a bearer-token
  /// route needs a key to actually exist in the keychain.
  Map<String, String> validateForSave({required bool hasStoredApiKey}) {
    final Map<String, String> errors = validate();
    if (authMode == FlowHeroModelAuthMode.bearerToken && !hasStoredApiKey) {
      errors['apiKey'] = '需要填写 API 密钥';
    }
    return errors;
  }

  /// The non-secret half, persisted locally so the panel reopens with the
  /// user's values. Never contains a credential.
  Map<String, Object?> toJson() => <String, Object?>{
    'endpointBase': endpointBase,
    'model': model,
    'contextTokens': contextTokens,
    'supportsTools': supportsTools,
    'maxConcurrency': maxConcurrency,
    'authMode': authMode.wireValue,
    'provider': provider.wireValue,
  };

  /// Returns null when the stored shape is not one this version wrote.
  ///
  /// `outputTokens` and `maxTotalTokens` are no longer part of the shape; a
  /// configuration that still carries them reads normally and the two keys are
  /// ignored, which is what makes the removal backward compatible.
  static FlowHeroModelConfig? fromJson(Map<String, dynamic> json) {
    final Object? endpoint = json['endpointBase'];
    final Object? model = json['model'];
    final Object? context = json['contextTokens'];
    final Object? supportsTools = json['supportsTools'];
    final Object? concurrency = json['maxConcurrency'];
    final Object? authMode = json['authMode'];
    if (endpoint is! String ||
        model is! String ||
        context is! int ||
        supportsTools is! bool ||
        concurrency is! int ||
        authMode is! String) {
      return null;
    }
    final FlowHeroModelAuthMode? mode = FlowHeroModelAuthMode.fromWireValue(
      authMode,
    );
    if (mode == null) return null;
    final FlowHeroModelProvider provider = FlowHeroModelProvider.fromWireValue(
      json['provider'],
    );
    return FlowHeroModelConfig(
      endpointBase: endpoint,
      // A DeepSeek route can only hold one of the official IDs: a stored model
      // outside the list (a retired V3 name, say) falls back to the default, so
      // the panel's selector always has a matching option.
      model: provider.offersModel(model) ? model : provider.defaultModel,
      contextTokens: context,
      supportsTools: supportsTools,
      maxConcurrency: concurrency,
      authMode: mode,
      provider: provider,
    );
  }

  /// The exact `provider.json` document the Rust runtime deserializes:
  /// camelCase, `deny_unknown_fields`, and only the limits the schema does not
  /// default. `auth.secretRef` is present only for a bearer-token route.
  ///
  /// `capabilities.outputTokens` and `limits.maxTotalTokens` are deliberately
  /// absent: both are optional in the runtime schema and a missing bound means
  /// "uncapped", so a configuration written here never caps output or the
  /// session. The `limits` key itself stays — the runtime requires the object —
  /// with nothing in it, since every field inside defaults.
  Map<String, Object?> toProviderConfigJson() => <String, Object?>{
    'adapter': kFlowHeroProviderAdapter,
    'endpointBase': endpointBase.trim(),
    'model': model.trim(),
    'capabilities': <String, Object?>{
      'contextTokens': contextTokens,
      'supportsTools': supportsTools,
      'maxConcurrency': maxConcurrency,
    },
    'limits': const <String, Object?>{},
    'auth': switch (authMode) {
      FlowHeroModelAuthMode.none => <String, Object?>{'mode': 'none'},
      FlowHeroModelAuthMode.bearerToken => <String, Object?>{
        'mode': 'bearer_token',
        'secretRef': <String, Object?>{
          'service': kFlowHeroAgentProviderService,
          'account': kFlowHeroAgentProviderAccount,
        },
      },
    },
  };
}

/// Mirrors the Rust endpoint checks: absolute URL, https only, a host, and no
/// user-info, query, or fragment.
String? _endpointError(String endpoint) {
  final Uri uri;
  try {
    uri = Uri.parse(endpoint);
  } on Object {
    return '服务端点不是有效的 URL';
  }
  if (uri.scheme != 'https') {
    return '服务端点必须是 https:// 地址';
  }
  if (uri.host.isEmpty) {
    return '服务端点缺少主机名';
  }
  if (uri.userInfo.isNotEmpty) {
    return '服务端点不能包含用户名或密码';
  }
  if (uri.hasQuery) {
    return '服务端点不能包含查询参数';
  }
  if (uri.hasFragment) {
    return '服务端点不能包含片段';
  }
  return null;
}

// ── persistence (non-secret) ──────────────────────────────────────────────

/// The persistence boundary the controller talks to. Only the non-secret half
/// is ever written here.
abstract class FlowHeroModelConfigStore {
  /// True only when the configuration survives a process restart.
  bool get persistent;

  /// The stored configuration, or null when nothing usable was stored.
  Future<FlowHeroModelConfig?> load();

  Future<void> save(FlowHeroModelConfig config);
}

/// Boots the real store, degrading to the in-process one without a failure.
class FlowHeroModelConfigStoreBoot {
  const FlowHeroModelConfigStoreBoot._();

  static Future<FlowHeroModelConfigStore> boot({
    VityodClient? vityodClient,
  }) async {
    try {
      final PlatformManagerBundle managers =
          await createDetectedPlatformManagerBundle(vityodClient: vityodClient);
      final String home = managers.context.resource.homePath?.trim() ?? '';
      if (home.isEmpty) {
        return FlowHeroMemoryModelConfigStore();
      }
      return FlowHeroFileModelConfigStore(
        fileSystem: managers.fileSystem,
        path: managers.fileSystem.joinPath(<String>[
          home,
          ...kFlowHeroModelConfigStorePathSegments,
        ]),
      );
    } on Object {
      return FlowHeroMemoryModelConfigStore();
    }
  }

  /// Resolves the real store on first use; see the theme store's twin.
  ///
  /// [localServices] supplies the shared vityod client the platform
  /// file-system manager needs; without one the "file" store reads and writes
  /// nothing while still claiming persistence.
  static FlowHeroModelConfigStore deferred({
    FlowHeroLocalServices? localServices,
  }) => _DeferredFlowHeroModelConfigStore(localServices);
}

class _DeferredFlowHeroModelConfigStore implements FlowHeroModelConfigStore {
  _DeferredFlowHeroModelConfigStore(this._localServices);

  final FlowHeroLocalServices? _localServices;
  Future<FlowHeroModelConfigStore>? _resolved;
  FlowHeroModelConfigStore? _store;

  Future<FlowHeroModelConfigStore> _resolve() async {
    final resolved = _resolved ??= _boot();
    return _store ??= await resolved;
  }

  Future<FlowHeroModelConfigStore> _boot() async =>
      FlowHeroModelConfigStoreBoot.boot(
        vityodClient: await _localServices?.client(),
      );

  @override
  bool get persistent => _store?.persistent ?? false;

  @override
  Future<FlowHeroModelConfig?> load() async => (await _resolve()).load();

  @override
  Future<void> save(FlowHeroModelConfig config) async =>
      (await _resolve()).save(config);
}

/// `model-config.json` under the home directory, read and written through the
/// platform file system manager.
class FlowHeroFileModelConfigStore implements FlowHeroModelConfigStore {
  const FlowHeroFileModelConfigStore({
    required FileSystemManager fileSystem,
    required String path,
  }) : _fileSystem = fileSystem,
       _path = path;

  final FileSystemManager _fileSystem;
  final String _path;

  @override
  bool get persistent => true;

  @override
  Future<FlowHeroModelConfig?> load() async {
    try {
      if (!await _fileSystem.exists(_path)) return null;
      final Map<String, dynamic>? decoded = _decodeObject(
        await _fileSystem.readText(_path),
      );
      if (decoded == null ||
          decoded['schemaVersion'] != kFlowHeroModelConfigSchemaVersion) {
        return null;
      }
      final Map<String, dynamic>? config = _asObject(decoded['config']);
      if (config == null) return null;
      return FlowHeroModelConfig.fromJson(config);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> save(FlowHeroModelConfig config) async {
    final String body = jsonEncode(<String, Object?>{
      'schemaVersion': kFlowHeroModelConfigSchemaVersion,
      'config': config.toJson(),
    });
    await _fileSystem.writeText(_path, '$body\n', atomic: true);
  }
}

/// In-process store: remembered for the session, gone after a restart.
class FlowHeroMemoryModelConfigStore implements FlowHeroModelConfigStore {
  FlowHeroMemoryModelConfigStore({FlowHeroModelConfig? config})
    : _config = config;

  FlowHeroModelConfig? _config;

  @override
  bool get persistent => false;

  @override
  Future<FlowHeroModelConfig?> load() async => _config;

  @override
  Future<void> save(FlowHeroModelConfig config) async {
    _config = config;
  }
}

// ── launch contract materialization ───────────────────────────────────────

/// Writes the `provider.json` the launch descriptor hands the executable.
abstract class FlowHeroProviderConfigWriter {
  /// True when a launch-contract `provider.json` exists right now.
  Future<bool> exists();

  /// Writes the exact schema the Rust runtime accepts. Never called with a
  /// configuration that failed validation.
  Future<void> write(FlowHeroModelConfig config);
}

/// Boots the real writer and, while the platform bundle resolves, refuses to
/// claim a route exists.
class FlowHeroProviderConfigWriterBoot {
  const FlowHeroProviderConfigWriterBoot._();

  static Future<FlowHeroProviderConfigWriter> boot({
    VityodClient? vityodClient,
  }) async {
    try {
      final String path = await resolvePackagedCodingAgentProviderConfigPath();
      final PlatformManagerBundle managers =
          await createDetectedPlatformManagerBundle(vityodClient: vityodClient);
      return FlowHeroFileProviderConfigWriter(
        fileSystem: managers.fileSystem,
        path: path,
      );
    } on Object {
      return const FlowHeroUnavailableProviderConfigWriter();
    }
  }

  /// Resolves the writer on first use.
  ///
  /// [localServices] supplies the shared vityod client. Without it the writer's
  /// `exists()` always answers false, which keeps the agent bridge gated in
  /// demo mode even when a real `provider.json` is on disk.
  static FlowHeroProviderConfigWriter deferred({
    FlowHeroLocalServices? localServices,
  }) => _DeferredFlowHeroProviderConfigWriter(localServices);
}

class _DeferredFlowHeroProviderConfigWriter
    implements FlowHeroProviderConfigWriter {
  _DeferredFlowHeroProviderConfigWriter(this._localServices);

  final FlowHeroLocalServices? _localServices;
  Future<FlowHeroProviderConfigWriter>? _resolved;
  FlowHeroProviderConfigWriter? _writer;

  Future<FlowHeroProviderConfigWriter> _resolve() async {
    final resolved = _resolved ??= _boot();
    return _writer ??= await resolved;
  }

  Future<FlowHeroProviderConfigWriter> _boot() async =>
      FlowHeroProviderConfigWriterBoot.boot(
        vityodClient: await _localServices?.client(),
      );

  @override
  Future<bool> exists() async => (await _resolve()).exists();

  @override
  Future<void> write(FlowHeroModelConfig config) async =>
      (await _resolve()).write(config);
}

class FlowHeroFileProviderConfigWriter implements FlowHeroProviderConfigWriter {
  const FlowHeroFileProviderConfigWriter({
    required FileSystemManager fileSystem,
    required String path,
  }) : _fileSystem = fileSystem,
       _path = path;

  final FileSystemManager _fileSystem;
  final String _path;

  @override
  Future<bool> exists() async {
    try {
      return await _fileSystem.exists(_path);
    } on Object {
      return false;
    }
  }

  @override
  Future<void> write(FlowHeroModelConfig config) async {
    final Map<String, String> errors = config.validate();
    if (errors.isNotEmpty) {
      throw ArgumentError.value(
        config,
        'config',
        'is not a valid provider configuration',
      );
    }
    final String body = jsonEncode(config.toProviderConfigJson());
    await _fileSystem.writeText(_path, '$body\n', atomic: true);
  }
}

/// No platform bundle could be built: nothing can be materialized and no route
/// may be claimed.
class FlowHeroUnavailableProviderConfigWriter
    implements FlowHeroProviderConfigWriter {
  const FlowHeroUnavailableProviderConfigWriter();

  @override
  Future<bool> exists() async => false;

  @override
  Future<void> write(FlowHeroModelConfig config) =>
      Future<void>.error(StateError('the provider config path is unavailable'));
}

// ── secret (write-only) ───────────────────────────────────────────────────

/// Write-only keychain access for the provider bearer token. There is no read
/// path by design: the token never re-enters the UI, a log, or a snapshot.
abstract class FlowHeroAgentSecretStore {
  Future<bool> hasKey();

  Future<void> saveKey(String key);

  Future<void> deleteKey();
}

/// The production keychain backend.
///
/// The `accountName` maps to `kSecAttrService` and the storage key to
/// `kSecAttrAccount`; `usesDataProtectionKeychain: false` keeps the item in the
/// user's login keychain, which is exactly the domain the Rust `keyring` crate
/// reads (`apple-native-keyring-store`, `MacKeychainDomain::User`). The mapping
/// was verified on macOS by creating an item with the plugin's exact
/// Security.framework attributes and reading it back through `keyring`
/// 4.2.0 (`v1`) — the token the workbench stores is the token the runtime
/// resolves. Interoperability on other platforms is not verified.
class FlowHeroKeychainAgentSecretStore implements FlowHeroAgentSecretStore {
  const FlowHeroKeychainAgentSecretStore({
    SecureCredentialKeyValueBackend? backend,
  }) : _backend = backend;

  final SecureCredentialKeyValueBackend? _backend;

  static const SecureCredentialKeyValueBackend _productionBackend =
      FlutterSecureStorageKeyValueBackend(
        storage: FlutterSecureStorage(
          mOptions: MacOsOptions(
            accountName: kFlowHeroAgentProviderService,
            usesDataProtectionKeychain: false,
          ),
        ),
      );

  SecureCredentialKeyValueBackend get _store => _backend ?? _productionBackend;

  @override
  Future<bool> hasKey() async {
    try {
      return await _store.containsKey(key: kFlowHeroAgentProviderAccount);
    } on Object {
      return false;
    }
  }

  @override
  Future<void> saveKey(String key) async {
    final String trimmed = key.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(key, 'key', 'must not be empty');
    }
    await _store.write(key: kFlowHeroAgentProviderAccount, value: trimmed);
  }

  @override
  Future<void> deleteKey() async {
    // A missing item is a success for the plugin, so any error here is a real
    // keychain failure and must not be reported as a cleared credential.
    await _store.delete(key: kFlowHeroAgentProviderAccount);
  }
}

// ── save result ───────────────────────────────────────────────────────────

/// What a save attempt did, stated plainly: field errors, a route failure, or
/// a configuration that is now on disk and reconnected.
class FlowHeroModelConfigSaveResult {
  const FlowHeroModelConfigSaveResult._({
    required this.saved,
    this.fieldErrors = const <String, String>{},
    this.failureMessage = '',
  });

  factory FlowHeroModelConfigSaveResult.saved() =>
      const FlowHeroModelConfigSaveResult._(saved: true);

  factory FlowHeroModelConfigSaveResult.invalid(
    Map<String, String> fieldErrors,
  ) => FlowHeroModelConfigSaveResult._(
    saved: false,
    fieldErrors: Map<String, String>.unmodifiable(fieldErrors),
  );

  factory FlowHeroModelConfigSaveResult.failed(String message) =>
      FlowHeroModelConfigSaveResult._(saved: false, failureMessage: message);

  final bool saved;
  final Map<String, String> fieldErrors;
  final String failureMessage;
}

Map<String, dynamic>? _decodeObject(String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty || !trimmed.startsWith('{')) return null;
  try {
    return _asObject(jsonDecode(trimmed));
  } on Object {
    return null;
  }
}

Map<String, dynamic>? _asObject(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is! Map) return null;
  return value.map(
    (Object? key, Object? value) => MapEntry<String, dynamic>('$key', value),
  );
}
