import 'dart:async';

import '../../ide/local_service/vityod_client.dart';
import '../../ide/workspace/workspace.dart';
import '../../view_ide/commands/commands.dart';
import '../../view_ide/interaction/interaction.dart';
import '../../view_ide/shell_runtime/shell_runtime.dart';
import 'shell_layout_plan.dart';

enum BottomSurfaceTab {
  runtime,
  commands,
  navigate,
  locations,
  documentLinks,
  documentHighlights,
  codeLenses,
  declarations,
  definitions,
  typeDefinitions,
  implementations,
  typeHierarchy,
  outline,
  rename,
  symbols,
  usages,
  calls,
  search,
  problems,
  actions,
  terminal,
  agent,
  sourceControl,
  testing,
  observable,
  extensions,
  debug,
  settings,
  commandPalette,
}

class ShellModel extends ShellRuntimeModel {
  ShellModel({
    required super.platformTarget,
    required super.supplementalAdapterCapabilities,
    required super.projectGraphAdapter,
    required super.workspaceController,
    required super.workspaceDocumentStore,
    required super.moduleRegistry,
    required super.nativeModuleLoader,
    super.extensionActivationSession,
    super.extensionHostSupervisorSnapshot,
    super.extensionHostLaunchResults,
    super.extensionHostTelemetryEvents,
    super.extensionMarketplaceRuntime,
    super.installedExtensionRegistry,
    required super.editorController,
    required super.executionAdapter,
    required super.executionAdapterFactory,
    required super.runtimeEventAdapter,
    required super.dependencySourceAdapter,
    required super.deploymentAdapter,
    super.terminalRuntimeRegistry,
    super.agentClientRegistry,
    super.agentCollaboration,
    super.runtimeOutputBuffer,
    super.refreshActiveLanguageService,
    super.styioServiceSubscriptionController,
    super.styioServiceDaemonProcessSupervisor,
    super.toolchainManager,
    super.editorSessionDataStore,
    super.editorSessionWorkspaceId,
    super.workspaceFileExplorerStateStore,
    super.documentCacheLimit,
    super.themeOverrideStore,
    super.commandPalettePreferencesStore,
    super.platformManagers,
    super.platformProbeRegistry,
    super.credentialStorageSettings,
    super.hostedControlPlaneClient,
    super.languageServiceStatus,
    super.toolchainStatusReport,
    super.clangCppVersionPreference,
    super.workspaceDiagnosticsController,
    super.testingSessionController,
    super.observableGraphController,
    super.sourceControlStatusController,
    super.projectLanguageService,
    super.debugAdapterLauncher,
    super.debugBreakpointStore,
    super.debugLaunchConfigurationStore,
    super.initialDebugLaunchProfiles,
    VityodClient? vityodClient,
    super.semanticPanelEventStateController,
    super.semanticPanelEventStore,
    super.semanticPanelEventWorkspaceId,
    super.workspaceQuickFixTelemetryStore,
    super.workspaceQuickFixTelemetryWorkspaceId,
    super.workspaceTextSearchProvider,
    ShellLayoutPreferenceController? shellLayoutPreferenceController,
    this.shellLayoutPreferencesStore,
  }) : vityodClient = vityodClient,
       shellLayoutPreferenceController =
           shellLayoutPreferenceController ??
           ShellLayoutPreferenceController(
             initialPreferences: const ShellLayoutPreferences(
               workspaceId: 'default',
             ),
           ) {
    _vityodStateSubscription = vityodClient?.states.listen((_) {
      notifyListeners();
    });
  }

  final ShellLayoutPreferenceController shellLayoutPreferenceController;
  final ShellLayoutPreferencesStore? shellLayoutPreferencesStore;
  final VityodClient? vityodClient;
  StreamSubscription<VityodConnectionState>? _vityodStateSubscription;
  Future<void> _shellLayoutSaveQueue = Future<void>.value();
  Future<void>? _shellLayoutLoadFuture;
  String? _shellLayoutLoadingWorkspaceId;
  bool _editorLanguageInspectorVisible = false;
  bool _shellLayoutDisposed = false;

  VityodConnectionState get localServiceConnection =>
      vityodClient?.state ?? const VityodConnectionState.disconnected();

