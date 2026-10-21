import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';
import 'package:vityo_app/src/view_ide/foundation/foundation.dart';
import 'package:vityo_app/src/view_ide/interaction/interaction.dart';
import 'package:vityo_app/src/view_ide/module_host/module_host.dart';
import 'package:vityo_app/src/view_ide/platform/platform.dart';
import 'package:vityo_app/src/view_ide/shell_runtime/controllers/extension_marketplace_controller.dart';
import 'package:vityo_app/src/view_render/extensions/extensions.dart';
import 'package:vityo_app/src/view_render/platform/platform.dart';
import 'package:vityo_app/src/view_render/settings/settings_surface.dart';

import '../test/support/vityod_test_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'macOS saves marketplace policy and installs a loopback package',
    (tester) async {
      expect(Platform.isMacOS, isTrue, reason: 'run this lane on macOS');
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 960);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      final packageBytes = utf8.encode('vityo-native-marketplace-package');
      final packageSha256 = sha256.convert(packageBytes).toString();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final baseUri = Uri.parse('http://127.0.0.1:${server.port}');
      final packageUri = baseUri.resolve('/package.bin');
      final indexUri = baseUri.resolve('/index.json');
      final listing = ExtensionMarketplaceListing(
        manifest: const ExtensionManifest(
          extensionId: 'fixture.native-marketplace',
          displayName: 'Native Marketplace Theme',
          version: '1.0.0',
          publisher: 'Vityo Verified',
          entrypoint: 'theme.dart',
          trustedByDefault: true,
          metadata: <String, Object?>{'isolationMode': 'in-process'},
        ),
        sourceUri: packageUri.toString(),
        summary: 'A verified loopback package used by the native IDE lane.',
        categories: const <String>['theme', 'native'],
        downloadSizeBytes: packageBytes.length,
        verified: true,
        metadata: <String, Object?>{'sha256': packageSha256},
      );
      final indexBody = jsonEncode(
        ExtensionMarketplaceIndex(
          workspaceId: 'native-marketplace',
          listings: <ExtensionMarketplaceListing>[listing],
        ).toJson(),
      );
      server.listen((request) async {
        if (request.uri.path == '/index.json') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(indexBody);
        } else if (request.uri.path == '/package.bin') {
          request.response.headers.contentType = ContentType.binary;
          request.response.add(packageBytes);
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });

      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_marketplace_native_ui_',
      );
      final daemon = await VityodTestHarness.start(
        clientId: 'extension-marketplace-native-ui',
      );
      final managers = await createDetectedPlatformManagerBundle(
        targetId: 'extension-marketplace-native-ui',
        vityodClient: daemon.client,
        workspaceRoot: tempRoot.path,
      );
      final resource = LocalResourceManager(
        facts: ResourceFacts(
          targetId: 'extension-marketplace-native-ui',
          operatingSystem: 'macos',
          distributionId: 'macos',
          architecture: 'arm64',
          providerKind: ResourceProviderKind.local,
          processorCount: Platform.numberOfProcessors,
          systemTempPath: tempRoot.path,
          homePath: tempRoot.path,
          supportsTempDirectory: true,
          supportsHomeDirectory: true,
          supportsStorageProbe: true,
        ),
      );
      final coordinator = FoundationResourceCoordinator(
        resourceManager: resource,
        fileSystemManager: managers.fileSystem,
      );
      final dataStore = FoundationDataStore(
        resourceCoordinator: coordinator,
        fileSystemManager: managers.fileSystem,
      );
      final indexStore = ExtensionMarketplaceIndexStore.fromDataStore(
        dataStore: dataStore,
      );
      final settingsStore = ExtensionMarketplaceSettingsStore.fromDataStore(
        dataStore: dataStore,
      );
      final platformIo = ExtensionMarketplacePlatformIo(
        networkManager: managers.network,
        fileSystemManager: managers.fileSystem,
        resourceCoordinator: coordinator,
        indexStore: indexStore,
        settingsStore: settingsStore,
      );
      final installedRegistry = ExtensionManifestRegistry();
      final controller = ExtensionMarketplaceController(
        workspaceId: () => 'native-marketplace',
        installedRegistry: installedRegistry,
        log: (_) {},
        runtime: ExtensionMarketplaceRuntimeServices(
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
        ),
      );
      addTearDown(() async {
        controller.dispose();
        await server.close(force: true);
        await daemon.close();
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });
      await controller.load();

      await tester.pumpWidget(
        _marketplaceSettingsApp(
          controller: controller,
          indexUrl: indexUri.toString(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('settings-extension-marketplace-index-url')),
        indexUri.toString(),
      );
      await tester.tap(
        find.byKey(const ValueKey('settings-extension-marketplace-save')),
      );
      await _pumpUntil(
        tester,
        () => controller.preferences.indexUrl == indexUri.toString(),
      );
      await tester.tap(
        find.byKey(const ValueKey('settings-extension-marketplace-refresh')),
      );
      await _pumpUntil(tester, () => controller.index.listings.length == 1);

      await tester.pumpWidget(_marketplaceExtensionsApp(controller));
      await tester.pumpAndSettle();
      final install = find.byKey(
        const ValueKey('extensions-install-fixture.native-marketplace'),
      );
      await tester.ensureVisible(install);
      await tester.tap(install);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('extensions-marketplace-confirmation')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(
          const ValueKey('extensions-marketplace-confirmation-confirm'),
        ),
      );
      await _pumpUntil(
        tester,
        () => controller.lastInstallResult?.installed == true,
        failureReason: () =>
            '${controller.message} / ${controller.lastInstallResult?.toJson()}',
      );

      expect(installedRegistry.lookup('fixture.native-marketplace'), isNotNull);
      expect(controller.lastIoBatch?.completed, isTrue);
      final artifactUri =
          controller
                  .lastInstallResult
                  ?.downloadReceipt
                  ?.artifact
                  .metadata['artifactUri']
              as String?;
      expect(artifactUri, isNotNull);
      expect(
        await managers.fileSystem.exists(
          managers.fileSystem.pathFromFileUri(Uri.parse(artifactUri!)),
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await _captureEvidence(tester);
    },
  );
}

