part of '../vityo_app_smoke_test.dart';

Future<void> revealMobileLanguagePane(WidgetTester tester) async {
  final mobileInspectorScroll = find.byKey(
    const ValueKey('editor-language-layout-scroll-mobile'),
    skipOffstage: false,
  );
  if (mobileInspectorScroll.evaluate().isNotEmpty) {
    for (var attempt = 0; attempt < 2; attempt += 1) {
      await tester.drag(mobileInspectorScroll, const Offset(0, -260));
      await tester.pumpAndSettle();
    }
  }
}

Future<void> revealMobileBottomSurface(WidgetTester tester) async {
  final mobileScroll = find.byKey(const ValueKey('shell-mobile-scroll'));
  expect(mobileScroll, findsOneWidget);
  final scrollable = find.descendant(
    of: mobileScroll,
    matching: find.byType(Scrollable),
  );
  final scrollableState = tester.state<ScrollableState>(scrollable.first);
  scrollableState.position.jumpTo(scrollableState.position.maxScrollExtent);
  await tester.pumpAndSettle();
}

Future<void> revealDesktopLanguagePane(WidgetTester tester) async {
  final languagePane = find.byKey(const ValueKey('language-pane-desktop'));
  if (languagePane.evaluate().isEmpty) {
    await tester.tap(
      find.byKey(const ValueKey('editor-language-inspector-toggle')),
    );
    await tester.pumpAndSettle();
  }
  expect(languagePane, findsOneWidget);
}

Future<void> tapVisibleKey(WidgetTester tester, String keyValue) async {
  final target = find.byKey(ValueKey(keyValue));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pump();
}

Future<void> sendShortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
  bool alt = false,
  bool shift = false,
}) async {
  if (control) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  }
  if (alt) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  }
  if (shift) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyEvent(key);
  if (shift) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
  if (alt) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  }
  if (control) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
  await tester.pump();
}

Future<void> pumpKeyboardSurface(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> commitPlatformText(WidgetTester tester, String text) async {
  final state = tester.testTextInput.editingState;
  expect(state, isNotNull);
  final source = state!['text'] as String;
  final selectionStart = state['selectionBase'] as int;
  final selectionEnd = state['selectionExtent'] as int;
  final replacementStart = selectionStart < selectionEnd
      ? selectionStart
      : selectionEnd;
  final replacementEnd = selectionStart < selectionEnd
      ? selectionEnd
      : selectionStart;
  final nextOffset = replacementStart + text.length;
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: source.replaceRange(replacementStart, replacementEnd, text),
      selection: TextSelection.collapsed(offset: nextOffset),
      composing: TextRange.empty,
    ),
  );
  await tester.pump();
}

List<Color?> backgroundsForTextOnLine(
  WidgetTester tester, {
  required int lineIndex,
  required String text,
}) {
  final colors = <Color?>[];

  void visit(InlineSpan span) {
    if (span is TextSpan) {
      if (span.text == text) {
        colors.add(span.style?.backgroundColor);
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child);
      }
    }
  }

  final richTexts = tester.widgetList<RichText>(
    find.descendant(
      of: find.byKey(ValueKey('source-line-$lineIndex'), skipOffstage: false),
      matching: find.byType(RichText, skipOffstage: false),
      skipOffstage: false,
    ),
  );
  for (final richText in richTexts) {
    visit(richText.text);
  }
  return colors;
}

List<String> spanTextsOnLine(WidgetTester tester, {required int lineIndex}) {
  final texts = <String>[];

  void visit(InlineSpan span) {
    if (span is TextSpan) {
      if (span.text != null) {
        texts.add(span.text!);
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child);
      }
    }
  }

  final richTexts = tester.widgetList<RichText>(
    find.descendant(
      of: find.byKey(ValueKey('source-line-$lineIndex'), skipOffstage: false),
      matching: find.byType(RichText, skipOffstage: false),
      skipOffstage: false,
    ),
  );
  for (final richText in richTexts) {
    visit(richText.text);
  }
  return texts;
}

