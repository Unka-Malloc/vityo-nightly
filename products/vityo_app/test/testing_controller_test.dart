import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/debugger/debugger.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process.dart';
import 'package:vityo_app/src/view_ide/runtime/runtime.dart';
import 'package:vityo_app/src/view_ide/shell_runtime/controllers/execution_controller.dart';
import 'package:vityo_app/src/view_ide/shell_runtime/controllers/testing_controller.dart';
import 'package:vityo_app/src/view_ide/testing/testing.dart';

void main() {
  test('native CTest receipt becomes typed testing session result', () {
    final sessionController = TestingSessionController();
    final outputBuffer = RuntimeOutputLiveBuffer();
    final controller = ShellTestingController(
      sessionController: sessionController,
      workspaceRoot: () => '/workspace',
      runNativeTests: ({onProcessStarted, required recordTestingResult}) async {
        throw StateError('Native tests are not expected in this test.');
      },
      processManager: null,
      runtimeOutputBuffer: outputBuffer,
      log: (_) {},
    );
    addTearDown(controller.dispose);
    addTearDown(sessionController.dispose);
    addTearDown(outputBuffer.dispose);

    controller.recordNativeToolResult(
      message: 'Run Tests failed.',
      metadata: <String, Object?>{
        'runner': 'ctest',
        'status': 'failed',
        'totalCount': '2',
        'passedCount': 1,
        'failedCount': 1.0,
        'failedTests': <Map<Object?, Object?>>[
          <Object?, Object?>{
            'id': 'parser',
            'name': 'parser_test',
            'status': 'failed',
            'message': 'assertion failed',
          },
        ],
      },
    );

    final result = sessionController.lastRun;
    expect(result, isNotNull);
    expect(result?.providerId, 'native-tool-runTests');
    expect(result?.runner, 'ctest');
    expect(result?.status, TestRunStatus.failed);
    expect(result?.totalCount, 2);
    expect(result?.passedCount, 1);
    expect(result?.failedCount, 1);
    expect(result?.cases.single.id, 'parser');
    expect(result?.cases.single.message, 'assertion failed');
  });

  test('native non-map metadata is ignored honestly', () {
    final sessionController = TestingSessionController();
    final outputBuffer = RuntimeOutputLiveBuffer();
    final controller = ShellTestingController(
      sessionController: sessionController,
      workspaceRoot: () => '/workspace',
      runNativeTests: ({onProcessStarted, required recordTestingResult}) async {
        throw StateError('Native tests are not expected in this test.');
      },
      processManager: null,
      runtimeOutputBuffer: outputBuffer,
      log: (_) {},
    );
    addTearDown(controller.dispose);
    addTearDown(sessionController.dispose);
    addTearDown(outputBuffer.dispose);

    controller.recordNativeToolResult(
      message: 'Malformed result.',
      metadata: 'not-a-map',
    );

    expect(sessionController.lastRun, isNull);
  });

  test('production test provider records its native CTest process', () async {
    final sessionController = TestingSessionController(
      providerCatalog: TestingProviderCatalog(),
      runtimeTaskLifecycleController: RuntimeTaskLifecycleController(),
    );
    final outputBuffer = RuntimeOutputLiveBuffer();
    final controller = ShellTestingController(
      sessionController: sessionController,
      workspaceRoot: () => '/workspace',
      runNativeTests: ({onProcessStarted, required recordTestingResult}) async {
        onProcessStarted?.call(
          const ProcessCommandHandle(
            processHandleId: 'task-native-tests-4',
            sourceManager: 'vityod',
          ),
        );
        return const NativeToolCommandResult(
          applied: true,
          message: 'Run Tests completed.',
          metadata: <String, Object?>{
            'testResult': <String, Object?>{
              'runner': 'ctest',
              'status': 'passed',
              'totalCount': 1,
              'passedCount': 1,
            },
          },
        );
      },
      processManager: null,
      runtimeOutputBuffer: outputBuffer,
      log: (_) {},
    );
    addTearDown(controller.dispose);
    addTearDown(sessionController.dispose);
    addTearDown(outputBuffer.dispose);

    await controller.runConfiguration(
      const TestRunConfiguration(
        id: 'all-tests',
        label: 'All tests',
        workspaceRoot: '/workspace',
        providerId: 'native-tool-runTests',
      ),
    );
    expect(sessionController.lastRun?.status, TestRunStatus.passed);
    expect(
      sessionController.lastRuntimeTask?.status,
      RuntimeTaskStatus.succeeded,
    );
    expect(
      sessionController.lastRuntimeTask?.events.any(
        (event) => event.metadata['processHandleId'] == 'task-native-tests-4',
      ),
      isTrue,
    );
  });

  test('production test provider binds and cancels its DAP process', () async {
    final lifecycle = RuntimeTaskLifecycleController();
    final handleRegistry = FailedTestDebugCancellationHandleRegistry();
    final sessionController = TestingSessionController(
      providerCatalog: TestingProviderCatalog(),
      runtimeTaskLifecycleController: lifecycle,
      failedTestDebugCancellationHandleRegistry: handleRegistry,
    );
    final outputBuffer = RuntimeOutputLiveBuffer();
    final transport = _ManagedFixtureDapTransport();
    final processBound = Completer<void>();
    void observeProcessBinding() {
      if (!processBound.isCompleted &&
          sessionController
                  .lastRuntimeTask
                  ?.lastEvent
                  ?.metadata['processHandleId'] ==
              'task-dap-tests-7') {
        processBound.complete();
      }
    }

    sessionController.addListener(observeProcessBinding);
    final controller = ShellTestingController(
      sessionController: sessionController,
      workspaceRoot: () => '/workspace',
      runNativeTests: ({onProcessStarted, required recordTestingResult}) async {
        throw StateError('CTest must not run for a DAP configuration.');
      },
      processManager: null,
      runtimeOutputBuffer: outputBuffer,
      log: (_) {},
      debugAdapterLauncher: DapDebugAdapterLauncher(
        transportFactory: (_) async => transport,
      ),
    );
    var controllerNotifications = 0;
    controller.addListener(() {
      controllerNotifications += 1;
    });
    addTearDown(controller.dispose);
    addTearDown(() {
      sessionController.removeListener(observeProcessBinding);
    });
    addTearDown(sessionController.dispose);
    addTearDown(outputBuffer.dispose);
    addTearDown(transport.close);
    const configuration = TestRunConfiguration(
      id: 'failed-tests',
      label: 'Debug failed tests',
      workspaceRoot: '/workspace',
      providerId: 'native-tool-runTests',
      debug: true,
      metadata: <String, Object?>{
        'debuggerExecutablePath': '/usr/bin/lldb-dap',
        'programPath': '/workspace/build/tests',
      },
    );

    final pending = controller.debugConfiguration(configuration);
    await processBound.future;

    await controller.runConfiguration(
      const TestRunConfiguration(
        id: 'all-tests',
        label: 'All tests',
        workspaceRoot: '/workspace',
        providerId: 'native-tool-runTests',
      ),
    );

    final snapshot = sessionController.lastRuntimeTask;
    final route = sessionController.planFailedTestDebugCancellation(
      failedTest: const <String, Object?>{
        'id': 'parser.syntax',
        'name': 'parser syntax',
      },
    );

    expect(snapshot?.active, isTrue);
    expect(controller.runActive, isTrue);
    expect(controllerNotifications, greaterThan(0));
    expect(snapshot?.definition.kind, RuntimeTaskKind.debug);
    expect(
      snapshot?.lastEvent?.metadata['processHandleId'],
      'task-dap-tests-7',
    );
    expect(route.ready, isTrue);
    expect(route.processHandleId, 'task-dap-tests-7');
    expect(
      handleRegistry
          .registrationFor(
            providerId: 'native-tool-runTests',
            configurationId: 'failed-tests',
          )
          ?.kind,
      FailedTestDebugCancellationHandleKind.debugAdapter,
    );

    await controller.cancelFailedDebug(const <String, Object?>{
      'id': 'parser.syntax',
      'name': 'parser syntax',
    });
    await pending;

    expect(transport.sentCommands.last, 'disconnect');
    expect(transport.closed, isTrue);
    expect(
      sessionController.lastRuntimeTask?.status,
      RuntimeTaskStatus.cancelled,
    );
    expect(sessionController.lastRun?.status, TestRunStatus.notRun);
  });

  test(
    'disposing the testing controller closes an active DAP process',
    () async {
      final sessionController = TestingSessionController(
        providerCatalog: TestingProviderCatalog(),
        runtimeTaskLifecycleController: RuntimeTaskLifecycleController(),
      );
      final outputBuffer = RuntimeOutputLiveBuffer();
      final transport = _ManagedFixtureDapTransport();
      final processBound = Completer<void>();
      void observeProcessBinding() {
        if (!processBound.isCompleted &&
            sessionController
                    .lastRuntimeTask
                    ?.lastEvent
                    ?.metadata['processHandleId'] ==
                'task-dap-tests-7') {
          processBound.complete();
        }
      }

      sessionController.addListener(observeProcessBinding);
      final controller = ShellTestingController(
        sessionController: sessionController,
        workspaceRoot: () => '/workspace',
        runNativeTests:
            ({onProcessStarted, required recordTestingResult}) async {
              throw StateError('CTest must not run for a DAP configuration.');
            },
        processManager: null,
        runtimeOutputBuffer: outputBuffer,
        log: (_) {},
        debugAdapterLauncher: DapDebugAdapterLauncher(
          transportFactory: (_) async => transport,
        ),
      );
      addTearDown(() {
        sessionController.removeListener(observeProcessBinding);
      });
      addTearDown(sessionController.dispose);
      addTearDown(outputBuffer.dispose);
      addTearDown(transport.close);

      final pending = controller.debugConfiguration(
        const TestRunConfiguration(
          id: 'dispose-debug',
          label: 'Dispose debug',
          workspaceRoot: '/workspace',
          providerId: 'native-tool-runTests',
          debug: true,
          metadata: <String, Object?>{
            'debuggerExecutablePath': '/usr/bin/lldb-dap',
            'programPath': '/workspace/build/tests',
          },
        ),
      );
      await processBound.future;

      controller.dispose();
      sessionController.dispose();
      await pending;

      expect(transport.closed, isTrue);
      expect(sessionController.lastRun?.status, TestRunStatus.notRun);
      expect(controller.runActive, isFalse);
    },
  );
}

final class _ManagedFixtureDapTransport
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
        processHandleId: 'task-dap-tests-7',
        source: 'fixture-dap',
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