  VityodServiceSnapshot? get localServiceSnapshot => vityodClient?.snapshot;

  Future<void> recoverServiceConnection() async {
    appendLog('Service recovery requested.');
    try {
      final client = vityodClient;
      if (client != null) {
        await client.connect();
      } else {
        await refreshProjectGraph(reason: 'service recovery');
      }
    } on Object {
      appendLog('Service recovery remains unavailable.');
      notifyListeners();
    }
  }

  @override
  Future<HostedBackendRetryActionExecutionResult> executeHostedBackendAction(
    HostedBackendRetryAction action,
  ) async {
    final result = await super.executeHostedBackendAction(action);
    if (action.kind == HostedBackendRetryActionKind.openSettings) {
      selectWorkbenchRoute(BottomSurfaceTab.settings);
    }
    return result;
  }

  @override
  void dispose() {
    _shellLayoutDisposed = true;
    unawaited(_vityodStateSubscription?.cancel());
    _vityodStateSubscription = null;
    super.dispose();
  }

  BottomSurfaceTab get activeWorkbenchRoute =>
      shellLayoutPreferenceController.preferences.activeWorkbenchRoute;

  bool get editorLanguageInspectorVisible => _editorLanguageInspectorVisible;

  void toggleEditorLanguageInspector() {
    _editorLanguageInspectorVisible = !_editorLanguageInspectorVisible;
    notifyListeners();
  }

  void selectWorkbenchRoute(BottomSurfaceTab route) {
    if (activeWorkbenchRoute == route) {
      if (_isDockedWorkbenchRoute(route)) {
        final expanded =
            shellLayoutPreferenceController.preferences.bottomPanelExpanded;
        shellLayoutPreferenceController.setBottomPanelExpanded(!expanded);
        appendLog('Bottom surface ${expanded ? "collapsed" : "expanded"}.');
        unawaited(persistShellLayoutPreferences());
      }
      return;
    }
    shellLayoutPreferenceController.selectWorkbenchRoute(route);
    // Mobile presents every workbench destination through the bottom surface,
    // while desktop routes some destinations into the primary sidebar. Keeping
    // the preference expanded here serves both layouts without coupling the
    // shared model to a viewport family.
    shellLayoutPreferenceController.setBottomPanelExpanded(true);
    appendLog('Workbench route switched to ${route.name}.');
    unawaited(persistShellLayoutPreferences());
  }

  Future<void> loadShellLayoutPreferences() {
    final store = shellLayoutPreferencesStore;
    if (store == null) {
      return Future<void>.value();
    }
    final workspaceId = workspaceController.activeProject.id;
    final inFlight = _shellLayoutLoadFuture;
    if (_shellLayoutLoadingWorkspaceId == workspaceId && inFlight != null) {
      return inFlight;
    }
    late final Future<void> loadFuture;
    loadFuture =
        _restoreShellLayoutPreferences(
          store: store,
          workspaceId: workspaceId,
        ).whenComplete(() {
          if (identical(_shellLayoutLoadFuture, loadFuture)) {
            _shellLayoutLoadFuture = null;
            _shellLayoutLoadingWorkspaceId = null;
          }
        });
    _shellLayoutLoadingWorkspaceId = workspaceId;
    _shellLayoutLoadFuture = loadFuture;
    return loadFuture;
  }

  Future<void> _restoreShellLayoutPreferences({
    required ShellLayoutPreferencesStore store,
    required String workspaceId,
  }) async {
    final revisionBeforeLoad = shellLayoutPreferenceController.revision;
    try {
      final preferences = await store.readPreferences(workspaceId: workspaceId);
      if (shellLayoutPreferenceController.revision == revisionBeforeLoad) {
        shellLayoutPreferenceController.hydrate(preferences);
        appendLog('Workbench layout restored for $workspaceId.');
      } else {
        await persistShellLayoutPreferences();
      }
    } on Object catch (error) {
      appendLog('Workbench layout restore failed: $error');
    }
  }

