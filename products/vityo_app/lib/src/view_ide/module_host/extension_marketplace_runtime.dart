import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../environment/system_compatibility/system_compatibility.dart';
import '../foundation/foundation.dart';
import 'extension_manifest_contract.dart';
import 'extension_marketplace.dart';

class ExtensionMarketplacePreferences {
  const ExtensionMarketplacePreferences({
    required this.workspaceId,
    this.indexUrl = '',
    this.enableAfterInstall = true,
    this.trustVerifiedListings = true,
    this.activateTrustedAfterInstall = false,
  });

  factory ExtensionMarketplacePreferences.fromJson(
    Map<String, Object?> json, {
    required String workspaceId,
  }) {
    return ExtensionMarketplacePreferences(
      workspaceId: json['workspaceId'] as String? ?? workspaceId,
      indexUrl: json['indexUrl'] as String? ?? '',
      enableAfterInstall: json['enableAfterInstall'] as bool? ?? true,
      trustVerifiedListings: json['trustVerifiedListings'] as bool? ?? true,
      activateTrustedAfterInstall:
          json['activateTrustedAfterInstall'] as bool? ?? false,
    );
  }

  final String workspaceId;
  final String indexUrl;
  final bool enableAfterInstall;
  final bool trustVerifiedListings;
  final bool activateTrustedAfterInstall;

  Uri? get indexUri {
    final value = indexUrl.trim();
    return value.isEmpty ? null : Uri.tryParse(value);
  }

  bool get configured => indexUri != null;

  ExtensionInstallLifecyclePolicy get lifecyclePolicy {
    return ExtensionInstallLifecyclePolicy(
      enableAfterInstall: enableAfterInstall,
      trustVerifiedListings: trustVerifiedListings,
      activateTrustedAfterInstall: activateTrustedAfterInstall,
    );
  }

  ExtensionMarketplacePreferences copyWith({
    String? workspaceId,
    String? indexUrl,
    bool? enableAfterInstall,
    bool? trustVerifiedListings,
    bool? activateTrustedAfterInstall,
  }) {
    return ExtensionMarketplacePreferences(
      workspaceId: workspaceId ?? this.workspaceId,
      indexUrl: indexUrl ?? this.indexUrl,
      enableAfterInstall: enableAfterInstall ?? this.enableAfterInstall,
      trustVerifiedListings:
          trustVerifiedListings ?? this.trustVerifiedListings,
      activateTrustedAfterInstall:
          activateTrustedAfterInstall ?? this.activateTrustedAfterInstall,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'workspaceId': workspaceId,
      'indexUrl': indexUrl.trim(),
      'enableAfterInstall': enableAfterInstall,
      'trustVerifiedListings': trustVerifiedListings,
      'activateTrustedAfterInstall': activateTrustedAfterInstall,
    };
  }
}

class ExtensionMarketplaceSettingsStore {
  ExtensionMarketplaceSettingsStore.fromDataStore({
    required FoundationDataStore dataStore,
  }) : this(
         owner: FoundationDataStoreOwner(
           descriptor: const FoundationDataStoreOwnerDescriptor(
             ownerId: 'extension.marketplace-settings',
             layer: 'extension',
             stateFamily: 'extension-marketplace-settings',
             allowedNamespaces: <String>{_namespaceName},
           ),
           dataStore: dataStore,
         ),
       );

  const ExtensionMarketplaceSettingsStore({
    required FoundationDataStoreOwner owner,
  }) : _owner = owner;

  static const int schemaVersion = 1;
  static const String _namespaceName = 'extension.marketplace-settings';
  static const String _preferencesKey = 'preferences';

  final FoundationDataStoreOwner _owner;

  Future<ExtensionMarketplacePreferences> readPreferences({
    required String workspaceId,
  }) async {
    final value = await _owner.readJson(
      namespaceName: _namespaceName,
      key: _preferencesKey,
      schemaVersion: schemaVersion,
      scope: FoundationResourceScope.workspace,
      workspaceId: workspaceId,
    );
    return value == null
        ? ExtensionMarketplacePreferences(workspaceId: workspaceId)
        : ExtensionMarketplacePreferences.fromJson(
            value,
            workspaceId: workspaceId,
          ).copyWith(workspaceId: workspaceId);
  }