ProjectGraphSnapshot createProjectSnapshot(PlatformTarget target) {
  final root = target == PlatformTarget.ios
      ? '/workspace/cloud-preview'
      : '/workspace/demo';
  final title = target == PlatformTarget.ios
      ? 'Cloud Preview Project'
      : 'Demo Project';
  const packageName = 'demo/app';
  final targets = <ProjectTargetDescriptor>[
    ProjectTargetDescriptor(
      id: '$packageName:bin:demo',
      packageName: packageName,
      kind: ProjectTargetKind.bin,
      name: 'demo',
      filePath: '$root/src/main.styio',
    ),
    ProjectTargetDescriptor(
      id: '$packageName:test:render-flow',
      packageName: packageName,
      kind: ProjectTargetKind.test,
      name: 'render-flow',
      filePath: '$root/src/render_flow.styio',
    ),
  ];

  return ProjectGraphSnapshot(
    id: '$root/pafio.toml',
    title: title,
    kind: ProjectKind.combinedRoot,
    workspaceRoot: root,
    workspaceMembers: const <String>['packages/render-kit'],
    manifestPath: '$root/pafio.toml',
    lockfilePath: '$root/pafio.lock',
    vendorRoot: '$root/.pafio/vendor',
    packages: <ProjectPackageSnapshot>[
      ProjectPackageSnapshot(
        packageName: packageName,
        version: '0.0.1',
        rootPath: root,
        manifestPath: '$root/pafio.toml',
        dependencies: const <ProjectDependencySnapshot>[
          ProjectDependencySnapshot(
            sourcePackageName: 'demo/app',
            dependencyName: 'render/kit',
            kind: ProjectDependencyKind.runtime,
            requirement: 'workspace',
            isWorkspaceReference: true,
          ),
          ProjectDependencySnapshot(
            sourcePackageName: 'demo/app',
            dependencyName: 'assertions',
            kind: ProjectDependencyKind.dev,
            requirement: '^1.0.0',
          ),
        ],
        targets: targets,
      ),
    ],
    dependencies: const <ProjectDependencySnapshot>[
      ProjectDependencySnapshot(
        sourcePackageName: 'demo/app',
        dependencyName: 'render/kit',
        kind: ProjectDependencyKind.runtime,
        requirement: 'workspace',
        isWorkspaceReference: true,
      ),
      ProjectDependencySnapshot(
        sourcePackageName: 'demo/app',
        dependencyName: 'assertions',
        kind: ProjectDependencyKind.dev,
        requirement: '^1.0.0',
      ),
    ],
    targets: targets,
    editorFiles: <String>[
      '$root/src/main.styio',
      '$root/src/render_flow.styio',
      '$root/src/runtime_graph.styio',
    ],
    toolchain: const ToolchainStatusSnapshot(
      source: ToolchainResolutionSource.environment,
      detail: 'System Styio discovered for the smoke test fixture.',
      channel: 'system',
      version: '0.0.1',
    ),
    lockState: ProjectLockState.unknown,
    vendorState: ProjectVendorState.present,
    activeCompiler: const CompilerHandshakeSnapshot(
      binaryPath: '/toolchains/styio/bin/styio',
      tool: 'styio',
      compilerVersion: '0.0.1',
      channel: 'stable',
      variant: 'smoke-fixture',
      capabilities: <String>[
        'machine_info_json',
        'single_file_entry',
        'jsonl_diagnostics',
      ],
      supportedContractVersions: <String, List<int>>{
        'machine_info': <int>[1],
        'jsonl_diagnostics': <int>[1],
      },
      integrationPhase: 'bootstrap-single-file',
    ),
    notes: const <String>[
      'Smoke test fixture mirrors a canonical pafio project.',
    ],
  );
}

ProjectGraphSnapshot createReadmeOnlyProjectSnapshot() {
  const root = '/workspace/readme-only';
  const activeFile = '$root/README.md';
  return const ProjectGraphSnapshot(
    id: '$root/pafio.toml',
    title: 'Readme Only Project',
    kind: ProjectKind.scratch,
    workspaceRoot: root,
    workspaceMembers: <String>[],
    packages: <ProjectPackageSnapshot>[],
    dependencies: <ProjectDependencySnapshot>[],
    targets: <ProjectTargetDescriptor>[],
    editorFiles: <String>[activeFile],
    toolchain: ToolchainStatusSnapshot(
      source: ToolchainResolutionSource.unavailable,
      detail: 'No Styio files are present in this smoke fixture.',
    ),
    lockState: ProjectLockState.missing,
    vendorState: ProjectVendorState.missing,
    notes: <String>['Fixture intentionally contains no Styio files.'],
  );
}

