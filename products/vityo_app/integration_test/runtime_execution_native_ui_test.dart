import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vityo_app/src/ide/editor/editor.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/backend_toolchain.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';
import 'package:vityo_app/src/view_ide/interaction/interaction.dart';
import 'package:vityo_app/src/view_ide/language/language.dart';
import 'package:vityo_app/src/view_ide/platform/platform.dart';
import 'package:vityo_app/src/view_ide/shell_runtime/controllers/execution_controller.dart';
import 'package:vityo_app/src/view_render/platform/platform.dart';
import 'package:vityo_app/src/view_render/runtime/runtime_surface.dart';

import '../test/support/vityod_test_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS engine runs and stops a managed Runtime Surface process', (
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
      clientId: 'runtime-execution-native-ui',
    );
    final processFacts = await const LocalProcessProber().probe();
    final processManager = LocalProcessManager(
      facts: processFacts,
      client: daemon.client,
    );
    final adapter = _NativeExecutionAdapter(processManager);
    final controller = ExecutionController(
      executionAdapter: adapter,
      executionAdapterFactory: (_) async => adapter,
      runtimeEventAdapter: const _EmptyRuntimeEventAdapter(),
      log: (_) {},
      applyDiagnostics: (_) {},
    );
    Future<void>? activeRun;
    addTearDown(() async {
      if (controller.canCancelActiveExecution) {
        await controller.cancelActiveExecution();
      }
      await activeRun;
      controller.dispose();
      await daemon.close();
    });

    final projectGraph = _projectGraph();
    const document = DocumentState(
      documentId: 'src/main.styio',
      text: 'print("runtime")\n',
      revision: 0,
    );
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
              key: const ValueKey('runtime-execution-native-evidence'),
              child: RuntimeSurface(
                platformTarget: PlatformTarget.macos,
                viewportProfile: resolveViewportProfile(
                  platformTarget: PlatformTarget.macos,
                  width: 1280,
                  height: 960,
                ),
                projectGraph: projectGraph,
                toolchainStatus: ToolchainStatusSurface.fromProjectToolchain(
                  projectGraph.toolchain,
                ),
                mountedModules: const [],
                adapterCapabilities: const <AdapterCapabilitySnapshot>[
                  _nativeCapabilitySnapshot,
                ],
                executionSession: controller.lastExecutionSession,
                executionRunActive: controller.runActive,
                executionCanCancel: controller.canCancelActiveExecution,
                onRunExecution: () {
                  final running = controller.run(
                    platformTarget: PlatformTarget.macos,
                    projectGraph: projectGraph,
                    adapterCapabilities: const <AdapterCapabilitySnapshot>[
                      _nativeCapabilitySnapshot,
                    ],
                    document: document,
                    selection: const SelectionState.collapsed(0),
                    activeFilePath: document.documentId,
                  );
                  activeRun = running;
                  return running;
                },
                onCancelExecution: () async {
                  await controller.cancelActiveExecution();
                },
                runtimeEvents: controller.lastRuntimeEvents,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final run = find.byKey(const ValueKey('runtime-run-execution'));
    await tester.ensureVisible(run);
    await tester.pumpAndSettle();
    await tester.tap(run);
    await _pumpUntil(tester, () => controller.canCancelActiveExecution);

    final stop = find.byKey(const ValueKey('runtime-stop-execution'));
    await tester.ensureVisible(stop);
    await tester.pump();
    expect(find.text('run · running'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('runtime-process-identity')),
      findsOneWidget,
    );
    expect(controller.activeProcessHandle?.pid, greaterThan(0));
    expect(tester.widget<FilledButton>(stop).onPressed, isNotNull);

    await _captureEvidence(tester);

    await tester.tap(stop);
    await _pumpUntil(tester, () => !controller.runActive);
    await activeRun;
    await tester.pumpAndSettle();

    expect(
      controller.lastExecutionSession?.status,
      ExecutionSessionStatus.cancelled,
    );
    expect(find.text('run · cancelled'), findsOneWidget);
    expect(find.text('Run again'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Runtime execution state did not settle.');
    }
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump();
}

Future<void> _captureEvidence(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('runtime-execution-native-evidence')),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  expect(bytes, isNotNull);
  final output = Directory('build/integration_test')
    ..createSync(recursive: true);
  File(
    '${output.path}/vityo-runtime-execution-macos.png',
  ).writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
}