  Future<void> savePreferences(ExtensionMarketplacePreferences preferences) {
    return _owner.writeJson(
      namespaceName: _namespaceName,
      key: _preferencesKey,
      value: preferences.toJson(),
      schemaVersion: schemaVersion,
      scope: FoundationResourceScope.workspace,
      workspaceId: preferences.workspaceId,
    );
  }

  Future<void> saveLifecycleDecision({
    required String workspaceId,
    required ExtensionInstallLifecyclePolicyDecision decision,
  }) {
    return _owner.writeJson(
      namespaceName: _namespaceName,
      key: 'lifecycle.${decision.extensionId}',
      value: decision.toJson(),
      schemaVersion: schemaVersion,
      scope: FoundationResourceScope.workspace,
      workspaceId: workspaceId,
    );
  }

  Future<ExtensionInstallLifecyclePolicyDecision?> readLifecycleDecision({
    required String workspaceId,
    required String extensionId,
  }) async {
    final value = await _owner.readJson(
      namespaceName: _namespaceName,
      key: 'lifecycle.$extensionId',
      schemaVersion: schemaVersion,
      scope: FoundationResourceScope.workspace,
      workspaceId: workspaceId,
    );
    if (value == null) {
      return null;
    }
    return ExtensionInstallLifecyclePolicyDecision(
      extensionId: value['extensionId'] as String? ?? extensionId,
      enabledAfterInstall: value['enabledAfterInstall'] as bool? ?? false,
      trustedAfterInstall: value['trustedAfterInstall'] as bool? ?? false,
      activateAfterInstall: value['activateAfterInstall'] as bool? ?? false,
      message: value['message'] as String? ?? '',
    );
  }
}

class ExtensionMarketplaceRuntimeServices {
  const ExtensionMarketplaceRuntimeServices({
    required this.indexStore,
    required this.settingsStore,
    required this.manifestRegistryStore,
    required this.ioBridge,
  });

  factory ExtensionMarketplaceRuntimeServices.fromFoundation({
    required FoundationDataStore dataStore,
    required PlatformManagerBundle platformManagers,
  }) {
    final indexStore = ExtensionMarketplaceIndexStore.fromDataStore(
      dataStore: dataStore,
    );
    final settingsStore = ExtensionMarketplaceSettingsStore.fromDataStore(
      dataStore: dataStore,
    );
    final platformIo = ExtensionMarketplacePlatformIo(
      networkManager: platformManagers.network,
      fileSystemManager: platformManagers.fileSystem,
      resourceCoordinator: FoundationResourceCoordinator(
        resourceManager: platformManagers.resource,
        fileSystemManager: platformManagers.fileSystem,
      ),
      indexStore: indexStore,
      settingsStore: settingsStore,
    );
    return ExtensionMarketplaceRuntimeServices(
      indexStore: indexStore,
      settingsStore: settingsStore,
      manifestRegistryStore: ExtensionManifestRegistryStore.fromDataStore(
        dataStore: dataStore,
      ),
      ioBridge: ExtensionMarketplaceIoBridge(
        registry: ExtensionMarketplaceIoOperationRegistry(
          handlers: platformIo.registrations,
        ),
      ),
    );
  }

  final ExtensionMarketplaceIndexStore indexStore;
  final ExtensionMarketplaceSettingsStore settingsStore;
  final ExtensionManifestRegistryStore manifestRegistryStore;
  final ExtensionMarketplaceIoBridge ioBridge;

  Future<ExtensionMarketplaceIoOperationResult> refreshIndex({
    required String workspaceId,
    required Uri indexUri,
  }) {
    return ioBridge.registry.execute(
      ExtensionMarketplaceIoOperationRequest(
        kind: ExtensionMarketplaceIoOperationKind.fetchIndex,
        timestamp: DateTime.now().toUtc(),
        indexUri: indexUri,
        workspaceId: workspaceId,
      ),
    );
  }
}

