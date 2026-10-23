import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';

void main() {
  for (final fixture in <_DesktopExecutionFixture>[
    _DesktopExecutionFixture(
      name: 'Linux',
      processFacts: ProcessFacts.linuxDebianArm(),
      shellFacts: ShellFacts.linuxDebianArm(defaultShellPath: '/bin/sh'),
      expectedShell: '/bin/sh',
      expectedCommandFlag: '-c',
    ),
    _DesktopExecutionFixture(
      name: 'Windows',
      processFacts: ProcessFacts.windowsX64(),
      shellFacts: ShellFacts.windowsX64(defaultShellPath: 'powershell.exe'),
      expectedShell: 'powershell.exe',
      expectedCommandFlag: '-Command',
    ),
  ]) {
    test(
      '${fixture.name} execution and shell routes preserve live identity and cancellation',
      () async {
        final manager = _HermeticProcessManager(fixture.processFacts);
        final executionManager = ExecutionManager(processManager: manager);
        final executionStarted = Completer<ProcessCommandHandle>();

        final execution = await executionManager.run(
          ExecutionRequest(
            executablePath: 'runtime-tool',
            arguments: const <String>['run'],
            onProcessStarted: executionStarted.complete,
          ),
        );
        final executionHandle = await executionStarted.future;

        expect(execution.succeeded, isTrue);
        expect(
          execution.processResult.metadata['processHandleId'],
          executionHandle.processHandleId,
        );
        expect(execution.processResult.metadata['pid'], executionHandle.pid);

        final shellManager = LocalShellManager(
          facts: fixture.shellFacts,
          processManager: manager,
        );
        final shellStarted = Completer<ProcessCommandHandle>();
        final shellResult = await shellManager.run(
          ShellCommandRequest(
            command: 'echo',
            arguments: const <String>['desktop-ok'],
            loginShell: false,
            onStarted: shellStarted.complete,
          ),
        );
        final shellHandle = await shellStarted.future;
        final cancellation = await shellManager.cancelProcess(
          shellHandle.processHandleId,
        );

        expect(shellResult.succeeded, isTrue);
        expect(shellResult.executablePath, fixture.expectedShell);
        expect(shellResult.arguments, contains(fixture.expectedCommandFlag));
        expect(
          shellResult.metadata['processHandleId'],
          shellHandle.processHandleId,
        );
        expect(shellResult.metadata['pid'], shellHandle.pid);
        expect(cancellation.accepted, isTrue);
        expect(cancellation.processTerminated, isTrue);
        expect(manager.cancelledHandles, <String>[shellHandle.processHandleId]);
      },
    );
  }
}

class _DesktopExecutionFixture {
  const _DesktopExecutionFixture({
    required this.name,
    required this.processFacts,
    required this.shellFacts,
    required this.expectedShell,
    required this.expectedCommandFlag,
  });

  final String name;
  final ProcessFacts processFacts;
  final ShellFacts shellFacts;
  final String expectedShell;
  final String expectedCommandFlag;
}

class _HermeticProcessManager
    implements ProcessManager, CancellableProcessManager {
  _HermeticProcessManager(this.facts)
    : compatibility = ProcessAdapter(facts).adapt();

  @override
  final ProcessFacts facts;

  @override
  final ProcessCompatibility compatibility;

  final List<String> cancelledHandles = <String>[];
  var _sequence = 0;

  @override
  Future<ProcessCommandResult> run(ProcessCommandRequest request) async {
    _sequence += 1;
    final handle = ProcessCommandHandle(
      processHandleId: '${facts.operatingSystem}-process-$_sequence',
      sourceManager: 'hermetic-${facts.operatingSystem}',
      pid: 7000 + _sequence,
    );
    request.onStarted?.call(handle);
    return ProcessCommandResult(
      status: ProcessCommandStatus.succeeded,
      executablePath: request.executablePath,
      arguments: request.arguments,
      exitCode: 0,
      stdout: 'desktop-ok',
      stderr: '',
      duration: const Duration(milliseconds: 1),
      metadata: handle.toMetadata(),
    );
  }

  @override
  Future<ProcessCommandCancellationResult> cancelProcess(
    String processHandleId,
  ) async {
    cancelledHandles.add(processHandleId);
    return ProcessCommandCancellationResult(
      accepted: true,
      processTerminated: true,
      message: 'Hermetic process terminated.',
      metadata: <String, Object?>{'processHandleId': processHandleId},
    );
  }

  @override
  ProcessOperationFailure? failureFor(
    ProcessCommandResult result, {
    String operation = 'process.spawn',
    String? recoveryHint,
  }) => null;
}
