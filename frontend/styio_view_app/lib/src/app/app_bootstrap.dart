import '../backend_toolchain/adapter_contracts.dart';
import '../backend_toolchain/dependency_source_adapter.dart';
import '../backend_toolchain/deployment_adapter.dart';
import '../backend_toolchain/execution_adapter.dart';
import '../backend_toolchain/project_graph_adapter.dart';
import '../backend_toolchain/project_graph_contract.dart';
import '../backend_toolchain/runtime_event_adapter.dart';
import '../backend_toolchain/toolchain_management_adapter.dart';
import '../editor/editor_controller.dart';
import '../language/simple_styio_language_service.dart';
import '../module_host/module_registry.dart';
import '../platform/native_module_loader.dart';
import '../platform/platform_target.dart';
import 'state/workspace_document_store.dart';
import 'state/workspace_controller.dart';

class AppBootstrap {
  const AppBootstrap({
    required this.platformTarget,
    required this.moduleRegistry,
    required this.nativeModuleLoader,
    required this.projectGraphAdapter,
    required this.supplementalAdapterCapabilities,
    required this.workspaceController,
    required this.workspaceDocumentStore,
    required this.editorController,
    required this.executionAdapter,
    required this.executionAdapterFactory,
    required this.runtimeEventAdapter,
    required this.dependencySourceAdapter,
    required this.deploymentAdapter,
    required this.toolchainManagementAdapter,
  });

  final PlatformTarget platformTarget;
  final ModuleRegistry moduleRegistry;
  final NativeModuleLoader nativeModuleLoader;
  final ProjectGraphAdapter projectGraphAdapter;
  final List<AdapterCapabilitySnapshot> supplementalAdapterCapabilities;
  final WorkspaceController workspaceController;
  final WorkspaceDocumentStore workspaceDocumentStore;
  final EditorSessionController editorController;
  final ExecutionAdapter executionAdapter;
  final ExecutionAdapterFactory executionAdapterFactory;
  final RuntimeEventAdapter runtimeEventAdapter;
  final DependencySourceAdapter dependencySourceAdapter;
  final DeploymentAdapter deploymentAdapter;
  final ToolchainManagementAdapter toolchainManagementAdapter;

  List<AdapterCapabilitySnapshot> get adapterCapabilities =>
      normalizeCapabilitySnapshots([
        projectGraphAdapter.capabilitySnapshot,
        executionAdapter.capabilitySnapshot,
        runtimeEventAdapter.capabilitySnapshot,
        ...supplementalAdapterCapabilities,
      ]);

  static Future<AppBootstrap> load() async {
    final platformTarget = detectPlatformTarget();
    final workspaceDocumentStore = await createWorkspaceDocumentStore();
    final moduleRegistry = await ModuleRegistry.loadFromAssets(
      indexAssetPath: 'assets/module_manifests/index.json',
      platformTarget: platformTarget,
    );
    final nativeModuleLoader = NoopNativeModuleLoader(
      platformTarget: platformTarget,
    );
    final projectGraphAdapter = await createProjectGraphAdapter(
      platformTarget: platformTarget,
    );
    final projectSnapshot = await projectGraphAdapter.loadProjectGraph();
    final workspaceController = WorkspaceController(
      projectSnapshot: projectSnapshot,
    );
    Future<ExecutionAdapter> executionAdapterFactory(
      ProjectGraphSnapshot refreshedProjectGraph,
    ) {
      return createExecutionAdapter(
        platformTarget: platformTarget,
        projectGraph: refreshedProjectGraph,
      );
    }

    final executionAdapter = await executionAdapterFactory(projectSnapshot);
    final runtimeEventAdapter = createRuntimeEventAdapter(
      platformTarget: platformTarget,
    );
    final dependencySourceAdapter = await createDependencySourceAdapter(
      platformTarget: platformTarget,
    );
    final deploymentAdapter = await createDeploymentAdapter(
      platformTarget: platformTarget,
    );
    final toolchainManagementAdapter = await createToolchainManagementAdapter(
      platformTarget: platformTarget,
    );
    final ffiBridge = await nativeModuleLoader.describe(
      'local.runtime.desktop',
    );
    final supplementalAdapterCapabilities = normalizeCapabilitySnapshots([
      buildFfiAdapterCapability(
        visible: ffiBridge.state != NativeBridgeState.unavailable,
        executionSlotVisible: ffiBridge.state != NativeBridgeState.unavailable,
        detail: ffiBridge.detail,
      ),
      buildCloudAdapterCapability(
        supportsCloudExecution:
            platformTarget == PlatformTarget.ios ||
            platformTarget == PlatformTarget.web ||
            platformTarget == PlatformTarget.android,
        supportsHostedProjectGraph:
            platformTarget == PlatformTarget.ios ||
            platformTarget == PlatformTarget.web,
        detail: platformTarget == PlatformTarget.web
            ? 'Hosted/cloud adapters back Web workspaces while local binaries stay unavailable.'
            : platformTarget == PlatformTarget.ios
            ? 'iOS keeps cloud execution as the compliance floor.'
            : 'Cloud adapters remain a supplement for mobile fallback and hosted workspaces.',
      ),
    ]);
    final initialDocument = await workspaceDocumentStore.loadDocument(
      workspaceController.activeFilePath,
    );

    return AppBootstrap(
      platformTarget: platformTarget,
      moduleRegistry: moduleRegistry,
      nativeModuleLoader: nativeModuleLoader,
      projectGraphAdapter: projectGraphAdapter,
      supplementalAdapterCapabilities: supplementalAdapterCapabilities,
      workspaceController: workspaceController,
      workspaceDocumentStore: workspaceDocumentStore,
      editorController: EditorSessionController(
        initialDocument: initialDocument,
        languageService: const SimpleStyioLanguageService(),
      ),
      executionAdapter: executionAdapter,
      executionAdapterFactory: executionAdapterFactory,
      runtimeEventAdapter: runtimeEventAdapter,
      dependencySourceAdapter: dependencySourceAdapter,
      deploymentAdapter: deploymentAdapter,
      toolchainManagementAdapter: toolchainManagementAdapter,
    );
  }
}
