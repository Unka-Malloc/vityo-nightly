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
import 'toolchain_store.dart';
import 'workspace_file_index.dart';
import 'workspace_store.dart';

class ProductionFlowHeroRuntime implements FlowHeroFeatureRuntime {
  factory ProductionFlowHeroRuntime({FlowHeroLocalServices? localServices}) =>
      ProductionFlowHeroRuntime._(localServices ?? FlowHeroLocalServices());

  ProductionFlowHeroRuntime._(this.localServices)
    : themeStore = FlowHeroThemeStoreBoot.deferred(
        localServices: localServices,
      ),
      workspaceStore = FlowHeroWorkspaceStoreBoot.deferred(
        localServices: localServices,
      ),
      modelConfigStore = FlowHeroModelConfigStoreBoot.deferred(
        localServices: localServices,
      ),
      providerConfigWriter = FlowHeroProviderConfigWriterBoot.deferred(
        localServices: localServices,
      ),
      agentSecretStore = const FlowHeroKeychainAgentSecretStore(),
      toolchainStore = FlowHeroToolchainStoreBoot.deferred(
        localServices: localServices,
      );

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
    vityodClient: await _clientFor(workspaceRoot),
  );

  @override
  Future<FlowHeroLanguageSession> bootLanguage(
    String workspaceRoot,
    FlowHeroToolchainSelection selection,
  ) async => FlowHeroLanguageRuntime.boot(
    workspaceRoot: workspaceRoot,
    toolchainSelection: selection,
    vityodClient: await _clientFor(workspaceRoot),
  );

  @override
  Future<FlowHeroToolchainProbeResult> probeToolchain(
    FlowHeroToolchainKind kind,
    String path,
  ) async => probeFlowHeroToolchainBinary(
    kind: kind,
    path: path,
    vityodClient: await localServices.client(),
  );

  @override
  Future<void> dispose() => localServices.dispose();

  Future<VityodClient?> _clientFor(String workspaceRoot) async {
    if (workspaceRoot.trim().isEmpty) return null;
    return localServices.client();
  }
}