Future<AppBootstrap> createBootstrap(
  PlatformTarget target, {
  ProjectGraphSnapshot? projectSnapshot,
  List<AdapterCapabilitySnapshot>? supplementalCapabilities,
  List<ModuleDefinition> moduleDefinitions = const <ModuleDefinition>[],
}) async {
  final project = projectSnapshot ?? createProjectSnapshot(target);
  final workspaceController = WorkspaceController(projectSnapshot: project);
  final projectGraphAdapter = _FakeProjectGraphAdapter(project);
  final toolchainStatusReport = ValueNotifier<ToolchainManagerStatusReport>(
    const ToolchainManagerStatusReport(
      status: ToolchainManagerStatus.ready,
      snapshot: ToolchainStateSnapshot(
        targetId: 'smoke-target',
        workspaceId: 'smoke-workspace',
        entries: <ToolchainStateEntry>[
          ToolchainStateEntry(
            id: 'smoke-language-service',
            kind: ToolchainKind.languageService,
            displayName: 'Smoke StyioService',
            executablePath: '/opt/styio/bin/styio',
            active: true,
            version: '0.0.9',
            channel: 'smoke',
          ),
        ],
      ),
      requirement: ToolchainRequirement(kind: ToolchainKind.languageService),
      resolution: ToolchainResolution(
        status: ToolchainResolutionStatus.resolved,
        requirement: ToolchainRequirement(kind: ToolchainKind.languageService),
        descriptor: ToolchainDescriptor(
          id: 'smoke-language-service',
          kind: ToolchainKind.languageService,
          displayName: 'Smoke StyioService',
          executablePath: '/opt/styio/bin/styio',
          version: '0.0.9',
          channel: 'smoke',
        ),
      ),
    ),
  );
  addTearDown(toolchainStatusReport.dispose);
  final workspaceDocumentStore = InMemoryWorkspaceDocumentStore();
  final editorController = EditorSessionController(
    initialDocument: EditorSessionController.seedDocumentForPath(
      workspaceController.activeFilePath,
    ),
    languageService: const SimpleStyioLanguageService(),
  );
  return AppBootstrap(
    platformTarget: target,
    backendProvider: backendProviderFor(target),
    moduleRegistry: ModuleRegistry(
      platformTarget: target,
      definitions: moduleDefinitions,
    ),
    nativeModuleLoader: NoopNativeModuleLoader(platformTarget: target),
    projectGraphAdapter: projectGraphAdapter,
    supplementalAdapterCapabilities:
        supplementalCapabilities ??
        normalizeCapabilitySnapshots([
          buildFfiAdapterCapability(
            visible:
                target != PlatformTarget.ios && target != PlatformTarget.web,
            executionSlotVisible:
                target != PlatformTarget.ios && target != PlatformTarget.web,
            detail: 'Smoke test FFI slot stays deferred.',
          ),
          buildCloudAdapterCapability(
            supportsCloudExecution:
                target == PlatformTarget.ios ||
                target == PlatformTarget.android,
            supportsHostedProjectGraph:
                target == PlatformTarget.ios || target == PlatformTarget.web,
            detail: 'Smoke test cloud route remains illustrative.',
          ),
        ]),
    workspaceController: workspaceController,
    workspaceDocumentStore: workspaceDocumentStore,
    editorController: editorController,
    executionAdapter: const _FakeExecutionAdapter(),
    executionAdapterFactory: (ProjectGraphSnapshot _) async =>
        const _FakeExecutionAdapter(),
    runtimeEventAdapter: createRuntimeEventAdapter(platformTarget: target),
    dependencySourceAdapter: const _FakeDependencySourceAdapter(),
    deploymentAdapter: const _FakeDeploymentAdapter(),
    toolchainStatusReport: toolchainStatusReport,
  );
}

