import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/debugger/debug_adapter_launcher.dart';
import 'package:vityo_app/src/view_ide/debugger/debug_adapter_process_transport_io.dart';
import 'package:vityo_app/src/view_ide/debugger/debug_launch_contract.dart';
import 'package:vityo_app/src/view_ide/environment/configuration/forwarded_host_environment.dart';
import 'package:vityo_app/src/view_ide/toolchain/toolchain_catalog.dart';

import 'support/vityod_test_harness.dart';

void main() {
  VityodTestHarness? vityod;

  setUpAll(() async {
    if (!VityodTestHarness.isSupported) return;
    vityod = await VityodTestHarness.start(clientId: 'dap-transport-test');
  });

  tearDownAll(() => vityod?.close());

  test(
    'DAP byte transport streams through the real daemon process owner',
    () async {
      final transport = DapProcessTransport(
        executable: await _nativeDartExecutable(),
        arguments: <String>[
          '--disable-dart-dev',
          File('test/support/dap_byte_echo.dart').absolute.path,
        ],
        environment: forwardedHostEnvironment(),
        client: vityod!.client,
      );
      addTearDown(transport.shutdown);
      await transport.start();
      expect(transport.processHandle?.processHandleId, startsWith('dap-'));
      expect(transport.processHandle?.pid, greaterThan(0));
      expect(transport.processHandle?.source, 'vityod-dap');
      const payload = <int>[100, 97, 112, 45, 111, 107, 10, 0, 13, 128, 255];
      final payloadReceived = Completer<void>();
      var receivedLength = 0;
      final echoed = transport.incomingBytes.expand((chunk) {
        receivedLength += chunk.length;
        if (receivedLength >= payload.length && !payloadReceived.isCompleted) {
          payloadReceived.complete();
        }
        return chunk;
      }).toList();
      await transport.send(payload);

      await payloadReceived.future.timeout(const Duration(seconds: 5));
      final shutdown = await transport.shutdown().timeout(
        const Duration(seconds: 5),
      );
      expect(await echoed.timeout(const Duration(seconds: 5)), payload);
      expect(shutdown.processTerminated, isTrue);
    },
    skip: !VityodTestHarness.isSupported
        ? 'Desktop vityod transport only.'
        : false,
  );

  test('DAP process shutdown escalates from terminate to kill', () async {
    final process = _FakeManagedProcess(exitOnKill: true);
    final transport = DapProcessTransport(
      executable: 'fixture-debugger',
      processStarter: (_) async => process,
      terminateGrace: Duration.zero,
      killGrace: const Duration(seconds: 1),
    );
    await transport.start();

    expect(transport.processHandle?.processHandleId, 'fixture-dap-4242');

    final result = await transport.shutdown();

    expect(result.status, DapProcessShutdownStatus.exitedAfterKill);
    expect(result.processTerminated, isTrue);
    expect(result.orphanDetected, isFalse);
    expect(result.exitCode, -1);
    expect(process.terminateCalls, 1);
    expect(process.killCalls, 1);
    expect(process.closeInputCalls, 1);
    expect(transport.lastShutdownResult, same(result));
  });

  test('DAP process shutdown reports an orphan after bounded kill', () async {
    final process = _FakeManagedProcess();
    final transport = DapProcessTransport(
      executable: 'fixture-debugger',
      processStarter: (_) async => process,
      terminateGrace: Duration.zero,
      killGrace: Duration.zero,
    );
    await transport.start();

    final result = await transport.shutdown();

    expect(result.status, DapProcessShutdownStatus.orphaned);
    expect(result.processTerminated, isFalse);
    expect(result.orphanDetected, isTrue);
    expect(result.toJson()['orphanDetected'], isTrue);
    expect(process.killCalls, 1);
  });

  test('DAP process shutdown is idempotent for concurrent callers', () async {
    final process = _FakeManagedProcess(exitOnTerminate: true);
    final transport = DapProcessTransport(
      executable: 'fixture-debugger',
      processStarter: (_) async => process,
    );
    await transport.start();

    final results = await Future.wait(<Future<DapProcessShutdownResult>>[
      transport.shutdown(),
      transport.shutdown(),
    ]);

    expect(results[1], same(results[0]));
    expect(results.first.status, DapProcessShutdownStatus.exitedAfterTerminate);
    expect(process.terminateCalls, 1);
    expect(process.killCalls, 0);
  });

  test(
    'production termination executor force-stops its DAP transport',
    () async {
      final process = _FakeManagedProcess(exitOnTerminate: true);
      final transport = DapProcessTransport(
        executable: 'fixture-debugger',
        processStarter: (_) async => process,
      );
      await transport.start();
      final launcher = DapDebugAdapterLauncher(
        transportFactory: (_) async => transport,
      );
      final handle = await launcher.launch(_readyLaunch());

      final result = await const DebugSessionTerminationExecutor().execute(
        handle: handle,
        plan: handle.terminationPlan(force: true),
        reason: 'Force stop fixture.',
      );

      expect(result.status, DebugSessionTerminationExecutionStatus.executed);
      expect(result.plan.action, DebugSessionTerminationAction.killProcess);
      expect(result.processResult?.processTerminated, isTrue);
      expect(result.processResult?.metadata['processId'], 4242);
      expect(result.processResult?.metadata['forceRequested'], isTrue);
      expect(process.terminateCalls, 1);
    },
  );
}

