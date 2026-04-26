import 'package:flutter_test/flutter_test.dart';
import 'package:styio_view_app/src/frontend_shell/frontend_shell.dart';
import 'package:styio_view_app/src/editor/editor_controller.dart';
import 'package:styio_view_app/src/editor/document_state.dart';
import 'package:styio_view_app/src/backend_toolchain/adapter_contracts.dart';
import 'package:styio_view_app/src/backend_toolchain/dependency_source_adapter.dart';
import 'package:styio_view_app/src/backend_toolchain/deployment_adapter.dart';
import 'package:styio_view_app/src/backend_toolchain/execution_adapter.dart';
import 'package:styio_view_app/src/backend_toolchain/project_graph_adapter.dart';
import 'package:styio_view_app/src/backend_toolchain/project_graph_contract.dart';
import 'package:styio_view_app/src/backend_toolchain/runtime_event_adapter.dart';
import 'package:styio_view_app/src/backend_toolchain/toolchain_management_adapter.dart';
import 'package:styio_view_app/src/language/language_contract.dart';
import 'package:styio_view_app/src/language/simple_styio_language_service.dart';
import 'package:styio_view_app/src/module_host/module_registry.dart';
import 'package:styio_view_app/src/platform/native_module_loader.dart';
import 'package:styio_view_app/src/platform/platform_target.dart';

