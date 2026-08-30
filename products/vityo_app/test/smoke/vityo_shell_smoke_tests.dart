part of '../vityo_app_smoke_test.dart';

void _registerShellSmokeTests() {
  testWidgets('builds shared shell scaffold in desktop viewport family', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    expect(
      find.byKey(const ValueKey('shell-viewport-desktop')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('editor-viewport-desktop')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('language-pane-desktop')), findsNothing);
    expect(
      find.byKey(const ValueKey('editor-language-family-desktop')),
      findsOneWidget,
    );
    expect(find.textContaining('M2/M3 editor anchor'), findsNothing);
    expect(find.textContaining('input disconnected'), findsNothing);
    expect(
      find.byKey(const ValueKey('workbench-auxiliary-panel')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('explorer-tree-scroll')), findsOneWidget);
    expect(find.text('EXPLORER'), findsOneWidget);
    expect(find.text('main.styio'), findsWidgets);

    final shell = ShellScope.of(
      tester.element(find.byType(VityoShellScaffold)),
    );
    expect(shell.activeBottomTab, BottomSurfaceTab.navigate);
    expect(find.byKey(const ValueKey('workbench-bottom-panel')), findsNothing);

    final commandLauncher = find.byKey(
      const ValueKey('workbench-command-launcher'),
    );
    await tester.tap(commandLauncher);
    await tester.pumpAndSettle();
    expect(shell.activeBottomTab, BottomSurfaceTab.commandPalette);
    expect(
      find.byKey(const ValueKey('command-palette-surface')),
      findsOneWidget,
    );

    await tester.tap(commandLauncher);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workbench-bottom-panel')), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('editor-language-inspector-toggle')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('language-pane-desktop')), findsOneWidget);

    shell.selectBottomTab(BottomSurfaceTab.runtime);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('runtime-surface-desktop')),
      findsOneWidget,
    );
    expect(find.text('source manager-report'), findsOneWidget);
    expect(find.byKey(const ValueKey('command-strip-run')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('command-strip-syncDependencies')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('command-strip-vendorDependencies')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('command-strip-refreshModules')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.play_arrow_rounded), findsWidgets);
    final arrowLine = bootstrap.editorController.document
        .positionForOffset(
          bootstrap.editorController.document.text.indexOf('total ->'),
        )
        .line;
    await tester.scrollUntilVisible(
      find.byKey(ValueKey('source-line-$arrowLine')),
      90,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('source-buffer-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('source-line-$arrowLine')), findsOneWidget);

    final vendorCommand = find.byKey(
      const ValueKey('command-strip-vendorDependencies'),
    );
    await tester.ensureVisible(vendorCommand);
    await tester.pumpAndSettle();
    await tester.tap(vendorCommand);
    await tester.pumpAndSettle();

    expect(shell.lastDependencySourceCommand?.command, 'vendor');

    await tester.focusEditorSource();

    await tester.tap(find.byKey(const ValueKey('source-line-0')));
    await tester.pump();

    expect(find.byKey(const ValueKey('source-buffer-surface')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('inline-language-feedback-desktop')),
      findsNothing,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(shell.editorController.selection.isCollapsed, isFalse);

    await shell.executeCommand(AppCommandId.showDebug);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('debug-surface-desktop')), findsOneWidget);
  });

  testWidgets('runs explorer create rename filter and confirmed batch delete', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));
    await tester.pumpAndSettle();
    final shell = ShellScope.of(
      tester.element(find.byType(VityoShellScaffold)),
    );

    await tester.tap(find.byKey(const ValueKey('explorer-create-file')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace-path-dialog')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('workspace-path-input')),
      'src/generated.styio',
    );
    await tester.tap(find.byKey(const ValueKey('workspace-path-apply')));
    await tester.pumpAndSettle();

    const generatedPath = '/workspace/demo/src/generated.styio';
    expect(shell.workspaceController.files, contains(generatedPath));
    expect(
      find.byKey(const ValueKey('explorer-file-$generatedPath')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('explorer-menu-$generatedPath')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('workspace-path-input')),
      'src/renamed.styio',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('workspace-path-apply')));
    await tester.pumpAndSettle();

    const renamedPath = '/workspace/demo/src/renamed.styio';
    expect(
      shell.workspaceController.files,
      isNot(contains(generatedPath)),
      reason: shell.debugLog.join('\n'),
    );
    expect(shell.workspaceController.files, contains(renamedPath));
    await tester.enterText(
      find.byKey(const ValueKey('explorer-filter')),
      'renamed',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('explorer-file-$renamedPath')),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(const ValueKey('explorer-filter')), '');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('explorer-sort')));
    await tester.pumpAndSettle();
    expect(
      shell.workspaceFileExplorerSnapshot.state?.sortMode.name,
      'alphabetical',
    );

    await tester.tap(find.byKey(const ValueKey('explorer-multi-select')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('explorer-checkbox-$renamedPath')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('explorer-delete-selected')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('workspace-file-batch-dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('workspace-file-batch-cancel')));
    await tester.pumpAndSettle();
    expect(shell.workspaceController.files, contains(renamedPath));
    expect(shell.pendingWorkspaceFileBatchActionPlan, isNull);

    await tester.tap(find.byKey(const ValueKey('explorer-delete-selected')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('workspace-file-batch-confirm')),
    );
    await tester.pumpAndSettle();

    expect(shell.workspaceController.files, isNot(contains(renamedPath)));
    expect(
      find.byKey(const ValueKey('explorer-file-$renamedPath')),
      findsNothing,
    );
  });

  testWidgets('renders scratch shell fallback project cards', (tester) async {
    tester.view.physicalSize = const Size(430, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const toolchain = ToolchainStatusSnapshot(
      source: ToolchainResolutionSource.environment,
      detail: 'Scratch project uses the system Styio contract.',
    );
    final scratchProject = ProjectGraphSnapshot.scratch(
      workspaceRoot: '/workspace/scratch',
      activeFilePath: '/workspace/scratch/main.styio',
      title: 'Scratch Coverage Project',
      toolchain: toolchain,
      notes: const <String>['Scratch fallback card coverage.'],
    );
    final bootstrap = await createBootstrap(
      PlatformTarget.android,
      projectSnapshot: scratchProject,
      supplementalCapabilities: const <AdapterCapabilitySnapshot>[
        AdapterCapabilitySnapshot(
          adapterKind: AdapterKind.cloud,
          languageService: AdapterEndpointCapability(
            level: AdapterCapabilityLevel.available,
            detail: 'language service available for fallback smoke',
          ),
          projectGraph: AdapterEndpointCapability(
            level: AdapterCapabilityLevel.available,
            detail: 'project graph available for fallback smoke',
          ),
          execution: AdapterEndpointCapability(
            level: AdapterCapabilityLevel.available,
            detail: 'execution available for fallback smoke',
          ),
          runtimeEvents: AdapterEndpointCapability(
            level: AdapterCapabilityLevel.available,
            detail: 'runtime events available for fallback smoke',
          ),
        ),
      ],
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    expect(find.text('Scratch Coverage Project'), findsWidgets);
    expect(find.text('scratch'), findsWidgets);
    expect(find.text('0 package'), findsOneWidget);
    expect(find.text('0 target'), findsOneWidget);
    expect(find.text('1 file'), findsOneWidget);

    final workspaceSidebarScrollable = find.descendant(
      of: find.byKey(const ValueKey('workspace-sidebar-scroll')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('compiler-handshake-card')),
      120,
      scrollable: workspaceSidebarScrollable,
    );
    await tester.pumpAndSettle();
    expect(
      find.text('No local styio machine-info handshake has been resolved yet.'),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('required-handoffs-card')),
      120,
      scrollable: workspaceSidebarScrollable,
    );
    await tester.pumpAndSettle();
    expect(find.text('0 blocking'), findsOneWidget);
    expect(find.text('0 styio'), findsOneWidget);
    expect(find.text('0 pafio'), findsOneWidget);
    expect(
      find.text(
        'No product-side handoffs are currently outstanding for this route.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('builds shared shell scaffold in mobile viewport family', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.android);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    expect(find.byKey(const ValueKey('shell-viewport-mobile')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('editor-viewport-mobile')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('editor-language-family-mobile')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('shell-mobile-scroll')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('command-strip-syncDependencies')),
      findsNothing,
    );

    await revealMobileLanguagePane(tester);
    expect(
      find.byKey(const ValueKey('language-pane-mobile'), skipOffstage: false),
      findsOneWidget,
    );

    final shell = ShellScope.of(
      tester.element(find.byType(VityoShellScaffold)),
    );
    await shell.executeCommand(AppCommandId.showAgent);
    await tester.pumpAndSettle();

    expect(shell.activeBottomTab, BottomSurfaceTab.agent);
  });

  testWidgets('builds every bottom surface tab in desktop viewport family', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createLiveWorkflowBootstrap(PlatformTarget.macos);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    final shell = ShellScope.of(
      tester.element(find.byType(VityoShellScaffold)),
    );
    for (final tab in BottomSurfaceTab.values.where(
      (tab) => tab != BottomSurfaceTab.commands,
    )) {
      shell.selectBottomTab(tab);
      await tester.pump();
      expect(shell.activeBottomTab, tab);
    }
  });

  testWidgets('builds every bottom surface tab in mobile viewport family', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createLiveWorkflowBootstrap(PlatformTarget.android);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    final shell = ShellScope.of(
      tester.element(find.byType(VityoShellScaffold)),
    );
    final scrollableTabs = BottomSurfaceTab.values.where(
      (tab) =>
          tab != BottomSurfaceTab.runtime &&
          tab != BottomSurfaceTab.debug &&
          tab != BottomSurfaceTab.commands,
    );
    for (final tab in scrollableTabs) {
      shell.selectBottomTab(tab);
      await tester.pump();
      await revealMobileBottomSurface(tester);
      expect(shell.activeBottomTab, tab);
    }
  });

  testWidgets('activates desktop contextual workbench regions', (tester) async {
    tester.view.physicalSize = const Size(2200, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createLiveWorkflowBootstrap(PlatformTarget.macos);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    final shell = ShellScope.of(
      tester.element(find.byType(VityoShellScaffold)),
    );

    Future<void> tapTab(String label, BottomSurfaceTab expectedTab) async {
      final chipText = find.text(label);
      expect(chipText, findsWidgets);
      final tab = find.ancestor(
        of: chipText.first,
        matching: find.byType(InkWell),
      );
      expect(tab, findsWidgets);
      await tester.ensureVisible(tab.first);
      await tester.pumpAndSettle();
      await tester.tap(tab.first);
      await tester.pumpAndSettle();
      expect(shell.activeBottomTab, expectedTab);
    }

    Future<void> tapActivity(String label, BottomSurfaceTab expectedTab) async {
      final destination = find.byTooltip(label);
      expect(destination, findsOneWidget);
      await tester.tap(destination);
      await tester.pumpAndSettle();
      expect(shell.activeBottomTab, expectedTab);
    }

    await tapTab('Runtime', BottomSurfaceTab.runtime);
    await tapTab('Terminal', BottomSurfaceTab.terminal);
    await tapTab('Problems', BottomSurfaceTab.problems);
    await tapTab('Tests', BottomSurfaceTab.testing);
    await tapTab('Debug', BottomSurfaceTab.debug);
    await tapActivity('Search', BottomSurfaceTab.search);
    await tapActivity('Source control', BottomSurfaceTab.sourceControl);
    await tapActivity('Coding Agent', BottomSurfaceTab.agent);
    await tapActivity('Extensions', BottomSurfaceTab.extensions);
    await tapActivity('Settings', BottomSurfaceTab.settings);
  });

  testWidgets('keeps the explorer available in a medium desktop window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    expect(
      find.byKey(const ValueKey('workbench-activity-rail')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('explorer-tree-scroll')), findsOneWidget);

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('workspace-search-surface')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('explorer-tree-scroll')), findsNothing);
  });

  testWidgets('activates mobile settings tab from tab chip', (tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.android);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    final shell = ShellScope.of(
      tester.element(find.byType(VityoShellScaffold)),
    );
    await revealMobileBottomSurface(tester);
    final tab = find.ancestor(
      of: find.text('Settings', skipOffstage: false).first,
      matching: find.byType(InkWell, skipOffstage: false),
    );
    expect(tab, findsWidgets);
    await tester.ensureVisible(tab.first);
    await tester.pumpAndSettle();
    await tester.tap(tab.first);
    await tester.pumpAndSettle();

    expect(shell.activeBottomTab, BottomSurfaceTab.settings);
    expect(
      find.byKey(const ValueKey('settings-surface'), skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('renders module sidebar and module-aware surfaces', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(
      PlatformTarget.macos,
      moduleDefinitions: createSmokeModuleDefinitions(),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    final shell = ShellScope.of(
      tester.element(find.byType(VityoShellScaffold)),
    );

    shell.selectBottomTab(BottomSurfaceTab.runtime);
    await tester.pumpAndSettle();
    expect(find.text('Mounted Runtime Modules'), findsOneWidget);
    expect(find.text('Smoke Runtime Bridge'), findsWidgets);

    shell.selectBottomTab(BottomSurfaceTab.agent);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('agent-workbench-surface')),
      findsOneWidget,
    );
    expect(find.textContaining('No Agent is connected'), findsOneWidget);
  });

  testWidgets('renders module sidebar in mobile viewport family', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(
      PlatformTarget.android,
      moduleDefinitions: createSmokeModuleDefinitions(),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    expect(find.text('Adapter Routes', skipOffstage: false), findsWidgets);
  });

  testWidgets('renders empty workspace bottom surface states', (tester) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const readmePath = '/workspace/readme-only/README.md';
    const readmeDocument = DocumentState(
      documentId: readmePath,
      text: '# Readme only\nNo Styio symbols live here.\n',
      revision: 1,
    );
    final bootstrap = await createBootstrap(
      PlatformTarget.macos,
      projectSnapshot: createReadmeOnlyProjectSnapshot(),
    );
    await bootstrap.workspaceDocumentStore.saveDocument(readmeDocument);
    bootstrap.editorController.loadDocument(readmeDocument);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    final shell = ShellScope.of(
      tester.element(find.byType(VityoShellScaffold)),
    );

    Future<void> showTab(BottomSurfaceTab tab, String resultKey) async {
      shell.selectBottomTab(tab);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey<String>(resultKey)), findsOneWidget);
    }

    await showTab(BottomSurfaceTab.search, 'workspace-search-surface');
    await showTab(BottomSurfaceTab.problems, 'problems-surface');
    await showTab(BottomSurfaceTab.commandPalette, 'command-palette-surface');
  });

  testWidgets('renders populated workspace bottom surfaces', (tester) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createLiveWorkflowBootstrap(PlatformTarget.macos);
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

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    final shell = ShellScope.of(
      tester.element(find.byType(VityoShellScaffold)),
    );

    Future<void> renderTab(BottomSurfaceTab tab) async {
      shell.selectBottomTab(tab);
      await tester.pump();
      expect(shell.activeBottomTab, tab);
    }

    await renderTab(BottomSurfaceTab.documentLinks);
    await renderTab(BottomSurfaceTab.documentHighlights);
    await renderTab(BottomSurfaceTab.codeLenses);
    await renderTab(BottomSurfaceTab.declarations);
    await renderTab(BottomSurfaceTab.definitions);
    await renderTab(BottomSurfaceTab.typeDefinitions);
    await renderTab(BottomSurfaceTab.implementations);
    await renderTab(BottomSurfaceTab.typeHierarchy);
    await renderTab(BottomSurfaceTab.outline);
    await renderTab(BottomSurfaceTab.rename);
    await renderTab(BottomSurfaceTab.symbols);
    await renderTab(BottomSurfaceTab.usages);
    await renderTab(BottomSurfaceTab.calls);
    await shell.previewWorkspaceReplace(query: 'blend', replacement: 'mix');
    await renderTab(BottomSurfaceTab.search);
    await renderTab(BottomSurfaceTab.problems);
    await renderTab(BottomSurfaceTab.actions);
  });

  testWidgets(
    'drives workspace bottom surface controls and result selections',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final bootstrap = await createLiveWorkflowBootstrap(PlatformTarget.macos);
      await seedWorkspaceSurfaceFixture(bootstrap);

      await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

      final shell = ShellScope.of(
        tester.element(find.byType(VityoShellScaffold)),
      );

      Finder keyPrefix(String prefix) {
        return find.byWidgetPredicate((widget) {
          final key = widget.key;
          return key is ValueKey<String> && key.value.startsWith(prefix);
        }, description: 'key prefix $prefix');
      }

      Future<void> showTab(BottomSurfaceTab tab) async {
        shell.selectBottomTab(tab);
        await tester.pumpAndSettle();
        expect(shell.activeBottomTab, tab);
      }

      Future<void> tapKeyIfPresent(String keyValue) async {
        final target = find.byKey(ValueKey<String>(keyValue));
        if (target.evaluate().isEmpty) {
          return;
        }
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      Future<void> tapFirstKeyPrefixIfPresent(String prefix) async {
        final target = keyPrefix(prefix);
        if (target.evaluate().isEmpty) {
          return;
        }
        await tester.ensureVisible(target.first);
        await tester.pumpAndSettle();
        await tester.tap(target.first);
        await tester.pumpAndSettle();
      }

      Future<void> submitField(String keyValue, String value) async {
        final target = find.byKey(ValueKey<String>(keyValue));
        expect(target, findsOneWidget);
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.enterText(target, value);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
      }

      await showTab(BottomSurfaceTab.commandPalette);
      await submitField('command-palette-query-input', 'run');
      await tapFirstKeyPrefixIfPresent('command-palette-');

      await showTab(BottomSurfaceTab.search);
      await submitField('workspace-search-query-input', 'blend');
      await tapFirstKeyPrefixIfPresent('workspace-search-match-');
      await tester.enterText(
        find.byKey(const ValueKey('workspace-replace-input')),
        'mix',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tapKeyIfPresent('workspace-replace-preview-submit');
      await tapFirstKeyPrefixIfPresent('workspace-replace-preview-');
      await tapKeyIfPresent('workspace-search-run');
      await showTab(BottomSurfaceTab.problems);
      expect(find.byKey(const ValueKey('problems-surface')), findsOneWidget);
    },
  );

  testWidgets('renders compact command and quick open empty states', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.android);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    final shell = ShellScope.of(
      tester.element(find.byType(VityoShellScaffold)),
    );
    expect(find.byKey(const ValueKey('shell-viewport-mobile')), findsOneWidget);

    shell.selectBottomTab(BottomSurfaceTab.commandPalette);
    await tester.pumpAndSettle();
    await revealMobileBottomSurface(tester);
    expect(
      find.byKey(
        const ValueKey('command-palette-surface'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    final commandField = find.byKey(
      const ValueKey('command-palette-query-input'),
      skipOffstage: false,
    );
    await tester.ensureVisible(commandField);
    await tester.enterText(commandField, 'zzzz-no-match');
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('command-palette-content-scroll')),
      const Offset(0, -520),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('No matching commands.', skipOffstage: false),
      findsNothing,
    );
    expect(
      find.text('No commands match "zzzz-no-match".', skipOffstage: false),
      findsOneWidget,
    );

    shell.selectBottomTab(BottomSurfaceTab.search);
    await tester.pumpAndSettle();
    await revealMobileBottomSurface(tester);
    expect(
      find.byKey(
        const ValueKey('workspace-search-surface'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    final compactSearchSurfaceScroll = find.descendant(
      of: find.byKey(
        const ValueKey('workspace-search-surface'),
        skipOffstage: false,
      ),
      matching: find.byType(Scrollable),
    );
    await tester.drag(compactSearchSurfaceScroll.first, const Offset(0, -700));
    await tester.pumpAndSettle();
    final quickOpenField = find.byKey(
      const ValueKey('workspace-quick-open-input'),
      skipOffstage: false,
    );
    await tester.ensureVisible(quickOpenField);
    await tester.enterText(quickOpenField, 'no-such-file');
    await tester.pumpAndSettle();
    expect(find.text('No matching files.', skipOffstage: false), findsNothing);
    expect(
      find.text('No files match "no-such-file".', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets(
    'executes sample project workflow through sidebar mainline lanes',
    (tester) async {
      tester.view.physicalSize = const Size(430, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final bootstrap = await createLiveWorkflowBootstrap(
        PlatformTarget.android,
      );

      await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

      expect(find.text('Project Graph'), findsOneWidget);

      final workspaceSidebarScrollable = find.descendant(
        of: find.byKey(const ValueKey('workspace-sidebar-scroll')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('project-operations-card')),
        120,
        scrollable: workspaceSidebarScrollable,
      );
      await tester.pumpAndSettle();

      final shell = ShellScope.of(
        tester.element(find.byType(VityoShellScaffold)),
      );

      Future<void> tapWorkflowAction(String key) async {
        await tester.scrollUntilVisible(
          find.byKey(ValueKey(key)),
          120,
          scrollable: workspaceSidebarScrollable,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
      }

      await tapWorkflowAction('project-operation-syncDependencies');
      await tapWorkflowAction('project-operation-vendorDependencies');
      await tapWorkflowAction('project-operation-run');
      await tapWorkflowAction('project-operation-preparePublish');

      expect(shell.lastDependencySourceCommand?.command, 'vendor');
      expect(shell.lastDependencySourceCommand?.succeeded, isTrue);
      expect(
        shell.lastExecutionSession?.status,
        ExecutionSessionStatus.succeeded,
      );
      expect(shell.lastDeploymentCommand?.succeeded, isTrue);
      expect(shell.lastRuntimeEvents, hasLength(2));

      expect(find.text('execution succeeded'), findsOneWidget);
      expect(find.text('dependencies succeeded'), findsOneWidget);
      expect(find.text('deployment succeeded'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('required-handoffs-card')),
        120,
        scrollable: workspaceSidebarScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('Required Handoffs'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Packages'),
        120,
        scrollable: workspaceSidebarScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('Packages'), findsOneWidget);
      expect(find.text('demo/app'), findsWidgets);
      expect(find.text('Adapter Routes'), findsWidgets);

      await tester.drag(workspaceSidebarScrollable, const Offset(0, 2000));
      await tester.pumpAndSettle();
      for (final commandId in const <AppCommandId>[
        AppCommandId.syncDependencies,
        AppCommandId.vendorDependencies,
        AppCommandId.run,
        AppCommandId.preparePublish,
      ]) {
        expect(shell.blockedReasonForCommand(commandId), isNull);
      }
      expect(find.textContaining('runtime 2'), findsWidgets);
      expect(find.textContaining('publishable 1'), findsWidgets);
    },
  );
}
