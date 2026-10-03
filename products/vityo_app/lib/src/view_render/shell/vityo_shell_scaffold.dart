import 'dart:async';

import 'package:flutter/material.dart';

import '../../ide/local_service/vityod_client.dart';
import '../../presentation/agent_workbench/task_center.dart';
import '../commands/command_palette_surface.dart';
import '../editor/editor.dart';
import '../extensions/extensions.dart';
import '../../view_ide/backend_toolchain/adapter_contracts.dart';
import '../../view_ide/backend_toolchain/dependency_source_adapter.dart';
import '../../view_ide/backend_toolchain/deployment_adapter.dart';
import '../../view_ide/backend_toolchain/execution_adapter.dart';
import '../../view_ide/backend_toolchain/execution_route_summary.dart';
import '../../view_ide/backend_toolchain/project_graph_contract.dart';
import '../../view_ide/backend_toolchain/required_handoff_summary.dart';
import '../../view_ide/interaction/interaction.dart';
import 'package:vityo_app/src/view_ide/module_host/module_definition.dart';
import 'package:vityo_app/src/view_ide/module_host/module_manifest.dart';
import 'package:vityo_app/src/view_ide/platform/platform_target.dart';
import '../platform/platform.dart';
import '../problems/problems.dart';
import '../runtime/runtime.dart';
import '../search/search.dart';
import '../settings/settings_surface.dart';
import '../source_control/source_control.dart';
import '../terminal/terminal.dart';
import '../testing/testing.dart';
import '../theme/vityo_theme.dart';
import '../observable/observable.dart';
import '../../view_ide/services/observable_topology/observable_topology.dart';
import '../../ide/workspace/workspace.dart';

import 'hosted_workspace_lifecycle_banner.dart';
import '../../app/commands/app_commands.dart';
import 'shell_layout_plan.dart';
import 'shell_model.dart';
import 'shell_scope.dart';
import 'workbench_regions/workbench_regions.dart';

part 'explorer_sidebar.dart';

class VityoShellScaffold extends StatelessWidget {
  const VityoShellScaffold({super.key});