void main() {
  test(
    'successful toolchain switch refreshes project graph and execution route',
    () async {
      final initialGraph = _projectGraph(
        compilerVersion: '0.0.1',
        compilePlanReady: false,
      );
      final refreshedGraph = _projectGraph(
        compilerVersion: '0.0.5',
        compilePlanReady: true,
      );
      final shell = ShellModel(
        platformTarget: PlatformTarget.macos,
        supplementalAdapterCapabilities: const <AdapterCapabilitySnapshot>[],
        projectGraphAdapter: _SequenceProjectGraphAdapter(
          snapshots: <ProjectGraphSnapshot>[refreshedGraph],
        ),
        workspaceController: WorkspaceController(projectSnapshot: initialGraph),
        workspaceDocumentStore: InMemoryWorkspaceDocumentStore(),
        moduleRegistry: ModuleRegistry(
          platformTarget: PlatformTarget.macos,
          definitions: const [],
        ),
        nativeModuleLoader: const NoopNativeModuleLoader(
          platformTarget: PlatformTarget.macos,
        ),
        editorController: EditorSessionController(
          initialDocument: EditorSessionController.seedDocumentForPath(
            initialGraph.editorFiles.first,
          ),
          languageService: const SimpleStyioLanguageService(),
        ),
        executionAdapter: _RefreshAwareExecutionAdapter(
          projectGraph: initialGraph,
        ),
        executionAdapterFactory: (ProjectGraphSnapshot projectGraph) async =>
            _RefreshAwareExecutionAdapter(projectGraph: projectGraph),
        runtimeEventAdapter: createRuntimeEventAdapter(
          platformTarget: PlatformTarget.macos,
        ),
        dependencySourceAdapter: const _SuccessfulDependencySourceAdapter(),
        deploymentAdapter: const _SuccessfulDeploymentAdapter(),
        toolchainManagementAdapter:
            const _SuccessfulToolchainManagementAdapter(),
      );
      addTearDown(shell.dispose);

      final result = await shell.useManagedCompiler(
        compilerVersion: '0.0.5',
        channel: 'stable',
      );

      expect(result.succeeded, isTrue);
      expect(
        shell.workspaceController.activeProject.activeCompiler?.compilerVersion,
        '0.0.5',
      );
      final cliCapability = shell.adapterCapabilities.firstWhere(
        (snapshot) => snapshot.adapterKind == AdapterKind.cli,
      );
      expect(cliCapability.execution.level, AdapterCapabilityLevel.available);
      expect(
        shell.debugLog.any(
          (entry) => entry.contains('Project graph refreshed'),
        ),
        isTrue,
      );
    },
  );

  test('successful publish preflight is stored as deployment state', () async {
    final initialGraph = _projectGraph(
      compilerVersion: '0.0.5',
      compilePlanReady: true,
    );
    final shell = ShellModel(
      platformTarget: PlatformTarget.macos,
      supplementalAdapterCapabilities: const <AdapterCapabilitySnapshot>[],
      projectGraphAdapter: _SequenceProjectGraphAdapter(
        snapshots: <ProjectGraphSnapshot>[initialGraph],
      ),
      workspaceController: WorkspaceController(projectSnapshot: initialGraph),
      workspaceDocumentStore: InMemoryWorkspaceDocumentStore(),
      moduleRegistry: ModuleRegistry(
        platformTarget: PlatformTarget.macos,
        definitions: const [],
      ),
      nativeModuleLoader: const NoopNativeModuleLoader(
        platformTarget: PlatformTarget.macos,
      ),
      editorController: EditorSessionController(
        initialDocument: EditorSessionController.seedDocumentForPath(
          initialGraph.editorFiles.first,
        ),
        languageService: const SimpleStyioLanguageService(),
      ),
      executionAdapter: _RefreshAwareExecutionAdapter(
        projectGraph: initialGraph,
      ),
      executionAdapterFactory: (ProjectGraphSnapshot projectGraph) async =>
          _RefreshAwareExecutionAdapter(projectGraph: projectGraph),
      runtimeEventAdapter: createRuntimeEventAdapter(
        platformTarget: PlatformTarget.macos,
      ),
      dependencySourceAdapter: const _SuccessfulDependencySourceAdapter(),
      deploymentAdapter: const _SuccessfulDeploymentAdapter(),
      toolchainManagementAdapter: const _SuccessfulToolchainManagementAdapter(),
    );
    addTearDown(shell.dispose);

    final result = await shell.preparePublish(packageName: 'demo/app');

    expect(result.succeeded, isTrue);
    expect(shell.lastDeploymentCommand, same(result));
    expect(
      shell.debugLog.any((entry) => entry.contains('deploy package: demo/app')),
      isTrue,
    );
    expect(
      shell.debugLog.any((entry) => entry.contains('deploy archive:')),
      isTrue,
    );
  });

  test(
    'toolchain and deployment commands dispatch through shell command flow',
    () async {
      final initialGraph = _projectGraph(
        compilerVersion: '0.0.5',
        compilePlanReady: true,
      );
      final refreshedGraph = _projectGraph(
        compilerVersion: '0.0.5',
        compilePlanReady: true,
      );
      final shell = ShellModel(
        platformTarget: PlatformTarget.macos,
        supplementalAdapterCapabilities: const <AdapterCapabilitySnapshot>[],
        projectGraphAdapter: _SequenceProjectGraphAdapter(
          snapshots: <ProjectGraphSnapshot>[refreshedGraph],
        ),
        workspaceController: WorkspaceController(projectSnapshot: initialGraph),
        workspaceDocumentStore: InMemoryWorkspaceDocumentStore(),
        moduleRegistry: ModuleRegistry(
          platformTarget: PlatformTarget.macos,
          definitions: const [],
        ),
        nativeModuleLoader: const NoopNativeModuleLoader(
          platformTarget: PlatformTarget.macos,
        ),
        editorController: EditorSessionController(
          initialDocument: EditorSessionController.seedDocumentForPath(
            initialGraph.editorFiles.first,
          ),
          languageService: const SimpleStyioLanguageService(),
        ),
        executionAdapter: _RefreshAwareExecutionAdapter(
          projectGraph: initialGraph,
        ),
        executionAdapterFactory: (ProjectGraphSnapshot projectGraph) async =>
            _RefreshAwareExecutionAdapter(projectGraph: projectGraph),
        runtimeEventAdapter: createRuntimeEventAdapter(
          platformTarget: PlatformTarget.macos,
        ),
        dependencySourceAdapter: const _SuccessfulDependencySourceAdapter(),
        deploymentAdapter: const _SuccessfulDeploymentAdapter(),
        toolchainManagementAdapter:
            const _SuccessfulToolchainManagementAdapter(),
      );
      addTearDown(shell.dispose);

      await shell.executeCommand(AppCommandId.useActiveCompiler);
      await shell.executeCommand(AppCommandId.preparePublish);

      expect(shell.lastToolchainCommand?.command, 'tool use');
      expect(shell.lastToolchainCommand?.succeeded, isTrue);
      expect(shell.lastDeploymentCommand?.command, 'publish');
      expect(shell.lastDeploymentCommand?.succeeded, isTrue);
      expect(
        shell.debugLog.any((entry) => entry.contains('tool use succeeded')),
        isTrue,
      );
      expect(
        shell.debugLog.any((entry) => entry.contains('publish succeeded')),
        isTrue,
      );
    },
  );

  test(
    'vendor command dispatch refreshes project graph and stores source state',
    () async {
      final initialGraph = _projectGraph(
        compilerVersion: '0.0.5',
        compilePlanReady: true,
      );
      final refreshedGraph =
          _projectGraph(
            compilerVersion: '0.0.5',
            compilePlanReady: true,
          ).copyWith(
            sourceState: const ProjectSourceStateSnapshot(
              schemaVersion: 1,
              vendor: VendorSourceStateSnapshot(
                vendorRoot: '/workspace/demo/.spio/vendor',
                metadataPath: '/workspace/demo/.spio/vendor/spio-vendor.json',
                vendorPresent: true,
                metadataPresent: true,
                gitSnapshots: 1,
              ),
            ),
          );
      final shell = ShellModel(
        platformTarget: PlatformTarget.macos,
        supplementalAdapterCapabilities: const <AdapterCapabilitySnapshot>[],
        projectGraphAdapter: _SequenceProjectGraphAdapter(
          snapshots: <ProjectGraphSnapshot>[refreshedGraph],
        ),
        workspaceController: WorkspaceController(projectSnapshot: initialGraph),
        workspaceDocumentStore: InMemoryWorkspaceDocumentStore(),
        moduleRegistry: ModuleRegistry(
          platformTarget: PlatformTarget.macos,
          definitions: const [],
        ),
        nativeModuleLoader: const NoopNativeModuleLoader(
          platformTarget: PlatformTarget.macos,
        ),
        editorController: EditorSessionController(
          initialDocument: EditorSessionController.seedDocumentForPath(
            initialGraph.editorFiles.first,
          ),
          languageService: const SimpleStyioLanguageService(),
        ),
        executionAdapter: _RefreshAwareExecutionAdapter(
          projectGraph: initialGraph,
        ),
        executionAdapterFactory: (ProjectGraphSnapshot projectGraph) async =>
            _RefreshAwareExecutionAdapter(projectGraph: projectGraph),
        runtimeEventAdapter: createRuntimeEventAdapter(
          platformTarget: PlatformTarget.macos,
        ),
        dependencySourceAdapter: const _SuccessfulDependencySourceAdapter(),
        deploymentAdapter: const _SuccessfulDeploymentAdapter(),
        toolchainManagementAdapter:
            const _SuccessfulToolchainManagementAdapter(),
      );
      addTearDown(shell.dispose);

      await shell.executeCommand(AppCommandId.vendorDependencies);

      expect(shell.lastDependencySourceCommand?.succeeded, isTrue);
      expect(shell.lastDependencySourceCommand?.command, 'vendor');
      expect(
        shell
            .workspaceController
            .activeProject
            .sourceState
            ?.vendor
            .gitSnapshots,
        1,
      );
      expect(
        shell.debugLog.any((entry) => entry.contains('vendor metadata:')),
        isTrue,
      );
    },
  );

  test(
    'run command logs runtime event summaries for published sessions',
    () async {
      final initialGraph = _projectGraph(
        compilerVersion: '0.0.5',
        compilePlanReady: true,
      );
      recordRuntimeEventsForSession(
        'shell-runtime-session',
        <RuntimeEventEnvelope>[
          RuntimeEventEnvelope(
            schemaVersion: 1,
            sessionId: 'shell-runtime-session',
            sequence: 1,
            timestamp: DateTime.utc(2026, 4, 17, 0, 0, 0),
            eventKind: 'compile.started',
            origin: 'styio.compile-plan',
            payload: const <String, Object?>{'intent': 'run'},
          ),
          RuntimeEventEnvelope(
            schemaVersion: 1,
            sessionId: 'shell-runtime-session',
            sequence: 2,
            timestamp: DateTime.utc(2026, 4, 17, 0, 0, 1),
            eventKind: 'run.finished',
            origin: 'styio.runtime',
            payload: const <String, Object?>{'success': true},
          ),
        ],
      );
      addTearDown(() => clearRuntimeEventsForSession('shell-runtime-session'));

      final shell = ShellModel(
        platformTarget: PlatformTarget.macos,
        supplementalAdapterCapabilities: const <AdapterCapabilitySnapshot>[],
        projectGraphAdapter: _SequenceProjectGraphAdapter(
          snapshots: <ProjectGraphSnapshot>[initialGraph],
        ),
        workspaceController: WorkspaceController(projectSnapshot: initialGraph),
        workspaceDocumentStore: InMemoryWorkspaceDocumentStore(),
        moduleRegistry: ModuleRegistry(
          platformTarget: PlatformTarget.macos,
          definitions: const [],
        ),
        nativeModuleLoader: const NoopNativeModuleLoader(
          platformTarget: PlatformTarget.macos,
        ),
        editorController: EditorSessionController(
          initialDocument: EditorSessionController.seedDocumentForPath(
            initialGraph.editorFiles.first,
          ),
          languageService: const SimpleStyioLanguageService(),
        ),
        executionAdapter: const _SuccessfulExecutionAdapter(
          sessionId: 'shell-runtime-session',
        ),
        executionAdapterFactory: (ProjectGraphSnapshot projectGraph) async =>
            const _SuccessfulExecutionAdapter(
              sessionId: 'shell-runtime-session',
            ),
        runtimeEventAdapter: createRuntimeEventAdapter(
          platformTarget: PlatformTarget.macos,
        ),
        dependencySourceAdapter: const _SuccessfulDependencySourceAdapter(),
        deploymentAdapter: const _SuccessfulDeploymentAdapter(),
        toolchainManagementAdapter:
            const _SuccessfulToolchainManagementAdapter(),
      );
      addTearDown(shell.dispose);

      await shell.executeCommand(AppCommandId.run);

      expect(shell.lastExecutionSession?.sessionId, 'shell-runtime-session');
      expect(
        shell.debugLog.any(
          (entry) => entry.contains('runtime events: 2 event(s)'),
        ),
        isTrue,
      );
      expect(
        shell.debugLog.any(
          (entry) => entry.contains('runtime: compile.started'),
        ),
        isTrue,
      );
      expect(
        shell.debugLog.any((entry) => entry.contains('runtime: run.finished')),
        isTrue,
      );
    },
  );
}

