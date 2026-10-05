import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../debugger/debug_breakpoint_store.dart';
import '../../debugger/debug_launch_contract.dart';
import '../../debugger/debug_launch_telemetry_store.dart';
import '../../debugger/debug_runtime_task_history.dart';
import '../../runtime/runtime_task_history_store.dart';
import '../../runtime/runtime_output_channels.dart';
import '../../toolchain/toolchain_catalog.dart';
import '../../toolchain/toolchain_manager.dart';
import '../../debugger/debug_adapter_protocol.dart';
import '../../debugger/debug_adapter_launcher.dart';
import '../../debugger/debug_adapter_session.dart';

enum DebugSessionStatus {
  idle,
  blocked,
  configured,
  launching,
  running,
  paused,
  stopped,
}

class DebugBreakpoint {
  const DebugBreakpoint({
    required this.filePath,
    required this.line,
    this.enabled = true,
  });

  final String filePath;
  final int line;
  final bool enabled;

  String get key => '$filePath:$line';

  DebugBreakpoint copyWith({String? filePath, int? line, bool? enabled}) {
    return DebugBreakpoint(
      filePath: filePath ?? this.filePath,
      line: line ?? this.line,
      enabled: enabled ?? this.enabled,
    );
  }
}

class DebugStackFrame {
  const DebugStackFrame({
    required this.id,
    required this.name,
    required this.filePath,
    required this.line,
    required this.column,
  });

  final String id;
  final String name;
  final String filePath;
  final int line;
  final int column;
}

class DebugThread {
  const DebugThread({required this.id, required this.name});

  final String id;
  final String name;
}

class DebugVariable {
  const DebugVariable({required this.name, required this.value, this.type});

  final String name;
  final String value;
  final String? type;
}

class DebugSessionSnapshot {
  const DebugSessionSnapshot({
    required this.status,
    required this.message,
    this.debuggerId,
    this.debuggerLabel,
    this.breakpoints = const <DebugBreakpoint>[],
    this.threads = const <DebugThread>[],
    this.stackFrames = const <DebugStackFrame>[],
    this.variables = const <DebugVariable>[],
    this.launchConfiguration,
    this.adapterSessionStatus,
    this.adapterPendingRequestCount = 0,
    this.adapterEventCount = 0,
  });

  final DebugSessionStatus status;
  final String message;
  final String? debuggerId;
  final String? debuggerLabel;
  final List<DebugBreakpoint> breakpoints;
  final List<DebugThread> threads;
  final List<DebugStackFrame> stackFrames;
  final List<DebugVariable> variables;
  final DebugLaunchConfiguration? launchConfiguration;
  final String? adapterSessionStatus;
  final int adapterPendingRequestCount;
  final int adapterEventCount;

  bool get hasConfiguredDebugger => debuggerId != null;
}

class DebugCommandResult {
  const DebugCommandResult({required this.applied, required this.message});

  final bool applied;
  final String message;
}

/// Owns debugger presentation state independently from shell composition.
final class DebugController extends ChangeNotifier {
  DebugController();

  DebugController.configured({
    required ToolchainManager? toolchainManager,
    required String Function() workspaceRoot,
    required DapDebugAdapterLauncher? launcher,
    required RuntimeOutputLiveBuffer runtimeOutputBuffer,
    required DebugRuntimeTaskHistoryBinder runtimeTaskHistoryBinder,
    required RuntimeTaskHistoryStore? runtimeTaskHistoryStore,
    required String runtimeTaskHistoryWorkspaceId,
    required int runtimeTaskHistoryMaxEntries,
    required void Function(String message) log,
    String Function()? workspaceId,
    DebugBreakpointStore? breakpointStore,
    DebugLaunchConfigurationStore? launchConfigurationStore,
    Iterable<DebugLaunchProfile> initialLaunchProfiles =
        const <DebugLaunchProfile>[],
  }) : _configuredToolchainManager = toolchainManager,
       _configuredWorkspaceRoot = workspaceRoot,
       _configuredWorkspaceId = workspaceId ?? workspaceRoot,
       _configuredLauncher = launcher,
       _configuredRuntimeOutputBuffer = runtimeOutputBuffer,
       _configuredRuntimeTaskHistoryBinder = runtimeTaskHistoryBinder,
       _configuredRuntimeTaskHistoryStore = runtimeTaskHistoryStore,
       _configuredRuntimeTaskHistoryWorkspaceId = runtimeTaskHistoryWorkspaceId,
       _configuredRuntimeTaskHistoryMaxEntries = runtimeTaskHistoryMaxEntries,
       _breakpointStore = breakpointStore,
       _launchConfigurationStore = launchConfigurationStore,
       _initialLaunchProfiles = List<DebugLaunchProfile>.unmodifiable(
         initialLaunchProfiles,
       ),
       _configuredLog = log;

  ToolchainManager? _configuredToolchainManager;
  String Function()? _configuredWorkspaceRoot;
  String Function()? _configuredWorkspaceId;
  DapDebugAdapterLauncher? _configuredLauncher;
  RuntimeOutputLiveBuffer? _configuredRuntimeOutputBuffer;
  DebugRuntimeTaskHistoryBinder? _configuredRuntimeTaskHistoryBinder;
  RuntimeTaskHistoryStore? _configuredRuntimeTaskHistoryStore;
  String? _configuredRuntimeTaskHistoryWorkspaceId;
  int? _configuredRuntimeTaskHistoryMaxEntries;
  void Function(String message)? _configuredLog;
  DebugBreakpointStore? _breakpointStore;
  DebugLaunchConfigurationStore? _launchConfigurationStore;
  List<DebugLaunchProfile> _initialLaunchProfiles =
      const <DebugLaunchProfile>[];

  final List<DebugBreakpoint> _breakpoints = <DebugBreakpoint>[];
  final List<DebugBreakpoint> _pendingBreakpointToggles = <DebugBreakpoint>[];
  DebugSessionSnapshot _session = const DebugSessionSnapshot(
    status: DebugSessionStatus.idle,
    message: 'No debug session has been started.',
  );
  DebugRuntimeExecutionResult? _lastRuntimeExecutionResult;
  DebugRuntimeExecutionAdapter? _runtimeExecutionAdapter;
  DapDebugSessionHandle? _sessionHandle;
  StreamSubscription<DapSessionSnapshot>? _sessionSubscription;
  final StreamController<DapSessionSnapshot> _dapSnapshotEvents =
      StreamController<DapSessionSnapshot>.broadcast(sync: true);
  bool _inspectionRequestInFlight = false;
  Future<void> _runtimeTaskHistoryAppendQueue = Future<void>.value();
  Future<void> _breakpointPersistenceQueue = Future<void>.value();
  Future<void> _launchConfigurationPersistenceQueue = Future<void>.value();
  Future<void>? _workspaceStateLoad;
  String? _loadingWorkspaceId;
  String? _loadedWorkspaceId;
  DebugLaunchConfigurationSet _launchConfigurations =
      const DebugLaunchConfigurationSet(workspaceId: '');

