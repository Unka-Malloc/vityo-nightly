import 'dart:async';

import '../../../../ide/local_service/vityod_client.dart';
import '../../configuration/forwarded_host_environment.dart';
import '../platform_adapter/platform_adapter.dart';
import '../platform_context/platform_context.dart';
import 'process_adapter.dart';
import 'process_facts.dart';
import 'process_manager.dart';
import 'process_prober.dart';
import 'process_prober_io.dart';

var _globalTaskSequence = 0;

Future<ProcessManager> createPlatformProcessManager({
  ProcessProber? prober,
  PlatformContextSnapshot? platformContext,
  VityodClient? vityodClient,
}) async {
  final adapter = platformContext == null
      ? null
      : PlatformAdapter(platformContext);
  final facts =
      adapter?.context.process ??
      await (prober ?? const LocalProcessProber()).probe();
  if (vityodClient == null) return UnsupportedProcessManager(facts: facts);
  return LocalProcessManager(
    facts: facts,
    client: vityodClient,
    adapter: adapter?.processAdapter,
  );
}

class LocalProcessManager implements ProcessManager, CancellableProcessManager {
  LocalProcessManager({
    required this.facts,
    required VityodClient client,
    ProcessAdapter? adapter,
  }) : _client = client,
       _adapter = adapter ?? ProcessAdapter(facts),
       compatibility = (adapter ?? ProcessAdapter(facts)).adapt();

  factory LocalProcessManager.linuxDebianArmForTest({
    required VityodClient client,
  }) =>
      LocalProcessManager(facts: ProcessFacts.linuxDebianArm(), client: client);

  final VityodClient _client;
  final ProcessAdapter _adapter;

  @override
  final ProcessFacts facts;

  @override
  final ProcessCompatibility compatibility;

  @override
  ProcessOperationFailure? failureFor(
    ProcessCommandResult result, {
    String operation = 'process.spawn',
    String? recoveryHint,
  }) {
    return const ProcessFailureClassifier(
      sourceManager: 'VityodProcessManager',
    ).classify(result, operation: operation, recoveryHint: recoveryHint);
  }

