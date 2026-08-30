import 'package:flutter/foundation.dart';

import '../../debugger/debugger.dart';
import '../../environment/system_compatibility/process/process_manager.dart';
import '../../foundation/foundation.dart';
import '../../runtime/runtime.dart';
import '../../testing/testing.dart';
import 'native_tool_test_run_provider.dart';

class ShellTestingController extends ChangeNotifier {
  ShellTestingController({
    required this.sessionController,
    required this.workspaceRoot,
    required this.runNativeTests,
    required this.processManager,
    required this.runtimeOutputBuffer,
    required this.log,
    this.debugAdapterLauncher,
  }) {
    sessionController?.addListener(_handleSessionChanged);
    _runProvider = NativeToolTestRunProvider(
      runNativeTests: runNativeTests,
      processManager: processManager,
      debugAdapterLauncher: debugAdapterLauncher,
      runtimeOutputBuffer: runtimeOutputBuffer,
    );
    sessionController?.providerCatalog?.registerRunProvider(
      TestingProviderRegistration(
        id: 'native-tool-runTests',
        provider: _runProvider,
        priority: 100,
        state: FoundationRegistryEntryState.active,
        metadata: const <String, Object?>{
          'runtime': 'toolchain-manager',
          'processIdentity': 'vityod-process-handle',
        },
      ),
    );
  }

  final TestingSessionController? sessionController;
  final String Function() workspaceRoot;
  final NativeTestCommandExecutor runNativeTests;
  final ProcessManager? processManager;
  final RuntimeOutputLiveBuffer runtimeOutputBuffer;
  final void Function(String message) log;
  final DapDebugAdapterLauncher? debugAdapterLauncher;
  late final NativeToolTestRunProvider _runProvider;

  String _selectedConfigurationId = '';
  bool _disposed = false;

  TestDiscoveryResult? get discovery => sessionController?.discovery;
  TestRunResult? get lastRun => sessionController?.lastRun;
  List<TestRunResult> get runHistory =>
      sessionController?.runHistory ?? const <TestRunResult>[];
  List<FailedTestRetryRecord> get failedRetryHistory =>
      sessionController?.failedRetryHistory ?? const <FailedTestRetryRecord>[];
  FailedTestDebugCancellationRoute? get failedDebugCancellationRoute =>
      sessionController?.lastFailedDebugCancellationRoute;
  bool get runActive => sessionController?.lastRuntimeTask?.active == true;

  TestRunConfigurationSet get configurationSet {
    final root = workspaceRoot();
    final providerId = lastRun?.providerId ?? 'native-tool-runTests';
    final configurations = <TestRunConfiguration>[
      TestRunConfiguration(
        id: 'all-tests',
        label: 'All Tests',
        workspaceRoot: root,
        providerId: providerId,
      ),
    ];
    final failedDebugConfiguration = sessionController?.rerunPlanner.plan(
      lastRun: lastRun,
      workspaceRoot: root,
      debug: true,
    );
    if (failedDebugConfiguration != null) {
      configurations.add(failedDebugConfiguration);
    }
    final selectedId =
        configurations.any(
          (configuration) => configuration.id == _selectedConfigurationId,
        )
        ? _selectedConfigurationId
        : configurations.first.id;
    return TestRunConfigurationSet(
      workspaceId: root,
      selectedConfigurationId: selectedId,
      configurations: List<TestRunConfiguration>.unmodifiable(configurations),
    );
  }

  TestRunConfiguration? configurationForId(String configurationId) {
    final normalizedId = configurationId.trim();
    if (normalizedId.isEmpty) {
      return null;
    }
    for (final configuration in configurationSet.configurations) {
      if (configuration.id == normalizedId) {
        return configuration;
      }
    }
    return null;
  }

  void selectConfiguration(TestRunConfiguration configuration) {
    _selectedConfigurationId = configuration.id;
    log('Selected test run configuration ${configuration.id}.');
    notifyListeners();
  }

  Future<void> rerunFailed() async {
    if (_blockWhileRunActive('Rerun failed tests')) {
      return;
    }
    final controller = sessionController;
    if (controller == null || !controller.hasActiveRunProvider) {
      await _runNativeTestsDirect();
      return;
    }
    final result = await controller.rerunFailed(workspaceRoot: workspaceRoot());
    log(resultMessage('Rerun failed tests', result));
    notifyListeners();
  }

  Future<void> debugFailed() async {
    if (_blockWhileRunActive('Debug failed tests')) {
      return;
    }
    final controller = sessionController;
    if (controller == null || !controller.hasActiveRunProvider) {
      log('Debug failed tests blocked: no test run provider is available.');
      notifyListeners();
      return;
    }
    final result = await controller.rerunFailed(
      workspaceRoot: workspaceRoot(),
      debug: true,
    );
    log(resultMessage('Debug failed tests', result));
    notifyListeners();
  }

