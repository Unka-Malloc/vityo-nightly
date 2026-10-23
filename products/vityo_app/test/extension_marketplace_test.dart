import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';
import 'package:vityo_app/src/view_ide/foundation/foundation.dart';
import 'package:vityo_app/src/view_ide/module_host/module_host.dart';
import 'package:vityo_app/src/view_ide/shell_runtime/controllers/extension_marketplace_controller.dart';

import 'support/test_file_system_manager.dart';

const _fixtureSha256 =
    '0000000000000000000000000000000000000000000000000000000000000000';

void main() {
  test('extension marketplace index searches and plans installs', () {
    const listing = ExtensionMarketplaceListing(
      manifest: ExtensionManifest(
        extensionId: 'styio.language',
        displayName: 'Styio Language',
        version: '1.0.0',
        publisher: 'vityo',
        entrypoint: 'styio_language.dart',
        description: 'Styio language service extension',
      ),
      sourceUri: 'https://marketplace.vityo.invalid/styio.language-1.0.0.zip',
      summary: 'Language support for Styio projects.',
      categories: <String>['language', 'styio'],
      verified: true,
      metadata: <String, Object?>{'sha256': _fixtureSha256},
    );
    const invalidListing = ExtensionMarketplaceListing(
      manifest: ExtensionManifest(
        extensionId: 'broken.extension',
        displayName: 'Broken Extension',
        version: '1.0.0',
        publisher: 'vityo',
        entrypoint: 'broken.dart',
      ),
      sourceUri: '',
    );
    const index = ExtensionMarketplaceIndex(
      workspaceId: 'demo',
      listings: <ExtensionMarketplaceListing>[invalidListing, listing],
    );

    expect(index.search('styio').single.extensionId, 'styio.language');
    expect(
      index
          .installPlan(
            installedRegistry: ExtensionManifestRegistry(),
            extensionId: 'styio.language',
          )
          .status,
      ExtensionInstallPlanStatus.ready,
    );
    expect(
      index
          .installPlan(
            installedRegistry: ExtensionManifestRegistry()
              ..register(listing.manifest),
            extensionId: 'styio.language',
          )
          .status,
      ExtensionInstallPlanStatus.alreadyInstalled,
    );
    expect(
      index
          .installPlan(
            installedRegistry: ExtensionManifestRegistry(),
            extensionId: 'broken.extension',
          )
          .status,
      ExtensionInstallPlanStatus.blockedInvalidListing,
    );
    expect(
      ExtensionMarketplaceIndex.fromJson(
        index.toJson(),
      ).lookup('styio.language'),
      isNotNull,
    );
  });

  test(
    'extension marketplace update plan compares installed listing versions',
    () {
      const installed = ExtensionManifest(
        extensionId: 'styio.language',
        displayName: 'Styio Language',
        version: '1.0.0',
        publisher: 'vityo',
        entrypoint: 'styio_language.dart',
      );
      const listing = ExtensionMarketplaceListing(
        manifest: ExtensionManifest(
          extensionId: 'styio.language',
          displayName: 'Styio Language',
          version: '1.1.0',
          publisher: 'vityo',
          entrypoint: 'styio_language.dart',
        ),
        sourceUri: 'https://marketplace.vityo.invalid/styio.language-1.1.0.zip',
        verified: true,
        metadata: <String, Object?>{'sha256': _fixtureSha256},
      );
      final registry = ExtensionManifestRegistry()..register(installed);

      final plan = ExtensionMarketplaceUpdatePlan.fromListing(
        listing: listing,
        installedRegistry: registry,
      );

      expect(plan.status, ExtensionMarketplaceUpdateStatus.updateAvailable);
      expect(plan.canUpdate, isTrue);
      expect(plan.installedVersion, '1.0.0');
      expect(plan.availableVersion, '1.1.0');
      expect(plan.toJson()['status'], 'update-available');
    },
  );

  test('extension marketplace installer composes execution steps', () {
    const listing = ExtensionMarketplaceListing(
      manifest: ExtensionManifest(
        extensionId: 'styio.language',
        displayName: 'Styio Language',
        version: '1.0.0',
        publisher: 'vityo',
        entrypoint: 'styio_language.dart',
        trustedByDefault: true,
        metadata: <String, Object?>{'isolationMode': 'local-process'},
      ),
      sourceUri: 'https://marketplace.vityo.invalid/styio.language-1.0.0.zip',
      verified: true,
      metadata: <String, Object?>{'sha256': _fixtureSha256},
    );
    const index = ExtensionMarketplaceIndex(
      workspaceId: 'demo',
      listings: <ExtensionMarketplaceListing>[listing],
    );
    final installPlan = index.installPlan(
      installedRegistry: ExtensionManifestRegistry(),
      extensionId: 'styio.language',
    );

    final executionPlan = const ExtensionMarketplaceInstaller().planExecution(
      installPlan,
    );

    expect(executionPlan.status, ExtensionInstallExecutionStatus.ready);
    expect(executionPlan.executable, isTrue);
    expect(
      executionPlan.steps.map((step) => step.kind).toList(growable: false),
      <ExtensionInstallExecutionStepKind>[
        ExtensionInstallExecutionStepKind.downloadPackage,
        ExtensionInstallExecutionStepKind.verifyPackageIntegrity,
        ExtensionInstallExecutionStepKind.registerManifest,
        ExtensionInstallExecutionStepKind.applyLifecyclePolicy,
        ExtensionInstallExecutionStepKind.planHostIsolation,
      ],
    );
    expect(
      executionPlan.hostExecutionPlan?.mode,
      ExtensionHostIsolationMode.localProcess,
    );
    expect(executionPlan.lifecycleDecision?.trustedAfterInstall, isTrue);
    expect(executionPlan.toJson()['status'], 'ready');
  });

  test('extension marketplace installer blocks unverified packages', () {
    const listing = ExtensionMarketplaceListing(
      manifest: ExtensionManifest(
        extensionId: 'external.theme',
        displayName: 'External Theme',
        version: '1.0.0',
        publisher: 'external',
        entrypoint: 'theme.dart',
        trustedByDefault: true,
      ),
      sourceUri: 'https://marketplace.vityo.invalid/external.theme-1.0.0.zip',
    );
    const index = ExtensionMarketplaceIndex(
      workspaceId: 'demo',
      listings: <ExtensionMarketplaceListing>[listing],
    );
    final installPlan = index.installPlan(
      installedRegistry: ExtensionManifestRegistry(),
      extensionId: 'external.theme',
    );

    final executionPlan = const ExtensionMarketplaceInstaller().planExecution(
      installPlan,
    );

    expect(
      executionPlan.status,
      ExtensionInstallExecutionStatus.blockedUnverifiedPackage,
    );
    expect(executionPlan.executable, isFalse);
    expect(
      executionPlan.steps
          .singleWhere(
            (step) =>
                step.kind ==
                ExtensionInstallExecutionStepKind.verifyPackageIntegrity,
          )
          .ready,
      isFalse,
    );
  });

  test(
    'extension marketplace install executor downloads verifies and registers',
    () async {
      const listing = ExtensionMarketplaceListing(
        manifest: ExtensionManifest(
          extensionId: 'styio.language',
          displayName: 'Styio Language',
          version: '1.0.0',
          publisher: 'vityo',
          entrypoint: 'styio_language.dart',
          trustedByDefault: true,
        ),
        sourceUri: 'https://marketplace.vityo.invalid/styio.language-1.0.0.zip',
        verified: true,
        metadata: <String, Object?>{'sha256': _fixtureSha256},
      );
      const index = ExtensionMarketplaceIndex(
        workspaceId: 'demo',
        listings: <ExtensionMarketplaceListing>[listing],
      );
      final registry = ExtensionManifestRegistry();
      final installPlan = index.installPlan(
        installedRegistry: registry,
        extensionId: 'styio.language',
      );
      final executionPlan = const ExtensionMarketplaceInstaller().planExecution(
        installPlan,
      );
      const executor = ExtensionMarketplaceInstallExecutor(
        downloader: _FakePackageDownloader(),
      );

      final result = await executor.execute(
        executionPlan: executionPlan,
        installedRegistry: registry,
      );

      expect(result.installed, isTrue);
      expect(result.status, ExtensionMarketplaceInstallResultStatus.installed);
      expect(
        result.downloadReceipt?.artifact.cacheKey,
        'cache/styio.language.zip',
      );
      expect(result.verificationReceipt?.verified, isTrue);
      expect(registry.lookup('styio.language'), isNotNull);
      expect(
        result.toJson()['registeredManifest'],
        isA<Map<String, Object?>>(),
      );
    },
  );

  test(
    'extension marketplace install executor blocks failed verification',
    () async {
      const listing = ExtensionMarketplaceListing(
        manifest: ExtensionManifest(
          extensionId: 'external.theme',
          displayName: 'External Theme',
          version: '1.0.0',
          publisher: 'external',
          entrypoint: 'theme.dart',
          trustedByDefault: true,
        ),
        sourceUri: 'https://marketplace.vityo.invalid/external.theme.zip',
        verified: true,
        metadata: <String, Object?>{'sha256': _fixtureSha256},
      );
      const index = ExtensionMarketplaceIndex(
        workspaceId: 'demo',
        listings: <ExtensionMarketplaceListing>[listing],
      );
      final registry = ExtensionManifestRegistry();
      final installPlan = index.installPlan(
        installedRegistry: registry,
        extensionId: 'external.theme',
      );
      final executionPlan = const ExtensionMarketplaceInstaller().planExecution(
        installPlan,
      );
      const executor = ExtensionMarketplaceInstallExecutor(
        downloader: _FakePackageDownloader(),
        verifier: _RejectingPackageVerifier(),
      );

      final result = await executor.execute(
        executionPlan: executionPlan,
        installedRegistry: registry,
      );

      expect(
        result.status,
        ExtensionMarketplaceInstallResultStatus.blockedVerification,
      );
      expect(result.installed, isFalse);
      expect(result.verificationReceipt?.verified, isFalse);
      expect(registry.lookup('external.theme'), isNull);
    },
  );

  test(
    'extension marketplace IO bridge executes install operations in order',
    () async {
      const listing = ExtensionMarketplaceListing(
        manifest: ExtensionManifest(
          extensionId: 'styio.language',
          displayName: 'Styio Language',
          version: '1.0.0',
          publisher: 'vityo',
          entrypoint: 'styio_language.dart',
          trustedByDefault: true,
        ),
        sourceUri: 'https://marketplace.vityo.invalid/styio.language.zip',
        verified: true,
        metadata: <String, Object?>{'sha256': _fixtureSha256},
      );
      const lifecycleDecision = ExtensionInstallLifecyclePolicyDecision(
        extensionId: 'styio.language',
        enabledAfterInstall: true,
        trustedAfterInstall: true,
        activateAfterInstall: true,
        message: 'Enable trusted extension after install.',
      );
      final observedKinds = <ExtensionMarketplaceIoOperationKind>[];
      late ExtensionMarketplaceIoOperationRegistration downloadHandler;
      late ExtensionMarketplaceIoOperationRegistration cacheHandler;
      late ExtensionMarketplaceIoOperationRegistration lifecycleHandler;
      downloadHandler = _marketplaceIoHandler(
        id: 'download',
        kind: ExtensionMarketplaceIoOperationKind.downloadPackage,
        observedKinds: observedKinds,
        cacheKey: 'cache/styio.language.zip',
        self: () => downloadHandler,
      );
      cacheHandler = _marketplaceIoHandler(
        id: 'cache',
        kind: ExtensionMarketplaceIoOperationKind.writePackageCache,
        observedKinds: observedKinds,
        cacheKey: 'cache/styio.language.zip',
        self: () => cacheHandler,
      );
      lifecycleHandler = _marketplaceIoHandler(
        id: 'lifecycle',
        kind: ExtensionMarketplaceIoOperationKind.persistLifecyclePolicy,
        observedKinds: observedKinds,
        self: () => lifecycleHandler,
      );
      final bridge = ExtensionMarketplaceIoBridge(
        registry: ExtensionMarketplaceIoOperationRegistry(
          handlers: <ExtensionMarketplaceIoOperationRegistration>[
            downloadHandler,
            cacheHandler,
            lifecycleHandler,
          ],
        ),
      );

      final result = await bridge.executeInstallIo(
        listing: listing,
        lifecycleDecision: lifecycleDecision,
        timestamp: DateTime.utc(2026, 5, 21),
      );

      expect(result.completed, isTrue);
      expect(observedKinds, <ExtensionMarketplaceIoOperationKind>[
        ExtensionMarketplaceIoOperationKind.downloadPackage,
        ExtensionMarketplaceIoOperationKind.writePackageCache,
        ExtensionMarketplaceIoOperationKind.persistLifecyclePolicy,
      ]);
      expect(result.results.first.cacheKey, 'cache/styio.language.zip');
      expect(result.toJson()['resultCount'], 3);
    },
  );

  test(
    'extension marketplace IO bridge executes update download flow',
    () async {
      const listing = ExtensionMarketplaceListing(
        manifest: ExtensionManifest(
          extensionId: 'styio.language',
          displayName: 'Styio Language',
          version: '1.1.0',
          publisher: 'vityo',
          entrypoint: 'styio_language.dart',
        ),
        sourceUri: 'https://marketplace.vityo.invalid/styio.language-1.1.0.zip',
        verified: true,
        metadata: <String, Object?>{'sha256': _fixtureSha256},
      );
      final updatePlan = ExtensionMarketplaceUpdatePlan.fromListing(
        listing: listing,
        installedRegistry: ExtensionManifestRegistry()
          ..register(
            const ExtensionManifest(
              extensionId: 'styio.language',
              displayName: 'Styio Language',
              version: '1.0.0',
              publisher: 'vityo',
              entrypoint: 'styio_language.dart',
            ),
          ),
      );
      final observedKinds = <ExtensionMarketplaceIoOperationKind>[];
      late ExtensionMarketplaceIoOperationRegistration updateDownloadHandler;
      late ExtensionMarketplaceIoOperationRegistration cacheHandler;
      updateDownloadHandler = _marketplaceIoHandler(
        id: 'update-download',
        kind: ExtensionMarketplaceIoOperationKind.downloadUpdatePackage,
        observedKinds: observedKinds,
        cacheKey: 'cache/styio.language-1.1.0.zip',
        self: () => updateDownloadHandler,
      );
      cacheHandler = _marketplaceIoHandler(
        id: 'cache',
        kind: ExtensionMarketplaceIoOperationKind.writePackageCache,
        observedKinds: observedKinds,
        cacheKey: 'cache/styio.language-1.1.0.zip',
        self: () => cacheHandler,
      );
      final bridge = ExtensionMarketplaceIoBridge(
        registry: ExtensionMarketplaceIoOperationRegistry(
          handlers: <ExtensionMarketplaceIoOperationRegistration>[
            updateDownloadHandler,
            cacheHandler,
          ],
        ),
      );

      final result = await bridge.executeUpdateIo(
        updatePlan: updatePlan,
        timestamp: DateTime.utc(2026, 5, 21),
      );

      expect(result.completed, isTrue);
      expect(observedKinds, <ExtensionMarketplaceIoOperationKind>[
        ExtensionMarketplaceIoOperationKind.downloadUpdatePackage,
        ExtensionMarketplaceIoOperationKind.writePackageCache,
      ]);
      expect(result.results.first.request.updatePlan?.canUpdate, isTrue);
      expect(result.results.first.cacheKey, 'cache/styio.language-1.1.0.zip');
    },
  );

  test('extension marketplace IO bridge reports missing handlers', () async {
    const listing = ExtensionMarketplaceListing(
      manifest: ExtensionManifest(
        extensionId: 'styio.language',
        displayName: 'Styio Language',
        version: '1.0.0',
        publisher: 'vityo',
        entrypoint: 'styio_language.dart',
      ),
      sourceUri: 'https://marketplace.vityo.invalid/styio.language.zip',
      verified: true,
      metadata: <String, Object?>{'sha256': _fixtureSha256},
    );
    const lifecycleDecision = ExtensionInstallLifecyclePolicyDecision(
      extensionId: 'styio.language',
      enabledAfterInstall: true,
      trustedAfterInstall: true,
      activateAfterInstall: true,
      message: 'Enable trusted extension after install.',
    );
    final bridge = ExtensionMarketplaceIoBridge(
      registry: ExtensionMarketplaceIoOperationRegistry(),
    );

    final result = await bridge.executeInstallIo(
      listing: listing,
      lifecycleDecision: lifecycleDecision,
      timestamp: DateTime.utc(2026, 5, 21),
    );

    expect(result.completed, isFalse);
    expect(
      result.results.map((entry) => entry.status).toSet(),
      <ExtensionMarketplaceIoOperationStatus>{
        ExtensionMarketplaceIoOperationStatus.missingHandler,
      },
    );
  });

  test(
    'extension marketplace index persists through Foundation DataStore',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_extension_marketplace_test_',
      );
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });
      final fileSystemManager = TestFileSystemManager.linuxDebianArm();
      final resourceManager = LocalResourceManager(
        facts: ResourceFacts.linuxDebianArm(
          systemTempPath: tempRoot.path,
          homePath: tempRoot.path,
        ),
      );
      final dataStore = FoundationDataStore(
        resourceCoordinator: FoundationResourceCoordinator(
          resourceManager: resourceManager,
          fileSystemManager: fileSystemManager,
        ),
        fileSystemManager: fileSystemManager,
      );
      final store = ExtensionMarketplaceIndexStore.fromDataStore(
        dataStore: dataStore,
      );

      await store.saveIndex(
        const ExtensionMarketplaceIndex(
          workspaceId: 'demo',
          listings: <ExtensionMarketplaceListing>[
            ExtensionMarketplaceListing(
              manifest: ExtensionManifest(
                extensionId: 'theme.solar',
                displayName: 'Solar Theme',
                version: '1.0.0',
                publisher: 'vityo',
                entrypoint: 'theme.dart',
              ),
              sourceUri: 'https://marketplace.vityo.invalid/theme.solar.zip',
              categories: <String>['theme'],
            ),
          ],
        ),
      );
      final restored = await store.readIndex(workspaceId: 'demo');

      expect(restored.workspaceId, 'demo');
      expect(restored.lookup('theme.solar'), isNotNull);
      expect(restored.search('theme').single.extensionId, 'theme.solar');
      expect(await store.deleteIndex(workspaceId: 'demo'), isTrue);
      expect((await store.readIndex(workspaceId: 'demo')).listings, isEmpty);
    },
  );

  test(
    'Linux concrete marketplace IO fetches verifies caches and persists policy',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_extension_marketplace_linux_',
      );
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });
      final packageBytes = utf8.encode('verified-vityo-extension-package');
      final packageSha256 = sha256.convert(packageBytes).toString();
      final listing = ExtensionMarketplaceListing(
        manifest: const ExtensionManifest(
          extensionId: 'fixture.linux-theme',
          displayName: 'Linux Theme',
          version: '2.0.0',
          publisher: 'vityo',
          entrypoint: 'theme.dart',
          trustedByDefault: true,
        ),
        sourceUri: 'https://marketplace.vityo.invalid/linux-theme.bin',
        verified: true,
        metadata: <String, Object?>{'sha256': packageSha256},
      );
      final indexUri = Uri.parse(
        'https://marketplace.vityo.invalid/index.json',
      );
      final network = _FixtureNetworkManager(
        facts: NetworkFacts.linuxDebianArm(targetId: 'linux-marketplace'),
        textResponses: <Uri, String>{
          indexUri: jsonEncode(
            ExtensionMarketplaceIndex(
              workspaceId: 'remote',
              listings: <ExtensionMarketplaceListing>[listing],
            ).toJson(),
          ),
        },
        binaryResponses: <Uri, List<int>>{
          Uri.parse(listing.sourceUri): packageBytes,
        },
      );
      final fileSystem = TestFileSystemManager.linuxDebianArm();
      final resource = LocalResourceManager(
        facts: ResourceFacts.linuxDebianArm(
          targetId: 'linux-marketplace',
          systemTempPath: tempRoot.path,
          homePath: tempRoot.path,
        ),
      );
      final coordinator = FoundationResourceCoordinator(
        resourceManager: resource,
        fileSystemManager: fileSystem,
      );
      final dataStore = FoundationDataStore(
        resourceCoordinator: coordinator,
        fileSystemManager: fileSystem,
      );
      final indexStore = ExtensionMarketplaceIndexStore.fromDataStore(
        dataStore: dataStore,
      );
      final settingsStore = ExtensionMarketplaceSettingsStore.fromDataStore(
        dataStore: dataStore,
      );
      final platformIo = ExtensionMarketplacePlatformIo(
        networkManager: network,
        fileSystemManager: fileSystem,
        resourceCoordinator: coordinator,
        indexStore: indexStore,
        settingsStore: settingsStore,
      );
      final bridge = ExtensionMarketplaceIoBridge(
        registry: ExtensionMarketplaceIoOperationRegistry(
          handlers: platformIo.registrations,
        ),
      );

      final indexResult = await bridge.registry.execute(
        ExtensionMarketplaceIoOperationRequest(
          kind: ExtensionMarketplaceIoOperationKind.fetchIndex,
          timestamp: DateTime.utc(2026, 8, 31),
          indexUri: indexUri,
          workspaceId: 'linux-workspace',
        ),
      );
      const lifecycleDecision = ExtensionInstallLifecyclePolicyDecision(
        extensionId: 'fixture.linux-theme',
        enabledAfterInstall: true,
        trustedAfterInstall: true,
        activateAfterInstall: false,
        message: 'Persist verified lifecycle choice.',
      );
      final installResult = await bridge.executeInstallIo(
        listing: listing,
        lifecycleDecision: lifecycleDecision,
        timestamp: DateTime.utc(2026, 8, 31),
        metadata: const <String, Object?>{'workspaceId': 'linux-workspace'},
      );

      expect(indexResult.completed, isTrue);
      expect(
        (await indexStore.readIndex(
          workspaceId: 'linux-workspace',
        )).lookup(listing.extensionId),
        isNotNull,
      );
      expect(installResult.completed, isTrue);
      expect(installResult.results, hasLength(3));
      final cache = installResult.results[1];
      expect(cache.metadata['sha256'], packageSha256);
      expect(
        await fileSystem.exists(Uri.parse(cache.artifactUri).toFilePath()),
        isTrue,
      );
      final restoredDecision = await settingsStore.readLifecycleDecision(
        workspaceId: 'linux-workspace',
        extensionId: listing.extensionId,
      );
      expect(restoredDecision?.trustedAfterInstall, isTrue);

      final preferences = ExtensionMarketplacePreferences(
        workspaceId: 'linux-workspace',
        indexUrl: indexUri.toString(),
        enableAfterInstall: false,
        trustVerifiedListings: true,
        activateTrustedAfterInstall: true,
      );
      await settingsStore.savePreferences(preferences);
      expect(
        (await settingsStore.readPreferences(
          workspaceId: 'linux-workspace',
        )).toJson(),
        preferences.toJson(),
      );
    },
  );

  test(
    'Windows marketplace matrix blocks mismatched packages before cache IO',
    () async {
      final packageUri = Uri.parse(
        'https://marketplace.vityo.invalid/windows-theme.bin',
      );
      final network = _FixtureNetworkManager(
        facts: const NetworkFacts(
          targetId: 'windows-marketplace',
          operatingSystem: 'windows',
          distributionId: 'windows',
          architecture: 'x64',
          providerKind: NetworkProviderKind.local,
          supportsHttpClient: true,
          supportsLoopback: true,
          proxyEnvironment: <String, String>{},
        ),
        binaryResponses: <Uri, List<int>>{
          packageUri: utf8.encode('tampered-windows-package'),
        },
      );
      final fileSystem = UnsupportedFileSystemManager(
        facts: FileSystemFacts.windowsX64(targetId: 'windows-marketplace'),
      );
      final resource = UnsupportedResourceManager(
        facts: const ResourceFacts(
          targetId: 'windows-marketplace',
          operatingSystem: 'windows',
          distributionId: 'windows',
          architecture: 'x64',
          providerKind: ResourceProviderKind.local,
          processorCount: 8,
          systemTempPath: r'C:\Temp',
          homePath: r'C:\Users\fixture',
          supportsTempDirectory: true,
          supportsHomeDirectory: true,
          supportsStorageProbe: true,
        ),
      );
      final coordinator = FoundationResourceCoordinator(
        resourceManager: resource,
        fileSystemManager: fileSystem,
      );
      final dataStore = FoundationDataStore(
        resourceCoordinator: coordinator,
        fileSystemManager: fileSystem,
      );
      final platformIo = ExtensionMarketplacePlatformIo(
        networkManager: network,
        fileSystemManager: fileSystem,
        resourceCoordinator: coordinator,
        indexStore: ExtensionMarketplaceIndexStore.fromDataStore(
          dataStore: dataStore,
        ),
        settingsStore: ExtensionMarketplaceSettingsStore.fromDataStore(
          dataStore: dataStore,
        ),
      );
      final bridge = ExtensionMarketplaceIoBridge(
        registry: ExtensionMarketplaceIoOperationRegistry(
          handlers: platformIo.registrations,
        ),
      );
      final result = await bridge.executeInstallIo(
        listing: ExtensionMarketplaceListing(
          manifest: const ExtensionManifest(
            extensionId: 'fixture.windows-theme',
            displayName: 'Windows Theme',
            version: '1.0.0',
            publisher: 'vityo',
            entrypoint: 'theme.dart',
          ),
          sourceUri: packageUri.toString(),
          verified: true,
          metadata: const <String, Object?>{'sha256': _fixtureSha256},
        ),
        lifecycleDecision: const ExtensionInstallLifecyclePolicyDecision(
          extensionId: 'fixture.windows-theme',
          enabledAfterInstall: true,
          trustedAfterInstall: true,
          activateAfterInstall: false,
          message: 'Should not persist.',
        ),
        timestamp: DateTime.utc(2026, 8, 31),
        metadata: const <String, Object?>{'workspaceId': 'windows-workspace'},
      );

      expect(fileSystem.compatibility.compatibilityTarget, 'windows-x64');
      expect(result.completed, isFalse);
      expect(result.results, hasLength(2));
      expect(
        result.results.last.status,
        ExtensionMarketplaceIoOperationStatus.blocked,
      );
      expect(result.results.last.message, contains('SHA-256'));
    },
  );

  test(
    'marketplace controller restores installs and persists extension registry',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_extension_marketplace_controller_',
      );
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });
      final fileSystem = TestFileSystemManager.linuxDebianArm();
      final resource = LocalResourceManager(
        facts: ResourceFacts.linuxDebianArm(
          systemTempPath: tempRoot.path,
          homePath: tempRoot.path,
        ),
      );
      final dataStore = FoundationDataStore(
        resourceCoordinator: FoundationResourceCoordinator(
          resourceManager: resource,
          fileSystemManager: fileSystem,
        ),
        fileSystemManager: fileSystem,
      );
      final indexStore = ExtensionMarketplaceIndexStore.fromDataStore(
        dataStore: dataStore,
      );
      final settingsStore = ExtensionMarketplaceSettingsStore.fromDataStore(
        dataStore: dataStore,
      );
      final registryStore = ExtensionManifestRegistryStore.fromDataStore(
        dataStore: dataStore,
      );
      const listing = ExtensionMarketplaceListing(
        manifest: ExtensionManifest(
          extensionId: 'fixture.controller',
          displayName: 'Controller Fixture',
          version: '1.0.0',
          publisher: 'vityo',
          entrypoint: 'fixture.dart',
          trustedByDefault: true,
        ),
        sourceUri: 'https://marketplace.vityo.invalid/controller.bin',
        verified: true,
        metadata: <String, Object?>{'sha256': _fixtureSha256},
      );
      await indexStore.saveIndex(
        const ExtensionMarketplaceIndex(
          workspaceId: 'controller-workspace',
          listings: <ExtensionMarketplaceListing>[listing],
        ),
      );
      await settingsStore.savePreferences(
        const ExtensionMarketplacePreferences(
          workspaceId: 'controller-workspace',
          indexUrl: 'https://marketplace.vityo.invalid/index.json',
        ),
      );
      final handlers = <ExtensionMarketplaceIoOperationRegistration>[
        for (final kind in <ExtensionMarketplaceIoOperationKind>[
          ExtensionMarketplaceIoOperationKind.downloadPackage,
          ExtensionMarketplaceIoOperationKind.writePackageCache,
          ExtensionMarketplaceIoOperationKind.persistLifecyclePolicy,
        ])
          ExtensionMarketplaceIoOperationRegistration(
            handlerId: 'controller.${kind.wireValue}',
            label: 'Controller ${kind.wireValue}',
            kind: kind,
            handler: (request) async {
              return ExtensionMarketplaceIoOperationResult.completed(
                request: request,
                message: '${kind.wireValue} completed.',
                artifactUri:
                    kind ==
                        ExtensionMarketplaceIoOperationKind.writePackageCache
                    ? 'file:///cache/controller/package.bin'
                    : listing.sourceUri,
                cacheKey: 'fixture.controller/1.0.0/package.bin',
                metadata: const <String, Object?>{
                  'sha256': _fixtureSha256,
                  'sizeBytes': 64,
                },
              );
            },
          ),
      ];
      final installedRegistry = ExtensionManifestRegistry();
      final controller = ExtensionMarketplaceController(
        workspaceId: () => 'controller-workspace',
        installedRegistry: installedRegistry,
        log: (_) {},
        runtime: ExtensionMarketplaceRuntimeServices(
          indexStore: indexStore,
          settingsStore: settingsStore,
          manifestRegistryStore: registryStore,
          ioBridge: ExtensionMarketplaceIoBridge(
            registry: ExtensionMarketplaceIoOperationRegistry(
              handlers: handlers,
            ),
          ),
        ),
      );
      addTearDown(controller.dispose);

      await controller.load();
      final plan = controller.index.installPlan(
        installedRegistry: installedRegistry,
        extensionId: listing.extensionId,
      );
      await controller.install(plan);

      expect(controller.lastInstallResult?.installed, isTrue);
      expect(installedRegistry.lookup(listing.extensionId), isNotNull);
      expect(
        (await registryStore.readRegistry(
          workspaceId: 'controller-workspace',
        )).lookup(listing.extensionId),
        isNotNull,
      );
    },
  );

  test('marketplace network policy rejects non-loopback cleartext URLs', () {
    expect(
      ExtensionMarketplacePlatformIo.allowsRemoteUri(
        Uri.parse('http://marketplace.example/index.json'),
      ),
      isFalse,
    );
    expect(
      ExtensionMarketplacePlatformIo.allowsRemoteUri(
        Uri.parse('http://127.0.0.1:8080/index.json'),
      ),
      isTrue,
    );
    expect(
      ExtensionMarketplacePlatformIo.allowsRemoteUri(
        Uri.parse('https://marketplace.example/index.json'),
      ),
      isTrue,
    );
  });
}

