import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vityo_app/src/view_ide/debugger/debug_adapter_process_transport_io.dart';
import 'package:vityo_app/src/view_ide/debugger/debug_launch_contract.dart';
import 'package:vityo_app/src/view_ide/debugger/debug_runtime_task_history.dart';
import 'package:vityo_app/src/view_ide/runtime/runtime_output_channels.dart';
import 'package:vityo_app/src/view_ide/shell_runtime/controllers/debug_controller.dart';
import 'package:vityo_app/src/view_render/platform/viewport_profile.dart';
import 'package:vityo_app/src/view_render/runtime/debug_console_surface.dart';

import '../test/support/vityod_test_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'macOS engine edits a Python DAP launch, starts it, and force-stops its real process',
    (tester) async {
      expect(Platform.isMacOS, isTrue, reason: 'run this lane on macOS');
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 960);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      final daemon = await VityodTestHarness.start(
        clientId: 'debugger-dap-native-ui',
      );
      final output = RuntimeOutputLiveBuffer();
      final controller = DebugController.configured(
        toolchainManager: null,
        workspaceRoot: () => '/tmp',
        workspaceId: () => 'debugger-native-ui',
        launcher: createIoDapDebugAdapterLauncher(daemon.client),
        runtimeOutputBuffer: output,
        runtimeTaskHistoryBinder: const DebugRuntimeTaskHistoryBinder(),
        runtimeTaskHistoryStore: null,
        runtimeTaskHistoryWorkspaceId: 'debugger-native-ui',
        runtimeTaskHistoryMaxEntries: 10,
        initialLaunchProfiles: _debugProfiles,
        log: (_) {},
      );
      await controller.loadConfiguredState();
      addTearDown(() async {
        if (controller.sessionHandle != null) {
          await controller.stopSession(force: true);
        }
        controller.dispose();
        await output.dispose();
        await daemon.close();
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
                key: const ValueKey('debugger-dap-native-evidence'),
                child: DebugConsoleSurface(
                  viewportProfile: const ViewportProfile(
                    family: ViewportFamily.desktop,
                    width: 1280,
                    height: 960,
                  ),
                  entries: const <String>[],
                  runtimeEvents: const [],
                  debugSession: controller.session,
                  debugRuntimeExecution: controller.lastRuntimeExecutionResult,
                  debugLaunchConfigurations: controller.launchConfigurations,
                  onStartDebugging: () async {
                    await controller.startConfiguredSession();
                  },
                  onStopDebugging: () async {
                    await controller.stopConfiguredSession();
                  },
                  onForceStopDebugging: () async {
                    await controller.forceStopConfiguredSession();
                  },
                  onSelectLaunchProfile: controller.selectLaunchProfile,
                  onUpdateLaunchConfiguration:
                      controller.updateSelectedLaunchConfiguration,
                  onSaveBreakpoint: controller.saveBreakpoint,
                  onRemoveBreakpoint: controller.removeBreakpoint,
                  onSetBreakpointEnabled: controller.setBreakpointEnabled,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final selector = find.byKey(const ValueKey('debug-adapter-selector'));
      await tester.ensureVisible(selector);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Python Debug Adapter').last);
      await tester.pumpAndSettle();
      expect(controller.selectedLaunchProfile?.id, 'python-dap');

      final configure = find.byKey(
        const ValueKey('debug-edit-launch-configuration'),
      );
      await tester.tap(configure);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('debug-launch-program-field')),
        '/bin/echo',
      );
      await tester.enterText(
        find.byKey(const ValueKey('debug-launch-cwd-field')),
        '/tmp',
      );
      await tester.enterText(
        find.byKey(const ValueKey('debug-launch-arguments-field')),
        'native-debug',
      );
      await tester.tap(find.byKey(const ValueKey('debug-launch-save')));
      await tester.pumpAndSettle();
      expect(controller.selectedLaunchProfile?.configuration.ready, isTrue);

      final addBreakpoint = find.byKey(const ValueKey('debug-add-breakpoint'));
      await tester.ensureVisible(addBreakpoint);
      await tester.tap(addBreakpoint);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('debug-breakpoint-path-field')),
        '/tmp/main.py',
      );
      await tester.enterText(
        find.byKey(const ValueKey('debug-breakpoint-line-field')),
        '1',
      );
      await tester.tap(find.byKey(const ValueKey('debug-breakpoint-save')));
      await tester.pumpAndSettle();
      expect(controller.breakpoints.single.line, 0);

      final start = find.byKey(const ValueKey('debug-control-start'));
      await tester.ensureVisible(start);
      await tester.tap(start);
      await _pumpUntil(tester, () => controller.sessionHandle != null);
      expect(controller.session.status, DebugSessionStatus.launching);
      expect(
        controller.lastRuntimeExecutionResult?.processHandle?.pid,
        greaterThan(0),
      );
      expect(
        find.byKey(const ValueKey('debug-process-identity')),
        findsOneWidget,
      );

      await _captureEvidence(tester);

      final forceStop = find.byKey(const ValueKey('debug-control-force-stop'));
      await tester.ensureVisible(forceStop);
      await tester.tap(forceStop);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('debug-force-stop-confirm')));
      await _pumpUntil(
        tester,
        () => controller.session.status == DebugSessionStatus.stopped,
      );

      expect(controller.sessionHandle, isNull);
      expect(
        controller
            .lastRuntimeExecutionResult
            ?.terminationExecution
            ?.processResult
            ?.processTerminated,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Debug adapter state did not settle.');
    }
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump();
}

Future<void> _captureEvidence(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('debugger-dap-native-evidence')),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  expect(bytes, isNotNull);
  final output = Directory('build/integration_test')
    ..createSync(recursive: true);
  File(
    '${output.path}/vityo-debugger-dap-macos.png',
  ).writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
}

final _debugProfiles = <DebugLaunchProfile>[
  DebugLaunchProfile.fromConfiguration(
    id: 'lldb-dap',
    displayName: 'LLDB DAP',
    configuration: const DebugLaunchConfiguration(
      readiness: DebugLaunchReadiness.missingProgram,
      reason: 'Select a native program.',
      debuggerId: 'lldb-dap',
      debuggerLabel: 'LLDB DAP',
      debuggerExecutablePath: '/bin/sleep',
      debuggerArguments: <String>['30'],
      adapterProtocol: 'dap',
      programPath: null,
      cwd: '/tmp',
    ),
    metadata: const <String, Object?>{
      'languages': <String>['c', 'cpp'],
    },
  ),
  DebugLaunchProfile.fromConfiguration(
    id: 'python-dap',
    displayName: 'Python Debug Adapter',
    configuration: const DebugLaunchConfiguration(
      readiness: DebugLaunchReadiness.missingProgram,
      reason: 'Select a Python program.',
      debuggerId: 'python-dap',
      debuggerLabel: 'Python Debug Adapter',
      debuggerExecutablePath: '/bin/sleep',
      debuggerArguments: <String>['30'],
      adapterProtocol: 'dap',
      programPath: null,
      cwd: '/tmp',
    ),
    metadata: const <String, Object?>{
      'languages': <String>['python'],
      'debuggerType': 'python',
    },
  ),
];