ProjectGraphSnapshot _projectGraph({
  required String compilerVersion,
  required bool compilePlanReady,
}) {
  return ProjectGraphSnapshot(
    id: '/workspace/demo/spio.toml',
    title: 'demo/app',
    kind: ProjectKind.package,
    workspaceRoot: '/workspace/demo',
    workspaceMembers: const <String>[],
    manifestPath: '/workspace/demo/spio.toml',
    packages: const <ProjectPackageSnapshot>[],
    dependencies: const <ProjectDependencySnapshot>[],
    targets: const <ProjectTargetDescriptor>[
      ProjectTargetDescriptor(
        id: 'demo/app:bin:demo',
        packageName: 'demo/app',
        kind: ProjectTargetKind.bin,
        name: 'demo',
        filePath: '/workspace/demo/src/main.styio',
      ),
    ],
    editorFiles: const <String>['/workspace/demo/src/main.styio'],
    toolchain: const ToolchainStatusSnapshot(
      source: ToolchainResolutionSource.projectPin,
      detail: 'Project toolchain pin discovered for shell-model testing.',
      pinPath: '/workspace/demo/spio-toolchain.toml',
      channel: 'stable',
    ),
    lockState: ProjectLockState.unknown,
    vendorState: ProjectVendorState.present,
    activeCompiler: CompilerHandshakeSnapshot(
      binaryPath: '/toolchains/styio/bin/styio',
      tool: 'styio',
      compilerVersion: compilerVersion,
      channel: 'stable',
      variant: 'test-fixture',
      capabilities: const <String>[
        'machine_info_json',
        'single_file_entry',
        'jsonl_diagnostics',
      ],
      supportedContractVersions: <String, List<int>>{
        'machine_info': const <int>[1],
        'compile_plan': compilePlanReady ? const <int>[1] : const <int>[],
      },
      integrationPhase: compilePlanReady
          ? 'compile-plan-live'
          : 'bootstrap-single-file',
      featureFlags: <String, bool>{'compile_plan_consumer': compilePlanReady},
    ),
    notes: const <String>[],
  );
}

