import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../editor/editor_controller.dart';
import '../../editor/document_state.dart';
import '../../backend_toolchain/adapter_contracts.dart';
import '../../backend_toolchain/dependency_source_adapter.dart';
import '../../backend_toolchain/deployment_adapter.dart';
import '../../backend_toolchain/execution_adapter.dart';
import '../../backend_toolchain/project_graph_adapter.dart';
import '../../backend_toolchain/project_graph_contract.dart';
import '../../backend_toolchain/runtime_event_adapter.dart';
import '../../backend_toolchain/toolchain_management_adapter.dart';
import '../../module_host/module_definition.dart';
import '../../module_host/module_registry.dart';
import '../../platform/native_module_loader.dart';
import '../../platform/platform_target.dart';
import '../commands/app_commands.dart';
import 'workspace_document_store.dart';
import 'workspace_controller.dart';

enum BottomSurfaceTab { runtime, agent, debug }

class ShellModel extends ChangeNotifier {
  ShellModel({
    required this.platformTarget,
    required List<AdapterCapabilitySnapshot> supplementalAdapterCapabilities,
    required ProjectGraphAdapter projectGraphAdapter,
    required this.workspaceController,
    required this.workspaceDocumentStore,
    required this.moduleRegistry,
    required this.nativeModuleLoader,
    required this.editorController,
    required this.executionAdapter,
    required ExecutionAdapterFactory executionAdapterFactory,
    required this.runtimeEventAdapter,
    required DependencySourceAdapter dependencySourceAdapter,
    required DeploymentAdapter deploymentAdapter,
    required ToolchainManagementAdapter toolchainManagementAdapter,
  }) : _activeBottomTab = BottomSurfaceTab.runtime,
       _activeDocumentPath = workspaceController.activeFilePath,
       _supplementalAdapterCapabilities =
           List<AdapterCapabilitySnapshot>.unmodifiable(
             supplementalAdapterCapabilities,
           ),
       _projectGraphAdapter = projectGraphAdapter,
       _executionAdapterFactory = executionAdapterFactory,
       _dependencySourceAdapter = dependencySourceAdapter,
       _deploymentAdapter = deploymentAdapter,
       _toolchainManagementAdapter = toolchainManagementAdapter,
       _adapterCapabilities = normalizeCapabilitySnapshots([
         projectGraphAdapter.capabilitySnapshot,
         executionAdapter.capabilitySnapshot,
         runtimeEventAdapter.capabilitySnapshot,
         ...supplementalAdapterCapabilities,
       ]) {
    workspaceController.addListener(_handleWorkspaceChanged);
    editorController.addListener(_handleDocumentChanged);
    _documentCache[_activeDocumentPath] = editorController.document;
    appendLog(
      'Shell booted for ${platformTarget.label} with '
      '${moduleRegistry.visibleModules.length} visible modules and '
      '${adapterCapabilities.length} adapter route(s).',
    );
  }

  final PlatformTarget platformTarget;
  final WorkspaceController workspaceController;
  final WorkspaceDocumentStore workspaceDocumentStore;
  final ModuleRegistry moduleRegistry;
  final NativeModuleLoader nativeModuleLoader;
  final EditorSessionController editorController;
  final ProjectGraphAdapter _projectGraphAdapter;
  final List<AdapterCapabilitySnapshot> _supplementalAdapterCapabilities;
  final ExecutionAdapterFactory _executionAdapterFactory;
  final DependencySourceAdapter _dependencySourceAdapter;
  final DeploymentAdapter _deploymentAdapter;
  final ToolchainManagementAdapter _toolchainManagementAdapter;
  final RuntimeEventAdapter runtimeEventAdapter;

  BottomSurfaceTab _activeBottomTab;
  final List<String> _debugLog = <String>[];
  final Map<String, DocumentState> _documentCache = <String, DocumentState>{};
  String _activeDocumentPath;
  ExecutionSession? _lastExecutionSession;
  List<RuntimeEventEnvelope> _lastRuntimeEvents =
      const <RuntimeEventEnvelope>[];
  DependencySourceCommandResult? _lastDependencySourceCommand;
  DeploymentCommandResult? _lastDeploymentCommand;
  ToolchainCommandResult? _lastToolchainCommand;
  ExecutionAdapter executionAdapter;
  List<AdapterCapabilitySnapshot> _adapterCapabilities;