  Future<void> persistShellLayoutPreferences() {
    final store = shellLayoutPreferencesStore;
    if (store == null) {
      return Future<void>.value();
    }
    final snapshot = shellLayoutPreferenceController.preferences.copyWith(
      workspaceId: workspaceController.activeProject.id,
    );
    _shellLayoutSaveQueue = _shellLayoutSaveQueue.then((_) async {
      try {
        await store.savePreferences(snapshot);
      } on Object catch (error) {
        if (!_shellLayoutDisposed) {
          appendLog('Workbench layout save failed: $error');
        }
      }
    });
    return _shellLayoutSaveQueue;
  }

  void setPrimarySidebarVisible(bool visible) {
    if (!shellLayoutPreferenceController.setPrimarySidebarVisible(visible)) {
      return;
    }
    appendLog('Primary sidebar ${visible ? "opened" : "closed"}.');
    unawaited(persistShellLayoutPreferences());
  }

  void activatePrimarySidebar(BottomSurfaceTab route) {
    final preferences = shellLayoutPreferenceController.preferences;
    if (activeWorkbenchRoute == route && preferences.primarySidebarVisible) {
      setPrimarySidebarVisible(false);
      return;
    }
    shellLayoutPreferenceController.selectWorkbenchRoute(route);
    shellLayoutPreferenceController.setPrimarySidebarVisible(true);
    appendLog('Primary sidebar switched to ${route.name}.');
    unawaited(persistShellLayoutPreferences());
  }

  void resizePrimarySidebar(double width) {
    if (shellLayoutPreferenceController.setPrimarySidebarWidth(width)) {
      notifyListeners();
    }
  }

  void resizeBottomPanel(double height) {
    if (shellLayoutPreferenceController.setBottomPanelHeight(height)) {
      notifyListeners();
    }
  }

  Future<void> commitShellLayoutResize() {
    appendLog('Workbench layout dimensions updated.');
    return persistShellLayoutPreferences();
  }

  void setBottomPanelExpanded(bool expanded) {
    if (!shellLayoutPreferenceController.setBottomPanelExpanded(expanded)) {
      return;
    }
    appendLog('Bottom surface ${expanded ? "expanded" : "collapsed"}.');
    unawaited(persistShellLayoutPreferences());
  }

  @override
  Future<void> handleToolchainRecoveryAction(
    ToolchainRecoveryAction action,
  ) async {
    await super.handleToolchainRecoveryAction(action);
    if (action.id == 'show-toolchain-logs') {
      selectWorkbenchRoute(BottomSurfaceTab.debug);
    } else if (action.id == 'select-existing-toolchain' ||
        action.id == 'configure-managed-download' ||
        action.id == 'enable-toolchain-installation' ||
        action.id == 'install-managed-toolchain') {
      selectWorkbenchRoute(BottomSurfaceTab.settings);
    }
  }