class _SequenceProjectGraphAdapter implements ProjectGraphAdapter {
  _SequenceProjectGraphAdapter({required List<ProjectGraphSnapshot> snapshots})
    : _snapshots = List<ProjectGraphSnapshot>.of(snapshots);

  final List<ProjectGraphSnapshot> _snapshots;

  @override
  AdapterCapabilitySnapshot get capabilitySnapshot =>
      const AdapterCapabilitySnapshot(
        adapterKind: AdapterKind.cli,
        languageService: AdapterEndpointCapability(
          level: AdapterCapabilityLevel.partial,
          detail: 'Project graph adapter does not provide language services.',
        ),
        projectGraph: AdapterEndpointCapability(
          level: AdapterCapabilityLevel.available,
          detail: 'Published project graph payload is available.',
        ),
        execution: AdapterEndpointCapability(
          level: AdapterCapabilityLevel.unavailable,
          detail: 'Project graph adapter does not execute documents.',
        ),
        runtimeEvents: AdapterEndpointCapability(
          level: AdapterCapabilityLevel.unavailable,
          detail: 'Project graph adapter does not emit runtime events.',
        ),
      );

  @override
  Future<ProjectGraphSnapshot> loadProjectGraph() async {
    if (_snapshots.isEmpty) {
      throw StateError('No project graph snapshots remain for the test.');
    }
    return _snapshots.removeAt(0);
  }
}