class _FakePackageDownloader implements ExtensionPackageDownloader {
  const _FakePackageDownloader();

  @override
  Future<ExtensionPackageDownloadReceipt> download(
    ExtensionMarketplaceListing listing,
  ) async {
    return ExtensionPackageDownloadReceipt(
      artifact: ExtensionPackageArtifact(
        extensionId: listing.extensionId,
        sourceUri: listing.sourceUri,
        cacheKey: 'cache/${listing.extensionId}.zip',
        sizeBytes: listing.downloadSizeBytes ?? 42,
        checksum: _fixtureSha256,
      ),
      message: 'Downloaded ${listing.extensionId}.',
    );
  }
}

ExtensionMarketplaceIoOperationRegistration _marketplaceIoHandler({
  required String id,
  required ExtensionMarketplaceIoOperationKind kind,
  required List<ExtensionMarketplaceIoOperationKind> observedKinds,
  required ExtensionMarketplaceIoOperationRegistration Function() self,
  String cacheKey = '',
}) {
  return ExtensionMarketplaceIoOperationRegistration(
    handlerId: id,
    label: id,
    kind: kind,
    handler: (request) async {
      observedKinds.add(request.kind);
      return ExtensionMarketplaceIoOperationResult.completed(
        request: request,
        handler: self(),
        message: '${request.kind.wireValue} completed.',
        artifactUri: request.listing?.sourceUri ?? '',
        cacheKey: cacheKey,
      );
    },
  );
}

