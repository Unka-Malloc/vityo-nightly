import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vityo_app/src/view_ide/debugger/debugger.dart';
import 'package:vityo_app/src/view_ide/runtime/runtime.dart';
import 'package:vityo_app/src/view_ide/shell_runtime/controllers/execution_controller.dart';
import 'package:vityo_app/src/view_ide/shell_runtime/controllers/testing_controller.dart';
import 'package:vityo_app/src/view_ide/testing/testing.dart';
import 'package:vityo_app/src/view_ide/platform/platform_target.dart';
import 'package:vityo_app/src/view_render/platform/platform.dart';
import 'package:vityo_app/src/view_render/testing/testing.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS engine drives live DAP test cancellation', (tester) async {
    expect(Platform.isMacOS, isTrue, reason: 'run this lane on macOS');
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1000);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final transport = _IntegrationDapTransport();
    final processBound = Completer<void>();
    final cancellationObserved = Completer<void>();
    final session = TestingSessionController(
      providerCatalog: TestingProviderCatalog(),
      runtimeTaskLifecycleController: RuntimeTaskLifecycleController(),
      failedTestDebugCancellationHandleRegistry:
          FailedTestDebugCancellationHandleRegistry(),
    );
    void observeSession() {
      final runtimeTask = session.lastRuntimeTask;
      if (!processBound.isCompleted &&
          runtimeTask?.lastEvent?.metadata['processHandleId'] ==
              'task-dap-ui-1') {
        processBound.complete();
      }
      if (!cancellationObserved.isCompleted &&
          runtimeTask?.status == RuntimeTaskStatus.cancelled) {
        cancellationObserved.complete();
      }
    }

    session.addListener(observeSession);
    final output = RuntimeOutputLiveBuffer();
    Future<void>? debugRun;
    final controller = ShellTestingController(
      sessionController: session,
      workspaceRoot: () => '/workspace/vityo',
      runNativeTests: ({onProcessStarted, required recordTestingResult}) async {
        throw StateError('CTest must not run for a DAP configuration.');
      },
      processManager: null,
      runtimeOutputBuffer: output,
      log: (_) {},
      debugAdapterLauncher: DapDebugAdapterLauncher(
        transportFactory: (_) async => transport,
      ),
    );
    addTearDown(() async {
      await transport.close();
      await debugRun;
      controller.dispose();
      session.removeListener(observeSession);
      session.dispose();
      output.dispose();
    });
    session.recordRunResult(
      const TestRunResult(
        providerId: 'native-tool-runTests',
        runner: 'ctest',
        status: TestRunStatus.failed,
        message: 'One test failed.',
        totalCount: 3,
        passedCount: 2,
        failedCount: 1,
        cases: <TestCaseResult>[
          TestCaseResult(
            id: 'parser.syntax',
            name: 'parser syntax',
            status: TestRunStatus.failed,
            message: 'Expected syntax node.',
          ),
        ],
        metadata: <String, Object?>{
          'debuggerExecutablePath': '/usr/bin/lldb-dap',
          'programPath': '/workspace/vityo/build/tests',
        },
      ),
    );
    final failedConfiguration = controller.configurationSet.configurations.last;
    controller.selectConfiguration(failedConfiguration);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff6750a4),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: session,
            builder: (_, _) => RepaintBoundary(
              key: const ValueKey('testing-process-native-evidence'),
              child: TestingSurface(
                viewportProfile: resolveViewportProfile(
                  platformTarget: PlatformTarget.macos,
                  width: 1280,
                  height: 1000,
                ),
                nativeToolResults: const <NativeToolResultRecord>[],
                lastRun: controller.lastRun,
                runHistory: controller.runHistory,
                configurationSet: controller.configurationSet,
                failedDebugCancellationRoute:
                    controller.failedDebugCancellationRoute,
                testRunActive: controller.runActive,
                onDebugConfiguration: (configuration) {
                  final pending = controller.debugConfiguration(configuration);
                  debugRun = pending;
                  return pending;
                },
                onCancelFailedTestDebug: controller.cancelFailedDebug,
                onSelectRunConfiguration: controller.selectConfiguration,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('testing-debug-selected-configuration')),
    );
    await processBound.future;
    session.planFailedTestDebugCancellation(
      failedTest: const <String, Object?>{
        'id': 'parser.syntax',
        'name': 'parser syntax',
      },
    );
    await tester.pump();
    expect(find.text('debug-cancel running'), findsOneWidget);
    expect(find.text('test task running'), findsOneWidget);
    expect(find.textContaining('task-dap-ui-1'), findsWidgets);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('testing-debug-selected-configuration')),
          )
          .onPressed,
      isNull,
    );

    await _captureEvidence(tester);

    final cancel = find.byKey(
      const ValueKey('testing-cancel-failed-debug-parser syntax'),
    );
    await tester.ensureVisible(cancel);
    await tester.pump();
    await tester.tap(cancel);
    await cancellationObserved.future;
    await tester.pumpAndSettle();

    expect(transport.sentCommands.last, 'disconnect');
    expect(transport.closed, isTrue);
    expect(session.lastRuntimeTask?.status, RuntimeTaskStatus.cancelled);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _captureEvidence(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('testing-process-native-evidence')),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  expect(bytes, isNotNull);
  final output = Directory('build/integration_test')
    ..createSync(recursive: true);
  File(
    '${output.path}/vityo-testing-process-macos.png',
  ).writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
}

final class _IntegrationDapTransport
    implements
        DapByteTransport,
        DapProcessIdentitySource,
        DapProcessLifecycleSource {
  final StreamController<List<int>> _incoming =
      StreamController<List<int>>.broadcast();
  final Completer<int> _exitCode = Completer<int>();
  final List<List<int>> _sentBytes = <List<int>>[];

  bool get closed => _incoming.isClosed;
  List<String> get sentCommands => _sentBytes
      .map(
        (bytes) =>
            const DapContentFrameCodec().decodeFirst(bytes)!.message['command']!
                as String,
      )
      .toList(growable: false);

  @override
  RuntimeProcessHandleIdentity get processHandle =>
      const RuntimeProcessHandleIdentity(
        managerId: 'debug-adapter',
        processHandleId: 'task-dap-ui-1',
        source: 'integration-dap',
      );

  @override
  Future<int> get processExitCode => _exitCode.future;

  @override
  Stream<List<int>> get incomingBytes => _incoming.stream;

  @override
  Future<void> send(List<int> bytes) async {
    _sentBytes.add(List<int>.unmodifiable(bytes));
  }

  @override
  Future<void> close() async {
    if (!_exitCode.isCompleted) {
      _exitCode.complete(0);
    }
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
  }
}