  BottomSurfaceTab get activeBottomTab => _activeBottomTab;
  List<AdapterCapabilitySnapshot> get adapterCapabilities =>
      _adapterCapabilities;
  List<String> get debugLog => List<String>.unmodifiable(_debugLog);
  ExecutionSession? get lastExecutionSession => _lastExecutionSession;
  List<RuntimeEventEnvelope> get lastRuntimeEvents =>
      List<RuntimeEventEnvelope>.unmodifiable(_lastRuntimeEvents);
  DependencySourceCommandResult? get lastDependencySourceCommand =>
      _lastDependencySourceCommand;
  DeploymentCommandResult? get lastDeploymentCommand => _lastDeploymentCommand;
  ToolchainCommandResult? get lastToolchainCommand => _lastToolchainCommand;

  List<ModuleDefinition> get mountedModules => moduleRegistry.mountedModules;
  List<ModuleDefinition> get visibleModules => moduleRegistry.visibleModules;

  void selectBottomTab(BottomSurfaceTab tab) {
    if (_activeBottomTab == tab) {
      return;
    }
    _activeBottomTab = tab;
    appendLog('Bottom surface switched to ${tab.name}.');
  }

  Future<void> executeCommand(AppCommandId commandId) async {
    final blockedReason = blockedReasonForCommand(commandId);
    if (blockedReason != null) {
      appendLog(
        '${StyioCommandRegistry.descriptorFor(commandId).label} blocked: $blockedReason',
      );
      return;
    }

    switch (commandId) {
      case AppCommandId.save:
        _documentCache[_activeDocumentPath] = editorController.document;
        await workspaceDocumentStore.saveDocument(editorController.document);
        appendLog(
          'Save requested for ${workspaceController.activeFilePath} '
          '(rev ${editorController.document.revision}).',
        );
        return;
      case AppCommandId.run:
        final session = await executionAdapter.runActiveDocument(
          platformTarget: platformTarget,
          projectGraph: workspaceController.activeProject,
          document: editorController.document,
          activeFilePath: workspaceController.activeFilePath,
        );
        _lastExecutionSession = session;
        _lastRuntimeEvents = await runtimeEventAdapter
            .sessionEvents(session.sessionId)
            .toList();
        appendLog('Run ${session.status.name}: ${session.statusMessage}');
        for (final event in session.stdoutEvents.take(3)) {
          appendLog('stdout: ${event.message}');
        }
        for (final event in session.stderrEvents.take(3)) {
          appendLog('stderr: ${event.message}');
        }
        if (session.diagnostics.isNotEmpty) {
          appendLog(
            'diagnostics: ${session.diagnostics.length} issue(s) returned by the execution route.',
          );
        }
        if (_lastRuntimeEvents.isNotEmpty) {
          appendLog(
            'runtime events: ${_lastRuntimeEvents.length} event(s) for session ${session.sessionId}.',
          );
          for (final event in _lastRuntimeEvents.take(4)) {
            appendLog('runtime: ${event.eventKind}');
          }
        }
        selectBottomTab(BottomSurfaceTab.runtime);
        notifyListeners();
        return;
      case AppCommandId.fetchDependencies:
        await fetchDependencies();
        return;
      case AppCommandId.vendorDependencies:
        await vendorDependencies();
        return;
      case AppCommandId.useActiveCompiler:
        final compiler = workspaceController.activeProject.activeCompiler!;
        await useManagedCompiler(
          compilerVersion: compiler.compilerVersion,
          channel: compiler.channel,
        );
        return;
      case AppCommandId.pinActiveCompiler:
        final compiler = workspaceController.activeProject.activeCompiler!;
        await pinManagedCompiler(
          compilerVersion: compiler.compilerVersion,
          channel: compiler.channel,
        );
        return;
      case AppCommandId.clearPinnedCompiler:
        await clearPinnedCompiler();
        return;
      case AppCommandId.packProject:
        await packProject();
        return;
      case AppCommandId.preparePublish:
        await preparePublish();
        return;
      case AppCommandId.showRuntime:
        selectBottomTab(BottomSurfaceTab.runtime);
        return;
      case AppCommandId.showAgent:
        selectBottomTab(BottomSurfaceTab.agent);
        return;
      case AppCommandId.showDebug:
        selectBottomTab(BottomSurfaceTab.debug);
        return;
      case AppCommandId.refreshModules:
        appendLog('Module host refresh requested on ${platformTarget.label}.');
        await refreshProjectGraph(
          reason: 'manual refresh requested from the shell command registry',
        );
        final bridge = await nativeModuleLoader.describe(
          'local.runtime.desktop',
        );
        appendLog(
          'Native bridge ${bridge.moduleId}: ${bridge.state.name} '
          '(${bridge.detail})',
        );
        return;
      case AppCommandId.openSettings:
        appendLog('Settings route is reserved for M7 theme/profile system.');
        return;
    }
  }

