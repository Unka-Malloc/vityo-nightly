import 'package:flutter/foundation.dart';

import '../../module_host/module_host.dart';

final class ExtensionMarketplaceController extends ChangeNotifier {
  ExtensionMarketplaceController({
    required this.workspaceId,
    required this.installedRegistry,
    required this.log,
    this.runtime,
  }) : _preferences = ExtensionMarketplacePreferences(
         workspaceId: workspaceId(),
       ),
       _index = ExtensionMarketplaceIndex(workspaceId: workspaceId());

  final String Function() workspaceId;
  final ExtensionManifestRegistry installedRegistry;
  final void Function(String message) log;
  final ExtensionMarketplaceRuntimeServices? runtime;

  ExtensionMarketplacePreferences _preferences;
  ExtensionMarketplaceIndex _index;
  ExtensionMarketplaceInstallExecutionResult? _lastInstallResult;
  ExtensionMarketplaceIoBatchResult? _lastIoBatch;
  String _query = '';
  String _message = 'Marketplace settings have not been loaded.';
  bool _busy = false;
  bool _loaded = false;

  ExtensionMarketplacePreferences get preferences => _preferences;
  ExtensionMarketplaceIndex get index => _index;
  ExtensionMarketplaceInstallExecutionResult? get lastInstallResult =>
      _lastInstallResult;
  ExtensionMarketplaceIoBatchResult? get lastIoBatch => _lastIoBatch;
  String get query => _query;
  String get message => _message;
  bool get busy => _busy;
  bool get loaded => _loaded;
  bool get available => runtime != null;

  void setQuery(String value) {
    if (_query == value) {
      return;
    }
    _query = value;
    notifyListeners();
  }