  DebugSessionSnapshot get session => _session;
  List<DebugBreakpoint> get breakpoints =>
      List<DebugBreakpoint>.unmodifiable(_breakpoints);
  DebugRuntimeExecutionResult? get lastRuntimeExecutionResult =>
      _lastRuntimeExecutionResult;
  DapDebugSessionHandle? get sessionHandle => _sessionHandle;

  /// Every DAP session snapshot the attached adapter publishes, across session
  /// restarts. Runtime output binds this instead of polling the handle.
  Stream<DapSessionSnapshot> get dapSnapshotEvents => _dapSnapshotEvents.stream;
  DebugLaunchConfigurationSet get launchConfigurations => _launchConfigurations;
  DebugLaunchProfile? get selectedLaunchProfile =>
      _launchConfigurations.selectedProfile;

  Future<void> loadConfiguredState({bool force = false}) {
    final workspaceRoot = _configuredWorkspaceRoot;
    final workspaceId = _configuredWorkspaceId;
    if (workspaceRoot == null || workspaceId == null) {
      return Future<void>.value();
    }
    return _ensureWorkspaceState(
      workspaceId: workspaceId(),
      workspaceRoot: workspaceRoot(),
      toolchainManager: _configuredToolchainManager,
      force: force,
    );
  }

  Future<void> _ensureWorkspaceState({
    required String workspaceId,
    required String workspaceRoot,
    required ToolchainManager? toolchainManager,
    bool force = false,
  }) {
    final normalizedId = workspaceId.trim().isEmpty
        ? workspaceRoot
        : workspaceId.trim();
    if (!force && _loadedWorkspaceId == normalizedId) {
      return Future<void>.value();
    }
    final loading = _workspaceStateLoad;
    if (!force && loading != null && _loadingWorkspaceId == normalizedId) {
      return loading;
    }
    _loadingWorkspaceId = normalizedId;
    late final Future<void> future;
    future =
        _loadWorkspaceState(
          workspaceId: normalizedId,
          workspaceRoot: workspaceRoot,
          toolchainManager: toolchainManager,
        ).whenComplete(() {
          if (identical(_workspaceStateLoad, future)) {
            _workspaceStateLoad = null;
            _loadingWorkspaceId = null;
          }
        });
    _workspaceStateLoad = future;
    return future;
  }

  Future<void> _loadWorkspaceState({
    required String workspaceId,
    required String workspaceRoot,
    required ToolchainManager? toolchainManager,
  }) async {
    DebugBreakpointSet storedBreakpoints = DebugBreakpointSet(
      workspaceId: workspaceId,
    );
    final breakpointStore = _breakpointStore;
    if (breakpointStore != null) {
      try {
        storedBreakpoints = await breakpointStore.readBreakpointSet(
          workspaceId: workspaceId,
        );
      } on Object catch (error) {
        _configuredLog?.call('Debug breakpoints could not be loaded: $error');
      }
    }

    DebugLaunchConfigurationSet storedConfigurations =
        DebugLaunchConfigurationSet(workspaceId: workspaceId);
    final launchStore = _launchConfigurationStore;
    if (launchStore != null) {
      try {
        storedConfigurations = await launchStore.loadConfigurationSet(
          workspaceId: workspaceId,
        );
      } on Object catch (error) {
        _configuredLog?.call(
          'Debug launch configurations could not be loaded: $error',
        );
      }
    }

    ToolchainCatalog? toolchainCatalog;
    if (toolchainManager != null) {
      try {
        toolchainCatalog = await toolchainManager.loadCatalog();
      } on Object catch (error) {
        _configuredLog?.call('Debug adapters could not be loaded: $error');
      }
    }
    final activeDebuggerId = toolchainCatalog
        ?.active(ToolchainKind.debugger)
        ?.id;
    final profilesById = <String, DebugLaunchProfile>{};
    for (final debugger
        in toolchainCatalog?.list(kind: ToolchainKind.debugger) ??
            const <ToolchainDescriptor>[]) {
      profilesById[debugger.id] = DebugLaunchProfile.fromConfiguration(
        id: debugger.id,
        displayName: debugger.displayName,
        isDefault: debugger.id == activeDebuggerId,
        configuration: DebugLaunchConfiguration.fromToolchainDescriptor(
          debugger: debugger,
          workspaceRoot: workspaceRoot,
        ),
        metadata: <String, Object?>{
          ...debugger.metadata,
          'source': 'toolchain-catalog',
        },
      );
    }
    for (final profile in _initialLaunchProfiles) {
      profilesById[profile.id] = profile;
    }
    for (final profile in storedConfigurations.profiles) {
      profilesById[profile.id] = profile;
    }
    final profiles = profilesById.values.toList(growable: false)
      ..sort((left, right) => left.displayName.compareTo(right.displayName));
    var selectedProfileId = storedConfigurations.selectedProfileId;
    if (selectedProfileId == null ||
        !profilesById.containsKey(selectedProfileId)) {
      selectedProfileId = profilesById.containsKey(activeDebuggerId)
          ? activeDebuggerId
          : _firstDefaultProfileId(profiles) ??
                (profiles.isEmpty ? null : profiles.first.id);
    }
    _launchConfigurations = DebugLaunchConfigurationSet(
      workspaceId: workspaceId,
      selectedProfileId: selectedProfileId,
      profiles: List<DebugLaunchProfile>.unmodifiable(profiles),
      updatedAt: storedConfigurations.updatedAt,
    );

    if (breakpointStore != null) {
      _breakpoints
        ..clear()
        ..addAll(
          storedBreakpoints.breakpoints.map(
            (breakpoint) => DebugBreakpoint(
              filePath: breakpoint.filePath,
              line: breakpoint.line,
              enabled: breakpoint.enabled,
            ),
          ),
        );
      for (final pending in _pendingBreakpointToggles) {
        final index = _breakpoints.indexWhere(
          (breakpoint) => breakpoint.key == pending.key,
        );
        if (index < 0) {
          _breakpoints.add(pending);
        } else {
          _breakpoints.removeAt(index);
        }
      }
    } else if (_loadedWorkspaceId != null &&
        _loadedWorkspaceId != workspaceId) {
      _breakpoints.clear();
    }
    _sortBreakpoints();
    _loadedWorkspaceId = workspaceId;
    final persistPendingBreakpoints = _pendingBreakpointToggles.isNotEmpty;
    _pendingBreakpointToggles.clear();
    refreshSessionBreakpoints();
    notifyListeners();
    if (persistPendingBreakpoints) {
      unawaited(_persistBreakpoints());
    }
  }