List<ModuleDefinition> createSmokeModuleDefinitions() {
  const desktopMountedRule = ModuleCapabilityRule(
    supported: true,
    visible: true,
    installable: true,
    mountedByDefault: true,
    iosSafe: false,
    distributionChannel: 'nightly',
    note: 'Desktop runtime bridge is mounted for smoke coverage.',
  );
  const desktopVisibleRule = ModuleCapabilityRule(
    supported: true,
    visible: true,
    installable: true,
    mountedByDefault: false,
    iosSafe: false,
    distributionChannel: 'preview',
    note: 'Agent prompt kit is visible but left unmounted by default.',
  );
  const hiddenMobileRule = ModuleCapabilityRule(
    supported: false,
    visible: false,
    installable: false,
    mountedByDefault: false,
    iosSafe: true,
    distributionChannel: 'blocked',
    note: 'Desktop-only smoke module stays hidden on mobile targets.',
  );

  return const <ModuleDefinition>[
    ModuleDefinition(
      manifest: ModuleManifest(
        moduleId: 'smoke.runtime.bridge',
        displayName: 'Smoke Runtime Bridge',
        version: '0.0.1',
        kind: ModuleKind.core,
        slot: ModuleSlot.localRuntime,
        description: 'Provides a local runtime bridge for smoke coverage.',
        enabledByDefault: true,
        entrypoint: 'package:smoke/runtime_bridge.dart',
        distributionPolicyRef: 'desktop-nightly',
        capabilityFlags: <String, bool>{'runtime': true},
      ),
      matrix: ModuleCapabilityMatrix(
        moduleId: 'smoke.runtime.bridge',
        platforms: <PlatformTarget, ModuleCapabilityRule>{
          PlatformTarget.macos: desktopMountedRule,
          PlatformTarget.android: hiddenMobileRule,
        },
      ),
    ),
    ModuleDefinition(
      manifest: ModuleManifest(
        moduleId: 'smoke.agent.prompts',
        displayName: 'Smoke Agent Prompts',
        version: '0.0.1',
        kind: ModuleKind.optional,
        slot: ModuleSlot.agentSurface,
        description: 'Provides prompt routing slots for smoke coverage.',
        enabledByDefault: false,
        entrypoint: 'package:smoke/agent_prompts.dart',
        distributionPolicyRef: 'desktop-preview',
        capabilityFlags: <String, bool>{'agent': true},
      ),
      matrix: ModuleCapabilityMatrix(
        moduleId: 'smoke.agent.prompts',
        platforms: <PlatformTarget, ModuleCapabilityRule>{
          PlatformTarget.macos: desktopVisibleRule,
          PlatformTarget.android: hiddenMobileRule,
        },
      ),
    ),
  ];
}