  String? blockedReasonForCommand(AppCommandId commandId) {
    final projectGraph = workspaceController.activeProject;
    switch (commandId) {
      case AppCommandId.fetchDependencies:
        return blockedDependencySourceCommandReason(
          platformTarget: platformTarget,
          projectGraph: projectGraph,
          command: 'fetch',
        );
      case AppCommandId.vendorDependencies:
        return blockedDependencySourceCommandReason(
          platformTarget: platformTarget,
          projectGraph: projectGraph,
          command: 'vendor',
        );
      case AppCommandId.useActiveCompiler:
        return _blockedToolchainCommandReason(
          projectGraph: projectGraph,
          requiresResolvedCompiler: true,
        );
      case AppCommandId.pinActiveCompiler:
        return _blockedToolchainCommandReason(
          projectGraph: projectGraph,
          requiresResolvedCompiler: true,
          requiresManifest: true,
        );
      case AppCommandId.clearPinnedCompiler:
        return _blockedToolchainCommandReason(
          projectGraph: projectGraph,
          requiresManifest: true,
          requiresPin: true,
        );
      case AppCommandId.packProject:
        return _blockedDeploymentCommandReason(projectGraph: projectGraph);
      case AppCommandId.preparePublish:
        return _blockedDeploymentCommandReason(
          projectGraph: projectGraph,
          requireResolvedPublishTarget: true,
        );
      case AppCommandId.save:
      case AppCommandId.run:
      case AppCommandId.showRuntime:
      case AppCommandId.showAgent:
      case AppCommandId.showDebug:
      case AppCommandId.refreshModules:
      case AppCommandId.openSettings:
        return null;
    }
  }

  String? _blockedToolchainCommandReason({
    required ProjectGraphSnapshot projectGraph,
    bool requiresResolvedCompiler = false,
    bool requiresManifest = false,
    bool requiresPin = false,
  }) {
    if (platformTarget == PlatformTarget.ios ||
        platformTarget == PlatformTarget.web) {
      if (!projectGraph.hasHostedWorkspace) {
        return '${platformTarget.label} does not expose local spio toolchain management.';
      }
    }
    if (requiresResolvedCompiler && projectGraph.activeCompiler == null) {
      return 'No active compiler handshake is currently resolved for this project.';
    }
    if (requiresManifest && !projectGraph.hasManifest) {
      return 'Project toolchain commands require a resolved spio manifest path.';
    }
    if (requiresPin && projectGraph.toolchainPinPath == null) {
      return 'No project toolchain pin is currently resolved.';
    }
    return null;
  }

  String? _blockedDeploymentCommandReason({
    required ProjectGraphSnapshot projectGraph,
    bool requireResolvedPublishTarget = false,
  }) {
    if (platformTarget == PlatformTarget.ios ||
        platformTarget == PlatformTarget.web) {
      if (!projectGraph.hasHostedWorkspace) {
        return '${platformTarget.label} does not expose local spio deployment commands.';
      }
    }
    if (!projectGraph.hasManifest) {
      return 'Deployment commands require a resolved spio manifest path.';
    }
    if (!requireResolvedPublishTarget) {
      return null;
    }
    final distribution = projectGraph.packageDistribution;
    if (distribution == null || distribution.packages.isEmpty) {
      return null;
    }
    final publishablePackages = distribution.packages
        .where((package) => package.publishReady)
        .toList(growable: false);
    if (publishablePackages.length == 1) {
      return null;
    }
    if (publishablePackages.isEmpty) {
      final blockedPackages = distribution.packages
          .where((package) => !package.publishReady)
          .toList(growable: false);
      if (blockedPackages.isEmpty) {
        return 'No publish-ready package is available for deployment.';
      }
      final headline =
          'No publish-ready package is available: ${blockedPackages.map((package) => package.packageName).join(', ')}.';
      final details = blockedPackages
          .take(2)
          .expand((package) {
            if (package.blockingReasons.isEmpty) {
              return <String>[];
            }
            return <String>[
              '${package.packageName}: ${package.blockingReasons.join(' | ')}',
            ];
          })
          .join(' ');
      return details.isEmpty ? headline : '$headline $details';
    }
    return 'Multiple publish-ready packages are available. Select a package before publish: ${publishablePackages.map((package) => package.packageName).join(', ')}.';
  }