  Future<DebugCommandResult> saveBreakpoint({
    DebugBreakpoint? previous,
    required String filePath,
    required int line,
    required bool enabled,
  }) async {
    await loadConfiguredState();
    final normalizedPath = filePath.trim();
    if (normalizedPath.isEmpty || line < 0) {
      return const DebugCommandResult(
        applied: false,
        message: 'Breakpoint requires a file path and a positive line number.',
      );
    }
    if (previous != null) {
      _breakpoints.removeWhere((breakpoint) => breakpoint.key == previous.key);
    }
    final replacement = DebugBreakpoint(
      filePath: normalizedPath,
      line: line,
      enabled: enabled,
    );
    final index = _breakpoints.indexWhere(
      (breakpoint) => breakpoint.key == replacement.key,
    );
    if (index < 0) {
      _breakpoints.add(replacement);
    } else {
      _breakpoints[index] = replacement;
    }
    _sortBreakpoints();
    refreshSessionBreakpoints();
    notifyListeners();
    await _persistBreakpoints();
    final message =
        'Saved breakpoint at $normalizedPath:${line + 1}${enabled ? '' : ' (disabled)'}.';
    _configuredLog?.call(message);
    return DebugCommandResult(applied: true, message: message);
  }

  Future<DebugCommandResult> removeBreakpoint(
    DebugBreakpoint breakpoint,
  ) async {
    final removed = _breakpoints.any(
      (candidate) => candidate.key == breakpoint.key,
    );
    if (!removed) {
      return const DebugCommandResult(
        applied: false,
        message: 'Breakpoint was already removed.',
      );
    }
    _breakpoints.removeWhere((candidate) => candidate.key == breakpoint.key);
    refreshSessionBreakpoints();
    notifyListeners();
    await _persistBreakpoints();
    final message =
        'Removed breakpoint at ${breakpoint.filePath}:${breakpoint.line + 1}.';
    _configuredLog?.call(message);
    return DebugCommandResult(applied: true, message: message);
  }

  Future<DebugCommandResult> setBreakpointEnabled(
    DebugBreakpoint breakpoint,
    bool enabled,
  ) async {
    final index = _breakpoints.indexWhere(
      (candidate) => candidate.key == breakpoint.key,
    );
    if (index < 0) {
      return const DebugCommandResult(
        applied: false,
        message: 'Breakpoint was not found.',
      );
    }
    _breakpoints[index] = _breakpoints[index].copyWith(enabled: enabled);
    refreshSessionBreakpoints();
    notifyListeners();
    await _persistBreakpoints();
    final message =
        '${enabled ? 'Enabled' : 'Disabled'} breakpoint at ${breakpoint.filePath}:${breakpoint.line + 1}.';
    _configuredLog?.call(message);
    return DebugCommandResult(applied: true, message: message);
  }

  Future<DebugCommandResult> selectLaunchProfile(String profileId) async {
    await loadConfiguredState();
    if (!_launchConfigurations.profiles.any(
      (profile) => profile.id == profileId,
    )) {
      return DebugCommandResult(
        applied: false,
        message: 'Debug adapter $profileId is not available.',
      );
    }
    _launchConfigurations = _launchConfigurations.selectProfile(profileId);
    notifyListeners();
    await _persistLaunchConfigurations();
    final profile = _launchConfigurations.selectedProfile!;
    final message = 'Selected debug adapter ${profile.displayName}.';
    _configuredLog?.call(message);
    return DebugCommandResult(applied: true, message: message);
  }

  Future<DebugCommandResult> updateSelectedLaunchConfiguration({
    required String programPath,
    required String cwd,
    required List<String> arguments,
    required bool stopOnEntry,
  }) async {
    await loadConfiguredState();
    final profile = _launchConfigurations.selectedProfile;
    if (profile == null) {
      return const DebugCommandResult(
        applied: false,
        message: 'No debug adapter is selected.',
      );
    }
    final configuration = profile.configuration.reconfigure(
      programPath: programPath,
      clearProgramPath: programPath.trim().isEmpty,
      cwd: cwd.trim().isEmpty ? (_configuredWorkspaceRoot?.call() ?? '') : cwd,
      arguments: arguments,
      stopOnEntry: stopOnEntry,
    );
    _launchConfigurations = _launchConfigurations.upsertProfile(
      profile.copyWith(configuration: configuration),
    );
    notifyListeners();
    await _persistLaunchConfigurations();
    final message = configuration.ready
        ? 'Saved launch configuration ${profile.displayName}.'
        : configuration.reason;
    _configuredLog?.call(message);
    return DebugCommandResult(applied: configuration.ready, message: message);
  }

  DebugCommandResult toggleBreakpointAt({
    required String filePath,
    required int line,
  }) {
    final breakpoint = DebugBreakpoint(filePath: filePath, line: line);
    final added = toggleBreakpoint(breakpoint);
    final message =
        '${added ? 'Added' : 'Removed'} breakpoint at ${breakpoint.filePath}:${breakpoint.line + 1}.';
    _configuredLog?.call(message);
    return DebugCommandResult(applied: true, message: message);
  }

  Future<DebugCommandResult> startConfiguredSession() async {
    final workspaceRoot = _configuredWorkspaceRoot;
    final runtimeOutputBuffer = _configuredRuntimeOutputBuffer;
    if (workspaceRoot == null || runtimeOutputBuffer == null) {
      final result = _applyCommandSnapshot(
        const DebugSessionSnapshot(
          status: DebugSessionStatus.blocked,
          message: 'Start Debugging blocked: debug runtime is not configured.',
        ),
      );
      _configuredLog?.call(result.message);
      return result;
    }
    final result = await startSession(
      toolchainManager: _configuredToolchainManager,
      workspaceId: _configuredWorkspaceId?.call(),
      workspaceRoot: workspaceRoot(),
      launcher: _configuredLauncher,
      runtimeOutputBuffer: runtimeOutputBuffer,
      onSnapshot: _handleConfiguredDapSnapshot,
    );
    _configuredLog?.call(result.message);
    return result;
  }

