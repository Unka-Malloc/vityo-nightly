import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vityo_app/src/ide/local_service/vityod_client.dart';
import 'package:vityo_app/src/view_ide/environment/configuration/host_environment.dart';
import 'package:vityo_app/src/view_ide/environment/configuration/shell_configuration.dart';
import 'package:vityo_app/src/view_ide/environment/execution/execution_manager.dart';
import 'package:vityo_app/src/view_ide/environment/execution/execution_sandbox.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_facts.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_manager.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_manager_io.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/shell/shell_facts.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/shell/shell_manager.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/shell/shell_manager_io.dart';
import 'package:vityo_daemon_protocol/vityo_daemon_protocol.dart';

void main() {
  tearDown(() => debugOverrideHostEnvironment(null));

  group('environment ownership', () {
    const safeHost = <String, String>{
      'PATH': '/fixture/bin',
      'HOME': '/fixture/home',
    };
    setUp(
      () => debugOverrideHostEnvironment(<String, String>{
        ...safeHost,
        'TOKEN': 'synthetic-fixture',
      }),
    );

    for (final environment in <Map<String, String>?>[
      null,
      const <String, String>{},
      const <String, String>{'PATH': ''},
      const <String, String>{'ONLY': 'explicit'},
    ]) {
      test(
        'process preserves omitted versus supplied environment $environment',
        () async {
          final fixture = await _Fixture.start();
          await fixture.manager.run(
            ProcessCommandRequest(
              executablePath: '/fixture/compiler',
              environment: environment,
            ),
          );
          expect(_launchedEnvironment(fixture), environment ?? safeHost);
        },
      );
    }

    test('const omitted and explicitly empty requests remain distinct', () {
      const omitted = ProcessCommandRequest(
        executablePath: '/fixture/compiler',
      );
      const isolated = ProcessCommandRequest(
        executablePath: '/fixture/compiler',
        environment: <String, String>{},
      );
      expect(omitted.environment, isNull);
      expect(isolated.environment, isEmpty);
    });

    for (final environment in <Map<String, String>?>[
      null,
      const <String, String>{},
      const <String, String>{'ONLY': 'explicit'},
    ]) {
      test('default shell preserves environment intent $environment', () async {
        final fixture = await _Fixture.start();
        final shell = LocalShellManager(
          facts: ShellFacts.linuxDebianArm(defaultShellPath: '/fixture/shell'),
          processManager: fixture.manager,
        );
        await shell.run(
          ShellCommandRequest(command: ':', environment: environment),
        );
        expect(_launchedEnvironment(fixture), environment ?? safeHost);
      });
    }

    test(
      'configured empty shell environment never inherits host values',
      () async {
        final fixture = await _Fixture.start();
        final shell = LocalShellManager(
          facts: ShellFacts.linuxDebianArm(defaultShellPath: '/fixture/shell'),
          processManager: fixture.manager,
        );
        await shell.run(
          const ShellCommandRequest(command: ':'),
          configuration: const ShellConfiguration(
            defaultProfileId: 'none',
            profiles: [],
          ),
        );
        expect(_launchedEnvironment(fixture), isEmpty);
      },
    );

    test(
      'sandbox-approved empty environment stays empty at daemon boundary',
      () async {
        final fixture = await _Fixture.start();
        final execution = ExecutionManager(
          processManager: fixture.manager,
          executionSandbox: const ExecutionSandbox(
            policy: ExecutionSandboxPolicy(
              workspaceRoot: '/fixture',
              trustState: WorkspaceTrustState.trusted,
            ),
          ),
        );
        final result = await execution.run(
          const ExecutionRequest(
            executablePath: '/fixture/compiler',
            workingDirectory: '/fixture',
          ),
        );
        expect(result.succeeded, isTrue);
        expect(result.redactedEnvironment, isEmpty);
        expect(_launchedEnvironment(fixture), isEmpty);
      },
    );

    test('explicit empty shell profile never inherits host values', () async {
      final fixture = await _Fixture.start();
      final shell = LocalShellManager(
        facts: ShellFacts.linuxDebianArm(defaultShellPath: '/fixture/shell'),
        processManager: fixture.manager,
      );
      await shell.run(
        const ShellCommandRequest(
          command: ':',
          profile: ShellProfileConfiguration(
            id: 'explicit',
            executablePath: '/fixture/shell',
            family: ShellFamily.sh,
          ),
        ),
      );
      expect(_launchedEnvironment(fixture), isEmpty);
    });
  });

  for (final service in ProcessServiceKind.values) {
    for (final receipt in <({int exitCode, bool timedOut})>[
      (exitCode: 0, timedOut: false),
      (exitCode: 7, timedOut: false),
      (exitCode: 1, timedOut: true),
    ]) {
      test('${service.name} preserves receipt when close is rejected: '
          '${receipt.exitCode}/${receipt.timedOut}', () async {
        final fixture = await _Fixture.start(
          exitCode: receipt.exitCode,
          timedOut: receipt.timedOut,
          close: _CloseReply.rejected,
        );
        final result = await fixture.run(service);

        _expectReceipt(result, receipt.exitCode, receipt.timedOut);
        expect(result.metadata['cleanup'], <String, Object?>{
          'operation': 'process.close',
          'sourceManager': 'vityod',
          'status': 'failed',
          'errorCode': 'task_still_running',
          'retryable': false,
        });
        expect(
          fixture.manager.failureFor(result)?.kind,
          receipt.timedOut
              ? ProcessFailureKind.timedOut
              : receipt.exitCode == 0
              ? null
              : ProcessFailureKind.nonZeroExit,
        );
        final close = fixture.transport.requests.last;
        expect(
          close.method,
          service == ProcessServiceKind.generic
              ? 'task.close'
              : '${service.name}.request',
        );
        if (service != ProcessServiceKind.generic) {
          expect(close.params['action'], 'close');
        }
        expect(fixture.transport.closeCount, 1);
      });
    }
  }

  test('successful acknowledgement confirms cleanup independently', () async {
    final fixture = await _Fixture.start(close: _CloseReply.closed);
    final result = await fixture.run();
    _expectReceipt(result, 0, false);
    expect(result.metadata['cleanup'], <String, Object?>{
      'operation': 'process.close',
      'sourceManager': 'vityod',
      'status': 'succeeded',
    });
    expect(result.toJson()['metadata'], result.metadata);
  });

  for (final close in <_CloseReply>[
    _CloseReply.timeout,
    _CloseReply.transportFailure,
    _CloseReply.malformed,
  ]) {
    test(
      '${close.name} leaves cleanup unconfirmed and retains receipt',
      () async {
        final fixture = await _Fixture.start(close: close);
        final result = await fixture.run();
        _expectReceipt(result, 0, false);
        final cleanup = result.metadata['cleanup']! as Map<String, Object?>;
        expect(cleanup['status'], 'unconfirmed');
        expect(cleanup['errorCode'], switch (close) {
          _CloseReply.timeout => 'task_close_timeout',
          _CloseReply.transportFailure => 'task_close_unconfirmed',
          _ => 'invalid_task_close_receipt',
        });
        expect(result.toJson().toString(), isNot(contains('fixture-secret')));
        expect(fixture.transport.closeCount, 1);
      },
    );
  }

  test(
    'malformed error code is replaced without copying error context',
    () async {
      final fixture = await _Fixture.start(close: _CloseReply.unsafeError);
      final result = await fixture.run();
      _expectReceipt(result, 0, false);
      final cleanup = result.metadata['cleanup']! as Map<String, Object?>;
      expect(cleanup['status'], 'failed');
      expect(cleanup['errorCode'], 'task_close_failed');
      expect(cleanup.containsKey('retryable'), isFalse);
      expect(result.toJson().toString(), isNot(contains('fixture-secret')));
    },
  );

  test(
    'start failure remains a process failure without a cleanup receipt',
    () async {
      final fixture = await _Fixture.start(failStart: true);
      final result = await fixture.run();
      expect(result.status, ProcessCommandStatus.failed);
      expect(result.exitCode, isNull);
      expect(result.stdout, isEmpty);
      expect(result.stderr, isEmpty);
      expect(result.metadata.containsKey('cleanup'), isFalse);
      expect(fixture.transport.closeCount, 0);
      expect(
        fixture.manager.failureFor(result)?.kind,
        ProcessFailureKind.spawnFailed,
      );
    },
  );

  test(
    'invalid output is not promoted to a completed process receipt',
    () async {
      final fixture = await _Fixture.start(invalidOutput: true);
      final result = await fixture.run();
      expect(result.status, ProcessCommandStatus.failed);
      expect(result.exitCode, isNull);
      expect(result.metadata.containsKey('cleanup'), isFalse);
      expect(fixture.transport.closeCount, 0);
    },
  );
}

