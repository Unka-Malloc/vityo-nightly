import 'dart:convert';

import 'package:vityo_app/src/view_ide/environment/configuration/environment_variable_configuration.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_manager.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/pty/pty_manager.dart';
import 'package:vityo_app/src/view_ide/runtime/task_execution_runtime.dart';

Future<void> main() async {
  _testEnvironmentIntent();
  var tick = 0;
  final runtime = TaskExecutionRuntime(
    redactionPolicy: const EnvironmentVariableRedactionPolicy(),
    stdoutCapBytes: 16,
    stderrCapBytes: 16,
    stdoutCapDeltas: 2,
    stderrCapDeltas: 2,
    clock: () => DateTime.utc(2026, 6, 29, 12, 0, tick++),
  );

  runtime.startFromProcessRequest(
    operationId: 'task.run',
    request: const ProcessCommandRequest(
      executablePath: 'dart',
      arguments: <String>['run', 'tool.dart'],
      environment: <String, String>{
        'TOKEN': 'secret-value',
        'PATH': '/usr/bin',
      },
      workingDirectory: '/workspace',
    ),
  );
  runtime.stdout('hello\n');
  runtime.stderr('warning\n');
  runtime.diagnostic(
    'lint',
    'Trailing whitespace.',
    severity: TaskExecutionDiagnosticSeverity.warning,
    source: 'analysis',
  );
  runtime.runtimeEvent('Runtime hook fired.');
  runtime.cancel(reason: 'User cancelled the task.');
  runtime.cleanup(message: 'Released temporary files.');

  final record = runtime.snapshot();
  final restored = TaskExecutionRuntimeRecord.fromJson(record.toJson());

  _expect(record.operationId == 'task.run', 'operationId');
  _expect(
    record.argv.length == 3 &&
        record.argv[0] == 'dart' &&
        record.argv[1] == 'run' &&
        record.argv[2] == 'tool.dart',
    'argv',
  );
  _expect(record.cwd == '/workspace', 'cwd');
  _expect(
    record.redactedEnvironment['TOKEN'] == '<redacted>',
    'redacted TOKEN',
  );
  _expect(record.redactedEnvironment['PATH'] == '/usr/bin', 'PATH');
  _expect(record.inheritsHostEnvironment == false, 'explicit environment');
  _expect(
    restored.inheritsHostEnvironment == false,
    'round-trip explicit environment',
  );
  _expect(record.stdoutDeltas.length == 1, 'stdout count');
  _expect(record.stderrDeltas.length == 1, 'stderr count');
  _expect(record.stdoutDeltas.single.text == 'hello\n', 'stdout text');
  _expect(record.stderrDeltas.single.text == 'warning\n', 'stderr text');
  _expect(record.diagnostics.single.code == 'lint', 'diagnostic code');
  _expect(
    record.runtimeEvents.first.kind == TaskExecutionEventKind.started,
    'started event',
  );
  _expect(
    record.runtimeEvents.any(
      (event) => event.kind == TaskExecutionEventKind.cancelled,
    ),
    'cancel event',
  );
  _expect(
    record.cancellation?.reason == 'User cancelled the task.',
    'cancellation',
  );
  _expect(
    record.cleanup?.message == 'Released temporary files.',
    'cleanup message',
  );
  _expect(record.completed, 'completed');
  _expect(record.cleanedUp, 'cleaned up');
  _expect(
    restored.runtimeEvents.length == record.runtimeEvents.length,
    'round-trip runtime events',
  );
  _expect(
    restored.cancellation?.reason == 'User cancelled the task.',
    'round-trip cancellation',
  );
  _expect(
    restored.cleanup?.message == 'Released temporary files.',
    'round-trip cleanup',
  );
  _expect(
    restored.toJson()['schemaVersion'] == 1 &&
        (restored.toJson()['stdoutDeltas'] as List<Object?>).every(
          (delta) => (delta as Map<String, Object?>)['schemaVersion'] == 1,
        ) &&
        (restored.toJson()['diagnostics'] as List<Object?>).every(
          (diagnostic) =>
              (diagnostic as Map<String, Object?>)['schemaVersion'] == 1,
        ) &&
        (restored.toJson()['runtimeEvents'] as List<Object?>).every(
          (event) => (event as Map<String, Object?>)['schemaVersion'] == 1,
        ) &&
        (restored.toJson()['cancellation']
                as Map<String, Object?>)['schemaVersion'] ==
            1 &&
        (restored.toJson()['cleanup']
                as Map<String, Object?>)['schemaVersion'] ==
            1,
    'nested schema versions',
  );

  final futurePayload = <String, Object?>{
    ...record.toJson(),
    'schemaVersion': 2,
    'futureRecordField': 'record-value',
    'stdoutDeltas': <Object?>[
      <String, Object?>{
        ...(record.stdoutDeltas.single.toJson()),
        'futureDeltaField': 'delta-value',
      },
    ],
    'diagnostics': <Object?>[
      <String, Object?>{
        ...(record.diagnostics.single.toJson()),
        'futureDiagnosticField': 'diagnostic-value',
      },
    ],
    'runtimeEvents': <Object?>[
      for (final event in record.runtimeEvents)
        <String, Object?>{
          ...event.toJson(),
          'futureEventField': event.sequence,
        },
    ],
    'cancellation': <String, Object?>{
      ...record.cancellation!.toJson(),
      'futureCancellationField': true,
    },
    'cleanup': <String, Object?>{
      ...record.cleanup!.toJson(),
      'futureCleanupField': true,
    },
  };
  final futureRestored = TaskExecutionRuntimeRecord.fromJson(futurePayload);
  final futureRoundTrip = futureRestored.toJson();
  _expect(futureRestored.schemaVersion == 2, 'future schema version');
  _expect(
    futureRoundTrip['futureRecordField'] == 'record-value',
    'record extension round-trip',
  );
  _expect(
    ((futureRoundTrip['stdoutDeltas'] as List<Object?>).single
            as Map<String, Object?>)['futureDeltaField'] ==
        'delta-value',
    'output delta extension round-trip',
  );
  _expect(
    ((futureRoundTrip['diagnostics'] as List<Object?>).single
            as Map<String, Object?>)['futureDiagnosticField'] ==
        'diagnostic-value',
    'diagnostic extension round-trip',
  );
  _expect(
    ((futureRoundTrip['runtimeEvents'] as List<Object?>).first
            as Map<String, Object?>)['futureEventField'] ==
        1,
    'runtime event extension round-trip',
  );
  _expect(
    (futureRoundTrip['cancellation']
            as Map<String, Object?>)['futureCancellationField'] ==
        true,
    'cancellation extension round-trip',
  );
  _expect(
    (futureRoundTrip['cleanup']
            as Map<String, Object?>)['futureCleanupField'] ==
        true,
    'cleanup extension round-trip',
  );

  // ignore: avoid_print
  print('task_execution_runtime_test passed');
}