  Future<DebugCommandResult> stopConfiguredSession() async {
    final result = await stopSession();
    _configuredLog?.call(result.message);
    return result;
  }

  Future<DebugCommandResult> forceStopConfiguredSession() async {
    final result = await stopSession(force: true);
    _configuredLog?.call(result.message);
    return result;
  }

  Future<DebugCommandResult> continueConfiguredSession() async {
    final result = await continueSession();
    _configuredLog?.call(result.message);
    return result;
  }

  Future<DebugCommandResult> stepOverConfiguredSession() async {
    final result = await stepOverSession();
    _configuredLog?.call(result.message);
    return result;
  }

  Future<DebugCommandResult> selectConfiguredStackFrame(String frameId) async {
    final result = await selectStackFrame(frameId);
    _configuredLog?.call(result.message);
    return result;
  }

  Future<DebugCommandResult> selectConfiguredThread(String threadId) async {
    final result = await selectThread(threadId);
    _configuredLog?.call(result.message);
    return result;
  }

  bool refreshConfiguredSession() {
    if (refreshAttachedSession()) {
      return true;
    }
    _configuredLog?.call(
      'Debug adapter refresh skipped: no DAP session is active.',
    );
    notifyListeners();
    return false;
  }

  Future<void> attachSession(
    DapDebugSessionHandle handle, {
    required void Function(DapSessionSnapshot snapshot) onSnapshot,
  }) async {
    final previousHandle = _sessionHandle;
    await _sessionSubscription?.cancel();
    _sessionHandle = handle;
    _sessionSubscription = handle.snapshotEvents.listen((snapshot) {
      if (!_dapSnapshotEvents.isClosed) {
        _dapSnapshotEvents.add(snapshot);
      }
      onSnapshot(snapshot);
    });
    if (previousHandle != null && !identical(previousHandle, handle)) {
      unawaited(previousHandle.close());
    }
  }

  Future<DapDebugSessionHandle?> detachSession() async {
    final handle = _sessionHandle;
    _sessionHandle = null;
    _inspectionRequestInFlight = false;
    final subscription = _sessionSubscription;
    _sessionSubscription = null;
    await subscription?.cancel();
    return handle;
  }

  DapDebugSessionHandle? detachTerminatedSession() {
    final handle = _sessionHandle;
    _sessionHandle = null;
    _inspectionRequestInFlight = false;
    final subscription = _sessionSubscription;
    _sessionSubscription = null;
    unawaited(subscription?.cancel());
    return handle;
  }

  bool refreshAttachedSession() {
    final handle = _sessionHandle;
    if (handle == null) {
      return false;
    }
    final snapshot = handle.snapshot;
    syncFromDapSnapshot(
      snapshot,
      message: 'Debug adapter session refreshed: ${snapshot.status.name}.',
    );
    return true;
  }

  void requestPausedInspection(
    DapSessionSnapshot snapshot, {
    required void Function(String message) onError,
  }) {
    if (_inspectionRequestInFlight) {
      return;
    }
    final handle = _sessionHandle;
    if (handle == null) {
      return;
    }
    final request = nextInspectionRequest(
      snapshot,
      reserveSeq: handle.bridge.session.reserveSeq,
    );
    if (request == null) {
      return;
    }
    _inspectionRequestInFlight = true;
    unawaited(
      (() async {
        try {
          await handle.sendRequest(request);
        } on Object catch (error) {
          onError('DAP inspection request failed: $error');
        } finally {
          _inspectionRequestInFlight = false;
        }
      })(),
    );
  }

  void _handleConfiguredDapSnapshot(DapSessionSnapshot snapshot) {
    syncFromDapSnapshot(
      snapshot,
      message: 'Debug adapter session updated: ${snapshot.status.name}.',
    );
    final binder = _configuredRuntimeTaskHistoryBinder;
    final workspaceId = _configuredRuntimeTaskHistoryWorkspaceId;
    final maxEntries = _configuredRuntimeTaskHistoryMaxEntries;
    if (binder != null && workspaceId != null && maxEntries != null) {
      queueRuntimeTaskHistoryAppend(
        snapshot,
        binder: binder,
        store: _configuredRuntimeTaskHistoryStore,
        workspaceId: workspaceId,
        maxEntries: maxEntries,
      );
    }
    if (snapshot.status == DapSessionStatus.terminated ||
        snapshot.status == DapSessionStatus.failed) {
      final handle = detachTerminatedSession();
      if (handle != null) {
        unawaited(handle.close());
      }
      return;
    }
    requestPausedInspection(
      snapshot,
      onError: (message) {
        _configuredLog?.call(message);
        notifyListeners();
      },
    );
  }

  void queueRuntimeTaskHistoryAppend(
    DapSessionSnapshot snapshot, {
    required DebugRuntimeTaskHistoryBinder binder,
    required RuntimeTaskHistoryStore? store,
    required String workspaceId,
    required int maxEntries,
  }) {
    final launch = _session.launchConfiguration;
    if (store == null || launch == null) {
      return;
    }
    _runtimeTaskHistoryAppendQueue = _runtimeTaskHistoryAppendQueue.then((
      _,
    ) async {
      try {
        await binder.appendSnapshot(
          store: store,
          workspaceId: workspaceId,
          launch: launch,
          adapterSnapshot: snapshot,
          taskId: 'debug.${launch.debuggerId}',
          maxEntries: maxEntries,
        );
      } on Object {
        // Persistence failure must not interrupt the live debug session.
      }
    });
    unawaited(_runtimeTaskHistoryAppendQueue);
  }

  bool toggleBreakpoint(DebugBreakpoint breakpoint) {
    if (_breakpointStore != null && _loadedWorkspaceId == null) {
      _pendingBreakpointToggles.add(breakpoint);
    }
    final existingIndex = _breakpoints.indexWhere(
      (candidate) => candidate.key == breakpoint.key,
    );
    final added = existingIndex < 0;
    if (added) {
      _breakpoints.add(breakpoint);
    } else {
      _breakpoints.removeAt(existingIndex);
    }
    _sortBreakpoints();
    refreshSessionBreakpoints();
    notifyListeners();
    unawaited(_persistBreakpoints());
    return added;
  }

  void _sortBreakpoints() {
    _breakpoints.sort((left, right) {
      final pathOrder = left.filePath.compareTo(right.filePath);
      return pathOrder == 0 ? left.line.compareTo(right.line) : pathOrder;
    });
  }