Future<AppBootstrap> createLiveWorkflowBootstrap(PlatformTarget target) async {
  final projectSnapshot = createProjectSnapshot(target).copyWith(
    activeCompiler: const CompilerHandshakeSnapshot(
      binaryPath: '/toolchains/styio/bin/styio',
      tool: 'styio',
      compilerVersion: '0.0.5',
      channel: 'stable',
      variant: 'live-mainline-fixture',
      capabilities: <String>[
        'machine_info_json',
        'single_file_entry',
        'jsonl_diagnostics',
        'runtime_event_stream',
      ],
      supportedContractVersions: <String, List<int>>{
        'machine_info': <int>[1],
        'compile_plan': <int>[1],
        'runtime_events': <int>[1],
      },
      integrationPhase: 'compile-plan-live',
      supportedAdapterModes: <String>['single-file', 'project'],
      featureFlags: <String, bool>{
        'compile_plan_consumer': true,
        'runtime_event_payload': true,
      },
    ),
    packageDistribution: const PackageDistributionSnapshot(
      schemaVersion: 1,
      publishablePackages: 1,
      blockedPackages: 0,
      packages: <PackageDistributionPackageSnapshot>[
        PackageDistributionPackageSnapshot(
          packageName: 'demo/app',
          manifestPath: '/workspace/demo/pafio.toml',
          publishEnabled: true,
          publishReady: true,
          runtimeRegistryDependencies: 1,
        ),
      ],
      registrySources: <RegistrySourceSnapshot>[
        RegistrySourceSnapshot(
          registryRoot: '/registry/local',
          transport: 'filesystem',
          dependencyRefs: 1,
          packages: <String>['assertions'],
        ),
      ],
    ),
    notes: const <String>[
      'Live workflow fixture mirrors a compile-plan-ready project route.',
    ],
  );
  final workspaceController = WorkspaceController(
    projectSnapshot: projectSnapshot,
  );
  recordRuntimeEventsForSession('live-workflow-run', <RuntimeEventEnvelope>[
    RuntimeEventEnvelope(
      schemaVersion: 1,
      sessionId: 'live-workflow-run',
      sequence: 1,
      timestamp: DateTime.utc(2026, 4, 18, 3, 0, 0),
      eventKind: 'compile.started',
      origin: 'styio.compile-plan',
      payload: const <String, Object?>{'intent': 'run'},
    ),
    RuntimeEventEnvelope(
      schemaVersion: 1,
      sessionId: 'live-workflow-run',
      sequence: 2,
      timestamp: DateTime.utc(2026, 4, 18, 3, 0, 1),
      eventKind: 'run.finished',
      origin: 'styio.runtime',
      payload: const <String, Object?>{'success': true},
    ),
  ]);
  addTearDown(() => clearRuntimeEventsForSession('live-workflow-run'));
  final toolchainStatusReport = ValueNotifier<ToolchainManagerStatusReport>(
    const ToolchainManagerStatusReport(
      status: ToolchainManagerStatus.ready,
      snapshot: ToolchainStateSnapshot(
        targetId: 'live-target',
        workspaceId: 'live-workspace',
        entries: <ToolchainStateEntry>[
          ToolchainStateEntry(
            id: 'live-language-service',
            kind: ToolchainKind.languageService,
            displayName: 'Live StyioService',
            executablePath: '/opt/styio/bin/styio',
            active: true,
            version: '0.0.5',
            channel: 'stable',
          ),
        ],
      ),
      requirement: ToolchainRequirement(kind: ToolchainKind.languageService),
      resolution: ToolchainResolution(
        status: ToolchainResolutionStatus.resolved,
        requirement: ToolchainRequirement(kind: ToolchainKind.languageService),
        descriptor: ToolchainDescriptor(
          id: 'live-language-service',
          kind: ToolchainKind.languageService,
          displayName: 'Live StyioService',
          executablePath: '/opt/styio/bin/styio',
          version: '0.0.5',
          channel: 'stable',
        ),
      ),
    ),
  );
  addTearDown(toolchainStatusReport.dispose);
  final workspaceDocumentStore = InMemoryWorkspaceDocumentStore();
  final editorController = EditorSessionController(
    initialDocument: EditorSessionController.seedDocumentForPath(
      workspaceController.activeFilePath,
    ),
    languageService: const SimpleStyioLanguageService(),
  );
  return AppBootstrap(
    platformTarget: target,
    backendProvider: backendProviderFor(target),
    moduleRegistry: ModuleRegistry(
      platformTarget: target,
      definitions: const [],
    ),
    nativeModuleLoader: NoopNativeModuleLoader(platformTarget: target),
    projectGraphAdapter: _FakeProjectGraphAdapter(projectSnapshot),
    supplementalAdapterCapabilities: normalizeCapabilitySnapshots([
      buildFfiAdapterCapability(
        visible: true,
        executionSlotVisible: true,
        detail: 'Live workflow fixture keeps desktop bridge available.',
      ),
      buildCloudAdapterCapability(
        supportsCloudExecution: false,
        supportsHostedProjectGraph: false,
        detail: 'Live workflow fixture stays on the desktop mainline path.',
      ),
    ]),
    workspaceController: workspaceController,
    workspaceDocumentStore: workspaceDocumentStore,
    editorController: editorController,
    executionAdapter: const _LiveExecutionAdapter(),
    executionAdapterFactory: (ProjectGraphSnapshot _) async =>
        const _LiveExecutionAdapter(),
    runtimeEventAdapter: createRuntimeEventAdapter(platformTarget: target),
    dependencySourceAdapter: const _LiveDependencySourceAdapter(),
    deploymentAdapter: const _LiveDeploymentAdapter(),
    toolchainStatusReport: toolchainStatusReport,
  );
}

Future<DocumentState> seedWorkspaceSurfaceFixture(
  AppBootstrap bootstrap,
) async {
  final project = bootstrap.workspaceController.activeProject;
  final mainPath = bootstrap.workspaceController.activeFilePath;
  final renderPath = '${project.workspaceRoot}/src/render_flow.styio';
  final runtimePath = '${project.workspaceRoot}/src/runtime_graph.styio';
  final mainDocument = DocumentState(
    documentId: mainPath,
    text: '''
@import { src/render_flow }
@import { src/runtime_graph }
schema Price {
}
schema OrderBook {
price: Price
}
#calculate := (input) => {
total = blend(input, input)
total -> @prices
<| total
}
value = calculate(1.0)
''',
    revision: 1,
  );
  await bootstrap.workspaceDocumentStore.saveDocument(mainDocument);
  await bootstrap.workspaceDocumentStore.saveDocument(
    DocumentState(
      documentId: renderPath,
      text: '''
schema Quote {
price: Price
}
task render {
<| calculate(2.0)
}
''',
      revision: 1,
    ),
  );
  await bootstrap.workspaceDocumentStore.saveDocument(
    DocumentState(
      documentId: runtimePath,
      text: '''
fn blend(left: f64, right: f64): f64 {
emit left + right
}
''',
      revision: 1,
    ),
  );
  bootstrap.editorController.loadDocument(mainDocument);
  return mainDocument;
}

