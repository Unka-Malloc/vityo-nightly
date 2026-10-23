import 'dart:async';

import '../../debugger/debugger.dart';
import '../../environment/system_compatibility/process/process_manager.dart';
import '../../runtime/runtime.dart';
import '../../testing/testing.dart';
import 'execution_controller.dart';

typedef NativeTestCommandExecutor =
    Future<NativeToolCommandResult> Function({
      ProcessCommandStartedCallback? onProcessStarted,
      required bool recordTestingResult,
    });

final class NativeToolTestRunProvider extends ProcessAwareTestRunProvider {
  NativeToolTestRunProvider({
    required this.runNativeTests,
    required this.processManager,
    required this.debugAdapterLauncher,
    required this.runtimeOutputBuffer,
  });

  final NativeTestCommandExecutor runNativeTests;
  final ProcessManager? processManager;
  final DapDebugAdapterLauncher? debugAdapterLauncher;
  final RuntimeOutputLiveBuffer runtimeOutputBuffer;
  final Map<String, _ActiveDebugTestRun> _activeDebugRuns =
      <String, _ActiveDebugTestRun>{};
  final Set<String> _activeNativeProcessHandles = <String>{};
  bool _disposed = false;

  @override
  String get providerId => 'native-tool-runTests';

  @override
  TestRunProcessKind processKind(TestRunRequest request) {
    return request.debug
        ? TestRunProcessKind.debugAdapter
        : TestRunProcessKind.testRunner;
  }

  @override
  Future<TestRunResult> runWithProcessObserver(
    TestRunRequest request, {
    required TestRunProcessStartedCallback onProcessStarted,
  }) async {
    if (_disposed) {
      return TestRunResult(
        providerId: providerId,
        status: TestRunStatus.notRun,
        message: 'Test run blocked: the testing controller is disposed.',
      );
    }
    if (request.debug) {
      return _runDebugConfiguration(
        request,
        onProcessStarted: onProcessStarted,
      );
    }
    var processHandleId = '';
    try {
      final commandResult = await runNativeTests(
        onProcessStarted: (handle) {
          final identity = RuntimeProcessHandleIdentity.tryFromMetadata(
            handle.toMetadata(),
            managerId: 'toolchain-manager',
          );
          if (identity != null) {
            processHandleId = identity.processHandleId;
            if (processHandleId.isNotEmpty) {
              final manager = processManager;
              if (_disposed && manager is CancellableProcessManager) {
                unawaited(
                  (manager as CancellableProcessManager).cancelProcess(
                    processHandleId,
                  ),
                );
              } else {
                _activeNativeProcessHandles.add(processHandleId);
              }
            }
            onProcessStarted(identity);
          }
        },
        recordTestingResult: false,
      );
      final testMetadata = normalizeNativeToolMetadata(
        commandResult.metadata['testResult'],
      );
      if (testMetadata == null) {
        return TestRunResult(
          providerId: providerId,
          status: TestRunStatus.error,
          message: commandResult.message,
          metadata: commandResult.metadata,
        );
      }
      return testRunResultFromNativeToolMetadata(
        testMetadata,
        message: commandResult.message,
      );
    } finally {
      if (processHandleId.isNotEmpty) {
        _activeNativeProcessHandles.remove(processHandleId);
      }
    }
  }

  @override
  Future<TestRunProcessCancellationResult> cancelProcess(
    String processHandleId,
  ) async {
    final debugRun = _activeDebugRuns[processHandleId];
    if (debugRun != null) {
      if (debugRun.cancelling) {
        return const TestRunProcessCancellationResult(
          accepted: true,
          processTerminated: false,
          message: 'The DAP test debug session is already stopping.',
        );
      }
      debugRun.cancelling = true;
      final result = await debugRun.adapter.cancelExecution(
        execution: debugRun.execution,
        buffer: runtimeOutputBuffer,
        reason: 'Test debug session cancelled.',
      );
      final accepted = result.status == DebugRuntimeExecutionStatus.cancelled;
      if (!accepted) {
        debugRun.cancelling = false;
        return TestRunProcessCancellationResult(
          accepted: false,
          processTerminated: false,
          message:
              _lastDebugTelemetryMessage(result) ??
              'The DAP test debug session could not be stopped.',
          metadata: <String, Object?>{
            'debugExecution': _debugExecutionMetadata(result),
          },
        );
      }
      await _finishDebugRun(
        debugRun,
        TestRunResult(
          providerId: providerId,
          runner: 'dap',
          status: TestRunStatus.notRun,
          message: 'Test debug session cancelled.',
          metadata: <String, Object?>{
            'debugExecution': _debugExecutionMetadata(result),
          },
        ),
        closeHandle: false,
      );
      return TestRunProcessCancellationResult(
        accepted: true,
        processTerminated: result.terminationExecution?.executed == true,
        message: 'The DAP test debug session was stopped.',
        metadata: <String, Object?>{
          'debugExecution': _debugExecutionMetadata(result),
        },
      );
    }
    final manager = processManager;
    if (manager is! CancellableProcessManager) {
      return const TestRunProcessCancellationResult(
        accepted: false,
        processTerminated: false,
        message: 'The active test process manager cannot cancel processes.',
      );
    }
    final result = await (manager as CancellableProcessManager).cancelProcess(
      processHandleId,
    );
    return TestRunProcessCancellationResult(
      accepted: result.accepted,
      processTerminated: result.processTerminated,
      message: result.message,
      metadata: <String, Object?>{
        ...result.metadata,
        if (result.exitCode != null) 'exitCode': result.exitCode,
      },
    );
  }

