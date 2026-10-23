import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_render/platform/viewport_profile.dart';
import 'package:vityo_app/src/view_render/runtime/debug_console_surface.dart';
import 'package:vityo_app/src/view_ide/debugger/debug_adapter_launcher.dart';
import 'package:vityo_app/src/view_ide/debugger/debug_launch_contract.dart';
import 'package:vityo_app/src/view_ide/debugger/debug_launch_telemetry_store.dart';
import 'package:vityo_app/src/view_ide/runtime/runtime.dart'
    hide DebugSessionSnapshot, DebugSessionStatus;
import 'package:vityo_app/src/view_ide/shell_runtime/controllers/debug_controller.dart';
import 'package:vityo_app/src/view_ide/toolchain/toolchain_catalog.dart';

void main() {
  testWidgets('debug console renders launch plan and telemetry summaries', (
    tester,
  ) async {
    final plan = DapDebugAdapterExecutionPlan.fromConfiguration(
      profileId: 'debug-styio',
      launchConfiguration: DebugLaunchConfiguration.fromToolchainDescriptor(
        debugger: const ToolchainDescriptor(
          id: 'lldb-dap',
          kind: ToolchainKind.debugger,
          displayName: 'LLDB DAP',
          executablePath: '/usr/bin/lldb-dap',
          metadata: <String, Object?>{
            'adapterProtocol': 'dap',
            'programPath': 'build/vityo',
          },
        ),
        workspaceRoot: '/workspace/vityo',
      ),
    );
    final telemetry = DebugLaunchTelemetrySnapshot(
      workspaceId: 'demo',
      records: <DebugLaunchTelemetryRecord>[
        DebugLaunchTelemetryRecord.fromExecutionPlan(
          workspaceId: 'demo',
          plan: plan,
          status: DebugLaunchTelemetryStatus.planned,
          timestamp: DateTime.utc(2026, 5, 20, 16),
        ),
      ],
    );
    final buffer = RuntimeOutputLiveBuffer();
    final dispatch = RuntimeExecutionManagerRegistry.defaultManagers()
        .dispatchToLiveBuffer(
          plan.outputBinding,
          buffer: buffer,
          timestamp: DateTime.utc(2026, 5, 20, 16, 1),
          metadata: const <String, Object?>{
            'debugRuntimeExecution': 'dap-launcher',
          },
        );
    final execution = DebugRuntimeExecutionResult(
      plan: plan,
      status: DebugRuntimeExecutionStatus.failed,
      telemetry: telemetry,
      outputEvents: const <RuntimeOutputEvent>[],
      dispatchResult: dispatch,
    );
    var retried = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 760,
            child: DebugConsoleSurface(
              viewportProfile: const ViewportProfile(
                family: ViewportFamily.desktop,
                width: 1200,
                height: 760,
              ),
              entries: const <String>[],
              runtimeEvents: const [],
              debugLaunchPlan: plan,
              debugTelemetry: telemetry,
              debugRuntimeExecution: execution,
              onRetryDebugLaunch: () async {
                retried = true;
              },
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('debug-launch-plan-section')),
      findsOneWidget,
    );
    expect(find.text('Debug Launch Plan'), findsOneWidget);
    expect(find.text('profile debug-styio'), findsOneWidget);
    expect(find.text('plan ready'), findsOneWidget);
    expect(find.text('ready true'), findsOneWidget);
    expect(find.text('route ready'), findsOneWidget);
    expect(find.text('telemetry 1'), findsOneWidget);
    expect(find.text('successful 0'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('debug-launch-plan-message')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('debug-launch-plan-adapter')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('debug-launch-plan-output')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('debug-launch-telemetry-latest')),
      findsOneWidget,
    );
    expect(find.text('execution failed'), findsOneWidget);
    expect(find.text('dispatch dispatched'), findsOneWidget);
    expect(find.text('output 0'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('debug-runtime-execution-message')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('debug-runtime-execution-output')),
      findsOneWidget,
    );
    final retryButton = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('debug-runtime-retry-launch')),
    );
    retryButton.onPressed!();
    await tester.pump();
    expect(retried, isTrue);
  });

  testWidgets(
    'debug console selects non-C++ adapters and edits launch and breakpoint state',
    (tester) async {
      var configurations = DebugLaunchConfigurationSet(
        workspaceId: 'demo',
        selectedProfileId: 'lldb-dap',
        profiles: <DebugLaunchProfile>[
          _profile(
            id: 'lldb-dap',
            label: 'LLDB DAP',
            executable: '/usr/bin/lldb-dap',
            languages: const <String>['c', 'cpp'],
          ),
          _profile(
            id: 'python-dap',
            label: 'Python Debug Adapter',
            executable: '/usr/bin/debugpy-adapter',
            languages: const <String>['python'],
          ),
        ],
      );
      var breakpoints = <DebugBreakpoint>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              height: 900,
              child: StatefulBuilder(
                builder: (context, setState) => DebugConsoleSurface(
                  viewportProfile: const ViewportProfile(
                    family: ViewportFamily.desktop,
                    width: 1200,
                    height: 900,
                  ),
                  entries: const <String>[],
                  runtimeEvents: const [],
                  debugSession: DebugSessionSnapshot(
                    status: DebugSessionStatus.idle,
                    message: 'Ready to debug.',
                    breakpoints: breakpoints,
                  ),
                  debugLaunchConfigurations: configurations,
                  onSelectLaunchProfile: (profileId) async {
                    setState(() {
                      configurations = configurations.selectProfile(profileId);
                    });
                    return const DebugCommandResult(
                      applied: true,
                      message: 'Adapter selected.',
                    );
                  },
                  onUpdateLaunchConfiguration:
                      ({
                        required programPath,
                        required cwd,
                        required arguments,
                        required stopOnEntry,
                      }) async {
                        final selected = configurations.selectedProfile!;
                        setState(() {
                          configurations = configurations.upsertProfile(
                            selected.copyWith(
                              configuration: selected.configuration.reconfigure(
                                programPath: programPath,
                                cwd: cwd,
                                arguments: arguments,
                                stopOnEntry: stopOnEntry,
                              ),
                            ),
                          );
                        });
                        return const DebugCommandResult(
                          applied: true,
                          message: 'Launch saved.',
                        );
                      },
                  onSaveBreakpoint:
                      ({
                        previous,
                        required filePath,
                        required line,
                        required enabled,
                      }) async {
                        setState(() {
                          breakpoints = <DebugBreakpoint>[
                            for (final breakpoint in breakpoints)
                              if (breakpoint.key != previous?.key) breakpoint,
                            DebugBreakpoint(
                              filePath: filePath,
                              line: line,
                              enabled: enabled,
                            ),
                          ];
                        });
                        return const DebugCommandResult(
                          applied: true,
                          message: 'Breakpoint saved.',
                        );
                      },
                  onRemoveBreakpoint: (breakpoint) async {
                    setState(() {
                      breakpoints = breakpoints
                          .where((candidate) => candidate.key != breakpoint.key)
                          .toList(growable: false);
                    });
                    return const DebugCommandResult(
                      applied: true,
                      message: 'Breakpoint removed.',
                    );
                  },
                  onSetBreakpointEnabled: (breakpoint, enabled) async {
                    setState(() {
                      breakpoints = breakpoints
                          .map(
                            (candidate) => candidate.key == breakpoint.key
                                ? candidate.copyWith(enabled: enabled)
                                : candidate,
                          )
                          .toList(growable: false);
                    });
                    return const DebugCommandResult(
                      applied: true,
                      message: 'Breakpoint updated.',
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final selector = find.byKey(const ValueKey('debug-adapter-selector'));
      await tester.ensureVisible(selector);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Python Debug Adapter').last);
      await tester.pumpAndSettle();
      expect(configurations.selectedProfileId, 'python-dap');

      final configure = find.byKey(
        const ValueKey('debug-edit-launch-configuration'),
      );
      await tester.ensureVisible(configure);
      await tester.tap(configure);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('debug-launch-program-field')),
        '/workspace/demo/main.py',
      );
      await tester.enterText(
        find.byKey(const ValueKey('debug-launch-cwd-field')),
        '/workspace/demo',
      );
      await tester.enterText(
        find.byKey(const ValueKey('debug-launch-arguments-field')),
        '--inspect\nvalue with spaces',
      );
      await tester.tap(find.byKey(const ValueKey('debug-launch-save')));
      await tester.pumpAndSettle();
      expect(configurations.selectedProfile?.configuration.arguments, <String>[
        '--inspect',
        'value with spaces',
      ]);
      expect(find.textContaining('/workspace/demo/main.py'), findsOneWidget);

      final addBreakpoint = find.byKey(const ValueKey('debug-add-breakpoint'));
      await tester.ensureVisible(addBreakpoint);
      await tester.tap(addBreakpoint);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('debug-breakpoint-path-field')),
        '/workspace/demo/main.py',
      );
      await tester.enterText(
        find.byKey(const ValueKey('debug-breakpoint-line-field')),
        '1',
      );
      await tester.tap(find.byKey(const ValueKey('debug-breakpoint-save')));
      await tester.pumpAndSettle();

      expect(breakpoints.single.line, 0);
      expect(find.text('/workspace/demo/main.py:1'), findsOneWidget);
      await tester.tap(
        find.byKey(
          const ValueKey('debug-breakpoint-enabled-/workspace/demo/main.py:0'),
        ),
      );
      await tester.pumpAndSettle();
      expect(breakpoints.single.enabled, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

DebugLaunchProfile _profile({
  required String id,
  required String label,
  required String executable,
  required List<String> languages,
}) {
  return DebugLaunchProfile.fromConfiguration(
    id: id,
    displayName: label,
    configuration: DebugLaunchConfiguration(
      readiness: DebugLaunchReadiness.missingProgram,
      reason: 'Select a program.',
      debuggerId: id,
      debuggerLabel: label,
      debuggerExecutablePath: executable,
      adapterProtocol: 'dap',
      programPath: null,
      cwd: '/workspace/demo',
    ),
    metadata: <String, Object?>{'languages': languages},
  );
}
