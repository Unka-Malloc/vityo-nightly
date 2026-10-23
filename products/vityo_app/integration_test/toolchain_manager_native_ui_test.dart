import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/backend_toolchain.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';
import 'package:vityo_app/src/view_ide/foundation/foundation.dart';
import 'package:vityo_app/src/view_ide/platform/platform.dart';
import 'package:vityo_app/src/view_ide/shell_runtime/controllers/toolchain_controller.dart';
import 'package:vityo_app/src/view_ide/toolchain/toolchain.dart';
import 'package:vityo_app/src/view_render/platform/platform.dart';
import 'package:vityo_app/src/view_render/settings/settings_surface.dart';

import '../test/support/vityod_test_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'macOS validates a real project toolchain and confirms an installer plan',
    (tester) async {
      expect(Platform.isMacOS, isTrue, reason: 'run this lane on macOS');
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 960);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_toolchain_native_ui_',
      );
      final daemon = await VityodTestHarness.start(
        clientId: 'toolchain-manager-native-ui',
      );
      final workspaceId = tempRoot.path.split(Platform.pathSeparator).last;
      final platformManagers = await createDetectedPlatformManagerBundle(
        targetId: 'toolchain-manager-native-ui',
        vityodClient: daemon.client,
        workspaceRoot: tempRoot.path,
      );
      final workspaceRoot = platformManagers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'workspace',
      ]);
      final executablePath = platformManagers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'bin',
        'styio-service',
      ]);
      final installerPath = platformManagers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'bin',
        'toolchain-installer',
      ]);
      await platformManagers.fileSystem.createDirectory(workspaceRoot);
      await platformManagers.fileSystem.writeText(
        executablePath,
        '#!/bin/sh\nexit 0\n',
      );
      await platformManagers.fileSystem.setExecutable(executablePath);
      await platformManagers.fileSystem.writeText(
        installerPath,
        '#!/bin/sh\nprintf "toolchain installer ready\\n"\n',
      );
      await platformManagers.fileSystem.setExecutable(installerPath);

      final configurationStore = ConfigurationStore(
        dataStore: FoundationDataStore(
          resourceCoordinator: FoundationResourceCoordinator(
            resourceManager: platformManagers.resource,
            fileSystemManager: platformManagers.fileSystem,
          ),
          fileSystemManager: platformManagers.fileSystem,
        ),
        credentialDataStore: InMemoryCredentialDataStore(),
      );
      final manager = ToolchainManager(
        configurationStore: ToolchainConfigurationStore(
          configurationStore: configurationStore,
        ),
        platformManagers: platformManagers,
        workspaceId: workspaceId,
      );
      await manager.registerToolchain(
        ToolchainDescriptor(
          id: 'native-styio-service',
          kind: ToolchainKind.languageService,
          displayName: 'Native Styio Service',
          executablePath: executablePath,
          version: '1.0.0',
          channel: 'local',
        ),
        activate: true,
      );
      final status = ValueNotifier<ToolchainManagerStatusReport>(
        await manager.statusReport(kind: ToolchainKind.languageService),
      );
      final project = ProjectGraphSnapshot.scratch(
        workspaceRoot: workspaceRoot,
        activeFilePath: platformManagers.fileSystem.joinPath(<String>[
          workspaceRoot,
          'main.styio',
        ]),
        title: 'Toolchain Native UI',
        notes: const <String>[],
      );
      final controller = ToolchainController(
        projectGraph: () => project,
        manager: manager,
        statusReport: status,
        log: (_) {},
      );
      await controller.refreshBootstrapSummary();
      controller.planInstallation(
        ToolchainInstallRequest(
          requirement: const ToolchainRequirement(
            kind: ToolchainKind.languageService,
          ),
          externalCommand: installerPath,
        ),
        policy: const ToolchainInstallPolicy(
          allowedModes: <ToolchainInstallMode>{
            ToolchainInstallMode.externalCommand,
          },
        ),
      );
      addTearDown(() async {
        controller.dispose();
        status.dispose();
        await daemon.close();
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

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
            body: ListenableBuilder(
              listenable: controller,
              builder: (_, _) => RepaintBoundary(
                key: const ValueKey('toolchain-manager-native-evidence'),
                child: SettingsSurface(
                  viewportProfile: resolveViewportProfile(
                    platformTarget: PlatformTarget.macos,
                    width: 1280,
                    height: 960,
                  ),
                  toolchainStatus: controller.statusSurface,
                  toolchainSettings: controller.settingsSurface,
                  toolchainInstallPlan: controller.installPlanSurface,
                  toolchainInstallExecution: controller.installExecutionSurface,
                  toolchainBootstrapSummary: controller.bootstrapSummary,
                  toolchainBootstrapActionDispatch:
                      controller.lastBootstrapActionDispatch,
                  onToolchainBootstrapAction: (actionId) async {
                    await controller.handleBootstrapAction(actionId);
                  },
                  onExecuteToolchainInstallPlan: () async {
                    await controller.executeLastInstallPlan(confirmed: true);
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final validate = find.byKey(
        const ValueKey(
          'settings-toolchain-bootstrap-project-validate-project-toolchain',
        ),
      );
      await tester.ensureVisible(validate);
      await tester.tap(validate);
      await _pumpUntil(
        tester,
        () =>
            controller.lastBootstrapActionDispatch?.actionId ==
            'validate-project-toolchain',
      );
      expect(controller.bootstrapSummary?.projectValidation?.ready, isTrue);
      expect(controller.lastBootstrapExecution?.completed, isTrue);
      await tester.ensureVisible(
        find.byKey(
          const ValueKey('settings-toolchain-project-validation-result'),
        ),
      );
      await tester.pumpAndSettle();
      await _captureEvidence(
        tester,
        fileName: 'vityo-toolchain-validation-macos.png',
      );

      final review = find.byKey(
        const ValueKey('settings-toolchain-execute-install-plan'),
      );
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-toolchain-install-confirmation')),
        findsOneWidget,
      );
      expect(controller.lastInstallExecutionResult, isNull);
      await tester.tap(
        find.byKey(
          const ValueKey('settings-toolchain-install-confirmation-confirm'),
        ),
      );
      await _pumpUntil(
        tester,
        () => controller.lastInstallExecutionResult != null,
      );
      expect(controller.lastInstallExecutionResult?.succeeded, isTrue);
      expect(
        controller.lastInstallExecutionResult?.processResult?.stdout,
        contains('toolchain installer ready'),
      );
      expect(
        find.byKey(const ValueKey('settings-toolchain-install-execution')),
        findsOneWidget,
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('settings-toolchain-install-execution')),
      );
      await tester.pumpAndSettle();
      await _captureEvidence(
        tester,
        fileName: 'vityo-toolchain-manager-macos.png',
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Toolchain manager state did not settle.');
    }
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle();
}

Future<void> _captureEvidence(
  WidgetTester tester, {
  required String fileName,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('toolchain-manager-native-evidence')),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  expect(bytes, isNotNull);
  final output = Directory('build/integration_test')
    ..createSync(recursive: true);
  File(
    '${output.path}/$fileName',
  ).writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
}
