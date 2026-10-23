import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/debugger/debug_adapter_launcher.dart';
import 'package:vityo_app/src/view_ide/debugger/debug_adapter_process_transport_io.dart';
import 'package:vityo_app/src/view_ide/debugger/debug_launch_contract.dart';
import 'package:vityo_app/src/view_ide/toolchain/toolchain_catalog.dart';

void main() {
  for (final fixture in <_DesktopDebugFixture>[
    const _DesktopDebugFixture(
      name: 'Linux Python',
      debuggerId: 'python-dap',
      debuggerLabel: 'Python Debug Adapter',
      debuggerExecutable: '/usr/bin/debugpy-adapter',
      workspaceRoot: '/workspace/demo',
      relativeProgram: 'src/main.py',
      expectedProgram: '/workspace/demo/src/main.py',
      languages: <String>['python'],
      pid: 7101,
    ),
    const _DesktopDebugFixture(
      name: 'Windows JavaScript',
      debuggerId: 'javascript-dap',
      debuggerLabel: 'JavaScript Debug Adapter',
      debuggerExecutable: r'C:\Tools\js-debug.exe',
      workspaceRoot: r'C:\workspace\demo',
      relativeProgram: r'src\main.js',
      expectedProgram: r'C:\workspace\demo\src\main.js',
      languages: <String>['javascript', 'typescript'],
      pid: 7201,
    ),
  ]) {
    test(
      '${fixture.name} routes a language-neutral DAP launch through real process identity and force termination contracts',
      () async {
        final launch = DebugLaunchConfiguration.fromToolchainDescriptor(
          debugger: ToolchainDescriptor(
            id: fixture.debuggerId,
            kind: ToolchainKind.debugger,
            displayName: fixture.debuggerLabel,
            executablePath: fixture.debuggerExecutable,
            metadata: <String, Object?>{
              'adapterProtocol': 'dap',
              'programPath': fixture.relativeProgram,
              'languages': fixture.languages,
            },
          ),
          workspaceRoot: fixture.workspaceRoot,
          breakpoints: <DebugLaunchBreakpoint>[
            DebugLaunchBreakpoint(filePath: fixture.expectedProgram, line: 0),
          ],
        );
        final process = _HermeticDapProcess(
          handleId: '${fixture.debuggerId}-process',
          pid: fixture.pid,
        );
        final transport = DapProcessTransport(
          executable: fixture.debuggerExecutable,
          processStarter: (_) async => process,
        );
        await transport.start();
        final handle = await DapDebugAdapterLauncher(
          transportFactory: (_) async => transport,
        ).launch(launch);

        expect(launch.ready, isTrue);
        expect(launch.programPath, fixture.expectedProgram);
        expect(handle.processHandle?.pid, fixture.pid);
        expect(handle.processHandle?.processHandleId, process.processHandleId);
        expect(handle.launchPlan.requests[1].command, 'setBreakpoints');

        final termination = await const DebugSessionTerminationExecutor()
            .execute(
              handle: handle,
              plan: handle.terminationPlan(force: true),
              reason: 'Desktop matrix force stop.',
            );

        expect(
          termination.status,
          DebugSessionTerminationExecutionStatus.executed,
        );
        expect(
          termination.plan.action,
          DebugSessionTerminationAction.killProcess,
        );
        expect(termination.processResult?.processTerminated, isTrue);
        expect(termination.processResult?.metadata['processId'], fixture.pid);
        expect(process.terminateCalls, 1);
      },
    );
  }
}

class _DesktopDebugFixture {
  const _DesktopDebugFixture({
    required this.name,
    required this.debuggerId,
    required this.debuggerLabel,
    required this.debuggerExecutable,
    required this.workspaceRoot,
    required this.relativeProgram,
    required this.expectedProgram,
    required this.languages,
    required this.pid,
  });

  final String name;
  final String debuggerId;
  final String debuggerLabel;
  final String debuggerExecutable;
  final String workspaceRoot;
  final String relativeProgram;
  final String expectedProgram;
  final List<String> languages;
  final int pid;
}

class _HermeticDapProcess implements DapManagedProcess {
  _HermeticDapProcess({required this.handleId, required this.pid});

  final String handleId;
  final Completer<int> _exitCode = Completer<int>();
  int terminateCalls = 0;

  @override
  String get processHandleId => handleId;

  @override
  final int pid;

  @override
  Stream<List<int>> get stdoutBytes => const Stream<List<int>>.empty();

  @override
  Stream<List<int>> get stderrBytes => const Stream<List<int>>.empty();

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void write(List<int> bytes) {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> closeInput() async {}

  @override
  bool terminate() {
    terminateCalls += 1;
    if (!_exitCode.isCompleted) {
      _exitCode.complete(0);
    }
    return true;
  }

  @override
  bool kill() => terminate();
}