void _testEnvironmentIntent() {
  final startedAt = DateTime.utc(2026, 6, 29, 12);
  for (final fixture
      in <
        ({
          String label,
          ProcessCommandRequest request,
          bool inheritsHostEnvironment,
        })
      >[
        (
          label: 'omitted',
          request: const ProcessCommandRequest(executablePath: 'dart'),
          inheritsHostEnvironment: true,
        ),
        (
          label: 'null',
          request: const ProcessCommandRequest(
            executablePath: 'dart',
            environment: null,
          ),
          inheritsHostEnvironment: true,
        ),
        (
          label: 'empty',
          request: const ProcessCommandRequest(
            executablePath: 'dart',
            environment: <String, String>{},
          ),
          inheritsHostEnvironment: false,
        ),
      ]) {
    final runtime = TaskExecutionRuntime(clock: () => startedAt);
    runtime.startFromProcessRequest(
      operationId: 'environment.${fixture.label}',
      request: fixture.request,
    );
    runtime.stdout('started');
    runtime.complete();
    final record = runtime.snapshot();
    final payload =
        jsonDecode(jsonEncode(record.toJson())) as Map<String, Object?>;
    final restored = TaskExecutionRuntimeRecord.fromJson(payload);
    _expect(
      record.inheritsHostEnvironment == fixture.inheritsHostEnvironment &&
          restored.inheritsHostEnvironment == fixture.inheritsHostEnvironment,
      '${fixture.label} environment intent survives runtime updates and JSON',
    );
    _expect(
      payload['inheritsHostEnvironment'] == fixture.inheritsHostEnvironment &&
          !restored.extensions.containsKey('inheritsHostEnvironment'),
      '${fixture.label} environment intent is a typed contract field',
    );
    _expect(
      record.redactedEnvironment.isEmpty &&
          restored.redactedEnvironment.isEmpty &&
          (payload['redactedEnvironment'] as Map).isEmpty,
      '${fixture.label} redacted environment remains an empty map',
    );
    _expect(
      restored
              .toRuntimeTaskSnapshot()
              .definition
              .metadata['inheritsHostEnvironment'] ==
          fixture.inheritsHostEnvironment,
      '${fixture.label} environment intent survives snapshot projection',
    );
  }

  final manual = TaskExecutionRuntimeRecord(
    operationId: 'manual',
    argv: const <String>['dart'],
    cwd: '.',
    redactedEnvironment: const <String, String>{},
    startedAt: startedAt,
  );
  final pty = TaskExecutionRuntimeRecord.fromPtyRequest(
    operationId: 'pty',
    request: const PtySessionRequest(executablePath: 'sh'),
    startedAt: startedAt,
  );
  for (final record in <TaskExecutionRuntimeRecord>[manual, pty]) {
    _expect(
      record.inheritsHostEnvironment == null &&
          record.copyWith().inheritsHostEnvironment == null &&
          !record.toJson().containsKey('inheritsHostEnvironment') &&
          !record.toRuntimeTaskSnapshot().definition.metadata.containsKey(
            'inheritsHostEnvironment',
          ),
      '${record.operationId} environment intent remains unknown',
    );
  }
  for (final environment in <Map<String, String>>[
    <String, String>{},
    <String, String>{'PATH': '/usr/bin'},
  ]) {
    final legacy = TaskExecutionRuntimeRecord.fromJson(<String, Object?>{
      ...manual.toJson(),
      'redactedEnvironment': environment,
      'futureRecordField': 'retained',
    });
    _expect(
      legacy.inheritsHostEnvironment == null &&
          !legacy.copyWith().toJson().containsKey('inheritsHostEnvironment') &&
          legacy.toJson()['futureRecordField'] == 'retained',
      'legacy environment contents do not invent inheritance intent',
    );
  }
  _expect(
    manual
            .copyWith(inheritsHostEnvironment: true)
            .copyWith(inheritsHostEnvironment: false)
            .inheritsHostEnvironment ==
        false,
    'copyWith can set either known environment intent',
  );
}

void _expect(bool condition, String label) {
  if (!condition) {
    throw StateError('task_execution_runtime_test failed: $label');
  }
}
