/// Feature operations supplied to the Flow Hero presentation by its app root.
///
/// This contract describes only the services Flow Hero uses. Platform
/// detection, service construction, and concrete adapters stay in the
/// production composition module.
library;

import 'execution_service.dart';
import 'language_service.dart';
import 'local_service_contract.dart';
import 'model_config.dart';
import 'theme_store.dart';
import 'toolchain_install_contract.dart';
import 'toolchain_store.dart';
import 'workspace_file_index.dart';
import 'workspace_store.dart';

abstract interface class FlowHeroFeatureRuntime {
  /// False for isolated compile acceptance, before any Agent state is read.
  bool get agentEnabled;
  FlowHeroLocalServiceOwner get localServices;
  FlowHeroThemeStore get themeStore;
  FlowHeroWorkspaceStore get workspaceStore;
  FlowHeroModelConfigStore get modelConfigStore;
  FlowHeroProviderConfigWriter get providerConfigWriter;
  FlowHeroAgentSecretStore get agentSecretStore;
  FlowHeroToolchainStore get toolchainStore;

  FlowHeroWorkspaceFileIndex createWorkspaceFileIndex(String root);

  Future<FlowHeroExecutionSource> bootExecution(
    String workspaceRoot,
    FlowHeroToolchainSelection selection,
  );

  Future<FlowHeroLanguageSession> bootLanguage(
    String workspaceRoot,
    FlowHeroToolchainSelection selection,
  );

  Future<FlowHeroToolchainProbeResult> probeToolchain(
    FlowHeroToolchainKind kind,
    String path,
  );

  Future<void> dispose();
}