  String? _firstDefaultProfileId(List<DebugLaunchProfile> profiles) {
    for (final profile in profiles) {
      if (profile.isDefault) {
        return profile.id;
      }
    }
    return null;
  }

  Future<void> _persistBreakpoints() {
    final store = _breakpointStore;
    final workspaceId = _loadedWorkspaceId ?? _configuredWorkspaceId?.call();
    if (store == null || workspaceId == null || workspaceId.trim().isEmpty) {
      return Future<void>.value();
    }
    final snapshot = DebugBreakpointSet(
      workspaceId: workspaceId,
      breakpoints: _breakpoints
          .map(
            (breakpoint) => DebugLaunchBreakpoint(
              filePath: breakpoint.filePath,
              line: breakpoint.line,
              enabled: breakpoint.enabled,
            ),
          )
          .toList(growable: false),
    );
    final previous = _breakpointPersistenceQueue;
    _breakpointPersistenceQueue = () async {
      await previous;
      try {
        await store.saveBreakpointSet(snapshot);
      } on Object catch (error) {
        _configuredLog?.call('Debug breakpoints could not be saved: $error');
      }
    }();
    return _breakpointPersistenceQueue;
  }

  Future<void> _persistLaunchConfigurations() {
    final store = _launchConfigurationStore;
    if (store == null || _launchConfigurations.workspaceId.trim().isEmpty) {
      return Future<void>.value();
    }
    final snapshot = _launchConfigurations;
    final previous = _launchConfigurationPersistenceQueue;
    _launchConfigurationPersistenceQueue = () async {
      await previous;
      try {
        await store.saveConfigurationSet(snapshot);
      } on Object catch (error) {
        _configuredLog?.call(
          'Debug launch configurations could not be saved: $error',
        );
      }
    }();
    return _launchConfigurationPersistenceQueue;
  }

  void replaceSession(DebugSessionSnapshot snapshot) {
    _session = DebugSessionSnapshot(
      status: snapshot.status,
      message: snapshot.message,
      debuggerId: snapshot.debuggerId,
      debuggerLabel: snapshot.debuggerLabel,
      breakpoints: List<DebugBreakpoint>.unmodifiable(snapshot.breakpoints),
      threads: List<DebugThread>.unmodifiable(snapshot.threads),
      stackFrames: List<DebugStackFrame>.unmodifiable(snapshot.stackFrames),
      variables: List<DebugVariable>.unmodifiable(snapshot.variables),
      launchConfiguration: snapshot.launchConfiguration,
      adapterSessionStatus: snapshot.adapterSessionStatus,
      adapterPendingRequestCount: snapshot.adapterPendingRequestCount,
      adapterEventCount: snapshot.adapterEventCount,
    );
    notifyListeners();
  }

  void refreshSessionBreakpoints() {
    _session = DebugSessionSnapshot(
      status: _session.status,
      message: _session.message,
      debuggerId: _session.debuggerId,
      debuggerLabel: _session.debuggerLabel,
      breakpoints: breakpoints,
      threads: _session.threads,
      stackFrames: _session.stackFrames,
      variables: _session.variables,
      launchConfiguration: _session.launchConfiguration,
      adapterSessionStatus: _session.adapterSessionStatus,
      adapterPendingRequestCount: _session.adapterPendingRequestCount,
      adapterEventCount: _session.adapterEventCount,
    );
  }

  DapRequest? nextInspectionRequest(
    DapSessionSnapshot snapshot, {
    required int Function() reserveSeq,
  }) {
    if (snapshot.status != DapSessionStatus.paused) {
      return null;
    }
    const requestFactory = DapProtocolRequestFactory();
    if (snapshot.stackFrames.isEmpty) {
      final threadId =
          snapshot.activeThreadId ??
          _firstInspectableThreadId(snapshot.threads);
      if (threadId == null) {
        if (_hasPendingDapCommand(snapshot, 'threads')) {
          return null;
        }
        return requestFactory.threads(seq: reserveSeq());
      }
      if (_hasPendingDapCommand(snapshot, 'stackTrace')) {
        return null;
      }
      return requestFactory.stackTrace(seq: reserveSeq(), threadId: threadId);
    }
    if (snapshot.scopes.isEmpty) {
      if (_hasPendingDapCommand(snapshot, 'scopes')) {
        return null;
      }
      return requestFactory.scopes(
        seq: reserveSeq(),
        frameId: snapshot.stackFrames.first.id,
      );
    }
    if (snapshot.variables.isEmpty) {
      if (_hasPendingDapCommand(snapshot, 'variables')) {
        return null;
      }
      final variablesReference = _firstScopeVariablesReference(snapshot.scopes);
      if (variablesReference == null) {
        return null;
      }
      return requestFactory.variables(
        seq: reserveSeq(),
        variablesReference: variablesReference,
      );
    }
    return null;
  }

  void syncFromDapSnapshot(
    DapSessionSnapshot snapshot, {
    required String message,
  }) {
    replaceSession(
      DebugSessionSnapshot(
        status: statusFromDapSession(snapshot.status),
        message: message,
        debuggerId: _session.debuggerId,
        debuggerLabel: _session.debuggerLabel,
        breakpoints: breakpoints,
        threads: snapshot.threads
            .map((thread) => DebugThread(id: '${thread.id}', name: thread.name))
            .toList(growable: false),
        stackFrames: snapshot.stackFrames
            .map(
              (frame) => DebugStackFrame(
                id: '${frame.id}',
                name: frame.name,
                filePath: frame.sourcePath,
                line: frame.line,
                column: frame.column,
              ),
            )
            .toList(growable: false),
        variables: snapshot.variables
            .map(
              (variable) => DebugVariable(
                name: variable.name,
                value: variable.value,
                type: variable.type,
              ),
            )
            .toList(growable: false),
        launchConfiguration: _session.launchConfiguration,
        adapterSessionStatus: snapshot.status.name,
        adapterPendingRequestCount: snapshot.pendingRequests.length,
        adapterEventCount: snapshot.events.length,
      ),
    );
  }

  DebugSessionStatus statusFromDapSession(DapSessionStatus status) {
    return switch (status) {
      DapSessionStatus.idle => DebugSessionStatus.configured,
      DapSessionStatus.initializing ||
      DapSessionStatus.launching => DebugSessionStatus.launching,
      DapSessionStatus.running => DebugSessionStatus.running,
      DapSessionStatus.paused => DebugSessionStatus.paused,
      DapSessionStatus.terminated => DebugSessionStatus.stopped,
      DapSessionStatus.failed => DebugSessionStatus.blocked,
    };
  }