class _RefreshAwareExecutionAdapter implements ExecutionAdapter {
  const _RefreshAwareExecutionAdapter({required this.projectGraph});

  final ProjectGraphSnapshot projectGraph;

  @override
  AdapterCapabilitySnapshot get capabilitySnapshot => AdapterCapabilitySnapshot(
    adapterKind: AdapterKind.cli,
    languageService: const AdapterEndpointCapability(
      level: AdapterCapabilityLevel.unavailable,
      detail: 'Execution adapter does not provide language services.',
    ),
    projectGraph: const AdapterEndpointCapability(
      level: AdapterCapabilityLevel.unavailable,
      detail: 'Execution adapter does not own project graph data.',
    ),
    execution: AdapterEndpointCapability(
      level: projectGraph.compilePlanConsumerAdvertised
          ? AdapterCapabilityLevel.available
          : AdapterCapabilityLevel.partial,
      detail: projectGraph.compilePlanConsumerAdvertised
          ? 'Project execution is live through compile-plan v1.'
          : 'Project execution is blocked until compile-plan support is advertised.',
    ),
    runtimeEvents: const AdapterEndpointCapability(
      level: AdapterCapabilityLevel.unavailable,
      detail: 'Runtime events stay unavailable in this test fixture.',
    ),
  );

  @override
  Future<ExecutionSession> runActiveDocument({
    required PlatformTarget platformTarget,
    required ProjectGraphSnapshot projectGraph,
    required DocumentState document,
    required String activeFilePath,
  }) async {
    return const ExecutionSession(
      sessionId: 'shell-model-test',
      kind: 'run',
      status: ExecutionSessionStatus.blocked,
      statusMessage: 'Execution is not exercised in this shell-model test.',
      diagnostics: <Diagnostic>[],
      stdoutEvents: <ExecutionLogEvent>[],
      stderrEvents: <ExecutionLogEvent>[],
    );
  }
}

class _SuccessfulExecutionAdapter implements ExecutionAdapter {
  const _SuccessfulExecutionAdapter({required this.sessionId});

  final String sessionId;

  @override
  AdapterCapabilitySnapshot get capabilitySnapshot =>
      const AdapterCapabilitySnapshot(
        adapterKind: AdapterKind.cli,
        languageService: AdapterEndpointCapability(
          level: AdapterCapabilityLevel.unavailable,
          detail: 'Execution adapter does not provide language services.',
        ),
        projectGraph: AdapterEndpointCapability(
          level: AdapterCapabilityLevel.unavailable,
          detail: 'Execution adapter does not own project graph data.',
        ),
        execution: AdapterEndpointCapability(
          level: AdapterCapabilityLevel.available,
          detail: 'Project execution is live through compile-plan v1.',
        ),
        runtimeEvents: AdapterEndpointCapability(
          level: AdapterCapabilityLevel.partial,
          detail: 'Runtime events are replayed from published artifacts.',
        ),
      );