Object? _launchedEnvironment(_Fixture fixture) => fixture.transport.requests
    .firstWhere(
      (request) =>
          request.method == 'task.start' || request.params['action'] == 'start',
    )
    .params['environment'];

void _expectReceipt(ProcessCommandResult result, int exitCode, bool timedOut) {
  expect(
    result.status,
    timedOut
        ? ProcessCommandStatus.timedOut
        : exitCode == 0
        ? ProcessCommandStatus.succeeded
        : ProcessCommandStatus.failed,
  );
  expect(result.exitCode, exitCode);
  expect(result.stdout, 'build summary\n');
  expect(result.stderr, 'compiler E123\n');
  expect(result.duration, const Duration(milliseconds: 17));
  expect(result.message, timedOut ? 'Process timed out inside vityod.' : null);
  expect(result.executablePath, '/fixture/compiler');
  expect(result.arguments, <String>['build']);
  expect(result.metadata['processHandleId'], isNotEmpty);
  expect(result.metadata['processHandleSource'], 'vityod');
  expect(result.metadata['pid'], 4321);
  expect(result.metadata['stdoutTruncated'], isTrue);
  expect(result.metadata['stderrTruncated'], isTrue);
}

enum _CloseReply {
  closed,
  rejected,
  timeout,
  transportFailure,
  malformed,
  unsafeError,
}