  Future<TestRunResult> _runDebugConfiguration(
    TestRunRequest request, {
    required TestRunProcessStartedCallback onProcessStarted,
  }) async {
    final configuration = TestRunConfiguration(
      id: request.configurationId.isEmpty
          ? 'debug-tests'
          : request.configurationId,
      label: request.configurationLabel.isEmpty
          ? 'Debug tests'
          : request.configurationLabel,
      workspaceRoot: request.workspaceRoot,
      providerId: request.providerId.isEmpty ? providerId : request.providerId,
      targetId: request.targetId,
      filter: request.filter,
      debug: true,
      metadata: request.metadata,
    );
    final launch = const TestDebugLaunchRoutePlanner().launchConfiguration(
      configuration,
    );
    final plan = DapDebugAdapterExecutionPlan.fromConfiguration(
      profileId: 'test-debug.${configuration.id}',
      launchConfiguration: launch,
    );
    final launcher = debugAdapterLauncher;
    if (launcher == null) {
      return TestRunResult(
        providerId: providerId,
        runner: 'dap',
        status: TestRunStatus.notRun,
        message: 'Test debug launch blocked: no DAP launcher is available.',
        metadata: <String, Object?>{'debugPlan': _debugPlanMetadata(plan)},
      );
    }
    final adapter = DebugRuntimeExecutionAdapter(
      launcher: launcher,
      workspaceId: request.workspaceRoot,
    );
    final execution = await adapter.executePlan(
      plan: plan,
      buffer: runtimeOutputBuffer,
    );
    if (!execution.launched) {
      return TestRunResult(
        providerId: providerId,
        runner: 'dap',
        status: execution.failed ? TestRunStatus.error : TestRunStatus.notRun,
        message: _lastDebugTelemetryMessage(execution) ?? plan.message,
        metadata: <String, Object?>{
          'debugExecution': _debugExecutionMetadata(execution),
        },
      );
    }
    final handle = execution.handle;
    final processHandle = execution.processHandle;
    final processExitCode = handle?.processExitCode;
    if (handle == null ||
        processHandle == null ||
        !processHandle.available ||
        processExitCode == null) {
      await handle?.close();
      return TestRunResult(
        providerId: providerId,
        runner: 'dap',
        status: TestRunStatus.error,
        message:
            'Test debug launch failed: the DAP transport did not expose a managed process lifecycle.',
        metadata: <String, Object?>{
          'debugExecution': _debugExecutionMetadata(execution),
        },
      );
    }
    if (_disposed) {
      await handle.close();
      return TestRunResult(
        providerId: providerId,
        runner: 'dap',
        status: TestRunStatus.notRun,
        message: 'Test debug session stopped during controller disposal.',
        metadata: <String, Object?>{
          'debugExecution': _debugExecutionMetadata(execution),
        },
      );
    }
    if (_activeDebugRuns.containsKey(processHandle.processHandleId)) {
      await handle.close();
      return TestRunResult(
        providerId: providerId,
        runner: 'dap',
        status: TestRunStatus.error,
        message:
            'Test debug launch failed: process handle ${processHandle.processHandleId} is already active.',
        metadata: <String, Object?>{
          'debugExecution': _debugExecutionMetadata(execution),
        },
      );
    }

    final active = _ActiveDebugTestRun(
      processHandleId: processHandle.processHandleId,
      adapter: adapter,
      execution: execution,
    );
    _activeDebugRuns[active.processHandleId] = active;
    active.snapshotSubscription = handle.snapshotEvents.listen(
      (snapshot) {
        switch (snapshot.status) {
          case DapSessionStatus.terminated:
            unawaited(
              _finishDebugRun(
                active,
                _debugCompletionResult(
                  active,
                  status: TestRunStatus.passed,
                  message: 'Test debug session completed.',
                  snapshot: snapshot,
                ),
              ),
            );
            break;
          case DapSessionStatus.failed:
            unawaited(
              _finishDebugRun(
                active,
                _debugCompletionResult(
                  active,
                  status: TestRunStatus.error,
                  message:
                      snapshot.failureMessage ?? 'Test debug session failed.',
                  snapshot: snapshot,
                ),
              ),
            );
            break;
          case DapSessionStatus.idle ||
              DapSessionStatus.initializing ||
              DapSessionStatus.launching ||
              DapSessionStatus.running ||
              DapSessionStatus.paused:
            break;
        }
      },
      onError: (Object error) {
        if (!active.cancelling) {
          unawaited(
            _finishDebugRun(
              active,
              _debugCompletionResult(
                active,
                status: TestRunStatus.error,
                message: 'Test debug session transport failed: $error',
              ),
            ),
          );
        }
      },
    );
    processExitCode.then(
      (exitCode) {
        if (!active.cancelling) {
          unawaited(
            _finishDebugRun(
              active,
              _debugCompletionResult(
                active,
                status: exitCode == 0
                    ? TestRunStatus.passed
                    : TestRunStatus.error,
                message: exitCode == 0
                    ? 'Test debug adapter exited cleanly.'
                    : 'Test debug adapter exited with code $exitCode.',
                exitCode: exitCode,
              ),
            ),
          );
        }
      },
      onError: (Object error) {
        if (!active.cancelling) {
          unawaited(
            _finishDebugRun(
              active,
              _debugCompletionResult(
                active,
                status: TestRunStatus.error,
                message: 'Test debug adapter process failed: $error',
              ),
            ),
          );
        }
      },
    );
    onProcessStarted(processHandle);

    final initialSnapshot = handle.snapshot;
    if (initialSnapshot.status == DapSessionStatus.terminated ||
        initialSnapshot.status == DapSessionStatus.failed) {
      unawaited(
        _finishDebugRun(
          active,
          _debugCompletionResult(
            active,
            status: initialSnapshot.status == DapSessionStatus.terminated
                ? TestRunStatus.passed
                : TestRunStatus.error,
            message:
                initialSnapshot.failureMessage ??
                (initialSnapshot.status == DapSessionStatus.terminated
                    ? 'Test debug session completed.'
                    : 'Test debug session failed.'),
            snapshot: initialSnapshot,
          ),
        ),
      );
    }
    return active.completer.future;
  }

