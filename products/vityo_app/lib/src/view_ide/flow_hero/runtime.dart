/// Production composition for Flow Hero's view-facing feature services.
///
/// The render layer sees one feature runtime and its contracts. Platform
/// detection, daemon ownership, persistence adapters, and tool execution stay
/// behind this boundary.
library;

import '../../ide/local_service/vityod_client.dart';
import 'execution_service.dart';
import 'language_service.dart';
import 'local_services.dart';
import 'model_config.dart';
import 'runtime_contract.dart';
import 'theme_store.dart';
import 'toolchain_install_contract.dart';
import 'toolchain_install_runtime.dart';
import 'toolchain_candidates.dart';
import 'toolchain_store.dart';
import 'workspace_file_index.dart';
import 'workspace_store.dart';

class ProductionFlowHeroRuntime implements FlowHeroFeatureRuntime {
  factory ProductionFlowHeroRuntime({FlowHeroLocalServices? localServices}) =>
      ProductionFlowHeroRuntime._(localServices ?? FlowHeroLocalServices());

  /// Compile-only acceptance uses an explicit private store root and never
  /// constructs provider or keychain adapters.
  factory ProductionFlowHeroRuntime.compileAcceptance({
    required FlowHeroLocalServices localServices,
    required String homePath,
    required Map<String, String> environment,
  }) {
    if (homePath.trim().isEmpty) {
      throw ArgumentError.value(homePath, 'homePath', 'must not be empty');
    }
    return ProductionFlowHeroRuntime._(
      localServices,
      homePath: homePath,
      agentEnabled: false,
      environment: Map<String, String>.unmodifiable(environment),
    );
  }

  ProductionFlowHeroRuntime._(
    this.localServices, {
    String? homePath,
    this.agentEnabled = true,
    Map<String, String>? environment,
  }) : _environment = environment,
       themeStore = FlowHeroThemeStoreBoot.deferred(
         localServices: localServices,
         homePath: homePath,
       ),
       workspaceStore = FlowHeroWorkspaceStoreBoot.deferred(
         localServices: localServices,
         homePath: homePath,
       ),
       modelConfigStore = agentEnabled
           ? FlowHeroModelConfigStoreBoot.deferred(localServices: localServices)
           : FlowHeroMemoryModelConfigStore(),
       providerConfigWriter = agentEnabled
           ? FlowHeroProviderConfigWriterBoot.deferred(
               localServices: localServices,
             )
           : const FlowHeroUnavailableProviderConfigWriter(),
       agentSecretStore = agentEnabled
           ? const FlowHeroKeychainAgentSecretStore()
           : const FlowHeroDisabledAgentSecretStore(),
       toolchainStore = FlowHeroToolchainStoreBoot.deferred(
         localServices: localServices,
         homePath: homePath,
       );

  final Map<String, String>? _environment;

  @override
  final bool agentEnabled;

  @override
  final FlowHeroLocalServices localServices;
  @override
  final FlowHeroThemeStore themeStore;
  @override
  final FlowHeroWorkspaceStore workspaceStore;
  @override
  final FlowHeroModelConfigStore modelConfigStore;
  @override
  final FlowHeroProviderConfigWriter providerConfigWriter;
  @override
  final FlowHeroAgentSecretStore agentSecretStore;
  @override
  final FlowHeroToolchainStore toolchainStore;

  @override
  FlowHeroWorkspaceFileIndex createWorkspaceFileIndex(String root) =>
      FlowHeroWorkspaceFileIndexIO(root: root);

  @override
  Future<FlowHeroExecutionSource> bootExecution(
    String workspaceRoot,
    FlowHeroToolchainSelection selection,
  ) async => FlowHeroExecutionRuntime.boot(
    workspaceRoot: workspaceRoot,
    toolchainSelection: selection,
    environment: _environment,
    vityodClient: await _clientFor(workspaceRoot),
  );

  @override
  Future<FlowHeroLanguageSession> bootLanguage(
    String workspaceRoot,
    FlowHeroToolchainSelection selection,
  ) async => FlowHeroLanguageRuntime.boot(
    workspaceRoot: workspaceRoot,
    toolchainSelection: selection,
    environment: _environment,
    requireVityod: !agentEnabled,
    vityodClient: await _clientFor(workspaceRoot),
  );

  @override
  Future<FlowHeroToolchainProbeResult> probeToolchain(
    FlowHeroToolchainKind kind,
    String path,
  ) async => probeFlowHeroToolchainBinary(
    kind: kind,
    path: path,
    environment: _environment,
    vityodClient: await localServices.client(),
  );

  @override
  Future<List<FlowHeroToolchainCandidate>> discoverToolchainCandidates(
    FlowHeroToolchainKind kind,
    String selectedPath,
  ) async => discoverFlowHeroToolchainCandidates(
    kind: kind,
    selectedPath: selectedPath,
    environment: _environment,
    vityodClient: await localServices.client().timeout(
      const Duration(seconds: 3),
    ),
  );

  @override
  Future<void> dispose() => localServices.dispose();

  Future<VityodClient?> _clientFor(String workspaceRoot) async {
    if (workspaceRoot.trim().isEmpty) return null;
    return localServices.client();
  }
}
