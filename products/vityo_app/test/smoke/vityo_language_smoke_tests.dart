part of '../vityo_app_smoke_test.dart';

void _registerLanguageSmokeTests() {
  testWidgets('opens quick documentation from editor keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = '''
/**
 * Primary value binding
 */
value = value
value -> @stdout
''';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'quick-doc-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('= value') + 3);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    final quickDocPanel = find.byKey(const ValueKey('source-quick-doc-panel'));
    expect(quickDocPanel, findsOneWidget);
    expect(
      find.descendant(
        of: quickDocPanel,
        matching: find.text('Quick Documentation: value'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: quickDocPanel,
        matching: find.textContaining('Styio variable `value`'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: quickDocPanel,
        matching: find.textContaining('Primary value binding'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: quickDocPanel,
        matching: find.textContaining('Declared at 4:1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: quickDocPanel,
        matching: find.text('3 current-file usages'),
      ),
      findsOneWidget,
    );

    final sourceScrollable = find.descendant(
      of: find.byKey(const ValueKey('source-buffer-scroll')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('source-quick-doc-definition')),
      80,
      scrollable: sourceScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-quick-doc-definition')));
    await tester.pump();

    expect(bootstrap.editorController.selection.start, text.indexOf('value ='));
    expect(bootstrap.editorController.canUndo, isFalse);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('source-quick-doc-usages')),
      80,
      scrollable: sourceScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-quick-doc-usages')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('source-usages-panel')), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('source-quick-doc-close')),
      -80,
      scrollable: sourceScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-quick-doc-close')));
    await tester.pump();

    expect(find.byKey(const ValueKey('source-quick-doc-panel')), findsNothing);
  });

  testWidgets('selects document symbol from language pane', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'fn main(user) {\n  value = user\n}\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'structure.styio',
        text: text,
        revision: 0,
      ),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));
    await revealDesktopLanguagePane(tester);

    final languageScrollable = find.descendant(
      of: find.byKey(const ValueKey('language-pane-desktop')),
      matching: find.byType(Scrollable),
    );
    const mainSymbolKey = ValueKey('language-document-symbol-function-main-3');
    await tester.scrollUntilVisible(
      find.byKey(mainSymbolKey),
      120,
      scrollable: languageScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(mainSymbolKey));
    await tester.pump();

    expect(bootstrap.editorController.selection.start, text.indexOf('main'));
    expect(
      bootstrap.editorController.selection.end,
      text.indexOf('main') + 'main'.length,
    );
    expect(bootstrap.editorController.canUndo, isFalse);
  });

  testWidgets('opens symbol lookup from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text =
        'fn buildPipe(user) {\n'
        '  value = user\n'
        '}\n'
        'fn renderPipe() {\n'
        '}\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'symbol-lookup-keymap.styio',
        text: text,
        revision: 0,
      ),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('source-symbol-lookup')), findsOneWidget);
    expect(find.text('Go to Symbol'), findsOneWidget);
    expect(find.text('buildPipe · function · 1:4'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pump();

    expect(find.text('renderPipe · function · 4:4'), findsOneWidget);
    expect(find.text('buildPipe · function · 1:4'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      bootstrap.editorController.selection.start,
      text.indexOf('renderPipe'),
    );
    expect(
      bootstrap.editorController.selection.end,
      text.indexOf('renderPipe') + 'renderPipe'.length,
    );
    expect(bootstrap.editorController.document.text, text);
    expect(find.byKey(const ValueKey('source-symbol-lookup')), findsNothing);
  });

  testWidgets('cycles resolved usages from editor keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'value = value\nvalue -> @stdout\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'usage-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('= value') + 3);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.pump();

    expect(
      bootstrap.editorController.selection.start,
      text.lastIndexOf('value'),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(
      bootstrap.editorController.selection.start,
      text.indexOf('= value') + 2,
    );
  });

  testWidgets('opens find usages panel from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = '@sink : i64|..1| := {}\nvalue -> @sink\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'find-usages-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.lastIndexOf('sink') + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f7);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('source-usages-panel')), findsOneWidget);
    expect(find.text('2 current-file usages'), findsOneWidget);
    expect(find.text('write · resource · 2:11'), findsOneWidget);

    final sourceScrollable = find.descendant(
      of: find.byKey(const ValueKey('source-buffer-scroll')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('source-usage-1')),
      80,
      scrollable: sourceScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-usage-1')));
    await tester.pump();

    expect(
      bootstrap.editorController.selection.start,
      text.lastIndexOf('sink'),
    );
    expect(bootstrap.editorController.canUndo, isFalse);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('source-usages-close')),
      -80,
      scrollable: sourceScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-usages-close')));
    await tester.pump();

    expect(find.byKey(const ValueKey('source-usages-panel')), findsNothing);
  });

  testWidgets('cycles resolved usages from language pane', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'value = value\nvalue -> @stdout\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(documentId: 'usages.styio', text: text, revision: 0),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('= value') + 3);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));
    await revealDesktopLanguagePane(tester);

    final languageScrollable = find.descendant(
      of: find.byKey(const ValueKey('language-pane-desktop')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('language-next-usage')),
      120,
      scrollable: languageScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language-next-usage')));
    await tester.pump();

    expect(
      bootstrap.editorController.selection.start,
      text.lastIndexOf('value'),
    );

    expect(
      find.byKey(
        const ValueKey('language-previous-usage'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
  });

  testWidgets('applies completion from editor keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'job = ||> { <| 42 }\njo';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'completion-keymap.styio',
        text: text,
        revision: 0,
      ),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();
    expect(
      bootstrap.editorController.completionsAtSelection.map(
        (item) => item.label,
      ),
      contains('job'),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(
      bootstrap.editorController.document.text,
      'job = ||> { <| 42 }\njob',
    );
  });

  testWidgets('applies postfix completion from editor keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = '  blend(price, tax).em';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'postfix-completion-keymap.styio',
        text: text,
        revision: 0,
      ),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();
    expect(
      bootstrap.editorController.completionsAtSelection.map(
        (item) => item.label,
      ),
      contains('.emit'),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(
      bootstrap.editorController.document.text,
      '  emit blend(price, tax)',
    );
  });

  testWidgets('opens completion lookup while typing source identifiers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'job = ||> { <| 42 }\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'completion-auto-popup.styio',
        text: text,
        revision: 0,
      ),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await commitPlatformText(tester, 'j');
    await tester.pumpAndSettle();

    expect(bootstrap.editorController.document.text, '${text}j');
    expect(
      find.byKey(const ValueKey('source-completion-lookup')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('source-completion-item-0')),
        matching: find.text('job · variable'),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('source-completion-preview-insert')),
          )
          .data,
      'Insert `job`',
    );
  });

  testWidgets('skips completion auto-popup while typing comments', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = '// comment ';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'completion-auto-popup-comment.styio',
        text: text,
        revision: 0,
      ),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await commitPlatformText(tester, 'j');
    await tester.pumpAndSettle();

    expect(bootstrap.editorController.document.text, '${text}j');
    expect(
      find.byKey(const ValueKey('source-completion-lookup')),
      findsNothing,
    );
  });

  testWidgets('opens completion lookup from editor keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'job = ||> { <| 42 }\njo';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'completion-lookup-keymap.styio',
        text: text,
        revision: 0,
      ),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('source-completion-lookup')),
      findsOneWidget,
    );
    expect(find.text('Code Completion'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('source-completion-item-0')),
        matching: find.text('job · variable'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('source-completion-preview')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('source-completion-preview-detail')),
          )
          .data,
      'Current file variable symbol.',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('source-completion-preview-insert')),
          )
          .data,
      'Insert `job`',
    );
    expect(bootstrap.editorController.document.text, text);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      bootstrap.editorController.document.text,
      'job = ||> { <| 42 }\njob',
    );
    expect(
      find.byKey(const ValueKey('source-completion-lookup')),
      findsNothing,
    );
  });

  testWidgets('opens completion documentation from lookup action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = '/// Runs async price work.\njob = ||> { <| 42 }\njo';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'completion-doc-keymap.styio',
        text: text,
        revision: 0,
      ),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('source-completion-lookup')),
      findsOneWidget,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('source-completion-preview-doc')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('source-completion-preview-doc')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('source-completion-lookup')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('source-quick-doc-panel')), findsOne);
    expect(find.text('Quick Documentation: job'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('source-quick-doc-body')))
          .data,
      'Runs async price work.',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('source-quick-doc-completion-insert')),
          )
          .data,
      'Completion variable · insert `job`',
    );
  });

  testWidgets('updates completion preview from keyboard selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'completion-preview-keymap.styio',
        text: '',
        revision: 0,
      ),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('source-completion-preview-title')),
          )
          .data,
      '@import',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('source-completion-preview-detail')),
          )
          .data,
      'Declare a top-level Styio import.',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('source-completion-preview-title')),
          )
          .data,
      '#function',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('source-completion-preview-insert')),
          )
          .data,
      'Insert `#main := () => {\\n  <| 0\\n}`',
    );
  });

  testWidgets('dismisses completion lookup from keyboard paths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'completion-dismiss-keymap.styio',
        text: '',
        revision: 0,
      ),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));
    await tester.focusEditorSource();

    await sendShortcut(tester, LogicalKeyboardKey.space, control: true);
    await pumpKeyboardSurface(tester);
    expect(
      find.byKey(const ValueKey('source-completion-lookup')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('source-completion-lookup')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('source-completion-lookup')),
      findsNothing,
    );

    await sendShortcut(tester, LogicalKeyboardKey.space, control: true);
    await pumpKeyboardSurface(tester);
    expect(
      find.byKey(const ValueKey('source-completion-lookup')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.semicolon, character: ';');
    await tester.pump();
    expect(
      find.byKey(const ValueKey('source-completion-lookup')),
      findsNothing,
    );
  });

  testWidgets('updates and dismisses symbol and surround lookups', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text =
        'fn buildPipe(user) {\n'
        '  value = user\n'
        '}\n'
        'fn renderPipe() {\n'
        '}\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'lookup-dismiss-keymap.styio',
        text: text,
        revision: 0,
      ),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));
    await tester.focusEditorSource();

    await sendShortcut(
      tester,
      LogicalKeyboardKey.keyN,
      control: true,
      alt: true,
      shift: true,
    );
    await pumpKeyboardSurface(tester);
    expect(find.byKey(const ValueKey('source-symbol-lookup')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(find.byKey(const ValueKey('source-symbol-lookup')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyR, character: 'r');
    await tester.pump();
    expect(find.text('renderPipe · function · 4:4'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(find.text('buildPipe · function · 1:4'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('source-symbol-lookup')), findsNothing);

    bootstrap.editorController.selectCollapsed(text.indexOf('value') + 2);
    await tester.pump();
    await tester.focusEditorSource();
    await sendShortcut(
      tester,
      LogicalKeyboardKey.keyT,
      control: true,
      alt: true,
    );
    await pumpKeyboardSurface(tester);
    expect(
      find.byKey(const ValueKey('source-surround-lookup')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('source-surround-lookup')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('source-surround-lookup')), findsNothing);

    await sendShortcut(
      tester,
      LogicalKeyboardKey.keyT,
      control: true,
      alt: true,
    );
    await pumpKeyboardSurface(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.semicolon, character: ';');
    await tester.pump();
    expect(find.byKey(const ValueKey('source-surround-lookup')), findsNothing);
  });

  testWidgets('dismisses quick fix lookup from keyboard paths', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'let stream\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'quickfix-dismiss-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('stream') + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));
    await tester.focusEditorSource();

    await sendShortcut(tester, LogicalKeyboardKey.enter, alt: true);
    await pumpKeyboardSurface(tester);
    expect(
      find.byKey(const ValueKey('source-quick-fix-lookup')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('source-quick-fix-lookup')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('source-quick-fix-lookup')), findsNothing);

    await sendShortcut(tester, LogicalKeyboardKey.enter, alt: true);
    await pumpKeyboardSurface(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.semicolon, character: ';');
    await tester.pump();
    expect(find.byKey(const ValueKey('source-quick-fix-lookup')), findsNothing);
  });

  testWidgets('opens quick fix lookup from editor keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'let stream\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'quickfix-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('stream') + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();

    final quickFixLookup = find.byKey(
      const ValueKey('source-quick-fix-lookup'),
    );
    expect(quickFixLookup, findsOneWidget);
    expect(
      find.descendant(
        of: quickFixLookup,
        matching: find.text('Context Actions'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: quickFixLookup,
        matching: find.text('Insert assignment'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('source-quick-fix-preview')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: quickFixLookup,
        matching: find.text('Preview 1 edit'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: quickFixLookup,
        matching: find.text('Insert ` = value` at 1:11'),
      ),
      findsOneWidget,
    );
    expect(bootstrap.editorController.document.text, text);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(bootstrap.editorController.document.text, 'let stream = value\n');
    expect(find.byKey(const ValueKey('source-quick-fix-lookup')), findsNothing);
  });
}