class _RejectingPackageVerifier implements ExtensionPackageVerifier {
  const _RejectingPackageVerifier();

  @override
  Future<ExtensionPackageVerificationReceipt> verify({
    required ExtensionMarketplaceListing listing,
    required ExtensionPackageArtifact artifact,
  }) async {
    return ExtensionPackageVerificationReceipt(
      verified: false,
      checksum: artifact.checksum,
      message: 'Rejected ${listing.extensionId}.',
    );
  }
}

class _FixtureNetworkManager implements NetworkManager {
  _FixtureNetworkManager({
    required this.facts,
    this.textResponses = const <Uri, String>{},
    this.binaryResponses = const <Uri, List<int>>{},
  }) : compatibility = NetworkAdapter(facts).adapt();

  @override
  final NetworkFacts facts;
  @override
  final NetworkCompatibility compatibility;
  final Map<Uri, String> textResponses;
  final Map<Uri, List<int>> binaryResponses;

  @override
  Future<NetworkTextResponse> getText(
    Uri uri, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final body = textResponses[uri];
    return NetworkTextResponse(
      status: body == null
          ? NetworkRequestStatus.failed
          : NetworkRequestStatus.succeeded,
      uri: uri,
      statusCode: body == null ? 404 : 200,
      body: body ?? '',
      message: body == null ? 'Fixture response not found.' : null,
    );
  }