  @override
  Future<ExecutionSession> runActiveDocument({
    required PlatformTarget platformTarget,
    required ProjectGraphSnapshot projectGraph,
    required DocumentState document,
    required String activeFilePath,
  }) async {
    return ExecutionSession(
      sessionId: sessionId,
      kind: 'run',
      status: ExecutionSessionStatus.succeeded,
      statusMessage:
          'Execution completed through the shell-model test fixture.',
      diagnostics: const <Diagnostic>[],
      stdoutEvents: const <ExecutionLogEvent>[],
      stderrEvents: const <ExecutionLogEvent>[],
    );
  }
}

class _SuccessfulToolchainManagementAdapter
    implements ToolchainManagementAdapter {
  const _SuccessfulToolchainManagementAdapter();

  @override
  Future<ToolchainCommandResult> clearPinnedCompiler({
    required ProjectGraphSnapshot projectGraph,
  }) async {
    return _success('tool pin');
  }

  @override
  Future<ToolchainCommandResult> installManagedCompiler({
    required ProjectGraphSnapshot projectGraph,
    required String styioBinaryPath,
  }) async {
    return _success('tool install');
  }

  @override
  Future<ToolchainCommandResult> pinManagedCompiler({
    required ProjectGraphSnapshot projectGraph,
    required String compilerVersion,
    String? channel,
  }) async {
    return _success('tool pin');
  }

  @override
  Future<ToolchainCommandResult> useManagedCompiler({
    required ProjectGraphSnapshot projectGraph,
    required String compilerVersion,
    String? channel,
  }) async {
    return _success('tool use');
  }

  ToolchainCommandResult _success(String command) {
    return ToolchainCommandResult(
      command: command,
      status: ToolchainCommandStatus.succeeded,
      statusMessage: 'toolchain command succeeded in the shell-model fixture.',
      stdout: '',
      stderr: '',
    );
  }
}

class _SuccessfulDependencySourceAdapter implements DependencySourceAdapter {
  const _SuccessfulDependencySourceAdapter();

  @override
  Future<DependencySourceCommandResult> fetchDependencies({
    required ProjectGraphSnapshot projectGraph,
    bool locked = false,
    bool offline = false,
  }) async {
    return _success('fetch');
  }

  @override
  Future<DependencySourceCommandResult> vendorDependencies({
    required ProjectGraphSnapshot projectGraph,
    String? outputPath,
    bool locked = false,
    bool offline = false,
  }) async {
    return _success('vendor');
  }

  DependencySourceCommandResult _success(String command) {
    return DependencySourceCommandResult(
      command: command,
      status: DependencySourceCommandStatus.succeeded,
      statusMessage: '$command command succeeded in the shell-model fixture.',
      stdout: '',
      stderr: '',
      payload: <String, dynamic>{
        'packages': 2,
        'vendor_root': '/workspace/demo/.spio/vendor',
        'metadata_path': '/workspace/demo/.spio/vendor/spio-vendor.json',
      },
    );
  }
}

class _SuccessfulDeploymentAdapter implements DeploymentAdapter {
  const _SuccessfulDeploymentAdapter();

  @override
  Future<DeploymentCommandResult> packProject({
    required ProjectGraphSnapshot projectGraph,
    String? packageName,
    String? outputPath,
  }) async {
    return _success('pack', packageName: packageName);
  }

  @override
  Future<DeploymentCommandResult> preparePublish({
    required ProjectGraphSnapshot projectGraph,
    String? packageName,
    String? outputPath,
  }) async {
    return _success('publish', packageName: packageName);
  }

  @override
  Future<DeploymentCommandResult> publishToRegistry({
    required ProjectGraphSnapshot projectGraph,
    required String registryRoot,
    String? packageName,
    String? outputPath,
  }) async {
    return _success('publish', packageName: packageName);
  }

  DeploymentCommandResult _success(String command, {String? packageName}) {
    return DeploymentCommandResult(
      command: command,
      status: DeploymentCommandStatus.succeeded,
      statusMessage: 'deployment command succeeded in the shell-model fixture.',
      stdout: '',
      stderr: '',
      payload: <String, dynamic>{
        'package': packageName ?? 'demo/app',
        'archive_path': '/workspace/demo/dist/app-0.0.5.tar',
      },
    );
  }
}