class _FakeProjectGraphAdapter implements ProjectGraphAdapter {
  const _FakeProjectGraphAdapter(this.projectSnapshot);

  final ProjectGraphSnapshot projectSnapshot;

  @override
  AdapterCapabilitySnapshot
  get capabilitySnapshot => const AdapterCapabilitySnapshot(
    adapterKind: AdapterKind.cli,
    languageService: AdapterEndpointCapability(
      level: AdapterCapabilityLevel.partial,
      detail:
          'Smoke test CLI adapter keeps language-service contracts partial.',
    ),
    projectGraph: AdapterEndpointCapability(
      level: AdapterCapabilityLevel.available,
      detail: 'Smoke test project graph is resolved from a canonical fixture.',
    ),
    execution: AdapterEndpointCapability(
      level: AdapterCapabilityLevel.unavailable,
      detail: 'Fake project graph adapter does not own execution routes.',
    ),
    runtimeEvents: AdapterEndpointCapability(
      level: AdapterCapabilityLevel.unavailable,
      detail: 'Fake project graph adapter does not emit runtime events.',
    ),
  );

  @override
  Future<ProjectGraphSnapshot> loadProjectGraph() async => projectSnapshot;
}

class _FakeExecutionAdapter implements ExecutionAdapter {
  const _FakeExecutionAdapter();

  @override
  AdapterCapabilitySnapshot get capabilitySnapshot =>
      const AdapterCapabilitySnapshot(
        adapterKind: AdapterKind.cli,
        languageService: AdapterEndpointCapability(
          level: AdapterCapabilityLevel.unavailable,
          detail: 'Fake execution adapter exposes no language-service data.',
        ),
        projectGraph: AdapterEndpointCapability(
          level: AdapterCapabilityLevel.unavailable,
          detail: 'Fake execution adapter does not own project graph data.',
        ),
        execution: AdapterEndpointCapability(
          level: AdapterCapabilityLevel.partial,
          detail: 'Fake execution adapter keeps run requests blocked.',
        ),
        runtimeEvents: AdapterEndpointCapability(
          level: AdapterCapabilityLevel.unavailable,
          detail: 'Fake execution adapter does not emit runtime events.',
        ),
      );

  @override
  Future<ExecutionSession> runActiveDocument({
    required PlatformTarget platformTarget,
    required ProjectGraphSnapshot projectGraph,
    required DocumentState document,
    required String activeFilePath,
    ExecutionProcessStartedCallback? onProcessStarted,
  }) async {
    return const ExecutionSession(
      sessionId: 'smoke-test',
      kind: 'run',
      status: ExecutionSessionStatus.blocked,
      statusMessage: 'Smoke test execution route remains blocked.',
      diagnostics: <Diagnostic>[],
      stdoutEvents: <ExecutionLogEvent>[],
      stderrEvents: <ExecutionLogEvent>[],
    );
  }
}

class _FakeDependencySourceAdapter implements DependencySourceAdapter {
  const _FakeDependencySourceAdapter();

  @override
  Future<DependencySourceCommandResult> syncDependencies({
    required ProjectGraphSnapshot projectGraph,
    bool locked = false,
    bool offline = false,
  }) async {
    return const DependencySourceCommandResult(
      command: 'sync',
      status: DependencySourceCommandStatus.blocked,
      statusMessage: 'Smoke test dependency-source operations remain blocked.',
      stdout: '',
      stderr: '',
    );
  }

  @override
  Future<DependencySourceCommandResult> vendorDependencies({
    required ProjectGraphSnapshot projectGraph,
    String? outputPath,
    bool locked = false,
    bool offline = false,
  }) async {
    return const DependencySourceCommandResult(
      command: 'vendor',
      status: DependencySourceCommandStatus.blocked,
      statusMessage: 'Smoke test dependency-source operations remain blocked.',
      stdout: '',
      stderr: '',
    );
  }
}

