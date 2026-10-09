import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';

void main() {
  for (final family in <ShellFamily>[
    ShellFamily.bash,
    ShellFamily.sh,
    ShellFamily.zsh,
    ShellFamily.fish,
    ShellFamily.powershell,
    ShellFamily.cmd,
  ]) {
    test('shell live probe uses the $family adapter entrypoint', () async {
      final process = _RecordingProcessManager();
      final shell = LocalShellManager(
        facts: _facts(family),
        processManager: process,
      );

      final health = await _probe(shell);

      expect(health.ready, isTrue, reason: health.message);
      expect(health.managerKey, 'shell');
      expect(health.operationId, 'platform.shell.live-operation');
      expect(health.recoveryActions, isEmpty);
      final request = process.requests.single;
      expect(request.executablePath, '/selected/${family.name}');
      expect(request.arguments, switch (family) {
        ShellFamily.powershell => <String>[
          '-NoLogo',
          '-NoProfile',
          '-Command',
          'exit 0',
        ],
        ShellFamily.cmd => <String>['/C', 'exit 0'],
        _ => <String>['-c', 'exit 0'],
      });
      expect(request.environment, isNull);
    });
  }

  test('shell live probe honors the manager selected default', () async {
    final process = _RecordingProcessManager();
    final shell = LocalShellManager(
      facts: ShellFacts.windowsX64(
        defaultShellPath: '/selected/cmd',
        availableShells: const <ShellExecutableFact>[
          ShellExecutableFact(
            path: '/available/pwsh',
            family: ShellFamily.powershell,
          ),
          ShellExecutableFact(path: '/selected/cmd', family: ShellFamily.cmd),
        ],
      ),
      processManager: process,
    );

    expect((await _probe(shell)).ready, isTrue);
    expect(process.requests.single.executablePath, '/selected/cmd');
    expect(process.requests.single.arguments, <String>['/C', 'exit 0']);
  });

  test('missing shell stays blocked without starting a process', () async {
    final process = _RecordingProcessManager();
    final health = await _probe(
      LocalShellManager(
        facts: ShellFacts.linuxDebianArm(
          availableShells: const <ShellExecutableFact>[],
        ),
        processManager: process,
      ),
    );

    expect(health.ready, isFalse);
    expect(health.metadata['status'], 'blocked');
    expect(health.message, contains('No executable shell'));
    expect(health.recoveryActions.single.managerKey, 'shell');
    expect(process.requests, isEmpty);
  });

  test('unsupported shell manager stays blocked', () async {
    final health = await _probe(
      UnsupportedShellManager(facts: _facts(ShellFamily.sh)),
    );

    expect(health.ready, isFalse);
    expect(health.metadata['status'], 'blocked');
    expect(health.message, contains('not available'));
    expect(health.recoveryActions.single.managerKey, 'shell');
  });

  for (final (status, exitCode) in <(ProcessCommandStatus, int?)>[
    (ProcessCommandStatus.failed, 7),
    (ProcessCommandStatus.failed, null),
    (ProcessCommandStatus.timedOut, null),
    (ProcessCommandStatus.blocked, null),
  ]) {
    test('shell live probe preserves $status / $exitCode failure', () async {
      final process = _RecordingProcessManager(
        status: status,
        exitCode: exitCode,
      );
      final health = await _probe(
        LocalShellManager(
          facts: _facts(ShellFamily.powershell),
          processManager: process,
        ),
      );

      expect(health.ready, isFalse);
      expect(health.metadata['status'], status.name);
      expect(health.metadata['exitCode'], exitCode);
      expect(health.message, 'Controlled process result');
      expect(health.recoveryActions.single.managerKey, 'shell');
      expect(process.requests, hasLength(1));
    });
  }

  for (final status in <ProcessCommandStatus>[
    ProcessCommandStatus.succeeded,
    ProcessCommandStatus.failed,
  ]) {
    test('unknown shell adapter fallback retains its $status result', () async {
      final process = _RecordingProcessManager(
        status: status,
        exitCode: status == ProcessCommandStatus.succeeded ? 0 : 1,
      );
      final health = await _probe(
        LocalShellManager(
          facts: _facts(ShellFamily.unknown),
          processManager: process,
        ),
      );

      expect(health.ready, status == ProcessCommandStatus.succeeded);
      expect(health.metadata['status'], status.name);
      expect(process.requests.single.arguments, <String>['-c', 'exit 0']);
    });
  }
}

ShellFacts _facts(ShellFamily family) => ShellFacts.linuxDebianArm(
  defaultShellPath: '/selected/${family.name}',
  availableShells: <ShellExecutableFact>[
    ShellExecutableFact(
      path: '/selected/${family.name}',
      family: family,
      isDefault: true,
    ),
  ],
);

Future<PlatformManagerComponentHealth> _probe(ShellManager shell) =>
    PlatformManagerLiveOperationProbeRegistry.defaults().registrations
        .singleWhere((registration) => registration.managerKey == 'shell')
        .run(_ShellOnlyBundle(shell));

/// Other bundle facts must not replace the selected manager's shell policy.
class _ShellOnlyBundle implements PlatformManagerBundle {
  _ShellOnlyBundle(this.shell);

  @override
  final ShellManager shell;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected bundle access: ${invocation.memberName}');
}

class _RecordingProcessManager implements ProcessManager {
  _RecordingProcessManager({
    this.status = ProcessCommandStatus.succeeded,
    this.exitCode = 0,
  });

  final ProcessCommandStatus status;
  final int? exitCode;
  final List<ProcessCommandRequest> requests = <ProcessCommandRequest>[];

  @override
  Future<ProcessCommandResult> run(ProcessCommandRequest request) async {
    requests.add(request);
    return ProcessCommandResult(
      status: status,
      executablePath: request.executablePath,
      arguments: request.arguments,
      exitCode: exitCode,
      stdout: '',
      stderr: '',
      duration: Duration.zero,
      message: 'Controlled process result',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected process access: ${invocation.memberName}');
}