  void appendLog(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    _debugLog.insert(0, '$timestamp  $message');
    if (_debugLog.length > 48) {
      _debugLog.removeRange(48, _debugLog.length);
    }
    notifyListeners();
  }

  void _handleWorkspaceChanged() {
    unawaited(_loadActiveWorkspaceDocument());
  }

  void _handleDocumentChanged() {
    _documentCache[_activeDocumentPath] = editorController.document;
  }

  Future<void> refreshProjectGraph({String? reason}) async {
    final previousProject = workspaceController.activeProject;
    final refreshedProject = await _projectGraphAdapter.loadProjectGraph();
    executionAdapter = await _executionAdapterFactory(refreshedProject);
    _adapterCapabilities = normalizeCapabilitySnapshots([
      _projectGraphAdapter.capabilitySnapshot,
      executionAdapter.capabilitySnapshot,
      runtimeEventAdapter.capabilitySnapshot,
      ..._supplementalAdapterCapabilities,
    ]);
    workspaceController.replaceProject(
      refreshedProject,
      activeFilePath: workspaceController.activeFilePath,
    );
    final previousCompiler = previousProject.activeCompiler?.compilerVersion;
    final refreshedCompiler = refreshedProject.activeCompiler?.compilerVersion;
    appendLog(
      'Project graph refreshed: ${refreshedProject.title}'
      '${reason == null ? '' : ' ($reason)'}'
      '${previousCompiler == refreshedCompiler ? '' : ' · compiler ${previousCompiler ?? 'unresolved'} -> ${refreshedCompiler ?? 'unresolved'}'}.',
    );
  }

  Future<ToolchainCommandResult> installManagedCompiler({
    required String styioBinaryPath,
  }) async {
    final result = await _toolchainManagementAdapter.installManagedCompiler(
      projectGraph: workspaceController.activeProject,
      styioBinaryPath: styioBinaryPath,
    );
    return _completeToolchainCommand(
      result,
      refreshReason: 'tool install completed',
    );
  }

  Future<ToolchainCommandResult> useManagedCompiler({
    required String compilerVersion,
    String? channel,
  }) async {
    final result = await _toolchainManagementAdapter.useManagedCompiler(
      projectGraph: workspaceController.activeProject,
      compilerVersion: compilerVersion,
      channel: channel,
    );
    return _completeToolchainCommand(
      result,
      refreshReason: 'tool use completed',
    );
  }

  Future<ToolchainCommandResult> pinManagedCompiler({
    required String compilerVersion,
    String? channel,
  }) async {
    final result = await _toolchainManagementAdapter.pinManagedCompiler(
      projectGraph: workspaceController.activeProject,
      compilerVersion: compilerVersion,
      channel: channel,
    );
    return _completeToolchainCommand(
      result,
      refreshReason: 'tool pin completed',
    );
  }

  Future<ToolchainCommandResult> clearPinnedCompiler() async {
    final result = await _toolchainManagementAdapter.clearPinnedCompiler(
      projectGraph: workspaceController.activeProject,
    );
    return _completeToolchainCommand(
      result,
      refreshReason: 'tool pin clear completed',
    );
  }

  Future<ToolchainCommandResult> _completeToolchainCommand(
    ToolchainCommandResult result, {
    required String refreshReason,
  }) async {
    _lastToolchainCommand = result;
    appendLog(
      '${result.command} ${result.status.name}: ${result.statusMessage}',
    );
    if (result.succeeded) {
      await refreshProjectGraph(reason: refreshReason);
    } else {
      notifyListeners();
    }
    return result;
  }