const _nativeCapabilitySnapshot = AdapterCapabilitySnapshot(
  adapterKind: AdapterKind.cli,
  languageService: AdapterEndpointCapability(
    level: AdapterCapabilityLevel.unavailable,
    detail: 'Not used by runtime execution validation.',
  ),
  projectGraph: AdapterEndpointCapability(
    level: AdapterCapabilityLevel.available,
    detail: 'Native validation graph ready.',
  ),
  execution: AdapterEndpointCapability(
    level: AdapterCapabilityLevel.available,
    detail: 'Managed native process execution ready.',
  ),
  runtimeEvents: AdapterEndpointCapability(
    level: AdapterCapabilityLevel.available,
    detail: 'Runtime lifecycle events ready.',
  ),
);

ProjectGraphSnapshot _projectGraph() {
  return ProjectGraphSnapshot.scratch(
    workspaceRoot: '/workspace/vityo-runtime',
    activeFilePath: 'src/main.styio',
    title: 'Vityo Runtime',
    toolchain: const ToolchainStatusSnapshot(
      source: ToolchainResolutionSource.environment,
      detail: 'Native runtime validation toolchain',
      channel: 'local',
      version: '1',
    ),
    activeCompiler: const CompilerHandshakeSnapshot(
      binaryPath: '/toolchains/styio',
      tool: 'styio',
      compilerVersion: '1',
      channel: 'local',
      variant: 'native-validation',
      capabilities: <String>['single_file_entry'],
      supportedContractVersions: <String, List<int>>{
        'machine_info': <int>[1],
      },
      integrationPhase: 'single-file-live',
    ),
    notes: const <String>[],
  );
}

class _NativeExecutionAdapter
    implements ExecutionAdapter, CancellableExecutionAdapter {
  const _NativeExecutionAdapter(this._processManager);

  final LocalProcessManager _processManager;

  @override
  AdapterCapabilitySnapshot get capabilitySnapshot => _nativeCapabilitySnapshot;

  @override
  Future<ExecutionSession> runActiveDocument({
    required PlatformTarget platformTarget,
    required ProjectGraphSnapshot projectGraph,
    required DocumentState document,
    required String activeFilePath,
    ExecutionProcessStartedCallback? onProcessStarted,
  }) async {
    final result = await _processManager.run(
      ProcessCommandRequest(
        executablePath: '/bin/sleep',
        arguments: const <String>['30'],
        timeout: const Duration(seconds: 60),
        onStarted: onProcessStarted,
      ),
    );
    return ExecutionSession(
      sessionId:
          result.metadata['processHandleId'] as String? ?? 'native-runtime',
      kind: 'run',
      status: result.succeeded
          ? ExecutionSessionStatus.succeeded
          : ExecutionSessionStatus.failed,
      statusMessage: result.succeeded
          ? 'Native process completed.'
          : 'Native process stopped.',
      diagnostics: const <Diagnostic>[],
      stdoutEvents: result.stdout.isEmpty
          ? const <ExecutionLogEvent>[]
          : <ExecutionLogEvent>[ExecutionLogEvent(message: result.stdout)],
      stderrEvents: result.stderr.isEmpty
          ? const <ExecutionLogEvent>[]
          : <ExecutionLogEvent>[ExecutionLogEvent(message: result.stderr)],
      metadata: result.metadata,
    );
  }

  @override
  Future<ExecutionCancellationResult> cancelExecution(String processHandleId) =>
      _processManager.cancelProcess(processHandleId);
}

class _EmptyRuntimeEventAdapter implements RuntimeEventAdapter {
  const _EmptyRuntimeEventAdapter();

  @override
  AdapterCapabilitySnapshot get capabilitySnapshot => _nativeCapabilitySnapshot;

  @override
  Stream<RuntimeEventEnvelope> sessionEvents(String sessionId) {
    return const Stream<RuntimeEventEnvelope>.empty();
  }
}