  TestRunResult _debugCompletionResult(
    _ActiveDebugTestRun active, {
    required TestRunStatus status,
    required String message,
    DapSessionSnapshot? snapshot,
    int? exitCode,
  }) {
    return TestRunResult(
      providerId: providerId,
      runner: 'dap',
      status: status,
      message: message,
      metadata: <String, Object?>{
        'debugExecution': _debugExecutionMetadata(active.execution),
        if (snapshot != null) 'debugSession': snapshot.toJson(),
        if (exitCode != null) 'exitCode': exitCode,
      },
    );
  }

  Future<void> _finishDebugRun(
    _ActiveDebugTestRun active,
    TestRunResult result, {
    bool closeHandle = true,
  }) async {
    if (active.finishing || active.completer.isCompleted) {
      return;
    }
    active.finishing = true;
    await active.snapshotSubscription?.cancel();
    if (closeHandle) {
      try {
        await active.execution.handle?.close();
      } on Object catch (error) {
        result = TestRunResult(
          providerId: providerId,
          runner: 'dap',
          status: TestRunStatus.error,
          message: 'Test debug session cleanup failed: $error',
          metadata: result.metadata,
        );
      }
    }
    if (identical(_activeDebugRuns[active.processHandleId], active)) {
      _activeDebugRuns.remove(active.processHandleId);
    }
    if (!active.completer.isCompleted) {
      active.completer.complete(result);
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final manager = processManager;
    if (manager is CancellableProcessManager) {
      for (final processHandleId in _activeNativeProcessHandles) {
        unawaited(
          (manager as CancellableProcessManager).cancelProcess(processHandleId),
        );
      }
    }
    _activeNativeProcessHandles.clear();
    for (final active in _activeDebugRuns.values.toList(growable: false)) {
      if (active.finishing) {
        continue;
      }
      active.cancelling = true;
      unawaited(_closeDebugRunOnDispose(active));
    }
  }

  Future<void> _closeDebugRunOnDispose(_ActiveDebugTestRun active) async {
    Object? closeError;
    try {
      await active.execution.handle?.close();
    } on Object catch (error) {
      closeError = error;
    } finally {
      await _finishDebugRun(
        active,
        TestRunResult(
          providerId: providerId,
          runner: 'dap',
          status: closeError == null
              ? TestRunStatus.notRun
              : TestRunStatus.error,
          message: closeError == null
              ? 'Test debug session stopped during controller disposal.'
              : 'Test debug session cleanup failed during controller disposal.',
          metadata: <String, Object?>{
            'debugExecution': _debugExecutionMetadata(active.execution),
          },
        ),
        closeHandle: false,
      );
    }
  }
}

final class _ActiveDebugTestRun {
  _ActiveDebugTestRun({
    required this.processHandleId,
    required this.adapter,
    required this.execution,
  });