  @override
  Future<void> executeCommand(AppCommandId commandId) async {
    switch (commandId) {
      case AppCommandId.showRuntime:
        selectWorkbenchRoute(BottomSurfaceTab.runtime);
        return;
      case AppCommandId.showAgent:
        selectWorkbenchRoute(BottomSurfaceTab.agent);
        return;
      case AppCommandId.searchWorkspace:
        selectWorkbenchRoute(BottomSurfaceTab.search);
        appendLog('Workspace search surface opened.');
        return;
      case AppCommandId.showDebug:
        selectWorkbenchRoute(BottomSurfaceTab.debug);
        return;
      case AppCommandId.openSettings:
        selectWorkbenchRoute(BottomSurfaceTab.settings);
        appendLog('Settings surface opened.');
        return;
      case AppCommandId.openFile:
      case AppCommandId.reloadFile:
      case AppCommandId.commandPalette:
      case AppCommandId.acceptExternalChange:
        await super.executeCommand(commandId);
        selectWorkbenchRoute(BottomSurfaceTab.commandPalette);
        return;
      case AppCommandId.quickOpen:
        await super.executeCommand(commandId);
        selectWorkbenchRoute(BottomSurfaceTab.navigate);
        return;
      case AppCommandId.showRecentLocations:
      case AppCommandId.showWorkspaceDocumentLinks:
      case AppCommandId.showWorkspaceDocumentHighlights:
      case AppCommandId.showWorkspaceCodeLenses:
      case AppCommandId.goToWorkspaceDeclaration:
      case AppCommandId.goToWorkspaceDefinition:
      case AppCommandId.goToWorkspaceTypeDefinition:
      case AppCommandId.goToWorkspaceImplementation:
      case AppCommandId.showWorkspaceTypeHierarchy:
      case AppCommandId.navigateBack:
      case AppCommandId.navigateForward:
      case AppCommandId.showWorkspaceOutline:
      case AppCommandId.renameWorkspaceSymbol:
      case AppCommandId.searchWorkspaceSymbols:
      case AppCommandId.findWorkspaceReferences:
      case AppCommandId.showWorkspaceCallHierarchy:
        await super.executeCommand(commandId);
        return;
      case AppCommandId.save:
      case AppCommandId.saveAll:
      case AppCommandId.run:
        await super.executeCommand(commandId);
        if (commandId == AppCommandId.run) {
          selectWorkbenchRoute(BottomSurfaceTab.runtime);
        }
        return;
      case AppCommandId.showWorkspaceProblems:
        await super.executeCommand(commandId);
        selectWorkbenchRoute(BottomSurfaceTab.problems);
        return;
      case AppCommandId.showWorkspaceCodeActions:
        await super.executeCommand(commandId);
        selectWorkbenchRoute(BottomSurfaceTab.problems);
        return;
      case AppCommandId.toggleBreakpoint:
      case AppCommandId.startDebugging:
      case AppCommandId.stopDebugging:
      case AppCommandId.continueDebugging:
      case AppCommandId.stepOver:
      case AppCommandId.selectDebugThread:
      case AppCommandId.selectDebugStackFrame:
      case AppCommandId.nextDiagnostic:
      case AppCommandId.previousDiagnostic:
      case AppCommandId.applyQuickFix:
      case AppCommandId.previewQuickFix:
      case AppCommandId.refreshLanguageService:
      case AppCommandId.refreshWorkspaceDiagnostics:
      case AppCommandId.refreshSourceControl:
      case AppCommandId.previewSourceControlDiff:
      case AppCommandId.stageSourceControl:
      case AppCommandId.unstageSourceControl:
      case AppCommandId.planSourceControlBranchSwitch:
      case AppCommandId.planSourceControlCommitDraft:
      case AppCommandId.collectProjectLanguageContext:
      case AppCommandId.goToDefinition:
      case AppCommandId.openWorkspaceFile:
      case AppCommandId.createWorkspaceFile:
      case AppCommandId.renameWorkspaceFile:
      case AppCommandId.deleteWorkspaceFile:
      case AppCommandId.revealWorkspaceFile:
      case AppCommandId.previewWorkspaceReplace:
      case AppCommandId.applyWorkspaceReplace:
      case AppCommandId.runBuild:
      case AppCommandId.formatActiveDocument:
      case AppCommandId.runStaticAnalysis:
      case AppCommandId.runTests:
      case AppCommandId.rerunFailedTests:
      case AppCommandId.debugFailedTests:
      case AppCommandId.runTestConfiguration:
      case AppCommandId.debugTestConfiguration:
      case AppCommandId.nextReference:
      case AppCommandId.previousReference:
      case AppCommandId.renameSymbol:
      case AppCommandId.safeDelete:
      case AppCommandId.inlineVariable:
      case AppCommandId.syncDependencies:
      case AppCommandId.vendorDependencies:
      case AppCommandId.executeToolchainInstallPlan:
      case AppCommandId.selectClangCppVersion:
      case AppCommandId.packProject:
      case AppCommandId.preparePublish:
      case AppCommandId.refreshModules:
        await super.executeCommand(commandId);
        return;
      case AppCommandId.runSelectedTarget:
        await super.executeCommand(commandId);
        selectWorkbenchRoute(BottomSurfaceTab.runtime);
        return;
      default:
        await super.executeCommand(commandId);
        return;
    }
  }
}

bool _isDockedWorkbenchRoute(BottomSurfaceTab route) {
  return switch (route) {
    BottomSurfaceTab.runtime ||
    BottomSurfaceTab.terminal ||
    BottomSurfaceTab.commandPalette ||
    BottomSurfaceTab.problems ||
    BottomSurfaceTab.testing ||
    BottomSurfaceTab.debug ||
    BottomSurfaceTab.agent => true,
    _ => false,
  };
}