  Future<void> runConfiguration(TestRunConfiguration configuration) async {
    if (_blockWhileRunActive('Run test configuration')) {
      return;
    }
    final controller = sessionController;
    if (controller == null || !controller.hasActiveRunProvider) {
      await _runNativeTestsDirect();
      return;
    }
    final result = await controller.runConfiguration(configuration);
    log(resultMessage('Run test configuration', result));
    notifyListeners();
  }

  Future<void> debugConfiguration(TestRunConfiguration configuration) async {
    if (_blockWhileRunActive('Debug test configuration')) {
      return;
    }
    final debugConfiguration = configuration.debug
        ? configuration
        : configuration.copyWith(debug: true);
    final route = const TestDebugLaunchRoutePlanner().plan(debugConfiguration);
    runtimeOutputBuffer.addEvent(
      RuntimeOutputEvent(
        channelId: route.handoff.outputChannelId ?? 'debug.tests',
        label: 'Test Debug',
        kind: RuntimeOutputChannelKind.debug,
        message:
            '${route.ready ? 'ready' : 'blocked'} ${route.profileId}: ${route.handoff.plan.message}',
        timestamp: DateTime.now().toUtc(),
        metadata: <String, Object?>{
          'testDebugLaunchRoute': <String, Object?>{
            'profileId': route.profileId,
            'status': route.status.wireValue,
            'ready': route.ready,
            'message': route.handoff.plan.message,
          },
          'configurationId': debugConfiguration.id,
          'providerId': debugConfiguration.providerId,
        },
      ),
    );
    if (!route.ready) {
      log(route.handoff.plan.message);
      notifyListeners();
      return;
    }
    final controller = sessionController;
    if (controller == null || !controller.hasActiveRunProvider) {
      log(
        'Debug test configuration blocked: no test run provider is available.',
      );
      notifyListeners();
      return;
    }
    final result = await controller.debugConfiguration(debugConfiguration);
    log(resultMessage('Debug test configuration', result));
    notifyListeners();
  }

  Future<void> runAllTests() async {
    final configuration = configurationSet.configurations.first;
    await runConfiguration(configuration);
  }

  Future<void> _runNativeTestsDirect() async {
    final result = await runNativeTests(recordTestingResult: false);
    recordNativeToolResult(
      message: result.message,
      metadata: result.metadata['testResult'],
    );
  }

  Future<void> cancelFailedDebug(Map<String, Object?> failedTest) async {
    final controller = sessionController;
    if (controller == null) {
      log('Failed-test debug cancellation skipped: no test controller.');
      notifyListeners();
      return;
    }
    final route = await controller.cancelFailedTestDebug(
      failedTest: failedTest,
    );
    log(route.message);
    notifyListeners();
  }

  String resultMessage(String action, TestRunResult result) {
    return '$action: ${result.status.wireValue} · ${result.message}';
  }

  bool agentCommandApplied(TestRunResult? result) {
    return result != null && result.status != TestRunStatus.notRun;
  }

  Map<String, Object?> agentCommandMetadata(TestRunResult? result) {
    return <String, Object?>{
      if (result != null) 'testResult': result.toJson(),
      'failedRetryHistory': failedRetryHistory
          .map((record) => record.toJson())
          .toList(growable: false),
    };
  }

  Map<String, Object?> configurationCommandMetadata({
    TestRunConfiguration? configuration,
    TestRunResult? result,
  }) {
    return <String, Object?>{
      'availableConfigurationIds': configurationSet.configurations
          .map((configuration) => configuration.id)
          .toList(growable: false),
      if (configuration != null) 'configuration': configuration.toJson(),
      ...agentCommandMetadata(result),
    };
  }

  void recordNativeToolResult({
    required String message,
    required Object? metadata,
  }) {
    final controller = sessionController;
    if (controller == null) {
      return;
    }
    final normalized = normalizeNativeToolMetadata(metadata);
    if (normalized == null) {
      return;
    }
    controller.recordRunResult(
      testRunResultFromNativeToolMetadata(normalized, message: message),
    );
  }

  bool _blockWhileRunActive(String action) {
    if (!runActive) {
      return false;
    }
    log('$action blocked: another test task is already active.');
    notifyListeners();
    return true;
  }

  void _handleSessionChanged() {
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    sessionController?.removeListener(_handleSessionChanged);
    _runProvider.dispose();
    super.dispose();
  }
}
