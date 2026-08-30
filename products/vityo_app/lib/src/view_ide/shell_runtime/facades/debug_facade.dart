// ignore_for_file: annotate_overrides

part of '../shell_runtime_model.dart';

/// Public debugger facade backed by the debug domain controller.
mixin ShellRuntimeDebugFacade on ShellRuntimeFacadeHost {
  DebugSessionSnapshot get debugSession => _debugController.session;
  DebugRuntimeExecutionResult? get lastDebugRuntimeExecutionResult =>
      _debugController.lastRuntimeExecutionResult;
  List<DebugBreakpoint> get debugBreakpoints => _debugController.breakpoints;
  DebugLaunchConfigurationSet get debugLaunchConfigurations =>
      _debugController.launchConfigurations;

  DebugCommandResult toggleBreakpointAtSelection() {
    final position = editorController.document.positionForOffset(
      editorController.selection.extentOffset,
    );
    return _debugController.toggleBreakpointAt(
      filePath: _activeDocumentPath,
      line: position.line,
    );
  }

  Future<DebugCommandResult> startDebugging() =>
      _debugController.startConfiguredSession();

  Future<DebugCommandResult> stopDebugging() =>
      _debugController.stopConfiguredSession();

  Future<DebugCommandResult> forceStopDebugging() =>
      _debugController.forceStopConfiguredSession();

  Future<DebugCommandResult> saveDebugBreakpoint({
    DebugBreakpoint? previous,
    required String filePath,
    required int line,
    required bool enabled,
  }) => _debugController.saveBreakpoint(
    previous: previous,
    filePath: filePath,
    line: line,
    enabled: enabled,
  );

  Future<DebugCommandResult> removeDebugBreakpoint(
    DebugBreakpoint breakpoint,
  ) => _debugController.removeBreakpoint(breakpoint);

  Future<DebugCommandResult> setDebugBreakpointEnabled(
    DebugBreakpoint breakpoint,
    bool enabled,
  ) => _debugController.setBreakpointEnabled(breakpoint, enabled);

  Future<DebugCommandResult> selectDebugLaunchProfile(String profileId) =>
      _debugController.selectLaunchProfile(profileId);

  Future<DebugCommandResult> updateDebugLaunchConfiguration({
    required String programPath,
    required String cwd,
    required List<String> arguments,
    required bool stopOnEntry,
  }) => _debugController.updateSelectedLaunchConfiguration(
    programPath: programPath,
    cwd: cwd,
    arguments: arguments,
    stopOnEntry: stopOnEntry,
  );

  bool refreshDebugAdapterSession() =>
      _debugController.refreshConfiguredSession();

  Future<DebugCommandResult> continueDebugging() =>
      _debugController.continueConfiguredSession();

  Future<DebugCommandResult> stepOver() =>
      _debugController.stepOverConfiguredSession();

  Future<DebugCommandResult> selectDebugStackFrame(String frameId) =>
      _debugController.selectConfiguredStackFrame(frameId);

  Future<DebugCommandResult> selectDebugThread(String threadId) =>
      _debugController.selectConfiguredThread(threadId);
}