class ExtensionMarketplacePlatformIo {
  ExtensionMarketplacePlatformIo({
    required NetworkManager networkManager,
    required FileSystemManager fileSystemManager,
    required FoundationResourceCoordinator resourceCoordinator,
    required ExtensionMarketplaceIndexStore indexStore,
    required ExtensionMarketplaceSettingsStore settingsStore,
    this.maxIndexBytes = 5 * 1024 * 1024,
    this.maxPackageBytes = 128 * 1024 * 1024,
  }) : _networkManager = networkManager,
       _fileSystemManager = fileSystemManager,
       _resourceCoordinator = resourceCoordinator,
       _indexStore = indexStore,
       _settingsStore = settingsStore;

  final NetworkManager _networkManager;
  final FileSystemManager _fileSystemManager;
  final FoundationResourceCoordinator _resourceCoordinator;
  final ExtensionMarketplaceIndexStore _indexStore;
  final ExtensionMarketplaceSettingsStore _settingsStore;
  final int maxIndexBytes;
  final int maxPackageBytes;
  final Map<String, _ExtensionMarketplacePendingDownload> _pendingDownloads =
      <String, _ExtensionMarketplacePendingDownload>{};

  List<ExtensionMarketplaceIoOperationRegistration> get registrations {
    return <ExtensionMarketplaceIoOperationRegistration>[
      _registration(
        id: 'platform.marketplace.fetch-index',
        label: 'Platform marketplace index client',
        kind: ExtensionMarketplaceIoOperationKind.fetchIndex,
        handler: _fetchIndex,
      ),
      _registration(
        id: 'platform.marketplace.download-package',
        label: 'Platform marketplace package downloader',
        kind: ExtensionMarketplaceIoOperationKind.downloadPackage,
        handler: _downloadPackage,
      ),
      _registration(
        id: 'platform.marketplace.download-update',
        label: 'Platform marketplace update downloader',
        kind: ExtensionMarketplaceIoOperationKind.downloadUpdatePackage,
        handler: _downloadPackage,
      ),
      _registration(
        id: 'platform.marketplace.write-cache',
        label: 'Foundation marketplace package cache',
        kind: ExtensionMarketplaceIoOperationKind.writePackageCache,
        handler: _writePackageCache,
      ),
      _registration(
        id: 'platform.marketplace.persist-lifecycle',
        label: 'Foundation extension lifecycle settings',
        kind: ExtensionMarketplaceIoOperationKind.persistLifecyclePolicy,
        handler: _persistLifecyclePolicy,
      ),
    ];
  }