  @override
  Future<ProcessCommandResult> run(ProcessCommandRequest request) async {
    final plan = _adapter.plan(request);
    if (!plan.supported) {
      return ProcessCommandResult(
        status: ProcessCommandStatus.blocked,
        executablePath: request.executablePath,
        arguments: request.arguments,
        exitCode: null,
        stdout: '',
        stderr: '',
        duration: Duration.zero,
        message: plan.unsupportedMessage,
      );
    }
    if (!_client.state.canDispatch) {
      return ProcessCommandResult(
        status: ProcessCommandStatus.blocked,
        executablePath: plan.executablePath,
        arguments: plan.arguments,
        exitCode: null,
        stdout: '',
        stderr: '',
        duration: Duration.zero,
        message: 'The local service is disconnected.',
      );
    }
    final servicePrefix = request.serviceKind == ProcessServiceKind.generic
        ? 'task'
        : request.serviceKind.name;
    final typedService = request.serviceKind != ProcessServiceKind.generic;
    final taskId =
        '$servicePrefix-${_client.clientInstanceId}-${++_globalTaskSequence}';
    final environment =
        plan.environment.isEmpty && compatibility.supportsEnvironmentOverlay
        ? forwardedHostEnvironment()
        : plan.environment;
    final stopwatch = Stopwatch()..start();
    var taskStarted = false;
    int? processId;
    try {
      final start = await _client.request(
        method: typedService ? '$servicePrefix.request' : 'task.start',
        idempotencyKey: 'task-start-$taskId',
        params: <String, Object?>{
          'taskId': taskId,
          if (typedService) 'action': 'start',
          'executable': plan.executablePath,
          'arguments': plan.arguments,
          'workingDirectory': plan.workingDirectory,
          'environment': environment,
          'standardInput': plan.standardInput,
          if (plan.timeout case final timeout?)
            'timeoutMillis': timeout.inMilliseconds,
        },
      );
      _throwIfError(start);
      taskStarted = true;
      processId = _positiveProcessId(start.params['pid']);
      final onStarted = request.onStarted;
      if (onStarted != null) {
        try {
          onStarted(
            ProcessCommandHandle(
              processHandleId: taskId,
              sourceManager: 'vityod',
              pid: processId,
              metadata: <String, Object?>{
                'serviceKind': request.serviceKind.name,
              },
            ),
          );
        } on Object {
          // Observers must not interrupt daemon task supervision.
        }
      }
      var pollSequence = 0;
      while (true) {
        final output = await _client.request(
          method: typedService ? '$servicePrefix.request' : 'task.output',
          idempotencyKey: 'task-output-$taskId-${++pollSequence}',
          params: <String, Object?>{
            'taskId': taskId,
            if (typedService) 'action': 'output',
          },
          deadline: const Duration(seconds: 5),
        );
        _throwIfError(output);
        if (output.params['running'] == true) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          continue;
        }
        stopwatch.stop();
        final timedOut = output.params['timedOut'] == true;
        final exitCode = output.params['exitCode'];
        final stdout = output.params['stdout'];
        final stderr = output.params['stderr'];
        final durationMillis = output.params['durationMillis'];
        if (exitCode is! int ||
            stdout is! String ||
            stderr is! String ||
            durationMillis is! int) {
          throw StateError('vityod returned an invalid task receipt');
        }
        // Closing retires the daemon record; it cannot change the command's
        // already validated execution receipt or erase captured output.
        final cleanup = <String, Object?>{
          'operation': 'process.close',
          'sourceManager': 'vityod',
        };
        try {
          final method = typedService ? '$servicePrefix.request' : 'task.close';
          final close = await _client.request(
            method: method,
            idempotencyKey: 'task-close-$taskId',
            params: <String, Object?>{
              'taskId': taskId,
              if (typedService) 'action': 'close',
            },
          );
          if (close.method == '$method.error') {
            final code = close.params['errorCode'];
            cleanup.addAll(<String, Object?>{
              'status': 'failed',
              'errorCode':
                  code is String &&
                      RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(code)
                  ? code
                  : 'task_close_failed',
              if (close.params['retryable'] case final bool retryable)
                'retryable': retryable,
            });
          } else if (close.method == '$method.result' &&
              close.params['state'] == 'closed') {
            cleanup['status'] = 'succeeded';
          } else {
            cleanup.addAll(<String, Object?>{
              'status': 'unconfirmed',
              'errorCode': 'invalid_task_close_receipt',
            });
          }
        } on TimeoutException {
          cleanup.addAll(<String, Object?>{
            'status': 'unconfirmed',
            'errorCode': 'task_close_timeout',
          });
        } on Object {
          cleanup.addAll(<String, Object?>{
            'status': 'unconfirmed',
            'errorCode': 'task_close_unconfirmed',
          });
        }
        return ProcessCommandResult(
          status: timedOut
              ? ProcessCommandStatus.timedOut
              : exitCode == 0
              ? ProcessCommandStatus.succeeded
              : ProcessCommandStatus.failed,
          executablePath: plan.executablePath,
          arguments: plan.arguments,
          exitCode: exitCode,
          stdout: stdout,
          stderr: stderr,
          duration: Duration(milliseconds: durationMillis),
          message: timedOut ? 'Process timed out inside vityod.' : null,
          metadata: <String, Object?>{
            'processHandleId': taskId,
            'processHandleSource': 'vityod',
            if (processId != null) 'pid': processId,
            if (output.params['stdoutTruncated'] == true)
              'stdoutTruncated': true,
            if (output.params['stderrTruncated'] == true)
              'stderrTruncated': true,
            'cleanup': cleanup,
          },
        );
      }
    } on Object catch (error) {
      stopwatch.stop();
      return ProcessCommandResult(
        status: ProcessCommandStatus.failed,
        executablePath: plan.executablePath,
        arguments: plan.arguments,
        exitCode: null,
        stdout: '',
        stderr: '',
        duration: stopwatch.elapsed,
        message: 'vityod process supervision failed: $error',
        metadata: <String, Object?>{
          if (taskStarted) 'processHandleId': taskId,
          if (taskStarted) 'processHandleSource': 'vityod',
          if (processId != null) 'pid': processId,
        },
      );
    }
  }

  @override
  Future<ProcessCommandCancellationResult> cancelProcess(
    String processHandleId,
  ) async {
    final taskId = processHandleId.trim();
    if (taskId.isEmpty) {
      return const ProcessCommandCancellationResult.unsupported(
        message: 'Process cancellation requires a process handle.',
      );
    }
    if (!_client.state.canDispatch) {
      return const ProcessCommandCancellationResult.unsupported(
        message:
            'Process cancellation is unavailable while vityod is disconnected.',
      );
    }
    final typedService = _typedServiceForTaskId(taskId);
    try {
      final response = await _client.request(
        method: typedService == null ? 'task.cancel' : '$typedService.request',
        idempotencyKey: 'task-cancel-$taskId',
        params: <String, Object?>{
          'taskId': taskId,
          if (typedService != null) 'action': 'cancel',
        },
      );
      _throwIfError(response);
      final cancelled = response.params['state'] == 'cancelled';
      final exitCode = response.params['exitCode'];
      return ProcessCommandCancellationResult(
        accepted: cancelled,
        processTerminated: cancelled,
        message: cancelled
            ? 'Process $taskId was cancelled by vityod.'
            : 'Process $taskId cancellation was not accepted by vityod.',
        exitCode: exitCode is int ? exitCode : null,
        metadata: <String, Object?>{
          'processHandleId': taskId,
          'processHandleSource': 'vityod',
          if (typedService != null) 'serviceKind': typedService,
        },
      );
    } on Object catch (error) {
      return ProcessCommandCancellationResult(
        accepted: false,
        processTerminated: false,
        message: 'Process $taskId cancellation failed: $error',
        metadata: <String, Object?>{
          'processHandleId': taskId,
          'processHandleSource': 'vityod',
          if (typedService != null) 'serviceKind': typedService,
        },
      );
    }
  }
}

int? _positiveProcessId(Object? value) {
  final processId = switch (value) {
    int value => value,
    String value => int.tryParse(value.trim()),
    _ => null,
  };
  return processId != null && processId > 0 ? processId : null;
}

String? _typedServiceForTaskId(String taskId) =>
    switch (taskId.split('-').first) {
      'styio' => 'styio',
      'pafio' => 'pafio',
      _ => null,
    };

void _throwIfError(dynamic response) {
  if (!response.method.endsWith('.error')) return;
  final code = response.params['errorCode'];
  throw StateError(code is String ? code : 'task_service_error');
}
