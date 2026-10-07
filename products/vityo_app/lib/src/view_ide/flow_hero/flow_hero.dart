/// Feature-facing Flow Hero services consumed by the render layer.
///
/// Concrete platform-manager and persistence implementations remain in this
/// feature directory; this barrel exposes only the state and service contracts
/// the presentation needs.
library;

export 'execution_service.dart'
    show
        FlowHeroExecutionKind,
        FlowHeroExecutionMode,
        FlowHeroExecutionOutcome,
        FlowHeroExecutionPhase,
        FlowHeroExecutionSource,
        FlowHeroExecutionUnavailableCause,
        FlowHeroToolchainCheck,
        FlowHeroToolchainDiagnosis,
        FlowHeroToolchainPairCheck,
        FlowHeroToolchainProvenanceDiagnosis,
        kFlowHeroPafioManifestName,
        kFlowHeroStyioSystemCandidatePaths;
export 'language_service.dart'
    show
        FlowHeroAnalysisOrigin,
        FlowHeroAsyncLanguageSource,
        FlowHeroLanguageMode,
        FlowHeroLanguageResult,
        FlowHeroLanguageSession,
        kFlowHeroLspProtocolVersion;
export 'model_config.dart'
    show
        FlowHeroAgentSecretStore,
        FlowHeroModelAuthMode,
        FlowHeroModelConfig,
        FlowHeroModelConfigSaveResult,
        FlowHeroModelConfigStore,
        FlowHeroModelProvider,
        FlowHeroProviderConfigWriter,
        kFlowHeroAgentProviderAccount,
        kFlowHeroAgentProviderService,
        kFlowHeroDeepSeekContextTokens,
        kFlowHeroDeepSeekDefaultModel,
        kFlowHeroDeepSeekEndpointBase,
        kFlowHeroDeepSeekModels,
        kFlowHeroProviderAdapter;
export 'runtime_contract.dart' show FlowHeroFeatureRuntime;
export 'local_service_contract.dart' show FlowHeroLocalServiceOwner;
export 'theme_store.dart' show FlowHeroThemeStore;
export 'toolchain_install_contract.dart'
    show
        FlowHeroToolchainProbe,
        FlowHeroToolchainProbeResult,
        FlowHeroToolchainSaveResult;
export 'toolchain_store.dart'
    show
        FlowHeroToolchainKind,
        FlowHeroToolchainSelection,
        FlowHeroToolchainStore;
export 'workspace_file_index.dart'
    show
        FlowHeroWorkspaceFileIndex,
        FlowHeroWorkspaceFileIndexFactory,
        flowHeroWorkspaceRoot,
        kFlowHeroWorkspaceNoise;
export 'workspace_store.dart' show FlowHeroWorkspaceStore;