  @override
  Widget build(BuildContext context) {
    final shell = ShellScope.of(context);
    final project = shell.workspaceController.activeProject;
    final hostedClosePlan = const HostedWorkspaceLifecycle().closePlanFor(
      project,
    );
    final viewportProfile = resolveViewportProfile(
      platformTarget: shell.platformTarget,
      width: MediaQuery.sizeOf(context).width,
      height: MediaQuery.sizeOf(context).height,
    );
    final servicePresentation = _servicePresentationFor(shell);
    final activeFileLabel = _fileName(shell.workspaceController.activeFilePath);
    final activeFileDisplayPath = _workspaceDisplayPath(
      workspaceRoot: project.workspaceRoot,
      filePath: shell.workspaceController.activeFilePath,
    );
    final caret = shell.editorController.document.positionForOffset(
      shell.editorController.selection.extentOffset,
    );
    final languageStatus = shell.languageServiceStatus.value;

    return Shortcuts(
      shortcuts: AppCommandShortcutRegistry.shortcutIntents,
      child: Actions(
        actions: <Type, Action<Intent>>{
          AppCommandIntent: CallbackAction<AppCommandIntent>(
            onInvoke: (intent) {
              shell.executeCommand(intent.commandId);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: SafeArea(
              child: Padding(
                padding: viewportProfile.isMobile
                    ? const EdgeInsets.all(18)
                    : EdgeInsets.zero,
                child: Column(
                  children: [
                    if (!viewportProfile.isMobile)
                      WorkbenchTitleBar(
                        title: activeFileLabel.isEmpty
                            ? project.title
                            : '${project.title} · $activeFileLabel',
                        commandHint: 'Search files or run a command',
                        connectionLabel: servicePresentation.label,
                        status: servicePresentation.status,
                        actions: _buildTitleCommandActions(context, shell),
                        onOpenCommands: () {
                          shell.selectWorkbenchRoute(
                            BottomSurfaceTab.commandPalette,
                          );
                        },
                      ),
                    if (servicePresentation.status != WorkbenchStatus.ready)
                      _ServiceStateBanner(
                        presentation: servicePresentation,
                        onRecover: shell.recoverServiceConnection,
                      ),
                    if (hostedClosePlan != null) ...[
                      Padding(
                        padding: viewportProfile.isMobile
                            ? EdgeInsets.zero
                            : const EdgeInsets.fromLTRB(14, 10, 14, 0),
                        child: HostedWorkspaceLifecycleBanner(
                          plan: hostedClosePlan,
                          connectorReport: shell.hostedBackendConnectorReport,
                          onRetryAction: shell.hostedBackendActionRunning
                              ? null
                              : (action) async {
                                  await shell.executeHostedBackendAction(
                                    action,
                                  );
                                },
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final layoutViewport = resolveViewportProfile(
                            platformTarget: shell.platformTarget,
                            width: constraints.maxWidth,
                            height: constraints.maxHeight,
                          );
                          final layoutBinding = shell
                              .shellLayoutPreferenceController
                              .renderBindingForViewport(
                                compact: layoutViewport.isMobile,
                              );

                          if (layoutViewport.isMobile) {
                            return _MobileShellBody(
                              shell: shell,
                              viewportProfile: layoutViewport,
                              layoutBinding: layoutBinding,
                              bottomSurface: _buildBottomSurface(
                                shell,
                                layoutViewport,
                              ),
                            );
                          }

                          return _DesktopShellBody(
                            shell: shell,
                            viewportProfile: layoutViewport,
                            layoutBinding: layoutBinding,
                            bottomSurface: _buildBottomSurface(
                              shell,
                              layoutViewport,
                            ),
                          );
                        },
                      ),
                    ),
                    WorkbenchStatusBar(
                      leading:
                          '$activeFileDisplayPath  Ln ${caret.line + 1}, Col ${caret.column + 1}',
                      trailing:
                          '${shell.editorController.analysis.diagnosticCount} problems · ${_languageStatusLabel(languageStatus)} · ${shell.platformTarget.label}',
                      status: servicePresentation.status,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildTitleCommandActions(
    BuildContext context,
    ShellModel shell,
  ) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);
    const titleCommandIds = <AppCommandId>{
      AppCommandId.save,
      AppCommandId.saveAll,
      AppCommandId.run,
      AppCommandId.syncDependencies,
      AppCommandId.vendorDependencies,
      AppCommandId.refreshModules,
    };
    return <Widget>[
      for (final command in VityoCommandRegistry.primaryCommands.where(
        (command) => titleCommandIds.contains(command.id),
      ))
        Tooltip(
          message:
              shell.blockedReasonForCommand(command.id) ??
              '${command.description} (${command.shortcutHint})',
          child: IconButton(
            key: ValueKey('command-strip-${command.id.name}'),
            visualDensity: VisualDensity.compact,
            hoverColor: tokens.hover,
            onPressed: shell.blockedReasonForCommand(command.id) == null
                ? () => shell.executeCommand(command.id)
                : null,
            icon: Icon(
              _commandIcon(command.id),
              size: 17,
              color: shell.blockedReasonForCommand(command.id) == null
                  ? tokens.muted
                  : theme.disabledColor,
            ),
          ),
        ),
      Tooltip(
        message: 'Open settings and profile routes. (Cmd/Ctrl+,)',
        child: IconButton(
          key: const ValueKey('command-strip-openSettings'),
          visualDensity: VisualDensity.compact,
          hoverColor: tokens.hover,
          onPressed: () => shell.executeCommand(AppCommandId.openSettings),
          icon: Icon(
            Icons.settings_outlined,
            size: 17,
            color: tokens.muted,
          ),
        ),
      ),
    ];
  }

  Widget _buildBottomSurface(
    ShellModel shell,
    ViewportProfile viewportProfile,
  ) {
    switch (shell.activeWorkbenchRoute) {
      case BottomSurfaceTab.runtime:
        return RuntimeSurface(
          platformTarget: shell.platformTarget,
          viewportProfile: viewportProfile,
          projectGraph: shell.workspaceController.activeProject,
          toolchainStatus: shell.toolchainStatusSurface,
          onToolchainRecoveryAction: shell.handleToolchainRecoveryAction,
          mountedModules: shell.mountedModules,
          adapterCapabilities: shell.adapterCapabilities,
          executionSession: shell.lastExecutionSession,
          executionRunActive: shell.executionRunActive,
          executionCanCancel: shell.executionCanCancel,
          onRunExecution: () => shell.executeCommand(AppCommandId.run),
          onCancelExecution: () async {
            await shell.cancelActiveExecution();
          },
          runtimeEvents: shell.lastRuntimeEvents,
          nativeToolResults: shell.nativeToolResults,
          outputSnapshot: shell.runtimeOutputBuffer.snapshot,
          onOpenNativeToolDiagnostics: shell.openFirstNativeToolDiagnostic,
        );
      case BottomSurfaceTab.terminal:
        return TerminalSurface(
          viewportProfile: viewportProfile,
          logEntries: shell.debugLog,
          runtimeEventSummaries: shell.lastRuntimeEvents
              .map(_terminalRuntimeEventSummary)
              .toList(growable: false),
          onRunActiveTarget: () {
            return shell.executeCommand(AppCommandId.run);
          },
        );
      case BottomSurfaceTab.commandPalette:
        return CommandPaletteSurface(
          viewportProfile: viewportProfile,
          onExecuteCommand: shell.executeCommand,
          onExecuteCommandWithInput: shell.executeCommandWithInput,
          blockedReasonForCommand: shell.blockedReasonForCommand,
        );
      case BottomSurfaceTab.agent:
        return TaskCenter(collaboration: shell.agentCollaboration);
      case BottomSurfaceTab.sourceControl:
        final sourceControlController = shell.sourceControlStatusController;
        Widget buildSourceControlSurface() {
          return SourceControlSurface(
            viewportProfile: viewportProfile,
            workspaceFileCount: shell.workspaceController.files.length,
            changedDocumentIds: shell.dirtyDocumentPaths,
            status: shell.sourceControlStatusSnapshot,
            diffPreview: shell.sourceControlDiffPreview,
            commitDraft: shell.sourceControlCommitDraft,
            commitDialogState: shell.sourceControlCommitDialogState,
            branchSnapshot: shell.sourceControlBranchSnapshot,
            historySnapshot: shell.sourceControlHistorySnapshot,
            lastHunkActionResult: shell.sourceControlHunkActionResult,
            mergeWorkflowPlan: shell.sourceControlMergeWorkflowPlan,
            mergeEditorSnapshot: shell.sourceControlMergeEditorSnapshot,
            lastConflictResolutionResult:
                shell.sourceControlConflictResolutionResult,
            onOpenFile: shell.openWorkspaceFile,
            onSaveAll: () {
              return shell.executeCommand(AppCommandId.saveAll);
            },
            onRefresh: () {
              return shell.executeCommand(AppCommandId.refreshSourceControl);
            },
            onPreviewDiff: shell.previewSourceControlDiff,
            onStagePaths: shell.stageSourceControlPaths,
            onUnstagePaths: shell.unstageSourceControlPaths,
            onSwitchBranch: (plan) {
              return shell.planSourceControlBranchSwitch(plan.targetBranch);
            },
            onOpenCommit: () async {
              shell.planSourceControlCommitDraft(message: '');
            },
            onConfirmDiffAction: shell.confirmSourceControlDiffAction,
            pendingHunkDiscardConfirmation:
                sourceControlController?.pendingHunkDiscardConfirmation,
            onSelectHunkAction: shell.planSourceControlHunkAction,
            onConfirmHunkDiscard: () async {
              await shell.confirmPendingSourceControlHunkDiscard();
            },
            onOpenMergeEditor: (plan) async {
              await shell.openSourceControlMergeEditor(plan);
            },
            onApplyConflictResolution:
                (plan, kind, resultText, expectedWorkingRevision) async {
                  await shell.resolveSourceControlConflict(
                    plan: plan,
                    kind: kind,
                    resultText: resultText,
                    expectedWorkingRevision: expectedWorkingRevision,
                  );
                },
            onCloseMergeEditor: shell.closeSourceControlMergeEditor,
          );
        }

        if (sourceControlController == null) {
          return buildSourceControlSurface();
        }
        return ListenableBuilder(
          listenable: sourceControlController,
          builder: (_, _) => buildSourceControlSurface(),
        );
      case BottomSurfaceTab.search:
        return WorkspaceSearchSurface(
          viewportProfile: viewportProfile,
          workspaceFileCount: shell.workspaceController.files.length,
          workspaceFiles: shell.workspaceController.files,
          lastSearch: shell.lastWorkspaceSearch,
          lastSymbolSearch: shell.lastWorkspaceSymbolSearch,
          lastSearchQuery: shell.lastWorkspaceSearchQuery,
          lastSearchScannedDocumentCount: shell.lastWorkspaceSearchScannedCount,
          lastReplacePreview: shell.lastWorkspaceReplacePreview,
          searchIndex: shell.workspaceSearchIndex,
          watcherSnapshot: shell.workspaceSearchWatcherSnapshot,
          onSearch: shell.searchWorkspace,
          onRecoverWatcher: shell.recoverWorkspaceSearchWatcher,
          onOpenFile: shell.openWorkspaceFile,
          onPreviewReplace: (query, replacement) async {
            await shell.previewWorkspaceReplace(
              query: query,
              replacement: replacement,
            );
          },
          onApplyReplacePreview: shell.applyWorkspaceReplacePreview,
          onOpenMatch: (match) => shell.openWorkspaceFile(match.documentId),
          onOpenSymbolMatch: (match) =>
              shell.openWorkspaceFile(match.documentId),
        );
      case BottomSurfaceTab.problems:
        final diagnosticsController = shell.workspaceDiagnosticsController;
        Widget buildProblemsSurface() {
          return ProblemsSurface(
            viewportProfile: viewportProfile,
            documentId: shell.editorController.document.documentId,
            diagnostics: shell.editorController.analysis.diagnostics,
            workspaceDiagnostics: shell.workspaceDiagnosticsSnapshot,
            diagnosticsProducerLifecycles: shell.diagnosticsProducerLifecycles,
            onSelectDiagnostic: shell.editorController.selectDiagnostic,
            onSelectWorkspaceDiagnostic: (diagnostic) {
              shell.selectWorkspaceDiagnostic(diagnostic);
            },
            workspaceEditPreview: shell.lastWorkspaceEditPreview,
            workspaceEditApplyResult: shell.lastWorkspaceEditApplyResult,
            quickFixTelemetry: shell.workspaceQuickFixTelemetrySnapshot,
            semanticSnapshotPanelViewModel:
                shell.semanticProblemsPanelViewModel,
            onRefreshWorkspaceDiagnostics: () {
              return shell.executeCommand(
                AppCommandId.refreshWorkspaceDiagnostics,
              );
            },
            onCancelDiagnosticsProducer:
                shell.cancelWorkspaceDiagnosticsProducer,
            onPreviewWorkspaceQuickFix: () async {
              await shell.executeCommand(AppCommandId.previewQuickFix);
            },
            onApplyWorkspaceQuickFix: () {
              return shell.executeCommand(AppCommandId.applyQuickFix);
            },
            onPreviewDiagnosticQuickFix: (route) async {
              shell.selectWorkspaceDiagnostic(route.diagnostic);
              await shell.executeCommand(AppCommandId.previewQuickFix);
            },
            onApplyDiagnosticQuickFix: (route) async {
              shell.selectWorkspaceDiagnostic(route.diagnostic);
              await shell.executeCommand(AppCommandId.applyQuickFix);
            },
          );
        }

        if (diagnosticsController == null) {
          return buildProblemsSurface();
        }
        return ListenableBuilder(
          listenable: diagnosticsController,
          builder: (_, _) => buildProblemsSurface(),
        );
      case BottomSurfaceTab.testing:
        final testingController = shell.testingSessionController;
        Widget buildTestingSurface() {
          return TestingSurface(
            viewportProfile: viewportProfile,
            nativeToolResults: shell.nativeToolResults,
            discovery: shell.testDiscovery,
            lastRun: shell.lastTestRun,
            runHistory: shell.testRunHistory,
            failedRetryHistory: shell.failedTestRetryHistory,
            configurationSet: shell.testRunConfigurationSet,
            failedDebugCancellationRoute: shell.failedDebugCancellationRoute,
            testRunActive: shell.testRunActive,
            onRunTests: () {
              return shell.executeCommand(AppCommandId.runTests);
            },
            onRunConfiguration: shell.runTestConfiguration,
            onDebugConfiguration: (configuration) async {
              await shell.debugTestConfiguration(configuration);
              shell.selectWorkbenchRoute(BottomSurfaceTab.debug);
            },
            onCancelFailedTestDebug: shell.cancelFailedTestDebug,
            onRerunFailed: () {
              return shell.rerunFailedTests();
            },
            onSelectRunConfiguration: shell.selectTestRunConfiguration,
            onSelectFailedTest: (_) {
              shell.openFirstNativeToolDiagnostic(AppCommandId.runTests);
            },
            onOpenDiagnostics: () {
              shell.openFirstNativeToolDiagnostic(AppCommandId.runTests);
            },
          );
        }

        if (testingController == null) {
          return buildTestingSurface();
        }
        return ListenableBuilder(
          listenable: testingController,
          builder: (_, _) => buildTestingSurface(),
        );
      case BottomSurfaceTab.observable:
        final observableController = shell.observableGraphController;
        Widget buildObservableSurface() {
          return ObservableGraphSurface(
            viewportProfile: viewportProfile,
            state: shell.observableGraphState,
            onRefresh: observableController == null
                ? null
                : () {
                    observableController.refreshNow();
                  },
            onSelectNode: observableController?.selectNode,
            onOpenAnchor: observableController == null
                ? null
                : (nodeId) {
                    final path = observableController.resolvedAnchorPath(
                      nodeId,
                    );
                    if (path != null) {
                      shell.openWorkspaceFile(path);
                    }
                  },
            onRunObserved: observableController == null
                ? null
                : (mode) {
                    shell.runObservedProgram(mode);
                  },
            observationUnavailableReason:
                observableController == null ||
                    observableController.runtimeObservationDecision.available
                ? null
                : observableController
                      .runtimeObservationDecision
                      .reason
                      ?.wireValue,
          );
        }

        if (observableController == null) {
          return buildObservableSurface();
        }
        return ListenableBuilder(
          listenable: observableController,
          builder: (_, _) => buildObservableSurface(),
        );
      case BottomSurfaceTab.extensions:
        return ExtensionsSurface(
          viewportProfile: viewportProfile,
          visibleModules: shell.visibleModules,
          mountedModules: shell.mountedModules,
          moduleStates: shell.moduleStates,
          activationSession: shell.extensionActivationSession,
          supervisorSnapshot: shell.extensionHostSupervisorSnapshot,
          launchResults: shell.extensionHostLaunchResults,
          telemetryEvents: shell.extensionHostTelemetryEvents,
          marketplaceIndex: shell.extensionMarketplaceIndex,
          installedExtensionRegistry: shell.installedExtensionRegistry,
          marketplaceQuery: shell.extensionMarketplaceQuery,
          marketplaceMessage: shell.extensionMarketplaceMessage,
          marketplaceBusy: shell.extensionMarketplaceBusy,
          lastMarketplaceInstallResult:
              shell.lastExtensionMarketplaceInstallResult,
          onRefreshModules: () {
            return shell.executeCommand(AppCommandId.refreshModules);
          },
          onRefreshMarketplace: shell.refreshExtensionMarketplace,
          onMarketplaceQueryChanged: shell.setExtensionMarketplaceQuery,
          onEnableModule: shell.enableModule,
          onDisableModule: shell.disableModule,
          onTrustModule: shell.trustModule,
          onInstallExtension: shell.installMarketplaceExtension,
          onUpdateExtension: shell.updateMarketplaceExtension,
        );
      case BottomSurfaceTab.debug:
        return DebugConsoleSurface(
          viewportProfile: viewportProfile,
          entries: shell.debugLog,
          runtimeEvents: shell.lastRuntimeEvents,
          debugSession: shell.debugSession,
          debugRuntimeExecution: shell.lastDebugRuntimeExecutionResult,
          debugLaunchConfigurations: shell.debugLaunchConfigurations,
          onStartDebugging: () {
            return shell.executeCommand(AppCommandId.startDebugging);
          },
          onRetryDebugLaunch: () {
            return shell.executeCommand(AppCommandId.startDebugging);
          },
          onStopDebugging: () {
            return shell.executeCommand(AppCommandId.stopDebugging);
          },
          onForceStopDebugging: () async {
            await shell.forceStopDebugging();
          },
          onContinueDebugging: () {
            return shell.executeCommand(AppCommandId.continueDebugging);
          },
          onStepOver: () {
            return shell.executeCommand(AppCommandId.stepOver);
          },
          onSelectLaunchProfile: shell.selectDebugLaunchProfile,
          onUpdateLaunchConfiguration: shell.updateDebugLaunchConfiguration,
          onSaveBreakpoint: shell.saveDebugBreakpoint,
          onRemoveBreakpoint: shell.removeDebugBreakpoint,
          onSetBreakpointEnabled: shell.setDebugBreakpointEnabled,
          onSelectStackFrame: (frameId) {
            shell.selectDebugStackFrame(frameId);
          },
          onSelectThread: (threadId) {
            shell.selectDebugThread(threadId);
          },
        );
      case BottomSurfaceTab.settings:
        return SettingsSurface(
          viewportProfile: viewportProfile,
          toolchainStatus: shell.toolchainStatusSurface,
          toolchainSettings: shell.toolchainSettingsSurface,
          toolchainInstallPlan: shell.toolchainInstallPlanSurface,
          toolchainInstallExecution: shell.toolchainInstallExecutionSurface,
          toolchainBootstrapSummary: shell.toolchainBootstrapSummary,
          toolchainBootstrapActionDispatch:
              shell.lastToolchainBootstrapActionDispatch,
          platformManagerSettings: shell.platformManagerSettingsSurface,
          credentialStorageSettings: shell.credentialStorageSettingsSurface,
          extensionMarketplacePreferences:
              shell.extensionMarketplacePreferences,
          extensionMarketplaceMessage: shell.extensionMarketplaceMessage,
          extensionMarketplaceBusy: shell.extensionMarketplaceBusy,
          hostedBackendConnector: shell.hostedBackendConnectorReport,
          hostedBackendActionResult: shell.lastHostedBackendActionResult,
          hostedBackendActionRunning: shell.hostedBackendActionRunning,
          platformManagerProbeRunning: shell.platformManagerProbeRunning,
          themeOverride: shell.themeOverride,
          commandPalettePreferences: shell.commandPalettePreferences,
          onToolchainRecoveryAction: shell.handleToolchainRecoveryAction,
          onToolchainBootstrapAction: shell.handleToolchainBootstrapAction,
          onSelectToolchain: shell.selectToolchainCandidate,
          onSelectClangCppVersion: (versionId, cppStandard) {
            return shell.selectClangCppVersion(
              versionId,
              cppStandard: cppStandard,
            );
          },
          onClearToolchain: shell.clearToolchainCandidate,
          onExecuteToolchainInstallPlan:
              shell.executeConfirmedToolchainInstallPlan,
          onRefreshPlatformManagers: shell.refreshPlatformManagerHealth,
          onPlatformRecoveryRoute: shell.handlePlatformRecoveryRoute,
          onSelectPlatformSettingsSection: shell.selectPlatformSettingsSection,
          onSaveExtensionMarketplacePreferences:
              shell.saveExtensionMarketplacePreferences,
          onRefreshExtensionMarketplace: shell.refreshExtensionMarketplace,
          onHostedBackendAction: (action) async {
            await shell.executeHostedBackendAction(action);
          },
          onSaveCommandPalettePreferences: shell.saveCommandPalettePreferences,
          onSaveThemeOverride: shell.saveThemeOverride,
        );
      case BottomSurfaceTab.navigate:
      case BottomSurfaceTab.locations:
      default:
        return const SizedBox.shrink();
    }
  }
}

class _DesktopShellBody extends StatelessWidget {
  const _DesktopShellBody({
    required this.shell,
    required this.viewportProfile,
    required this.layoutBinding,
    required this.bottomSurface,
  });

  final ShellModel shell;
  final ViewportProfile viewportProfile;
  final ShellLayoutRenderBinding layoutBinding;
  final Widget bottomSurface;

  @override
  Widget build(BuildContext context) {
    final denseDesktop = viewportProfile.width < 1440;
    final primarySidebarVisible =
        viewportProfile.width >= 760 && layoutBinding.primarySidebarVisible;
    final primaryToolSurface = _usesPrimarySidebar(shell.activeWorkbenchRoute);
    final primarySidebarMaximum = viewportProfile.width * 0.42;
    final workspaceWidth = layoutBinding.primarySidebarWidth
        .clamp(
          ShellLayoutPreferences.minPrimarySidebarWidth,
          primarySidebarMaximum < ShellLayoutPreferences.maxPrimarySidebarWidth
              ? primarySidebarMaximum
              : ShellLayoutPreferences.maxPrimarySidebarWidth,
        )
        .toDouble();
    final bottomPanelMaximum = viewportProfile.height * 0.62;
    final bottomSurfaceHeight = layoutBinding.bottomPanelHeight
        .clamp(
          ShellLayoutPreferences.minBottomPanelHeight,
          bottomPanelMaximum < ShellLayoutPreferences.maxBottomPanelHeight
              ? bottomPanelMaximum
              : ShellLayoutPreferences.maxBottomPanelHeight,
        )
        .toDouble();
    final agentUsesAuxiliaryPanel =
        viewportProfile.width >= 1320 &&
        shell.activeWorkbenchRoute == BottomSurfaceTab.agent;
    final primaryToolUsesBottomPanel =
        !primarySidebarVisible && primaryToolSurface;
    final bottomSurfaceVisible =
        layoutBinding.bottomPanelExpanded &&
        (primaryToolUsesBottomPanel ||
            _usesBottomPanel(
              shell.activeWorkbenchRoute,
              agentUsesAuxiliaryPanel: agentUsesAuxiliaryPanel,
            ));

    return KeyedSubtree(
      key: ValueKey(layoutBinding.viewportKey),
      child: Theme(
        data: Theme.of(context).copyWith(
          cardTheme: Theme.of(context).cardTheme.copyWith(
            elevation: 0,
            margin: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
            ),
          ),
        ),
        child: Row(
          children: [
            if (layoutBinding.isPanelVisible('activity-rail'))
              WorkbenchActivityRail(
                destinations: const <WorkbenchDestination>[
                  WorkbenchDestination(
                    label: 'Explorer',
                    icon: Icons.folder_outlined,
                  ),
                  WorkbenchDestination(label: 'Search', icon: Icons.search),
                  WorkbenchDestination(
                    label: 'Source control',
                    icon: Icons.fork_right,
                  ),
                  WorkbenchDestination(
                    label: 'Coding Agent',
                    icon: Icons.auto_awesome_outlined,
                  ),
                  WorkbenchDestination(
                    label: 'Extensions',
                    icon: Icons.extension_outlined,
                  ),
                  WorkbenchDestination(
                    label: 'Settings',
                    icon: Icons.settings_outlined,
                  ),
                ],
                selectedIndex: switch (shell.activeWorkbenchRoute) {
                  BottomSurfaceTab.search => 1,
                  BottomSurfaceTab.sourceControl => 2,
                  BottomSurfaceTab.agent => 3,
                  BottomSurfaceTab.extensions => 4,
                  BottomSurfaceTab.settings => 5,
                  _ => 0,
                },
                onSelected: (index) {
                  switch (index) {
                    case 1:
                      shell.activatePrimarySidebar(BottomSurfaceTab.search);
                      break;
                    case 2:
                      shell.activatePrimarySidebar(
                        BottomSurfaceTab.sourceControl,
                      );
                      break;
                    case 3:
                      shell.selectWorkbenchRoute(
                        shell.activeWorkbenchRoute == BottomSurfaceTab.agent
                            ? BottomSurfaceTab.navigate
                            : BottomSurfaceTab.agent,
                      );
                      break;
                    case 4:
                      shell.activatePrimarySidebar(BottomSurfaceTab.extensions);
                      break;
                    case 5:
                      shell.activatePrimarySidebar(BottomSurfaceTab.settings);
                      break;
                    default:
                      shell.activatePrimarySidebar(BottomSurfaceTab.navigate);
                      break;
                  }
                },
              ),
            if (primarySidebarVisible)
              SizedBox(
                key: const ValueKey('workbench-primary-sidebar'),
                width: workspaceWidth,
                child: WorkbenchRegionSurface(
                  label: _primarySidebarLabel(shell.activeWorkbenchRoute),
                  child: primaryToolSurface
                      ? bottomSurface
                      : _ExplorerSidebar(shell: shell),
                ),
              ),
            if (primarySidebarVisible)
              _WorkbenchResizeHandle.vertical(
                key: const ValueKey('workbench-primary-sidebar-resize-handle'),
                semanticsLabel: 'Resize primary sidebar',
                onDelta: (delta) {
                  shell.resizePrimarySidebar(
                    shell
                            .shellLayoutPreferenceController
                            .preferences
                            .primarySidebarWidth +
                        delta,
                  );
                },
                onEnd: shell.commitShellLayoutResize,
              ),
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          flex: denseDesktop ? 6 : 5,
                          child: EditorSurface(
                            controller: shell.editorController,
                            viewportProfile: viewportProfile,
                            languageServiceStatus:
                                shell.languageServiceStatus.value,
                            projectHoverAtSelection:
                                shell.projectHoverAtSelection,
                            projectCompletionsAtSelection:
                                shell.projectCompletionsAtSelection,
                            fileBindingSnapshot:
                                shell.editorFileBindingSnapshot,
                            closeRequestSurface: shell.closeRequestSurface,
                            onAcceptExternalChange:
                                shell.acceptEditorExternalChange,
                            onSaveLocalChanges: () {
                              shell.saveActiveWorkspaceFileChanges();
                            },
                            onDiscardLocalChanges: () {
                              shell.discardActiveWorkspaceFileChanges();
                            },
                            onSaveAndCloseRequest: () {
                              shell.saveAndCloseRequestedWorkspaceFile();
                            },
                            onDiscardAndCloseRequest: () {
                              shell.discardAndCloseRequestedWorkspaceFile();
                            },
                            onSwitchToCloseRequestFile:
                                shell.switchToCloseRequestFile,
                            onCancelCloseRequest: shell.clearCloseRequestResult,
                            openDocumentIds:
                                shell.workspaceController.openFilePaths,
                            dirtyDocumentIds: shell.dirtyDocumentPaths,
                            activeDocumentId:
                                shell.workspaceController.activeFilePath,
                            onSelectDocument:
                                shell.workspaceController.openFile,
                            onCloseDocument: shell.requestCloseWorkspaceFile,
                            onRefreshLanguageService: () {
                              shell.executeCommand(
                                AppCommandId.refreshLanguageService,
                              );
                            },
                            showDevelopmentChrome: false,
                            languageInspectorVisible:
                                shell.editorLanguageInspectorVisible,
                            onToggleLanguageInspector:
                                shell.toggleEditorLanguageInspector,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _WorkbenchRoutes(
                    shell: shell,
                    viewportProfile: viewportProfile,
                  ),
                  if (bottomSurfaceVisible) ...[
                    _WorkbenchResizeHandle.horizontal(
                      key: const ValueKey(
                        'workbench-bottom-panel-resize-handle',
                      ),
                      semanticsLabel: 'Resize bottom panel',
                      onDelta: (delta) {
                        shell.resizeBottomPanel(
                          shell
                                  .shellLayoutPreferenceController
                                  .preferences
                                  .bottomPanelHeight -
                              delta,
                        );
                      },
                      onEnd: shell.commitShellLayoutResize,
                    ),
                    SizedBox(
                      key: const ValueKey('workbench-bottom-panel'),
                      height: bottomSurfaceHeight,
                      child: AnimatedSwitcher(
                        duration: VityoMotion.of(context).surface,
                        switchInCurve: VityoMotion.of(context).emphasized,
                        switchOutCurve: VityoMotion.of(context).standard,
                        transitionBuilder: (child, animation) {
                          final slide = Tween<Offset>(
                            begin: const Offset(0, 0.02),
                            end: Offset.zero,
                          ).animate(animation);
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: slide,
                              child: child,
                            ),
                          );
                        },
                        child: KeyedSubtree(
                          key: ValueKey(layoutBinding.activePanelId),
                          child: bottomSurface,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (agentUsesAuxiliaryPanel) ...[
              const VerticalDivider(width: 1, thickness: 1),
              WorkbenchAuxiliaryPanel(
                label: 'Coding Agent',
                child: TaskCenter(collaboration: shell.agentCollaboration),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WorkbenchResizeHandle extends StatefulWidget {
  const _WorkbenchResizeHandle.vertical({
    required this.semanticsLabel,
    required this.onDelta,
    required this.onEnd,
    super.key,
  }) : axis = Axis.vertical;

  const _WorkbenchResizeHandle.horizontal({
    required this.semanticsLabel,
    required this.onDelta,
    required this.onEnd,
    super.key,
  }) : axis = Axis.horizontal;

  final Axis axis;
  final String semanticsLabel;
  final ValueChanged<double> onDelta;
  final Future<void> Function() onEnd;

  @override
  State<_WorkbenchResizeHandle> createState() => _WorkbenchResizeHandleState();
}

class _WorkbenchResizeHandleState extends State<_WorkbenchResizeHandle> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final tokens = VityoWorkbenchTokens.of(context);
    final motion = VityoMotion.of(context);
    final vertical = widget.axis == Axis.vertical;
    void commit() {
      unawaited(widget.onEnd());
    }

    return Semantics(
      label: widget.semanticsLabel,
      slider: true,
      onIncrease: () {
        widget.onDelta(vertical ? 16 : -16);
        commit();
      },
      onDecrease: () {
        widget.onDelta(vertical ? -16 : 16);
        commit();
      },
      child: MouseRegion(
        cursor: vertical
            ? SystemMouseCursors.resizeLeftRight
            : SystemMouseCursors.resizeUpDown,
        onEnter: (_) => setState(() => _active = true),
        onExit: (_) => setState(() => _active = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: vertical
              ? (details) => widget.onDelta(details.delta.dx)
              : null,
          onHorizontalDragStart: vertical
              ? (_) => setState(() => _active = true)
              : null,
          onHorizontalDragEnd: vertical
              ? (_) {
                  setState(() => _active = false);
                  commit();
                }
              : null,
          onVerticalDragUpdate: vertical
              ? null
              : (details) => widget.onDelta(details.delta.dy),
          onVerticalDragStart: vertical
              ? null
              : (_) => setState(() => _active = true),
          onVerticalDragEnd: vertical
              ? null
              : (_) {
                  setState(() => _active = false);
                  commit();
                },
          child: SizedBox(
            width: vertical ? 7 : double.infinity,
            height: vertical ? double.infinity : 7,
            child: Center(
              child: AnimatedContainer(
                duration: motion.micro,
                curve: motion.standard,
                width: vertical ? (_active ? 3 : 1) : double.infinity,
                height: vertical ? double.infinity : (_active ? 3 : 1),
                color: _active
                    ? tokens.accent.withValues(alpha: 0.55)
                    : tokens.divider,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileShellBody extends StatelessWidget {
  const _MobileShellBody({
    required this.shell,
    required this.viewportProfile,
    required this.layoutBinding,
    required this.bottomSurface,
  });

  final ShellModel shell;
  final ViewportProfile viewportProfile;
  final ShellLayoutRenderBinding layoutBinding;
  final Widget bottomSurface;

  @override
  Widget build(BuildContext context) {
    final editorHeight = viewportProfile.height >= 820 ? 460.0 : 400.0;
    final workspaceHeight = viewportProfile.height >= 820 ? 320.0 : 280.0;
    final moduleHeight = viewportProfile.height >= 820 ? 320.0 : 280.0;
    final bottomSurfaceHeight = layoutBinding.bottomPanelHeight
        .clamp(
          ShellLayoutPreferences.minBottomPanelHeight,
          viewportProfile.height * 0.55,
        )
        .toDouble();

    return KeyedSubtree(
      key: ValueKey(layoutBinding.viewportKey),
      child: ListView(
        key: const ValueKey('shell-mobile-scroll'),
        children: [
          SizedBox(
            height: editorHeight,
            child: EditorSurface(
              controller: shell.editorController,
              viewportProfile: viewportProfile,
              languageServiceStatus: shell.languageServiceStatus.value,
              projectHoverAtSelection: shell.projectHoverAtSelection,
              projectCompletionsAtSelection:
                  shell.projectCompletionsAtSelection,
              fileBindingSnapshot: shell.editorFileBindingSnapshot,
              closeRequestSurface: shell.closeRequestSurface,
              onAcceptExternalChange: shell.acceptEditorExternalChange,
              onSaveLocalChanges: () {
                shell.saveActiveWorkspaceFileChanges();
              },
              onDiscardLocalChanges: () {
                shell.discardActiveWorkspaceFileChanges();
              },
              onSaveAndCloseRequest: () {
                shell.saveAndCloseRequestedWorkspaceFile();
              },
              onDiscardAndCloseRequest: () {
                shell.discardAndCloseRequestedWorkspaceFile();
              },
              onSwitchToCloseRequestFile: shell.switchToCloseRequestFile,
              onCancelCloseRequest: shell.clearCloseRequestResult,
              openDocumentIds: shell.workspaceController.openFilePaths,
              dirtyDocumentIds: shell.dirtyDocumentPaths,
              activeDocumentId: shell.workspaceController.activeFilePath,
              onSelectDocument: shell.workspaceController.openFile,
              onCloseDocument: shell.requestCloseWorkspaceFile,
              onRefreshLanguageService: () {
                shell.executeCommand(AppCommandId.refreshLanguageService);
              },
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: workspaceHeight,
            child: _WorkspaceSidebar(shell: shell),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: moduleHeight,
            child: _ModuleSidebar(shell: shell),
          ),
          const SizedBox(height: 16),
          _WorkbenchRoutes(shell: shell, viewportProfile: viewportProfile),
          if (layoutBinding.bottomPanelExpanded) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: bottomSurfaceHeight,
              child: KeyedSubtree(
                key: ValueKey(layoutBinding.activePanelId),
                child: bottomSurface,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

TextStyle _sidebarSectionStyle(BuildContext context) {
  final tokens = VityoWorkbenchTokens.of(context);
  return Theme.of(context).textTheme.labelSmall!.copyWith(
    color: tokens.muted,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.5,
  );
}

class _WorkspaceSidebar extends StatelessWidget {
  const _WorkspaceSidebar({required this.shell});

  final ShellModel shell;

  @override
  Widget build(BuildContext context) {
    final project = shell.workspaceController.activeProject;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: ListView(
          key: const ValueKey('workspace-sidebar-scroll'),
          children: [
            Text('Project Graph', style: _sidebarSectionStyle(context)),
            const SizedBox(height: 12),
            _ProjectSummaryCard(project: project),
            const SizedBox(height: 12),
            _ProjectWorkflowCard(
              platformTarget: shell.platformTarget,
              project: project,
              adapterCapabilities: shell.adapterCapabilities,
            ),
            const SizedBox(height: 12),
            _CompilerHandshakeCard(project: project),
            const SizedBox(height: 12),
            _ProjectOperationsCard(shell: shell),
            if (shell.pendingWorkspaceFileCommandConfirmation != null) ...[
              const SizedBox(height: 12),
              _WorkspaceFileCommandConfirmationCard(
                pending: shell.pendingWorkspaceFileCommandConfirmation!,
                onConfirm: () {
                  shell.confirmPendingWorkspaceFileCommand();
                },
                onCancel: shell.cancelPendingWorkspaceFileCommand,
              ),
            ],
            const SizedBox(height: 12),
            _RequiredHandoffsCard(
              platformTarget: shell.platformTarget,
              project: project,
              adapterCapabilities: shell.adapterCapabilities,
            ),
            if (project.workspaceMembers.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text('Workspace Members', style: _sidebarSectionStyle(context)),
              const SizedBox(height: 12),
              for (final member in project.workspaceMembers)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _WorkspaceMemberTile(memberPath: member),
                ),
            ],
            if (project.packages.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text('Packages', style: _sidebarSectionStyle(context)),
              const SizedBox(height: 12),
              for (final package in project.packages)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ProjectPackageTile(package: package),
                ),
            ],
            if (project.dependencies.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text('Dependencies', style: _sidebarSectionStyle(context)),
              const SizedBox(height: 12),
              for (final dependency in project.dependencies)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ProjectDependencyTile(dependency: dependency),
                ),
            ],
            if (shell.workspaceController.targets.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text('Targets', style: _sidebarSectionStyle(context)),
              const SizedBox(height: 12),
              for (final target in shell.workspaceController.targets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ProjectTargetTile(
                    target: target,
                    active:
                        target.filePath ==
                        shell.workspaceController.activeFilePath,
                    onTap: () => shell.workspaceController.openTarget(target),
                  ),
                ),
            ],
            const SizedBox(height: 18),
            Text('Files', style: _sidebarSectionStyle(context)),
            const SizedBox(height: 12),
            for (final file in shell.workspaceController.files)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _WorkspaceFileTile(
                  file: file,
                  active: file == shell.workspaceController.activeFilePath,
                  onTap: () => shell.workspaceController.openFile(file),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProjectSummaryCard extends StatelessWidget {
  const _ProjectSummaryCard({required this.project});

  final ProjectGraphSnapshot project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return WorkbenchCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(project.title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(project.workspaceRoot, style: theme.textTheme.bodySmall),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              WorkbenchMetaPill(label: project.kind.label),
              WorkbenchMetaPill(label: 'lock ${project.lockState.label}'),
              WorkbenchMetaPill(label: 'vendor ${project.vendorState.label}'),
              WorkbenchMetaPill(label: '${project.packageCount} package'),
              WorkbenchMetaPill(
                label: '${project.workspaceMemberCount} member',
              ),
              WorkbenchMetaPill(label: '${project.dependencyCount} dependency'),
              WorkbenchMetaPill(label: '${project.targetCount} target'),
              WorkbenchMetaPill(label: '${project.editorFileCount} file'),
            ],
          ),
          const SizedBox(height: 10),
          Text(project.toolchain.detail, style: theme.textTheme.bodySmall),
          if (project.manifestPath != null) ...[
            const SizedBox(height: 6),
            Text(
              'manifest ${project.manifestPath}',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (project.notes.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(project.notes.first, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

class _ProjectWorkflowCard extends StatelessWidget {
  const _ProjectWorkflowCard({
    required this.platformTarget,
    required this.project,
    required this.adapterCapabilities,
  });

  final PlatformTarget platformTarget;
  final ProjectGraphSnapshot project;
  final List<AdapterCapabilitySnapshot> adapterCapabilities;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selection = selectBackendExecutionRoute(
      platformTarget: platformTarget,
      projectGraph: project,
      adapterCapabilities: adapterCapabilities,
    );
    final summary = summarizeExecutionRoute(
      platformTarget: platformTarget,
      projectGraph: project,
      adapterCapabilities: adapterCapabilities,
    );

    return WorkbenchCard(
      key: const ValueKey('project-workflow-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Project Workflow', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(selection.title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(selection.detail, style: theme.textTheme.bodySmall),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              WorkbenchMetaPill(label: selection.adapterKind.label),
              WorkbenchMetaPill(label: selection.routeKind.wireValue),
              WorkbenchMetaPill(
                label: selection.allowed ? 'live-capable' : 'blocked',
                color: selection.allowed
                    ? VityoWorkbenchTokens.of(context).success
                    : VityoWorkbenchTokens.of(context).error,
                filled: true,
              ),
              if (project.compilePlanConsumerAdvertised)
                const WorkbenchMetaPill(label: 'compile-plan detected'),
              WorkbenchMetaPill(
                label: summary.jitRoute.blocked ? 'JIT blocked' : 'JIT live',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CompilerHandshakeCard extends StatelessWidget {
  const _CompilerHandshakeCard({required this.project});

  final ProjectGraphSnapshot project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compiler = project.activeCompiler;

    return WorkbenchCard(
      key: const ValueKey('compiler-handshake-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Compiler Handshake', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          if (compiler == null)
            Text(
              'No local styio machine-info handshake has been resolved yet.',
              style: theme.textTheme.bodySmall,
            )
          else ...[
            Text(
              '${compiler.tool} ${compiler.compilerVersion} · ${compiler.channel}',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              'variant ${compiler.variant} · phase ${compiler.integrationPhase}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(compiler.contractSummary, style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            Text(compiler.capabilitySummary, style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              WorkbenchMetaPill(label: project.toolchain.source.label),
              if (project.toolchain.channel != null)
                WorkbenchMetaPill(
                  label: 'channel ${project.toolchain.channel}',
                ),
              if (compiler != null && compiler.supportsContract('compile_plan'))
                const WorkbenchMetaPill(label: 'compile-plan ready'),
            ],
          ),
        ],
      ),
    );
  }
}

class _RequiredHandoffsCard extends StatelessWidget {
  const _RequiredHandoffsCard({
    required this.platformTarget,
    required this.project,
    required this.adapterCapabilities,
  });

  final PlatformTarget platformTarget;
  final ProjectGraphSnapshot project;
  final List<AdapterCapabilitySnapshot> adapterCapabilities;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final handoffs = summarizeRequiredHandoffs(
      platformTarget: platformTarget,
      projectGraph: project,
      adapterCapabilities: adapterCapabilities,
    );
    final blockingCount = handoffs.where((handoff) => handoff.blocking).length;
    final styioCount = handoffs
        .where((handoff) => handoff.owner == HandoffOwner.styio)
        .length;
    final pafioCount = handoffs
        .where((handoff) => handoff.owner == HandoffOwner.pafio)
        .length;

    return WorkbenchCard(
      key: const ValueKey('required-handoffs-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Required Handoffs', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'This card only states what `Vityo` still needs from upstream machine contracts. It does not prescribe upstream internals.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              WorkbenchMetaPill(
                label: '$blockingCount blocking',
                color: blockingCount > 0
                    ? VityoWorkbenchTokens.of(context).warning
                    : null,
                filled: blockingCount > 0,
              ),
              WorkbenchMetaPill(label: '$styioCount styio'),
              WorkbenchMetaPill(label: '$pafioCount pafio'),
            ],
          ),
          const SizedBox(height: 10),
          if (handoffs.isEmpty)
            Text(
              'No product-side handoffs are currently outstanding for this route.',
              style: theme.textTheme.bodySmall,
            )
          else
            for (var index = 0; index < handoffs.length; index += 1) ...[
              if (index > 0) const SizedBox(height: 10),
              _RequiredHandoffTile(handoff: handoffs[index]),
            ],
        ],
      ),
    );
  }
}

class _ProjectOperationsCard extends StatelessWidget {
  const _ProjectOperationsCard({required this.shell});

  final ShellModel shell;

  String? _stringPayload(Map<String, dynamic>? payload, String key) {
    final value = payload?[key];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    return null;
  }

  List<String> _blockedWorkflowPreview() {
    return VityoCommandRegistry.workflowCommands
        .map((command) {
          final reason = shell.blockedReasonForCommand(command.id);
          if (reason == null) {
            return null;
          }
          return '${command.label}: $reason';
        })
        .whereType<String>()
        .take(3)
        .toList(growable: false);
  }

  Color _laneColor(BuildContext context, String status) {
    final tokens = VityoWorkbenchTokens.of(context);
    switch (status) {
      case 'succeeded':
      case 'resolved':
      case 'ready':
        return tokens.success;
      case 'failed':
        return tokens.error;
      case 'blocked':
        return tokens.warning;
      case 'running':
        return tokens.accent;
      case 'idle':
      case 'pending':
        return tokens.muted;
      default:
        return tokens.muted;
    }
  }

  String _executionStatusLabel(ExecutionSession? session) {
    if (session == null) {
      return 'idle';
    }
    return switch (session.status) {
      ExecutionSessionStatus.succeeded => 'succeeded',
      ExecutionSessionStatus.failed => 'failed',
      ExecutionSessionStatus.blocked => 'blocked',
      ExecutionSessionStatus.running => 'running',
      ExecutionSessionStatus.cancelled => 'cancelled',
    };
  }

  String _dependencyStatusLabel(DependencySourceCommandResult? result) {
    if (result == null) {
      return 'idle';
    }
    return switch (result.status) {
      DependencySourceCommandStatus.succeeded => 'succeeded',
      DependencySourceCommandStatus.failed => 'failed',
      DependencySourceCommandStatus.blocked => 'blocked',
    };
  }

  String _deploymentStatusLabel(DeploymentCommandResult? result) {
    if (result == null) {
      return 'ready';
    }
    return switch (result.status) {
      DeploymentCommandStatus.succeeded => 'succeeded',
      DeploymentCommandStatus.failed => 'failed',
      DeploymentCommandStatus.blocked => 'blocked',
    };
  }

  Widget _buildCommandChip(
    BuildContext context,
    ThemeData theme,
    AppCommandDescriptor command,
  ) {
    final blockedReason = shell.blockedReasonForCommand(command.id);
    return Tooltip(
      message: blockedReason ?? command.description,
      child: ActionChip(
        key: ValueKey('project-operation-${command.id.name}'),
        onPressed: blockedReason == null
            ? () => shell.executeCommand(command.id)
            : null,
        avatar: Icon(
          _commandIcon(command.id),
          size: 18,
          color: blockedReason == null
              ? theme.colorScheme.primary
              : theme.disabledColor,
        ),
        label: Text(command.label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final project = shell.workspaceController.activeProject;
    final activeCompiler = project.activeCompiler;
    final distribution = project.packageDistribution;
    final publishablePackages = distribution?.publishablePackages ?? 0;
    final blockedPackages = distribution?.blockedPackages ?? 0;
    final blockedWorkflowPreview = _blockedWorkflowPreview();
    final lastDeployment = shell.lastDeploymentCommand;
    final lastExecution = shell.lastExecutionSession;
    final lastDependency = shell.lastDependencySourceCommand;
    final executionStatus = _executionStatusLabel(lastExecution);
    final dependencyStatus = _dependencyStatusLabel(lastDependency);
    final toolchainStatus = project.activeCompiler == null
        ? 'unavailable'
        : 'resolved';
    final deploymentStatus = _deploymentStatusLabel(lastDeployment);
    final deploymentPackage = _stringPayload(
      lastDeployment?.payload,
      'package',
    );
    final deploymentArchive = _stringPayload(
      lastDeployment?.payload,
      'archive_path',
    );
    final vendorMetadata = _stringPayload(
      lastDependency?.payload,
      'metadata_path',
    );
    final vendorRoot = _stringPayload(lastDependency?.payload, 'vendor_root');
    final dependencyPackages = lastDependency?.payload?['packages'];
    final gitDependencies = project.dependencies
        .where(
          (dependency) =>
              dependency.sourceKind == ProjectDependencySourceKind.git,
        )
        .length;
    final registryDependencies = project.dependencies
        .where(
          (dependency) =>
              dependency.sourceKind == ProjectDependencySourceKind.registry,
        )
        .length;

    return WorkbenchCard(
      key: const ValueKey('project-operations-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Project Workflow', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'One shell-owned surface for execution, dependency materialization, toolchain routing, and deployment preflight.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _WorkflowStatusChip(
                label: 'execution $executionStatus',
                color: _laneColor(context, executionStatus),
              ),
              _WorkflowStatusChip(
                label: 'dependencies $dependencyStatus',
                color: _laneColor(context, dependencyStatus),
              ),
              _WorkflowStatusChip(
                label: 'environment $toolchainStatus',
                color: _laneColor(context, toolchainStatus),
              ),
              _WorkflowStatusChip(
                label: 'deployment $deploymentStatus',
                color: _laneColor(context, deploymentStatus),
              ),
              WorkbenchMetaPill(
                label: activeCompiler == null
                    ? 'compiler unresolved'
                    : 'compiler ${activeCompiler.compilerVersion}',
              ),
              WorkbenchMetaPill(label: 'publishable $publishablePackages'),
              WorkbenchMetaPill(label: 'blocked $blockedPackages'),
              WorkbenchMetaPill(
                label:
                    'workflow blockers ${VityoCommandRegistry.workflowCommands.where((command) => shell.blockedReasonForCommand(command.id) != null).length}',
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (blockedWorkflowPreview.isNotEmpty) ...[
            Text('Current Blockers', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final blocker in blockedWorkflowPreview) ...[
              Text(blocker, style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
            ],
            const SizedBox(height: 8),
          ],
          _WorkflowLanePanel(
            title: 'Execution',
            statusLabel: executionStatus,
            statusColor: _laneColor(context, executionStatus),
            detail: lastExecution == null
                ? 'Run has not been routed through the active project shell yet.'
                : '${lastExecution.kind} ${lastExecution.status.name}: ${lastExecution.statusMessage}',
            metaLabels: [
              'runtime ${shell.lastRuntimeEvents.length}',
              if (lastExecution != null) ...[
                'diagnostics ${lastExecution.diagnostics.length}',
                'stdout ${lastExecution.stdoutEvents.length}',
                'stderr ${lastExecution.stderrEvents.length}',
              ],
            ],
            actions: VityoCommandRegistry.executionCommands
                .map((command) => _buildCommandChip(context, theme, command))
                .toList(growable: false),
          ),
          const SizedBox(height: 12),
          _WorkflowLanePanel(
            title: 'Dependencies',
            statusLabel: dependencyStatus,
            statusColor: _laneColor(context, dependencyStatus),
            detail: lastDependency == null
                ? 'Sync/vendor has not been materialized in this shell session yet.'
                : '${lastDependency.command} ${lastDependency.status.name}: ${lastDependency.statusMessage}',
            metaLabels: [
              'git $gitDependencies',
              'registry $registryDependencies',
              'vendor ${project.vendorState.label}',
              if (dependencyPackages is num)
                'packages ${dependencyPackages.toInt()}',
              if (vendorRoot != null) 'vendor root',
              if (vendorMetadata != null) 'vendor metadata',
            ],
            actions: VityoCommandRegistry.dependencyCommands
                .map((command) => _buildCommandChip(context, theme, command))
                .toList(growable: false),
          ),
          const SizedBox(height: 12),
          _WorkflowLanePanel(
            title: 'Environment',
            statusLabel: toolchainStatus,
            statusColor: _laneColor(context, toolchainStatus),
            detail: project.toolchain.detail,
            metaLabels: [
              'source ${project.toolchain.source.label}',
              if (activeCompiler != null) 'channel ${activeCompiler.channel}',
            ],
            actions: VityoCommandRegistry.toolchainCommands
                .map((command) => _buildCommandChip(context, theme, command))
                .toList(growable: false),
          ),
          const SizedBox(height: 12),
          _WorkflowLanePanel(
            title: 'Deployment',
            statusLabel: deploymentStatus,
            statusColor: _laneColor(context, deploymentStatus),
            detail: lastDeployment == null
                ? 'Pack and publish preflight are ready to route through the active project shell.'
                : '${lastDeployment.command} ${lastDeployment.status.name}: ${lastDeployment.statusMessage}',
            metaLabels: [
              'packages ${distribution?.packages.length ?? 0}',
              'publishable $publishablePackages',
              'blocked $blockedPackages',
              if (deploymentPackage != null) 'package $deploymentPackage',
              if (deploymentArchive != null) 'archive ready',
            ],
            actions: VityoCommandRegistry.deploymentCommands
                .map((command) => _buildCommandChip(context, theme, command))
                .toList(growable: false),
          ),
        ],
      ),
    );
  }
}

class _WorkflowLanePanel extends StatelessWidget {
  const _WorkflowLanePanel({
    required this.title,
    required this.statusLabel,
    required this.statusColor,
    required this.detail,
    required this.metaLabels,
    required this.actions,
  });

  final String title;
  final String statusLabel;
  final Color statusColor;
  final String detail;
  final List<String> metaLabels;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.canvas,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
                _WorkflowStatusChip(label: statusLabel, color: statusColor),
              ],
            ),
            const SizedBox(height: 6),
            Text(detail, style: theme.textTheme.bodySmall),
            if (metaLabels.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: metaLabels
                    .map((label) => WorkbenchMetaPill(label: label))
                    .toList(growable: false),
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}

class _WorkflowStatusChip extends StatelessWidget {
  const _WorkflowStatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return WorkbenchMetaPill(label: label, color: color, filled: true);
  }
}

class _RequiredHandoffTile extends StatelessWidget {
  const _RequiredHandoffTile({required this.handoff});

  final RequiredHandoff handoff;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.canvas,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                WorkbenchMetaPill(label: handoff.owner.label),
                WorkbenchMetaPill(
                  label: handoff.blocking ? 'blocking' : 'follow-up',
                  color: handoff.blocking ? tokens.warning : null,
                  filled: handoff.blocking,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(handoff.title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(handoff.detail, style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            Text(handoff.docPath, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceFileTile extends StatelessWidget {
  const _WorkspaceFileTile({
    required this.file,
    required this.active,
    required this.onTap,
  });

  final String file;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: active ? tokens.selection : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(
              active ? Icons.article_rounded : Icons.article_outlined,
              size: 18,
              color: active ? tokens.ink : tokens.muted,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(file, style: theme.textTheme.bodyMedium)),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceFileCommandConfirmationCard extends StatelessWidget {
  const _WorkspaceFileCommandConfirmationCard({
    required this.pending,
    required this.onConfirm,
    required this.onCancel,
  });

  final WorkspaceFileCommandRouteResult pending;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);
    final plan = pending.confirmationPlan;
    final request = pending.request;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tokens.warning.withValues(alpha: 0.40)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              plan?.title ?? 'Confirm workspace file command',
              key: const ValueKey('workspace-file-confirmation-title'),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              pending.message,
              key: const ValueKey('workspace-file-confirmation-message'),
              style: theme.textTheme.bodySmall,
            ),
            if (request != null) ...[
              const SizedBox(height: 8),
              Text(
                '${request.kind.wireValue}: ${request.path}',
                key: const ValueKey('workspace-file-confirmation-target'),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  key: const ValueKey('workspace-file-confirmation-apply'),
                  onPressed: onConfirm,
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Confirm'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('workspace-file-confirmation-cancel'),
                  onPressed: onCancel,
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectTargetTile extends StatelessWidget {
  const _ProjectTargetTile({
    required this.target,
    required this.active,
    required this.onTap,
  });

  final ProjectTargetDescriptor target;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: active ? tokens.selection : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(
              Icons.track_changes_rounded,
              size: 18,
              color: active ? tokens.ink : tokens.muted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${target.kind.name} ${target.name}'),
                  Text(target.packageName, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectPackageTile extends StatelessWidget {
  const _ProjectPackageTile({required this.package});

  final ProjectPackageSnapshot package;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.elevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    package.packageName,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                WorkbenchMetaPill(label: package.version),
              ],
            ),
            const SizedBox(height: 6),
            Text(package.rootPath, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                WorkbenchMetaPill(label: '${package.targets.length} target'),
                WorkbenchMetaPill(
                  label: '${package.dependencies.length} dependency',
                ),
                WorkbenchMetaPill(
                  label: package.isWorkspaceMember
                      ? 'workspace member'
                      : 'root package',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceMemberTile extends StatelessWidget {
  const _WorkspaceMemberTile({required this.memberPath});

  final String memberPath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.elevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.folder_open_rounded, size: 18, color: tokens.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(memberPath, style: theme.textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectDependencyTile extends StatelessWidget {
  const _ProjectDependencyTile({required this.dependency});

  final ProjectDependencySnapshot dependency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.elevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                WorkbenchMetaPill(label: dependency.kind.label),
                if (dependency.isWorkspaceReference)
                  const WorkbenchMetaPill(label: 'workspace ref'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${dependency.sourcePackageName} -> ${dependency.dependencyName}',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(dependency.requirement, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _ModuleSidebar extends StatelessWidget {
  const _ModuleSidebar({required this.shell});

  final ShellModel shell;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: ListView(
          children: [
            Text('Adapter Routes', style: _sidebarSectionStyle(context)),
            const SizedBox(height: 6),
            Text(
              'Product-owned capability surface across CLI, FFI, and Cloud adapters.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            for (final capability in shell.adapterCapabilities)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _AdapterCapabilityTile(capability: capability),
              ),
            const SizedBox(height: 8),
            Text('Module Host', style: _sidebarSectionStyle(context)),
            const SizedBox(height: 6),
            Text(
              'Capability matrix filtered for ${shell.platformTarget.label}.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            for (var index = 0; index < shell.visibleModules.length; index += 1)
              Padding(
                padding: EdgeInsets.only(
                  bottom: index == shell.visibleModules.length - 1 ? 0 : 10,
                ),
                child: _ModuleTile(
                  module: shell.visibleModules[index],
                  mounted: shell.visibleModules[index].isMountedOn(
                    shell.platformTarget,
                  ),
                  platformTarget: shell.platformTarget,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AdapterCapabilityTile extends StatelessWidget {
  const _AdapterCapabilityTile({required this.capability});

  final AdapterCapabilitySnapshot capability;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.elevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              capability.adapterKind.label,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'language ${capability.languageService.level.label} · project ${capability.projectGraph.level.label}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              'execution ${capability.execution.level.label} · runtime ${capability.runtimeEvents.level.label}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(capability.execution.detail, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _WorkbenchRoutes extends StatelessWidget {
  const _WorkbenchRoutes({required this.shell, required this.viewportProfile});

  final ShellModel shell;
  final ViewportProfile viewportProfile;

  @override
  Widget build(BuildContext context) {
    final bottomToolTabs = <Widget>[
      _SurfaceTabChip(
        key: const ValueKey('bottom-tab-runtime'),
        label: 'Runtime',
        active: shell.activeWorkbenchRoute == BottomSurfaceTab.runtime,
        onTap: () => shell.selectWorkbenchRoute(BottomSurfaceTab.runtime),
      ),
      _SurfaceTabChip(
        key: const ValueKey('bottom-tab-terminal'),
        label: 'Terminal',
        active: shell.activeWorkbenchRoute == BottomSurfaceTab.terminal,
        onTap: () => shell.selectWorkbenchRoute(BottomSurfaceTab.terminal),
      ),
      _SurfaceTabChip(
        key: const ValueKey('bottom-tab-problems'),
        label: 'Problems',
        active: shell.activeWorkbenchRoute == BottomSurfaceTab.problems,
        onTap: () => shell.selectWorkbenchRoute(BottomSurfaceTab.problems),
      ),
      _SurfaceTabChip(
        key: const ValueKey('bottom-tab-tests'),
        label: 'Tests',
        active: shell.activeWorkbenchRoute == BottomSurfaceTab.testing,
        onTap: () => shell.selectWorkbenchRoute(BottomSurfaceTab.testing),
      ),
      _SurfaceTabChip(
        key: const ValueKey('bottom-tab-observable'),
        label: 'Observable',
        active: shell.activeWorkbenchRoute == BottomSurfaceTab.observable,
        onTap: () => shell.selectWorkbenchRoute(BottomSurfaceTab.observable),
      ),
      _SurfaceTabChip(
        key: const ValueKey('bottom-tab-extensions'),
        label: 'Extensions',
        active: shell.activeWorkbenchRoute == BottomSurfaceTab.extensions,
        onTap: () => shell.selectWorkbenchRoute(BottomSurfaceTab.extensions),
      ),
      _SurfaceTabChip(
        key: const ValueKey('bottom-tab-debug'),
        label: 'Debug',
        active: shell.activeWorkbenchRoute == BottomSurfaceTab.debug,
        onTap: () => shell.selectWorkbenchRoute(BottomSurfaceTab.debug),
      ),
      if (!viewportProfile.isMobile && viewportProfile.width < 1320)
        _SurfaceTabChip(
          key: const ValueKey('bottom-tab-agent'),
          label: 'Agent',
          active: shell.activeWorkbenchRoute == BottomSurfaceTab.agent,
          onTap: () => shell.selectWorkbenchRoute(BottomSurfaceTab.agent),
        ),
    ];
    final tabs = viewportProfile.isMobile
        ? <Widget>[
            ...bottomToolTabs,
            _SurfaceTabChip(
              label: 'Commands',
              active:
                  shell.activeWorkbenchRoute == BottomSurfaceTab.commandPalette,
              onTap: () =>
                  shell.selectWorkbenchRoute(BottomSurfaceTab.commandPalette),
            ),
            _SurfaceTabChip(
              label: 'Agent',
              active: shell.activeWorkbenchRoute == BottomSurfaceTab.agent,
              onTap: () => shell.selectWorkbenchRoute(BottomSurfaceTab.agent),
            ),
            _SurfaceTabChip(
              label: 'SCM',
              active:
                  shell.activeWorkbenchRoute == BottomSurfaceTab.sourceControl,
              onTap: () =>
                  shell.selectWorkbenchRoute(BottomSurfaceTab.sourceControl),
            ),
            _SurfaceTabChip(
              label: 'Search',
              active: shell.activeWorkbenchRoute == BottomSurfaceTab.search,
              onTap: () => shell.selectWorkbenchRoute(BottomSurfaceTab.search),
            ),
            _SurfaceTabChip(
              label: 'Extensions',
              active: shell.activeWorkbenchRoute == BottomSurfaceTab.extensions,
              onTap: () =>
                  shell.selectWorkbenchRoute(BottomSurfaceTab.extensions),
            ),
            _SurfaceTabChip(
              label: 'Settings',
              active: shell.activeWorkbenchRoute == BottomSurfaceTab.settings,
              onTap: () => shell.selectWorkbenchRoute(BottomSurfaceTab.settings),
            ),
          ]
        : bottomToolTabs;

    if (viewportProfile.isMobile) {
      return Semantics(
        container: true,
        label: 'Compact workbench navigation',
        child: Column(
          key: const ValueKey('compact-workbench-navigation'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(spacing: 10, runSpacing: 10, children: tabs),
            const SizedBox(height: 8),
            Text(
              'Mobile shell keeps runtime, terminal, commands, agent, source control, search, problems, testing, observable, extensions, debug, and settings on one vertical route. Hardware keyboard shortcuts remain optional.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    final expanded =
        shell.shellLayoutPreferenceController.preferences.bottomPanelExpanded;
    final dockedRoute = _usesBottomPanel(
      shell.activeWorkbenchRoute,
      agentUsesAuxiliaryPanel:
          viewportProfile.width >= 1320 &&
          shell.activeWorkbenchRoute == BottomSurfaceTab.agent,
    );
    final tokens = VityoWorkbenchTokens.of(context);
    return Container(
      key: const ValueKey('workbench-bottom-panel-header'),
      width: double.infinity,
      height: 36,
      decoration: BoxDecoration(
        color: tokens.region,
        border: Border(top: BorderSide(color: tokens.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Row(children: tabs),
              ),
            ),
          ),
          Tooltip(
            message: expanded ? 'Hide bottom panel' : 'Show bottom panel',
            child: IconButton(
              key: const ValueKey('workbench-bottom-panel-toggle'),
              onPressed: dockedRoute
                  ? () => shell.setBottomPanelExpanded(!expanded)
                  : null,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              padding: EdgeInsets.zero,
              icon: Icon(
                expanded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_up_rounded,
                size: 18,
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

bool _usesPrimarySidebar(BottomSurfaceTab tab) {
  return tab == BottomSurfaceTab.search ||
      tab == BottomSurfaceTab.sourceControl ||
      tab == BottomSurfaceTab.extensions ||
      tab == BottomSurfaceTab.settings;
}

String _primarySidebarLabel(BottomSurfaceTab tab) {
  return switch (tab) {
    BottomSurfaceTab.search => 'Search',
    BottomSurfaceTab.sourceControl => 'Source Control',
    BottomSurfaceTab.extensions => 'Extensions',
    BottomSurfaceTab.settings => 'Settings',
    _ => 'Explorer',
  };
}

bool _usesBottomPanel(
  BottomSurfaceTab tab, {
  required bool agentUsesAuxiliaryPanel,
}) {
  return switch (tab) {
    BottomSurfaceTab.runtime ||
    BottomSurfaceTab.terminal ||
    BottomSurfaceTab.commandPalette ||
    BottomSurfaceTab.problems ||
    BottomSurfaceTab.testing ||
    BottomSurfaceTab.debug => true,
    BottomSurfaceTab.agent => !agentUsesAuxiliaryPanel,
    _ => false,
  };
}

final class _ServicePresentation {
  const _ServicePresentation({
    required this.status,
    required this.label,
    required this.detail,
  });

  final WorkbenchStatus status;
  final String label;
  final String detail;
}

_ServicePresentation _servicePresentationFor(ShellModel shell) {
  switch (shell.platformTarget) {
    case PlatformTarget.linux:
    case PlatformTarget.macos:
    case PlatformTarget.windows:
      return switch (shell.localServiceConnection.phase) {
        VityodConnectionPhase.connected => const _ServicePresentation(
          status: WorkbenchStatus.ready,
          label: 'Local service connected',
          detail: 'Workspace services are available.',
        ),
        VityodConnectionPhase.connecting ||
        VityodConnectionPhase.reconnecting => const _ServicePresentation(
          status: WorkbenchStatus.reconnecting,
          label: 'Local service reconnecting',
          detail: 'Editing remains local while workspace services reconnect.',
        ),
        VityodConnectionPhase.resyncRequired => const _ServicePresentation(
          status: WorkbenchStatus.blocked,
          label: 'Workspace resync required',
          detail: 'Refresh the authoritative workspace snapshot to continue.',
        ),
        VityodConnectionPhase.blocked => const _ServicePresentation(
          status: WorkbenchStatus.blocked,
          label: 'Local service blocked',
          detail: 'Resolve the local service capability block to continue.',
        ),
        VityodConnectionPhase.disconnected => const _ServicePresentation(
          status: WorkbenchStatus.blocked,
          label: 'Local service disconnected',
          detail: 'Reconnect to resume durable workspace services.',
        ),
      };
    case PlatformTarget.web:
    case PlatformTarget.ios:
      if (shell.workspaceController.activeProject.hostedWorkspace != null) {
        return const _ServicePresentation(
          status: WorkbenchStatus.ready,
          label: 'Hosted workspace connected',
          detail: 'Hosted workspace services are available.',
        );
      }
      return const _ServicePresentation(
        status: WorkbenchStatus.blocked,
        label: 'Hosted workspace unavailable',
        detail: 'Reconnect to the hosted workspace to resume services.',
      );
    case PlatformTarget.android:
    case PlatformTarget.unknown:
      return const _ServicePresentation(
        status: WorkbenchStatus.blocked,
        label: 'Native IDE services unavailable',
        detail: 'This platform keeps unsupported native capabilities blocked.',
      );
  }
}

class _ServiceStateBanner extends StatelessWidget {
  const _ServiceStateBanner({
    required this.presentation,
    required this.onRecover,
  });

  final _ServicePresentation presentation;
  final Future<void> Function() onRecover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);
    final tone = switch (presentation.status) {
      WorkbenchStatus.ready => tokens.success,
      WorkbenchStatus.reconnecting => tokens.warning,
      WorkbenchStatus.blocked => tokens.blocked,
      WorkbenchStatus.error => tokens.error,
    };
    return Container(
      key: ValueKey('service-state-${presentation.status.name}'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.07),
        border: Border(bottom: BorderSide(color: tone.withValues(alpha: 0.20))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      child: Row(
        children: [
          Icon(
            presentation.status == WorkbenchStatus.reconnecting
                ? Icons.sync_rounded
                : Icons.cloud_off_outlined,
            size: 13,
            color: tone,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${presentation.label} — ${presentation.detail}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: tokens.ink.withValues(alpha: 0.82),
                letterSpacing: 0,
              ),
            ),
          ),
          InkWell(
            key: const ValueKey('service-state-recover'),
            onTap: () => onRecover(),
            borderRadius: BorderRadius.circular(6),
            hoverColor: tokens.hover,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Text(
                'Reconnect',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: tone,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _terminalRuntimeEventSummary(RuntimeEventEnvelope event) {
  final payloadMessage =
      event.payload['message'] ??
      event.payload['text'] ??
      event.payload['line'] ??
      event.payload['data'];
  if (payloadMessage == null) {
    return '${event.eventKind}: ${event.origin}';
  }
  return '${event.eventKind}: $payloadMessage';
}

IconData _commandIcon(AppCommandId commandId) {
  switch (commandId) {
    case AppCommandId.run:
      return Icons.play_arrow_rounded;
    case AppCommandId.syncDependencies:
      return Icons.cloud_download_rounded;
    case AppCommandId.vendorDependencies:
      return Icons.inventory_2_rounded;
    case AppCommandId.executeToolchainInstallPlan:
      return Icons.download_for_offline_outlined;
    case AppCommandId.selectClangCppVersion:
      return Icons.developer_board_rounded;
    case AppCommandId.packProject:
      return Icons.archive_rounded;
    case AppCommandId.preparePublish:
      return Icons.publish_rounded;
    case AppCommandId.refreshModules:
      return Icons.refresh_rounded;
    case AppCommandId.save:
      return Icons.save_rounded;
    case AppCommandId.saveAll:
      return Icons.save_as_rounded;
    case AppCommandId.showRuntime:
      return Icons.terminal_rounded;
    case AppCommandId.showAgent:
      return Icons.smart_toy_outlined;
    case AppCommandId.showDebug:
      return Icons.bug_report_outlined;
    case AppCommandId.toggleBreakpoint:
      return Icons.radio_button_checked_rounded;
    case AppCommandId.startDebugging:
      return Icons.play_circle_outline_rounded;
    case AppCommandId.stopDebugging:
      return Icons.stop_circle_outlined;
    case AppCommandId.continueDebugging:
      return Icons.not_started_outlined;
    case AppCommandId.stepOver:
      return Icons.skip_next_rounded;
    case AppCommandId.selectDebugThread:
      return Icons.account_tree_outlined;
    case AppCommandId.selectDebugStackFrame:
      return Icons.layers_outlined;
    case AppCommandId.nextDiagnostic:
      return Icons.keyboard_double_arrow_down_rounded;
    case AppCommandId.previousDiagnostic:
      return Icons.keyboard_double_arrow_up_rounded;
    case AppCommandId.applyQuickFix:
      return Icons.auto_fix_high_rounded;
    case AppCommandId.previewQuickFix:
      return Icons.difference_outlined;
    case AppCommandId.refreshLanguageService:
      return Icons.manage_search_rounded;
    case AppCommandId.refreshWorkspaceDiagnostics:
      return Icons.rule_folder_outlined;
    case AppCommandId.refreshSourceControl:
      return Icons.account_tree_rounded;
    case AppCommandId.previewSourceControlDiff:
      return Icons.difference_outlined;
    case AppCommandId.stageSourceControl:
      return Icons.add_task_rounded;
    case AppCommandId.unstageSourceControl:
      return Icons.remove_done_outlined;
    case AppCommandId.planSourceControlBranchSwitch:
      return Icons.alt_route_rounded;
    case AppCommandId.planSourceControlCommitDraft:
      return Icons.commit_rounded;
    case AppCommandId.collectProjectLanguageContext:
      return Icons.schema_outlined;
    case AppCommandId.goToDefinition:
      return Icons.subdirectory_arrow_right_rounded;
    case AppCommandId.openWorkspaceFile:
      return Icons.file_open_outlined;
    case AppCommandId.createWorkspaceFile:
      return Icons.note_add_outlined;
    case AppCommandId.renameWorkspaceFile:
      return Icons.drive_file_rename_outline_rounded;
    case AppCommandId.deleteWorkspaceFile:
      return Icons.delete_outline_rounded;
    case AppCommandId.revealWorkspaceFile:
      return Icons.folder_open_outlined;
    case AppCommandId.searchWorkspace:
      return Icons.search_rounded;
    case AppCommandId.previewWorkspaceReplace:
      return Icons.find_replace_rounded;
    case AppCommandId.applyWorkspaceReplace:
      return Icons.playlist_add_check_rounded;
    case AppCommandId.runBuild:
      return Icons.construction_rounded;
    case AppCommandId.formatActiveDocument:
      return Icons.format_align_left_rounded;
    case AppCommandId.runStaticAnalysis:
      return Icons.fact_check_outlined;
    case AppCommandId.runTests:
      return Icons.science_outlined;
    case AppCommandId.rerunFailedTests:
      return Icons.replay_circle_filled_outlined;
    case AppCommandId.debugFailedTests:
      return Icons.bug_report_rounded;
    case AppCommandId.runTestConfiguration:
      return Icons.playlist_play_rounded;
    case AppCommandId.debugTestConfiguration:
      return Icons.science_rounded;
    case AppCommandId.nextReference:
      return Icons.keyboard_arrow_down_rounded;
    case AppCommandId.previousReference:
      return Icons.keyboard_arrow_up_rounded;
    case AppCommandId.renameSymbol:
      return Icons.drive_file_rename_outline_rounded;
    case AppCommandId.safeDelete:
      return Icons.delete_sweep_outlined;
    case AppCommandId.inlineVariable:
      return Icons.merge_type_rounded;
    case AppCommandId.openFile:
      return Icons.folder_open_rounded;
    case AppCommandId.reloadFile:
      return Icons.refresh_rounded;
    case AppCommandId.openSettings:
      return Icons.settings_outlined;
    default:
      return Icons.help_outline_rounded;
  }
}

class _SurfaceTabChip extends StatelessWidget {
  const _SurfaceTabChip({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);
    final motion = VityoMotion.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        hoverColor: tokens.hover,
        child: AnimatedContainer(
          duration: motion.fast,
          curve: motion.emphasized,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
          decoration: BoxDecoration(
            color: active ? tokens.elevated : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: active ? tokens.divider : Colors.transparent,
            ),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: active ? tokens.ink : tokens.muted,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              letterSpacing: 0,
            ),
          ),
        ),
      ),
    );
  }
}

String _fileName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/').where((segment) => segment.isNotEmpty);
  return segments.isEmpty ? path : segments.last;
}

String _workspaceDisplayPath({
  required String workspaceRoot,
  required String filePath,
}) {
  final normalizedRoot = workspaceRoot
      .replaceAll('\\', '/')
      .replaceFirst(RegExp(r'/$'), '');
  final normalizedPath = filePath.replaceAll('\\', '/');
  final rootPrefix = '$normalizedRoot/';
  final windowsPath = RegExp(r'^[A-Za-z]:/').hasMatch(normalizedRoot);
  final withinRoot = windowsPath
      ? normalizedPath.toLowerCase().startsWith(rootPrefix.toLowerCase())
      : normalizedPath.startsWith(rootPrefix);
  if (normalizedRoot.isNotEmpty && withinRoot) {
    return normalizedPath.substring(rootPrefix.length);
  }
  if (!normalizedPath.startsWith('/') &&
      !RegExp(r'^[A-Za-z]:/').hasMatch(normalizedPath)) {
    return normalizedPath;
  }
  return _fileName(normalizedPath);
}

String _languageStatusLabel(LanguageServiceStatusSurface? status) {
  if (status == null) {
    return 'language starting';
  }
  return switch (status.severity) {
    LanguageServiceStatusSeverity.ready => 'Styio ready',
    LanguageServiceStatusSeverity.refreshing => 'Styio refreshing',
    LanguageServiceStatusSeverity.degraded => 'Styio degraded',
    LanguageServiceStatusSeverity.unavailable => 'Styio unavailable',
    LanguageServiceStatusSeverity.failed => 'Styio failed',
  };
}

class _ModuleTile extends StatelessWidget {
  const _ModuleTile({
    required this.module,
    required this.mounted,
    required this.platformTarget,
  });

  final ModuleDefinition module;
  final bool mounted;
  final PlatformTarget platformTarget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);
    final rule = module.ruleFor(platformTarget);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: mounted ? tokens.accentSoft : tokens.elevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: mounted
              ? tokens.accent.withValues(alpha: 0.30)
              : tokens.divider,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    module.manifest.displayName,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                WorkbenchMetaPill(
                  label: mounted ? 'Mounted' : 'Visible',
                  color: mounted ? tokens.accent : null,
                  filled: mounted,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(module.manifest.description, style: theme.textTheme.bodySmall),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                WorkbenchMetaPill(label: module.manifest.kind.wireValue),
                WorkbenchMetaPill(label: module.manifest.slot.wireValue),
                WorkbenchMetaPill(label: rule.distributionChannel),
              ],
            ),
            const SizedBox(height: 10),
            Text(rule.note, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