  Future<DeploymentCommandResult> packProject({
    String? packageName,
    String? outputPath,
  }) async {
    final result = await _deploymentAdapter.packProject(
      projectGraph: workspaceController.activeProject,
      packageName: packageName,
      outputPath: outputPath,
    );
    return _completeDeploymentCommand(result);
  }

  Future<DeploymentCommandResult> preparePublish({
    String? packageName,
    String? outputPath,
  }) async {
    final result = await _deploymentAdapter.preparePublish(
      projectGraph: workspaceController.activeProject,
      packageName: packageName,
      outputPath: outputPath,
    );
    return _completeDeploymentCommand(result);
  }

  Future<DeploymentCommandResult> publishToRegistry({
    required String registryRoot,
    String? packageName,
    String? outputPath,
  }) async {
    final result = await _deploymentAdapter.publishToRegistry(
      projectGraph: workspaceController.activeProject,
      registryRoot: registryRoot,
      packageName: packageName,
      outputPath: outputPath,
    );
    return _completeDeploymentCommand(result);
  }

  Future<DeploymentCommandResult> _completeDeploymentCommand(
    DeploymentCommandResult result,
  ) async {
    _lastDeploymentCommand = result;
    appendLog(
      '${result.command} ${result.status.name}: ${result.statusMessage}',
    );
    if (result.payload case final payload?) {
      final packageName = payload['package'] as String?;
      final archivePath = payload['archive_path'] as String?;
      if (packageName != null && packageName.isNotEmpty) {
        appendLog('deploy package: $packageName');
      }
      if (archivePath != null && archivePath.isNotEmpty) {
        appendLog('deploy archive: $archivePath');
      }
    }
    notifyListeners();
    return result;
  }

  Future<DependencySourceCommandResult> fetchDependencies({
    bool locked = false,
    bool offline = false,
  }) async {
    final result = await _dependencySourceAdapter.fetchDependencies(
      projectGraph: workspaceController.activeProject,
      locked: locked,
      offline: offline,
    );
    return _completeDependencySourceCommand(
      result,
      refreshReason: 'fetch completed',
    );
  }

  Future<DependencySourceCommandResult> vendorDependencies({
    String? outputPath,
    bool locked = false,
    bool offline = false,
  }) async {
    final result = await _dependencySourceAdapter.vendorDependencies(
      projectGraph: workspaceController.activeProject,
      outputPath: outputPath,
      locked: locked,
      offline: offline,
    );
    return _completeDependencySourceCommand(
      result,
      refreshReason: 'vendor completed',
    );
  }

  Future<DependencySourceCommandResult> _completeDependencySourceCommand(
    DependencySourceCommandResult result, {
    required String refreshReason,
  }) async {
    _lastDependencySourceCommand = result;
    appendLog(
      '${result.command} ${result.status.name}: ${result.statusMessage}',
    );
    if (result.payload case final payload?) {
      final packages = payload['packages'];
      final vendorRoot = payload['vendor_root'] as String?;
      final metadataPath = payload['metadata_path'] as String?;
      if (packages is num) {
        appendLog('${result.command} packages: ${packages.toInt()}');
      }
      if (vendorRoot != null && vendorRoot.isNotEmpty) {
        appendLog('vendor root: $vendorRoot');
      }
      if (metadataPath != null && metadataPath.isNotEmpty) {
        appendLog('vendor metadata: $metadataPath');
      }
    }
    if (result.succeeded) {
      await refreshProjectGraph(reason: refreshReason);
    } else {
      notifyListeners();
    }
    return result;
  }

  Future<void> _loadActiveWorkspaceDocument() async {
    _documentCache[_activeDocumentPath] = editorController.document;
    final nextPath = workspaceController.activeFilePath;
    _activeDocumentPath = nextPath;
    final nextDocument =
        _documentCache[nextPath] ??
        await workspaceDocumentStore.loadDocument(nextPath);
    if (_activeDocumentPath != nextPath) {
      return;
    }
    editorController.loadDocument(nextDocument);
    appendLog(
      'Project route -> ${workspaceController.activeProject.title} / '
      '${workspaceController.activeFilePath}',
    );
  }

  @override
  void dispose() {
    workspaceController.removeListener(_handleWorkspaceChanged);
    editorController.removeListener(_handleDocumentChanged);
    super.dispose();
  }
}