class _Fixture {
  _Fixture(this.transport, this.manager);

  final _ProcessTransport transport;
  final LocalProcessManager manager;

  static Future<_Fixture> start({
    int exitCode = 0,
    bool timedOut = false,
    _CloseReply close = _CloseReply.closed,
    bool failStart = false,
    bool invalidOutput = false,
  }) async {
    final transport = _ProcessTransport(
      exitCode: exitCode,
      timedOut: timedOut,
      closeReply: close,
      failStart: failStart,
      invalidOutput: invalidOutput,
    );
    final client = VityodClient(
      transport: transport,
      clientInstanceId: 'receipt-test',
    );
    addTearDown(client.dispose);
    await client.connect();
    return _Fixture(
      transport,
      LocalProcessManager(facts: ProcessFacts.linuxDebianArm(), client: client),
    );
  }

  Future<ProcessCommandResult> run([
    ProcessServiceKind service = ProcessServiceKind.generic,
  ]) => manager.run(
    ProcessCommandRequest(
      executablePath: '/fixture/compiler',
      arguments: const <String>['build'],
      environment: const <String, String>{'VITYO_TEST': 'receipt'},
      serviceKind: service,
    ),
  );
}

class _ProcessTransport implements VityodTransport {
  _ProcessTransport({
    required this.exitCode,
    required this.timedOut,
    required this.closeReply,
    required this.failStart,
    required this.invalidOutput,
  });

  final int exitCode;
  final bool timedOut;
  final _CloseReply closeReply;
  final bool failStart;
  final bool invalidOutput;
  final memory = MemoryVityodTransport();
  final requests = <VityodControlEnvelope>[];
  int closeCount = 0;

  @override
  Stream<Uint8List> get incomingControl => memory.incomingControl;
  @override
  Stream<VityodBinaryFrame> get incomingBinary => memory.incomingBinary;
  @override
  Future<String> connect() => memory.connect();
  @override
  Future<void> sendBinary(VityodBinaryFrame frame) => memory.sendBinary(frame);
  @override
  Future<void> close() => memory.close();
  @override
  Future<void> dispose() => memory.dispose();

  @override
  Future<void> sendControl(Uint8List bytes) async {
    await memory.sendControl(bytes);
    final request = VityodControlCodec.decode(bytes);
    requests.add(request);
    final action = request.params['action'] ?? request.method.split('.').last;
    if (action == 'start') {
      _respond(
        request,
        failStart
            ? <String, Object?>{'errorCode': 'task_start_failed'}
            : <String, Object?>{'state': 'running', 'pid': 4321},
        error: failStart,
      );
    } else if (action == 'output') {
      _respond(request, <String, Object?>{
        'running': false,
        'timedOut': timedOut,
        'exitCode': invalidOutput ? null : exitCode,
        'stdout': 'build summary\n',
        'stderr': 'compiler E123\n',
        'durationMillis': 17,
        'stdoutTruncated': true,
        'stderrTruncated': true,
      });
    } else if (action == 'close') {
      closeCount += 1;
      switch (closeReply) {
        case _CloseReply.closed:
          _respond(request, <String, Object?>{'state': 'closed'});
        case _CloseReply.rejected:
          _respond(request, <String, Object?>{
            'errorCode': 'task_still_running',
            'retryable': false,
          }, error: true);
        case _CloseReply.timeout:
          throw TimeoutException('fixture-secret');
        case _CloseReply.transportFailure:
          throw StateError('fixture-secret');
        case _CloseReply.malformed:
          _respond(request, <String, Object?>{'state': 'running'});
        case _CloseReply.unsafeError:
          _respond(request, <String, Object?>{
            'errorCode': 'token=fixture-secret',
            'retryable': 'fixture-secret',
            'context': <String, Object?>{'secret': 'fixture-secret'},
          }, error: true);
      }
    }
  }

  void _respond(
    VityodControlEnvelope request,
    Map<String, Object?> params, {
    bool error = false,
  }) {
    memory.receiveControl(
      VityodControlCodec.encode(
        VityodControlEnvelope(
          method: '${request.method}.${error ? 'error' : 'result'}',
          requestId: request.requestId,
          clientInstanceId: 'receipt-daemon',
          idempotencyKey: request.idempotencyKey,
          deadlineUnixMillis: request.deadlineUnixMillis,
          params: params,
        ),
      ),
    );
  }
}