  Future<void> load() async {
    final services = runtime;
    final activeWorkspaceId = workspaceId();
    if (services == null) {
      _loaded = true;
      _message = 'Marketplace platform services are unavailable.';
      notifyListeners();
      return;
    }
    _setBusy(true);
    try {
      _preferences = await services.settingsStore.readPreferences(
        workspaceId: activeWorkspaceId,
      );
      _index = await services.indexStore.readIndex(
        workspaceId: activeWorkspaceId,
      );
      final persistedRegistry = await services.manifestRegistryStore
          .readRegistry(workspaceId: activeWorkspaceId);
      for (final manifest in persistedRegistry.list()) {
        if (installedRegistry.lookup(manifest.extensionId) == null) {
          installedRegistry.register(manifest);
        }
      }
      _message = _preferences.configured
          ? 'Marketplace ready with ${_index.listings.length} cached listing(s).'
          : 'Set a marketplace index URL in Settings to browse extensions.';
      _loaded = true;
      log(_message);
    } on Object catch (error) {
      _message = 'Marketplace state could not be restored: $error';
      log(_message);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> savePreferences(
    ExtensionMarketplacePreferences preferences,
  ) async {
    final services = runtime;
    final next = preferences.copyWith(workspaceId: workspaceId());
    final uri = next.indexUri;
    if (next.indexUrl.trim().isNotEmpty &&
        (uri == null || !ExtensionMarketplacePlatformIo.allowsRemoteUri(uri))) {
      _message =
          'Marketplace URL must use HTTPS; loopback HTTP is allowed for local development.';
      notifyListeners();
      return;
    }
    if (services == null) {
      _message = 'Marketplace settings cannot be persisted on this platform.';
      notifyListeners();
      return;
    }
    _setBusy(true);
    try {
      await services.settingsStore.savePreferences(next);
      _preferences = next;
      _message = 'Marketplace settings saved for ${next.workspaceId}.';
      log(_message);
    } on Object catch (error) {
      _message = 'Marketplace settings save failed: $error';
      log(_message);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> refreshIndex() async {
    final services = runtime;
    final uri = _preferences.indexUri;
    if (services == null) {
      _message = 'Marketplace platform services are unavailable.';
      notifyListeners();
      return;
    }
    if (uri == null) {
      _message = 'Configure a marketplace index URL in Settings first.';
      notifyListeners();
      return;
    }
    _setBusy(true);
    try {
      final result = await services.refreshIndex(
        workspaceId: workspaceId(),
        indexUri: uri,
      );
      if (!result.completed) {
        _message = result.message;
        log(_message);
        return;
      }
      _index = await services.indexStore.readIndex(workspaceId: workspaceId());
      _message = result.message;
      log(_message);
    } on Object catch (error) {
      _message = 'Marketplace index refresh failed: $error';
      log(_message);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> install(ExtensionInstallPlan installPlan) async {
    final executionPlan = ExtensionMarketplaceInstaller(
      lifecyclePolicy: _preferences.lifecyclePolicy,
    ).planExecution(installPlan);
    final listing = installPlan.listing;
    if (!executionPlan.executable ||
        listing == null ||
        executionPlan.lifecycleDecision == null) {
      _lastInstallResult = ExtensionMarketplaceInstallExecutionResult(
        extensionId: executionPlan.extensionId,
        status: ExtensionMarketplaceInstallResultStatus.blockedPlan,
        message: executionPlan.message,
        executionPlan: executionPlan,
      );
      _message = executionPlan.message;
      notifyListeners();
      return;
    }
    final services = runtime;
    if (services == null) {
      _recordUnavailable(executionPlan);
      return;
    }
    _setBusy(true);
    try {
      final batch = await services.ioBridge.executeInstallIo(
        listing: listing,
        lifecycleDecision: executionPlan.lifecycleDecision!,
        timestamp: DateTime.now().toUtc(),
        metadata: <String, Object?>{'workspaceId': workspaceId()},
      );
      await _completePackageOperation(
        services: services,
        listing: listing,
        executionPlan: executionPlan,
        batch: batch,
        update: false,
      );
    } finally {
      _setBusy(false);
    }
  }

  Future<void> update(ExtensionMarketplaceUpdatePlan updatePlan) async {
    final listing = updatePlan.listing;
    if (!updatePlan.canUpdate || listing == null) {
      _message = updatePlan.message;
      notifyListeners();
      return;
    }
    final installPlan = ExtensionInstallPlan(
      extensionId: listing.extensionId,
      status: ExtensionInstallPlanStatus.ready,
      message: updatePlan.message,
      listing: listing,
    );
    final executionPlan = ExtensionMarketplaceInstaller(
      lifecyclePolicy: _preferences.lifecyclePolicy,
    ).planExecution(installPlan);
    final services = runtime;
    if (!executionPlan.executable || services == null) {
      _recordUnavailable(executionPlan);
      return;
    }
    _setBusy(true);
    try {
      final batch = await services.ioBridge.executeUpdateIo(
        updatePlan: updatePlan,
        timestamp: DateTime.now().toUtc(),
        metadata: <String, Object?>{'workspaceId': workspaceId()},
      );
      await _completePackageOperation(
        services: services,
        listing: listing,
        executionPlan: executionPlan,
        batch: batch,
        update: true,
      );
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _completePackageOperation({
    required ExtensionMarketplaceRuntimeServices services,
    required ExtensionMarketplaceListing listing,
    required ExtensionInstallExecutionPlan executionPlan,
    required ExtensionMarketplaceIoBatchResult batch,
    required bool update,
  }) async {
    _lastIoBatch = batch;
    if (!batch.completed) {
      final failure = batch.results.last;
      _lastInstallResult = ExtensionMarketplaceInstallExecutionResult(
        extensionId: listing.extensionId,
        status: ExtensionMarketplaceInstallResultStatus.failed,
        message: failure.message,
        executionPlan: executionPlan,
      );
      _message = failure.message;
      log(_message);
      return;
    }
    final download = batch.results.firstWhere(
      (result) =>
          result.request.kind ==
              ExtensionMarketplaceIoOperationKind.downloadPackage ||
          result.request.kind ==
              ExtensionMarketplaceIoOperationKind.downloadUpdatePackage,
    );
    final cache = batch.results.firstWhere(
      (result) =>
          result.request.kind ==
          ExtensionMarketplaceIoOperationKind.writePackageCache,
    );
    final checksum = cache.metadata['sha256'] as String? ?? '';
    final sizeBytes = cache.metadata['sizeBytes'] as int? ?? 0;
    final receipt = ExtensionPackageDownloadReceipt(
      artifact: ExtensionPackageArtifact(
        extensionId: listing.extensionId,
        sourceUri: download.artifactUri,
        cacheKey: cache.cacheKey,
        sizeBytes: sizeBytes,
        checksum: checksum,
        metadata: <String, Object?>{'artifactUri': cache.artifactUri},
      ),
      message: cache.message,
    );
    final verification = await const ListingMetadataPackageVerifier().verify(
      listing: listing,
      artifact: receipt.artifact,
    );
    if (!verification.verified) {
      _lastInstallResult = ExtensionMarketplaceInstallExecutionResult(
        extensionId: listing.extensionId,
        status: ExtensionMarketplaceInstallResultStatus.blockedVerification,
        message: verification.message,
        executionPlan: executionPlan,
        downloadReceipt: receipt,
        verificationReceipt: verification,
      );
      _message = verification.message;
      log(_message);
      return;
    }

    final previous = installedRegistry.lookup(listing.extensionId);
    if (previous != null) {
      installedRegistry.unregister(listing.extensionId);
    }
    installedRegistry.register(listing.manifest);
    try {
      await services.manifestRegistryStore.saveRegistry(
        workspaceId: workspaceId(),
        registry: installedRegistry,
      );
    } on Object catch (error) {
      installedRegistry.unregister(listing.extensionId);
      if (previous != null) {
        installedRegistry.register(previous);
      }
      _lastInstallResult = ExtensionMarketplaceInstallExecutionResult(
        extensionId: listing.extensionId,
        status: ExtensionMarketplaceInstallResultStatus.failed,
        message: 'Extension registry persistence failed: $error',
        executionPlan: executionPlan,
        downloadReceipt: receipt,
        verificationReceipt: verification,
      );
      _message = _lastInstallResult!.message;
      log(_message);
      return;
    }
    _lastInstallResult = ExtensionMarketplaceInstallExecutionResult(
      extensionId: listing.extensionId,
      status: ExtensionMarketplaceInstallResultStatus.installed,
      message: update
          ? 'Extension ${listing.extensionId} updated to ${listing.manifest.version}.'
          : 'Extension ${listing.extensionId} installed and registered.',
      executionPlan: executionPlan,
      downloadReceipt: receipt,
      verificationReceipt: verification,
      registeredManifest: listing.manifest,
    );
    _message = _lastInstallResult!.message;
    log(_message);
  }

  void _recordUnavailable(ExtensionInstallExecutionPlan executionPlan) {
    _lastInstallResult = ExtensionMarketplaceInstallExecutionResult(
      extensionId: executionPlan.extensionId,
      status: ExtensionMarketplaceInstallResultStatus.failed,
      message: 'Marketplace platform services are unavailable.',
      executionPlan: executionPlan,
    );
    _message = _lastInstallResult!.message;
    notifyListeners();
  }

  void _setBusy(bool value) {
    if (_busy == value) {
      return;
    }
    _busy = value;
    notifyListeners();
  }
}