  final String processHandleId;
  final DebugRuntimeExecutionAdapter adapter;
  final DebugRuntimeExecutionResult execution;
  final Completer<TestRunResult> completer = Completer<TestRunResult>();
  StreamSubscription<DapSessionSnapshot>? snapshotSubscription;
  bool cancelling = false;
  bool finishing = false;
}

String? _lastDebugTelemetryMessage(DebugRuntimeExecutionResult execution) {
  final records = execution.telemetry.records;
  return records.isEmpty ? null : records.last.message;
}

Map<String, Object?> _debugPlanMetadata(DapDebugAdapterExecutionPlan plan) {
  return <String, Object?>{
    'profileId': plan.profileId,
    'status': plan.status.wireValue,
    'ready': plan.ready,
    'message': plan.message,
  };
}

Map<String, Object?> _debugExecutionMetadata(
  DebugRuntimeExecutionResult execution,
) {
  final termination = execution.terminationExecution;
  return <String, Object?>{
    'status': execution.status.wireValue,
    'plan': _debugPlanMetadata(execution.plan),
    'dispatchStatus': execution.dispatchResult.status.name,
    if (execution.processHandle != null)
      'processHandle': execution.processHandle!.toJson(),
    if (execution.handle != null)
      'sessionStatus': execution.handle!.snapshot.status.name,
    if (termination != null)
      'termination': <String, Object?>{
        'status': termination.status.wireValue,
        'action': termination.plan.action.wireValue,
        'executed': termination.executed,
        if (termination.processResult != null)
          'processTerminated': termination.processResult!.processTerminated,
      },
  };
}

Map<String, Object?>? normalizeNativeToolMetadata(Object? metadata) {
  return switch (metadata) {
    Map<String, Object?> value => value,
    Map value => value.map(
      (key, value) => MapEntry<String, Object?>(key.toString(), value),
    ),
    _ => null,
  };
}

TestRunResult testRunResultFromNativeToolMetadata(
  Map<String, Object?> metadata, {
  required String message,
}) {
  return TestRunResult(
    providerId: 'native-tool-runTests',
    runner: metadata['runner']?.toString() ?? 'native-tool',
    status: _testRunStatusFromNativeToolMetadata(metadata['status']),
    message: message,
    totalCount: _intFromNativeToolMetadata(metadata['totalCount']) ?? 0,
    passedCount: _intFromNativeToolMetadata(metadata['passedCount']) ?? 0,
    failedCount: _intFromNativeToolMetadata(metadata['failedCount']) ?? 0,
    skippedCount: _intFromNativeToolMetadata(metadata['skippedCount']) ?? 0,
    cases: _failedTestCasesFromNativeToolMetadata(metadata),
    metadata: Map<String, Object?>.unmodifiable(metadata),
  );
}

List<TestCaseResult> _failedTestCasesFromNativeToolMetadata(
  Map<String, Object?> metadata,
) {
  final value = metadata['failedTests'];
  if (value is! List) {
    return const <TestCaseResult>[];
  }
  return value
      .whereType<Map>()
      .map((entry) {
        final normalized = entry.map(
          (key, value) => MapEntry(key.toString(), value),
        );
        return TestCaseResult(
          id: normalized['id']?.toString() ?? '',
          name: normalized['name']?.toString() ?? 'unknown',
          status: _testRunStatusFromNativeToolMetadata(
            normalized['status'] ?? 'failed',
          ),
          message: normalized['message']?.toString() ?? '',
        );
      })
      .toList(growable: false);
}

TestRunStatus _testRunStatusFromNativeToolMetadata(Object? value) {
  return switch (value?.toString()) {
    'passed' => TestRunStatus.passed,
    'failed' => TestRunStatus.failed,
    'skipped' => TestRunStatus.skipped,
    'not-run' || 'blocked' => TestRunStatus.notRun,
    _ => TestRunStatus.error,
  };
}

int? _intFromNativeToolMetadata(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}