class _FakeDeploymentAdapter implements DeploymentAdapter {
  const _FakeDeploymentAdapter();

  @override
  Future<DeploymentCommandResult> packProject({
    required ProjectGraphSnapshot projectGraph,
    String? packageName,
    String? outputPath,
  }) async {
    return const DeploymentCommandResult(
      command: 'pack',
      status: DeploymentCommandStatus.blocked,
      statusMessage: 'Smoke test deployment operations remain blocked.',
      stdout: '',
      stderr: '',
    );
  }

  @override
  Future<DeploymentCommandResult> preparePublish({
    required ProjectGraphSnapshot projectGraph,
    String? packageName,
    String? outputPath,
  }) async {
    return const DeploymentCommandResult(
      command: 'publish',
      status: DeploymentCommandStatus.blocked,
      statusMessage: 'Smoke test deployment operations remain blocked.',
      stdout: '',
      stderr: '',
    );
  }

  @override
  Future<DeploymentCommandResult> publishToRegistry({
    required ProjectGraphSnapshot projectGraph,
    required String registryRoot,
    String? packageName,
    String? outputPath,
  }) async {
    return const DeploymentCommandResult(
      command: 'publish',
      status: DeploymentCommandStatus.blocked,
      statusMessage: 'Smoke test deployment operations remain blocked.',
      stdout: '',
      stderr: '',
    );
  }
}

class _LiveExecutionAdapter implements ExecutionAdapter {
  const _LiveExecutionAdapter();

  @override
  AdapterCapabilitySnapshot
  get capabilitySnapshot => const AdapterCapabilitySnapshot(
    adapterKind: AdapterKind.cli,
    languageService: AdapterEndpointCapability(
      level: AdapterCapabilityLevel.unavailable,
      detail: 'Live workflow fixture does not expose language-service data.',
    ),
    projectGraph: AdapterEndpointCapability(
      level: AdapterCapabilityLevel.unavailable,
      detail: 'Live workflow execution stays on the published shell route.',
    ),
    execution: AdapterEndpointCapability(
      level: AdapterCapabilityLevel.available,
      detail:
          'Live workflow fixture exposes project execution through published compile-plan support.',
    ),
    runtimeEvents: AdapterEndpointCapability(
      level: AdapterCapabilityLevel.partial,
      detail: 'Live workflow fixture replays published runtime events.',
    ),
  );

  @override
  Future<ExecutionSession> runActiveDocument({
    required PlatformTarget platformTarget,
    required ProjectGraphSnapshot projectGraph,
    required DocumentState document,
    required String activeFilePath,
    ExecutionProcessStartedCallback? onProcessStarted,
  }) async {
    return const ExecutionSession(
      sessionId: 'live-workflow-run',
      kind: 'run',
      status: ExecutionSessionStatus.succeeded,
      statusMessage: 'Live workflow fixture executed the active project route.',
      diagnostics: <Diagnostic>[],
      stdoutEvents: <ExecutionLogEvent>[ExecutionLogEvent(message: 'run-ok')],
      stderrEvents: <ExecutionLogEvent>[],
    );
  }
}

class _LiveDependencySourceAdapter implements DependencySourceAdapter {
  const _LiveDependencySourceAdapter();

  @override
  Future<DependencySourceCommandResult> syncDependencies({
    required ProjectGraphSnapshot projectGraph,
    bool locked = false,
    bool offline = false,
  }) async {
    return _success('sync');
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
      statusMessage: 'live workflow dependency command succeeded.',
      stdout: '',
      stderr: '',
      payload: <String, dynamic>{
        'packages': 2,
        'vendor_root': '/workspace/demo/.pafio/vendor',
        'metadata_path': '/workspace/demo/.pafio/vendor/pafio-vendor.json',
      },
    );
  }
}

class _LiveDeploymentAdapter implements DeploymentAdapter {
  const _LiveDeploymentAdapter();

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
      statusMessage: 'live workflow deployment command succeeded.',
      stdout: '',
      stderr: '',
      payload: <String, dynamic>{
        'package': packageName ?? 'demo/app',
        'archive_path': '/workspace/demo/dist/app-0.0.5.tar',
      },
    );
  }
}
