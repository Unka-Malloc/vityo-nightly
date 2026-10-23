import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';
import 'package:vityo_app/src/view_ide/module_host/module_host.dart';
import 'package:vityo_app/src/view_ide/platform/platform.dart';
import 'package:vityo_app/src/view_ide/runtime/runtime.dart';
import 'package:vityo_app/src/view_render/extensions/extensions.dart';
import 'package:vityo_app/src/view_render/platform/platform.dart';

import '../test/support/vityod_test_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS launches and renders a managed extension host', (
    tester,
  ) async {
    expect(Platform.isMacOS, isTrue, reason: 'run this lane on macOS');
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 960);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final daemon = await VityodTestHarness.start(
      clientId: 'extension-manifest-native-ui',
    );
    final processManager = LocalProcessManager(
      facts: await const LocalProcessProber().probe(),
      client: daemon.client,
    );
    final manifestRegistry = ExtensionManifestRegistry(<ExtensionManifest>[
      const ExtensionManifest(
        extensionId: 'fixture.native-language',
        displayName: 'Native Language Host',
        version: '1.0.0',
        publisher: 'vityo',
        entrypoint: '/bin/sleep',
        activationEvents: <String>['onStartup'],
        trustedByDefault: true,
        metadata: <String, Object?>{
          'isolationMode': 'local-process',
          'hostArguments': <String>['30'],
        },
      ),
    ]);
    final activationSession = const ExtensionActivator().activate(
      registry: manifestRegistry,
      event: 'onStartup',
    );
    final startupSnapshot = const ExtensionHostSupervisor().applyActivation(
      registry: manifestRegistry,
      session: activationSession,
    );
    final launchers = createPlatformExtensionHostSandboxLauncherRegistry(
      platformTarget: PlatformTarget.macos,
      processManager: processManager,
    );
    final receipt =
        await ExtensionHostStartupExecutor(
          bridge: ExtensionHostSupervisorExecutionBridge(
            sandboxLaunchers: launchers,
          ),
        ).execute(
          snapshot: startupSnapshot,
          manifestRegistry: manifestRegistry,
          buffer: RuntimeOutputLiveBuffer(),
        );
    final launch = receipt.launchResults.single;
    addTearDown(() async {
      if (launch.processHandleId.isNotEmpty) {
        await processManager.cancelProcess(launch.processHandleId);
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      await daemon.close();
    });

    expect(receipt.ready, isTrue);
    expect(launch.pid, greaterThan(0));
    expect(launch.processHandleId, isNotEmpty);
    expect(receipt.supervisorSnapshot.runningExtensionIds, <String>[
      'fixture.native-language',
    ]);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff6f78a8),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('extension-manifest-native-evidence'),
            child: ExtensionsSurface(
              viewportProfile: resolveViewportProfile(
                platformTarget: PlatformTarget.macos,
                width: 1280,
                height: 960,
              ),
              visibleModules: const <ModuleDefinition>[],
              mountedModules: const <ModuleDefinition>[],
              activationSession: activationSession,
              supervisorSnapshot: receipt.supervisorSnapshot,
              launchResults: receipt.launchResults,
              telemetryEvents: receipt.telemetryEvents,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final telemetry = find.byKey(
      const ValueKey('extensions-activation-telemetry-toggle'),
    );
    await tester.ensureVisible(telemetry);
    await tester.tap(telemetry);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('extensions-host-fixture.native-language')),
      findsOneWidget,
    );
    expect(find.text('Managed local process'), findsOneWidget);
    expect(find.text('managed process'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('extensions-activation-timeline')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await _captureEvidence(tester);
  });
}

Future<void> _captureEvidence(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('extension-manifest-native-evidence')),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  expect(bytes, isNotNull);
  final output = Directory('build/integration_test')
    ..createSync(recursive: true);
  File(
    '${output.path}/vityo-extension-manifest-macos.png',
  ).writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
}