  @override
  Future<NetworkBinaryResponse> getBytes(
    Uri uri, {
    Duration? timeout = const Duration(seconds: 10),
  }) async {
    final bytes = binaryResponses[uri];
    return NetworkBinaryResponse(
      status: bytes == null
          ? NetworkRequestStatus.failed
          : NetworkRequestStatus.succeeded,
      uri: uri,
      statusCode: bytes == null ? 404 : 200,
      bytes: bytes ?? const <int>[],
      message: bytes == null ? 'Fixture response not found.' : null,
    );
  }

  @override
  Future<NetworkTextResponse> postJson(
    Uri uri, {
    required Map<String, String> headers,
    required Map<String, Object?> body,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    return NetworkTextResponse(
      status: NetworkRequestStatus.blocked,
      uri: uri,
      statusCode: null,
      body: '',
      message: 'POST is not used by this fixture.',
    );
  }

  @override
  NetworkOperationFailure? failureForText(
    NetworkTextResponse response, {
    String operation = 'network.getText',
    String? recoveryHint,
  }) {
    return const NetworkFailureClassifier(
      sourceManager: '_FixtureNetworkManager',
    ).classify(
      status: response.status,
      uri: response.uri,
      statusCode: response.statusCode,
      message: response.message,
      operation: operation,
      recoveryHint: recoveryHint,
    );
  }

  @override
  NetworkOperationFailure? failureForBytes(
    NetworkBinaryResponse response, {
    String operation = 'network.getBytes',
    String? recoveryHint,
  }) {
    return const NetworkFailureClassifier(
      sourceManager: '_FixtureNetworkManager',
    ).classify(
      status: response.status,
      uri: response.uri,
      statusCode: response.statusCode,
      message: response.message,
      operation: operation,
      recoveryHint: recoveryHint,
    );
  }
}