Future<String> _nativeDartExecutable() async {
  final name = Platform.isWindows ? 'dart.exe' : 'dart';
  final current = File(
    await File(Platform.resolvedExecutable).resolveSymbolicLinks(),
  );
  if (current.uri.pathSegments.last == name) return current.path;
  // flutter_tester lives inside this same installed SDK's engine cache.
  var directory = current.parent;
  for (var depth = 0; depth < 8; depth++) {
    final candidate = File('${directory.path}/bin/cache/dart-sdk/bin/$name');
    if (await candidate.exists()) return candidate.absolute.path;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  throw StateError(
    'Native Dart binary in the installed Flutter SDK is required',
  );
}

final class _FakeManagedProcess implements DapManagedProcess {
  _FakeManagedProcess({this.exitOnTerminate = false, this.exitOnKill = false});

  final bool exitOnTerminate;
  final bool exitOnKill;
  final Completer<int> _exit = Completer<int>();
  int terminateCalls = 0;
  int killCalls = 0;
  int closeInputCalls = 0;

  @override
  String get processHandleId => 'fixture-dap-4242';
  @override
  int get pid => 4242;
  @override
  Stream<List<int>> get stdoutBytes => const Stream<List<int>>.empty();
  @override
  Stream<List<int>> get stderrBytes => const Stream<List<int>>.empty();
  @override
  Future<int> get exitCode => _exit.future;
  @override
  void write(List<int> bytes) {}
  @override
  Future<void> flush() async {}
  @override
  Future<void> closeInput() async {
    closeInputCalls += 1;
  }

  @override
  bool terminate() {
    terminateCalls += 1;
    if (exitOnTerminate && !_exit.isCompleted) {
      _exit.complete(0);
    }
    return true;
  }

  @override
  bool kill() {
    killCalls += 1;
    if (exitOnKill && !_exit.isCompleted) {
      _exit.complete(-1);
    }
    return true;
  }
}

DebugLaunchConfiguration _readyLaunch() {
  return DebugLaunchConfiguration.fromToolchainDescriptor(
    debugger: const ToolchainDescriptor(
      id: 'python-dap',
      kind: ToolchainKind.debugger,
      displayName: 'Python Debug Adapter',
      executablePath: '/debug/debugpy-adapter',
      metadata: <String, Object?>{
        'adapterProtocol': 'dap',
        'programPath': 'main.py',
        'languages': <String>['python'],
      },
    ),
    workspaceRoot: '/workspace/demo',
  );
}