Widget _marketplaceSettingsApp({
  required ExtensionMarketplaceController controller,
  required String indexUrl,
}) {
  return MaterialApp(
    theme: _theme,
    home: Scaffold(
      body: ListenableBuilder(
        listenable: controller,
        builder: (_, _) => SettingsSurface(
          viewportProfile: resolveViewportProfile(
            platformTarget: PlatformTarget.macos,
            width: 1280,
            height: 960,
          ),
          toolchainStatus: const ToolchainStatusSurface(
            source: 'native-marketplace',
            severity: ToolchainStatusSeverity.ready,
            title: 'Native toolchain ready',
            message: 'Marketplace native UI lane.',
            recoveryActions: <ToolchainRecoveryAction>[],
          ),
          extensionMarketplacePreferences: controller.preferences.copyWith(
            indexUrl: controller.preferences.indexUrl.isEmpty
                ? indexUrl
                : controller.preferences.indexUrl,
          ),
          extensionMarketplaceMessage: controller.message,
          extensionMarketplaceBusy: controller.busy,
          onSaveExtensionMarketplacePreferences: controller.savePreferences,
          onRefreshExtensionMarketplace: controller.refreshIndex,
        ),
      ),
    ),
  );
}

Widget _marketplaceExtensionsApp(ExtensionMarketplaceController controller) {
  return MaterialApp(
    theme: _theme,
    home: Scaffold(
      body: ListenableBuilder(
        listenable: controller,
        builder: (_, _) => RepaintBoundary(
          key: const ValueKey('extension-marketplace-native-evidence'),
          child: ExtensionsSurface(
            viewportProfile: resolveViewportProfile(
              platformTarget: PlatformTarget.macos,
              width: 1280,
              height: 960,
            ),
            visibleModules: const <ModuleDefinition>[],
            mountedModules: const <ModuleDefinition>[],
            marketplaceIndex: controller.index,
            installedExtensionRegistry: controller.installedRegistry,
            marketplaceQuery: controller.query,
            marketplaceMessage: controller.message,
            marketplaceBusy: controller.busy,
            lastMarketplaceInstallResult: controller.lastInstallResult,
            onRefreshMarketplace: controller.refreshIndex,
            onMarketplaceQueryChanged: controller.setQuery,
            onInstallExtension: controller.install,
            onUpdateExtension: controller.update,
          ),
        ),
      ),
    ),
  );
}

ThemeData get _theme {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff6f78a8),
      brightness: Brightness.dark,
    ),
    useMaterial3: true,
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  String Function()? failureReason,
}) async {
  for (var attempt = 0; attempt < 120 && !condition(); attempt += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue, reason: failureReason?.call());
  await tester.pumpAndSettle();
}

Future<void> _captureEvidence(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('extension-marketplace-native-evidence')),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  expect(bytes, isNotNull);
  final output = Directory('build/integration_test')
    ..createSync(recursive: true);
  File(
    '${output.path}/vityo-extension-marketplace-macos.png',
  ).writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
}