  Future<DebugCommandResult> continueSession() async {
    final sessionHandle = _sessionHandle;
    if (_session.status != DebugSessionStatus.paused) {
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: DebugSessionStatus.blocked,
          message: 'Continue Debugging blocked: no paused debug session.',
          breakpoints: breakpoints,
        ),
      );
    }
    if (sessionHandle != null) {
      final adapterSnapshot = sessionHandle.snapshot;
      final threadId = adapterSnapshot.activeThreadId;
      if (threadId == null) {
        return _applyCommandSnapshot(
          DebugSessionSnapshot(
            status: DebugSessionStatus.blocked,
            message:
                'Continue Debugging blocked: DAP stopped event did not provide a threadId.',
            breakpoints: breakpoints,
            launchConfiguration: _session.launchConfiguration,
            adapterSessionStatus: adapterSnapshot.status.name,
            adapterPendingRequestCount: adapterSnapshot.pendingRequests.length,
            adapterEventCount: adapterSnapshot.events.length,
          ),
        );
      }
      await sessionHandle.sendRequest(
        const DapProtocolRequestFactory().continueThread(
          seq: sessionHandle.bridge.session.reserveSeq(),
          threadId: threadId,
        ),
      );
      final refreshed = sessionHandle.snapshot;
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: DebugSessionStatus.running,
          message: 'Continue Debugging request sent to DAP adapter.',
          debuggerId: _session.debuggerId,
          debuggerLabel: _session.debuggerLabel,
          breakpoints: breakpoints,
          threads: _session.threads,
          stackFrames: _session.stackFrames,
          variables: _session.variables,
          launchConfiguration: _session.launchConfiguration,
          adapterSessionStatus: refreshed.status.name,
          adapterPendingRequestCount: refreshed.pendingRequests.length,
          adapterEventCount: refreshed.events.length,
        ),
      );
    }
    return _applyCommandSnapshot(
      DebugSessionSnapshot(
        status: DebugSessionStatus.running,
        message: 'Debug session continued.',
        debuggerId: _session.debuggerId,
        debuggerLabel: _session.debuggerLabel,
        breakpoints: breakpoints,
        threads: _session.threads,
        stackFrames: _session.stackFrames,
        variables: _session.variables,
        launchConfiguration: _session.launchConfiguration,
        adapterSessionStatus: _session.adapterSessionStatus,
        adapterPendingRequestCount: _session.adapterPendingRequestCount,
        adapterEventCount: _session.adapterEventCount,
      ),
    );
  }

  Future<DebugCommandResult> stopSession({bool force = false}) async {
    final handle = await detachSession();
    if (handle != null) {
      final adapterSnapshot = handle.snapshot;
      DebugSessionTerminationExecutionResult termination;
      final runtimeExecution = _lastRuntimeExecutionResult;
      final runtimeAdapter = _runtimeExecutionAdapter;
      final runtimeOutputBuffer = _configuredRuntimeOutputBuffer;
      if (runtimeExecution != null &&
          runtimeAdapter != null &&
          runtimeOutputBuffer != null &&
          identical(runtimeExecution.handle, handle)) {
        final cancelled = await runtimeAdapter.cancelExecution(
          execution: runtimeExecution,
          buffer: runtimeOutputBuffer,
          reason: force
              ? 'Debug adapter process force-stopped by the user.'
              : 'Debug session stopped by the user.',
          force: force,
        );
        _lastRuntimeExecutionResult = cancelled;
        termination = cancelled.terminationExecution!;
      } else {
        termination = await const DebugSessionTerminationExecutor().execute(
          handle: handle,
          plan: handle.terminationPlan(force: force),
          reason: force
              ? 'Debug adapter process force-stopped by the user.'
              : 'Debug session stopped by the user.',
        );
      }
      if (!termination.executed) {
        await handle.close();
      }
      final stopped =
          termination.executed ||
          termination.status == DebugSessionTerminationExecutionStatus.skipped;
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: stopped
              ? DebugSessionStatus.stopped
              : DebugSessionStatus.blocked,
          message: termination.message,
          breakpoints: breakpoints,
          launchConfiguration: _session.launchConfiguration,
          adapterSessionStatus: adapterSnapshot.status.name,
          adapterPendingRequestCount: adapterSnapshot.pendingRequests.length,
          adapterEventCount: adapterSnapshot.events.length,
        ),
      );
    }
    return _applyCommandSnapshot(
      DebugSessionSnapshot(
        status: DebugSessionStatus.stopped,
        message: 'Debug session stopped.',
        breakpoints: breakpoints,
      ),
    );
  }

  Future<DebugCommandResult> startSession({
    required ToolchainManager? toolchainManager,
    String? workspaceId,
    required String workspaceRoot,
    required DapDebugAdapterLauncher? launcher,
    required RuntimeOutputLiveBuffer runtimeOutputBuffer,
    required void Function(DapSessionSnapshot snapshot) onSnapshot,
  }) async {
    await _ensureWorkspaceState(
      workspaceId: workspaceId ?? workspaceRoot,
      workspaceRoot: workspaceRoot,
      toolchainManager: toolchainManager,
    );
    final profile = _launchConfigurations.selectedProfile;
    if (profile == null && toolchainManager == null) {
      return _applyCommandSnapshot(
        const DebugSessionSnapshot(
          status: DebugSessionStatus.blocked,
          message:
              'Start Debugging blocked: no toolchain manager is available.',
        ),
      );
    }
    if (profile == null) {
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: DebugSessionStatus.blocked,
          message:
              'Start Debugging blocked: no DAP debug adapter is registered.',
          breakpoints: breakpoints,
        ),
      );
    }
    final launchConfiguration = profile.configuration
        .resolveForWorkspace(workspaceRoot)
        .reconfigure(
          breakpoints: breakpoints
              .map(
                (breakpoint) => DebugLaunchBreakpoint(
                  filePath: breakpoint.filePath,
                  line: breakpoint.line,
                  enabled: breakpoint.enabled,
                ),
              )
              .toList(growable: false),
        );
    if (!launchConfiguration.ready) {
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: DebugSessionStatus.blocked,
          message: launchConfiguration.reason,
          debuggerId: profile.id,
          debuggerLabel: profile.displayName,
          breakpoints: breakpoints,
          launchConfiguration: launchConfiguration,
        ),
      );
    }
    if (launcher == null) {
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: DebugSessionStatus.configured,
          message:
              'Debug session configured with ${profile.displayName} for ${launchConfiguration.programPath}; process launch adapter is not attached yet.',
          debuggerId: profile.id,
          debuggerLabel: profile.displayName,
          breakpoints: breakpoints,
          launchConfiguration: launchConfiguration,
        ),
      );
    }
    try {
      final executionPlan = DapDebugAdapterExecutionPlan.fromConfiguration(
        profileId: profile.id,
        launchConfiguration: launchConfiguration,
      );
      final runtimeAdapter = DebugRuntimeExecutionAdapter(
        launcher: launcher,
        workspaceId: workspaceRoot,
      );
      _runtimeExecutionAdapter = runtimeAdapter;
      final executionResult = await runtimeAdapter.executePlan(
        plan: executionPlan,
        buffer: runtimeOutputBuffer,
      );
      _lastRuntimeExecutionResult = executionResult;
      if (!executionResult.launched || executionResult.handle == null) {
        final record = executionResult.telemetry.records.isEmpty
            ? null
            : executionResult.telemetry.records.first;
        return _applyCommandSnapshot(
          DebugSessionSnapshot(
            status: DebugSessionStatus.blocked,
            message: record?.message ?? executionResult.dispatchResult.message,
            debuggerId: profile.id,
            debuggerLabel: profile.displayName,
            breakpoints: breakpoints,
            launchConfiguration: launchConfiguration,
          ),
        );
      }
      final handle = executionResult.handle!;
      await attachSession(handle, onSnapshot: onSnapshot);
      final adapterSnapshot = handle.snapshot;
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: statusFromDapSession(adapterSnapshot.status),
          message:
              'Debug adapter launch plan sent with ${adapterSnapshot.pendingRequests.length} pending DAP request(s).',
          debuggerId: profile.id,
          debuggerLabel: profile.displayName,
          breakpoints: breakpoints,
          launchConfiguration: launchConfiguration,
          adapterSessionStatus: adapterSnapshot.status.name,
          adapterPendingRequestCount: adapterSnapshot.pendingRequests.length,
          adapterEventCount: adapterSnapshot.events.length,
        ),
      );
    } on Object catch (error) {
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: DebugSessionStatus.blocked,
          message: 'Start Debugging failed: $error',
          debuggerId: profile.id,
          debuggerLabel: profile.displayName,
          breakpoints: breakpoints,
          launchConfiguration: launchConfiguration,
        ),
      );
    }
  }

  Future<DebugCommandResult> stepOverSession() async {
    final sessionHandle = _sessionHandle;
    if (_session.status != DebugSessionStatus.paused) {
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: DebugSessionStatus.blocked,
          message: 'Step Over blocked: no paused debug session.',
          breakpoints: breakpoints,
        ),
      );
    }
    if (sessionHandle != null) {
      final adapterSnapshot = sessionHandle.snapshot;
      final threadId = adapterSnapshot.activeThreadId;
      if (threadId == null) {
        return _applyCommandSnapshot(
          DebugSessionSnapshot(
            status: DebugSessionStatus.blocked,
            message:
                'Step Over blocked: DAP stopped event did not provide a threadId.',
            breakpoints: breakpoints,
            launchConfiguration: _session.launchConfiguration,
            adapterSessionStatus: adapterSnapshot.status.name,
            adapterPendingRequestCount: adapterSnapshot.pendingRequests.length,
            adapterEventCount: adapterSnapshot.events.length,
          ),
        );
      }
      await sessionHandle.sendRequest(
        const DapProtocolRequestFactory().next(
          seq: sessionHandle.bridge.session.reserveSeq(),
          threadId: threadId,
        ),
      );
      final refreshed = sessionHandle.snapshot;
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: DebugSessionStatus.running,
          message: 'Step Over request sent to DAP adapter.',
          debuggerId: _session.debuggerId,
          debuggerLabel: _session.debuggerLabel,
          breakpoints: breakpoints,
          threads: _session.threads,
          stackFrames: _session.stackFrames,
          variables: _session.variables,
          launchConfiguration: _session.launchConfiguration,
          adapterSessionStatus: refreshed.status.name,
          adapterPendingRequestCount: refreshed.pendingRequests.length,
          adapterEventCount: refreshed.events.length,
        ),
      );
    }
    return _applyCommandSnapshot(
      DebugSessionSnapshot(
        status: DebugSessionStatus.paused,
        message: 'Step Over completed.',
        debuggerId: _session.debuggerId,
        debuggerLabel: _session.debuggerLabel,
        breakpoints: breakpoints,
        threads: _session.threads,
        stackFrames: _session.stackFrames,
        variables: _session.variables,
        launchConfiguration: _session.launchConfiguration,
        adapterSessionStatus: _session.adapterSessionStatus,
        adapterPendingRequestCount: _session.adapterPendingRequestCount,
        adapterEventCount: _session.adapterEventCount,
      ),
    );
  }

  Future<DebugCommandResult> selectStackFrame(String frameId) async {
    final sessionHandle = _sessionHandle;
    if (_session.status != DebugSessionStatus.paused) {
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: DebugSessionStatus.blocked,
          message: 'Select Debug Stack Frame blocked: no paused debug session.',
          breakpoints: breakpoints,
          threads: _session.threads,
          stackFrames: _session.stackFrames,
          variables: _session.variables,
          launchConfiguration: _session.launchConfiguration,
          adapterSessionStatus: _session.adapterSessionStatus,
          adapterPendingRequestCount: _session.adapterPendingRequestCount,
          adapterEventCount: _session.adapterEventCount,
        ),
      );
    }
    if (sessionHandle == null) {
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: DebugSessionStatus.blocked,
          message:
              'Select Debug Stack Frame blocked: no DAP session is active.',
          breakpoints: breakpoints,
          threads: _session.threads,
          stackFrames: _session.stackFrames,
          variables: _session.variables,
          launchConfiguration: _session.launchConfiguration,
          adapterSessionStatus: _session.adapterSessionStatus,
          adapterPendingRequestCount: _session.adapterPendingRequestCount,
          adapterEventCount: _session.adapterEventCount,
        ),
      );
    }
    final frameIdValue = int.tryParse(frameId);
    if (frameIdValue == null) {
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: DebugSessionStatus.blocked,
          message:
              'Select Debug Stack Frame blocked: invalid frame id $frameId.',
          breakpoints: breakpoints,
          threads: _session.threads,
          stackFrames: _session.stackFrames,
          variables: _session.variables,
          launchConfiguration: _session.launchConfiguration,
          adapterSessionStatus: _session.adapterSessionStatus,
          adapterPendingRequestCount: _session.adapterPendingRequestCount,
          adapterEventCount: _session.adapterEventCount,
        ),
      );
    }
    final adapterSnapshot = sessionHandle.snapshot;
    if (!adapterSnapshot.stackFrames.any((frame) => frame.id == frameIdValue)) {
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: DebugSessionStatus.blocked,
          message:
              'Select Debug Stack Frame blocked: frame $frameId was not found.',
          breakpoints: breakpoints,
          threads: _session.threads,
          stackFrames: _session.stackFrames,
          variables: _session.variables,
          launchConfiguration: _session.launchConfiguration,
          adapterSessionStatus: adapterSnapshot.status.name,
          adapterPendingRequestCount: adapterSnapshot.pendingRequests.length,
          adapterEventCount: adapterSnapshot.events.length,
        ),
      );
    }
    await sessionHandle.sendRequest(
      const DapProtocolRequestFactory().scopes(
        seq: sessionHandle.bridge.session.reserveSeq(),
        frameId: frameIdValue,
      ),
    );
    final refreshed = sessionHandle.snapshot;
    return _applyCommandSnapshot(
      DebugSessionSnapshot(
        status: DebugSessionStatus.paused,
        message:
            'Select Debug Stack Frame request sent to DAP adapter for frame $frameId.',
        debuggerId: _session.debuggerId,
        debuggerLabel: _session.debuggerLabel,
        breakpoints: breakpoints,
        threads: _session.threads,
        stackFrames: _session.stackFrames,
        variables: const <DebugVariable>[],
        launchConfiguration: _session.launchConfiguration,
        adapterSessionStatus: refreshed.status.name,
        adapterPendingRequestCount: refreshed.pendingRequests.length,
        adapterEventCount: refreshed.events.length,
      ),
    );
  }

  Future<DebugCommandResult> selectThread(String threadId) async {
    final sessionHandle = _sessionHandle;
    if (_session.status != DebugSessionStatus.paused) {
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: DebugSessionStatus.blocked,
          message: 'Select Debug Thread blocked: no paused debug session.',
          breakpoints: breakpoints,
          threads: _session.threads,
          stackFrames: _session.stackFrames,
          variables: _session.variables,
          launchConfiguration: _session.launchConfiguration,
          adapterSessionStatus: _session.adapterSessionStatus,
          adapterPendingRequestCount: _session.adapterPendingRequestCount,
          adapterEventCount: _session.adapterEventCount,
        ),
      );
    }
    if (sessionHandle == null) {
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: DebugSessionStatus.blocked,
          message: 'Select Debug Thread blocked: no DAP session is active.',
          breakpoints: breakpoints,
          threads: _session.threads,
          stackFrames: _session.stackFrames,
          variables: _session.variables,
          launchConfiguration: _session.launchConfiguration,
          adapterSessionStatus: _session.adapterSessionStatus,
          adapterPendingRequestCount: _session.adapterPendingRequestCount,
          adapterEventCount: _session.adapterEventCount,
        ),
      );
    }
    final threadIdValue = int.tryParse(threadId);
    if (threadIdValue == null) {
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: DebugSessionStatus.blocked,
          message: 'Select Debug Thread blocked: invalid thread id $threadId.',
          breakpoints: breakpoints,
          threads: _session.threads,
          stackFrames: _session.stackFrames,
          variables: _session.variables,
          launchConfiguration: _session.launchConfiguration,
          adapterSessionStatus: _session.adapterSessionStatus,
          adapterPendingRequestCount: _session.adapterPendingRequestCount,
          adapterEventCount: _session.adapterEventCount,
        ),
      );
    }
    final adapterSnapshot = sessionHandle.snapshot;
    if (!adapterSnapshot.threads.any((thread) => thread.id == threadIdValue)) {
      return _applyCommandSnapshot(
        DebugSessionSnapshot(
          status: DebugSessionStatus.blocked,
          message:
              'Select Debug Thread blocked: thread $threadId was not found.',
          breakpoints: breakpoints,
          threads: _session.threads,
          stackFrames: _session.stackFrames,
          variables: _session.variables,
          launchConfiguration: _session.launchConfiguration,
          adapterSessionStatus: adapterSnapshot.status.name,
          adapterPendingRequestCount: adapterSnapshot.pendingRequests.length,
          adapterEventCount: adapterSnapshot.events.length,
        ),
      );
    }
    await sessionHandle.sendRequest(
      const DapProtocolRequestFactory().stackTrace(
        seq: sessionHandle.bridge.session.reserveSeq(),
        threadId: threadIdValue,
      ),
    );
    final refreshed = sessionHandle.snapshot;
    return _applyCommandSnapshot(
      DebugSessionSnapshot(
        status: DebugSessionStatus.paused,
        message:
            'Select Debug Thread request sent to DAP adapter for thread $threadId.',
        debuggerId: _session.debuggerId,
        debuggerLabel: _session.debuggerLabel,
        breakpoints: breakpoints,
        threads: _session.threads,
        stackFrames: const <DebugStackFrame>[],
        variables: const <DebugVariable>[],
        launchConfiguration: _session.launchConfiguration,
        adapterSessionStatus: refreshed.status.name,
        adapterPendingRequestCount: refreshed.pendingRequests.length,
        adapterEventCount: refreshed.events.length,
      ),
    );
  }

  DebugCommandResult _applyCommandSnapshot(DebugSessionSnapshot snapshot) {
    replaceSession(snapshot);
    return DebugCommandResult(
      applied:
          snapshot.status != DebugSessionStatus.blocked &&
          snapshot.status != DebugSessionStatus.idle,
      message: snapshot.message,
    );
  }

  bool _hasPendingDapCommand(DapSessionSnapshot snapshot, String command) {
    return snapshot.pendingRequests.any(
      (request) => request.command == command,
    );
  }

  int? _firstScopeVariablesReference(List<DapScope> scopes) {
    for (final scope in scopes) {
      if (scope.variablesReference > 0) {
        return scope.variablesReference;
      }
    }
    return null;
  }

  int? _firstInspectableThreadId(List<DapThread> threads) {
    for (final thread in threads) {
      if (thread.id > 0) {
        return thread.id;
      }
    }
    return null;
  }

  @override
  void dispose() {
    final handle = _sessionHandle;
    _sessionHandle = null;
    _inspectionRequestInFlight = false;
    final subscription = _sessionSubscription;
    _sessionSubscription = null;
    unawaited(subscription?.cancel());
    if (handle != null) {
      unawaited(handle.close());
    }
    unawaited(_dapSnapshotEvents.close());
    super.dispose();
  }
}