  static bool allowsRemoteUri(Uri uri) {
    if (uri.userInfo.isNotEmpty || uri.host.isEmpty) {
      return false;
    }
    if (uri.scheme == 'https') {
      return true;
    }
    if (uri.scheme != 'http') {
      return false;
    }
    final host = uri.host.toLowerCase();
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  ExtensionMarketplaceIoOperationRegistration _registration({
    required String id,
    required String label,
    required ExtensionMarketplaceIoOperationKind kind,
    required ExtensionMarketplaceIoOperationHandler handler,
  }) {
    return ExtensionMarketplaceIoOperationRegistration(
      handlerId: id,
      label: label,
      kind: kind,
      handler: handler,
      metadata: const <String, Object?>{'implementation': 'production'},
    );
  }

  Future<ExtensionMarketplaceIoOperationResult> _fetchIndex(
    ExtensionMarketplaceIoOperationRequest request,
  ) async {
    final uri = request.indexUri;
    if (uri == null || !allowsRemoteUri(uri)) {
      return ExtensionMarketplaceIoOperationResult.blocked(
        request: request,
        message:
            'Marketplace index must use HTTPS (loopback HTTP is allowed for local development).',
      );
    }
    final response = await _networkManager.getText(uri);
    if (!response.succeeded) {
      return ExtensionMarketplaceIoOperationResult.blocked(
        request: request,
        message: response.message ?? 'Marketplace index request failed.',
        metadata: <String, Object?>{
          if (response.statusCode != null) 'statusCode': response.statusCode,
        },
      );
    }
    if (utf8.encode(response.body).length > maxIndexBytes) {
      return ExtensionMarketplaceIoOperationResult.blocked(
        request: request,
        message: 'Marketplace index exceeds the configured size limit.',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      return ExtensionMarketplaceIoOperationResult.blocked(
        request: request,
        message: 'Marketplace index must be a JSON object.',
      );
    }
    final raw = decoded.map(
      (key, value) => MapEntry<String, Object?>(key.toString(), value),
    );
    final parsed = ExtensionMarketplaceIndex.fromJson(raw);
    final index = ExtensionMarketplaceIndex(
      workspaceId: request.workspaceId,
      listings: parsed.listings,
      updatedAt: DateTime.now().toUtc(),
      schemaVersion: parsed.schemaVersion,
      extensions: parsed.extensions,
    );
    await _indexStore.saveIndex(index);
    return ExtensionMarketplaceIoOperationResult.completed(
      request: request,
      message:
          'Marketplace index refreshed with ${index.listings.length} listing(s).',
      artifactUri: uri.toString(),
      metadata: <String, Object?>{
        'listingCount': index.listings.length,
        'index': index.toJson(),
      },
    );
  }

  Future<ExtensionMarketplaceIoOperationResult> _downloadPackage(
    ExtensionMarketplaceIoOperationRequest request,
  ) async {
    final listing = request.listing;
    if (listing == null) {
      return ExtensionMarketplaceIoOperationResult.blocked(
        request: request,
        message: 'Marketplace package download requires a listing.',
      );
    }
    final uri = Uri.tryParse(listing.sourceUri);
    if (uri == null || !allowsRemoteUri(uri)) {
      return ExtensionMarketplaceIoOperationResult.blocked(
        request: request,
        message:
            'Extension package must use HTTPS (loopback HTTP is allowed for local development).',
      );
    }
    final response = await _networkManager.getBytes(uri);
    if (!response.succeeded) {
      return ExtensionMarketplaceIoOperationResult.blocked(
        request: request,
        message: response.message ?? 'Extension package download failed.',
        metadata: <String, Object?>{
          if (response.statusCode != null) 'statusCode': response.statusCode,
        },
      );
    }
    if (response.bytes.length > maxPackageBytes) {
      return ExtensionMarketplaceIoOperationResult.blocked(
        request: request,
        message: 'Extension package exceeds the configured size limit.',
      );
    }
    final checksum = sha256.convert(response.bytes).toString();
    final pending = _ExtensionMarketplacePendingDownload(
      bytes: List<int>.unmodifiable(response.bytes),
      checksum: checksum,
      sourceUri: uri,
    );
    _pendingDownloads[_downloadKey(request, listing)] = pending;
    return ExtensionMarketplaceIoOperationResult.completed(
      request: request,
      message: 'Downloaded ${listing.extensionId} for integrity verification.',
      artifactUri: uri.toString(),
      cacheKey: _relativeCacheKey(listing),
      metadata: <String, Object?>{
        'sha256': checksum,
        'sizeBytes': response.bytes.length,
      },
    );
  }

  Future<ExtensionMarketplaceIoOperationResult> _writePackageCache(
    ExtensionMarketplaceIoOperationRequest request,
  ) async {
    final listing = request.listing;
    if (listing == null) {
      return ExtensionMarketplaceIoOperationResult.blocked(
        request: request,
        message: 'Marketplace cache write requires a listing.',
      );
    }
    final key = _downloadKey(request, listing);
    final pending = _pendingDownloads.remove(key);
    if (pending == null) {
      return ExtensionMarketplaceIoOperationResult.blocked(
        request: request,
        message: 'No downloaded package is available for cache staging.',
      );
    }
    if (!listing.installVerified ||
        pending.checksum != listing.expectedSha256) {
      return ExtensionMarketplaceIoOperationResult.blocked(
        request: request,
        message:
            'Extension package SHA-256 does not match verified marketplace metadata.',
        metadata: <String, Object?>{
          'actualSha256': pending.checksum,
          if (listing.expectedSha256.isNotEmpty)
            'expectedSha256': listing.expectedSha256,
        },
      );
    }
    final workspaceId = _workspaceId(request);
    final root = _resourceCoordinator
        .location(
          kind: FoundationResourceKind.workspaceCache,
          namespace: 'extension-marketplace-packages',
          scope: FoundationResourceScope.workspace,
          workspaceId: workspaceId,
        )
        .path;
    final packagePath = _fileSystemManager.joinPath(<String>[
      root,
      _safeSegment(listing.extensionId),
      _safeSegment(listing.manifest.version),
      'package.bin',
    ]);
    FileSystemBoundaryGuard(
      fileSystemManager: _fileSystemManager,
      rootPath: root,
      sourceManager: 'ExtensionMarketplacePlatformIo',
    ).requireWithin(packagePath, operation: 'writeMarketplacePackageCache');
    await _fileSystemManager.writeBytes(packagePath, pending.bytes);
    await _fileSystemManager.writeText(
      _fileSystemManager.joinPath(<String>[
        root,
        _safeSegment(listing.extensionId),
        _safeSegment(listing.manifest.version),
        'receipt.json',
      ]),
      jsonEncode(<String, Object?>{
        'extensionId': listing.extensionId,
        'version': listing.manifest.version,
        'sha256': pending.checksum,
        'sizeBytes': pending.bytes.length,
        'sourceUri': pending.sourceUri.toString(),
        'cachedAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    return ExtensionMarketplaceIoOperationResult.completed(
      request: request,
      message: 'Verified package cached for ${listing.extensionId}.',
      artifactUri: _fileSystemManager.toFileUri(packagePath).toString(),
      cacheKey: _relativeCacheKey(listing),
      metadata: <String, Object?>{
        'sha256': pending.checksum,
        'sizeBytes': pending.bytes.length,
      },
    );
  }

  Future<ExtensionMarketplaceIoOperationResult> _persistLifecyclePolicy(
    ExtensionMarketplaceIoOperationRequest request,
  ) async {
    final decision = request.lifecycleDecision;
    if (decision == null) {
      return ExtensionMarketplaceIoOperationResult.blocked(
        request: request,
        message: 'Extension install lifecycle decision is missing.',
      );
    }
    await _settingsStore.saveLifecycleDecision(
      workspaceId: _workspaceId(request),
      decision: decision,
    );
    return ExtensionMarketplaceIoOperationResult.completed(
      request: request,
      message: 'Extension install lifecycle decision persisted.',
    );
  }

  String _downloadKey(
    ExtensionMarketplaceIoOperationRequest request,
    ExtensionMarketplaceListing listing,
  ) {
    return '${_workspaceId(request)}:${listing.extensionId}:${listing.manifest.version}';
  }

  String _workspaceId(ExtensionMarketplaceIoOperationRequest request) {
    if (request.workspaceId.trim().isNotEmpty) {
      return request.workspaceId.trim();
    }
    final value = request.metadata['workspaceId'];
    return value is String && value.trim().isNotEmpty
        ? value.trim()
        : 'default';
  }

  String _relativeCacheKey(ExtensionMarketplaceListing listing) {
    return '${_safeSegment(listing.extensionId)}/${_safeSegment(listing.manifest.version)}/package.bin';
  }

  String _safeSegment(String value) {
    return value
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
  }
}

class _ExtensionMarketplacePendingDownload {
  const _ExtensionMarketplacePendingDownload({
    required this.bytes,
    required this.checksum,
    required this.sourceUri,
  });

  final List<int> bytes;
  final String checksum;
  final Uri sourceUri;
}
