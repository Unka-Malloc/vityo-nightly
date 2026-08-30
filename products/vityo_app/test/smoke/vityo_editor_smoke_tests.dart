part of '../vityo_app_smoke_test.dart';

void _registerEditorSmokeTests() {
  testWidgets('keeps mobile editor layout on wide iOS viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1366, 1024);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.ios);

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
    expect(
      find.byKey(const ValueKey('editor-language-family-desktop')),
      findsNothing,
    );

    await revealMobileLanguagePane(tester);
    expect(
      find.byKey(const ValueKey('language-pane-mobile'), skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('shows token context for the caret-resolved token', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    final sourceOffset = bootstrap.editorController.document.text.indexOf(
      'source',
    );
    bootstrap.editorController.selectCollapsed(sourceOffset + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));
    await revealDesktopLanguagePane(tester);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('language-token-context')),
      120,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('language-pane-desktop')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('language-token-context')),
      findsOneWidget,
    );
    expect(find.textContaining('Lexeme `source`'), findsOneWidget);
  });

  testWidgets('highlights resolved current-file usages at caret', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'value = value\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(documentId: 'usages.styio', text: text, revision: 0),
    );
    bootstrap.editorController.selectCollapsed(text.lastIndexOf('value') + 2);
    expect(bootstrap.editorController.referencesAtSelection.length, 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    expect(
      backgroundsForTextOnLine(tester, lineIndex: 0, text: 'value'),
      contains(const Color(0xFFF5DA91)),
    );
    bootstrap.editorController.selectCollapsed(2);
    await tester.pump();
    expect(
      backgroundsForTextOnLine(tester, lineIndex: 0, text: 'value'),
      contains(const Color(0xFFDDEACB)),
    );
  });

  testWidgets('shows unresolved reference diagnostics from symbol index', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'unresolved.styio',
        text: 'known = 1\nmissingPrice -> @stdout\n',
        revision: 0,
      ),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));
    await revealDesktopLanguagePane(tester);

    expect(
      bootstrap.editorController.analysis.diagnostics.map(
        (diagnostic) => diagnostic.message,
      ),
      contains('Identifier is not resolved by the current symbol index.'),
    );
    final languageScrollable = find.descendant(
      of: find.byKey(const ValueKey('language-pane-desktop')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('language-desktop-section-diagnostics')),
      120,
      scrollable: languageScrollable,
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'Identifier is not resolved by the current symbol index.',
        skipOffstage: false,
      ),
      findsOneWidget,
    );
  });

  testWidgets('navigates diagnostics from editor keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'let stream\nmissingPrice -> @stdout\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'diagnostic-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(0);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pump();

    expect(bootstrap.editorController.selection.start, 0);
    expect(bootstrap.editorController.selection.end, text.indexOf('\n'));

    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pump();

    expect(
      bootstrap.editorController.selection.start,
      text.indexOf('missingPrice'),
    );
  });

  testWidgets('selects diagnostics from problems list', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'let stream\nmissingPrice -> @stdout\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'problems-list.styio',
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
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('language-diagnostic-1')),
      120,
      scrollable: languageScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language-diagnostic-1')));
    await tester.pump();

    expect(
      bootstrap.editorController.selection.start,
      text.indexOf('missingPrice'),
    );
    expect(bootstrap.editorController.canUndo, isFalse);
  });

  testWidgets('navigates to resolved definition from language pane', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'value = value\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'definition.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.lastIndexOf('value') + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));
    await revealDesktopLanguagePane(tester);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('language-go-to-definition')),
      120,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('language-pane-desktop')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language-go-to-definition')));
    await tester.pump();

    expect(bootstrap.editorController.selection.start, 0);
    expect(bootstrap.editorController.selection.end, 'value'.length);
  });

  testWidgets('navigates to definition from editor keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'value = value\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'definition-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.lastIndexOf('value') + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(bootstrap.editorController.selection.start, 0);
    expect(bootstrap.editorController.selection.end, 'value'.length);
  });

  testWidgets('extends and shrinks structural selection from editor keymap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'fn main(user) {\n  value = user\n}\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'selection-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('value') + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(bootstrap.editorController.selection.start, text.indexOf('value'));
    expect(
      bootstrap.editorController.selection.end,
      text.indexOf('value') + 'value'.length,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(bootstrap.editorController.selection.isCollapsed, isTrue);
    expect(bootstrap.editorController.selection.end, text.indexOf('value') + 2);
    expect(bootstrap.editorController.canUndo, isFalse);
  });

  testWidgets('toggles line comment from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'value = 1\nnext = 2\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'line-comment-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('value') + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(
      bootstrap.editorController.document.text,
      '// value = 1\nnext = 2\n',
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(bootstrap.editorController.document.text, text);
  });

  testWidgets('duplicates current line from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'value = 1\nnext = 2\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'duplicate-line-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('value') + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(
      bootstrap.editorController.document.text,
      'value = 1\nvalue = 1\nnext = 2\n',
    );
    expect(bootstrap.editorController.canUndo, isTrue);
  });

  testWidgets('moves current line from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'alpha\nbeta\ngamma\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'move-line-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('beta') + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();

    expect(bootstrap.editorController.document.text, 'alpha\ngamma\nbeta\n');
    expect(bootstrap.editorController.selection.end, 14);
    expect(bootstrap.editorController.canUndo, isTrue);
  });

  testWidgets('joins lines from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'value =\n  source\nnext\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'join-lines-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(bootstrap.editorController.document.text, 'value = source\nnext\n');
    expect(bootstrap.editorController.selection.end, 'value = '.length);
    expect(bootstrap.editorController.canUndo, isTrue);
  });

  testWidgets('deletes current line from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'alpha\nbeta\ngamma\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'delete-line-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('beta') + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(bootstrap.editorController.document.text, 'alpha\ngamma\n');
    expect(bootstrap.editorController.selection.end, 'alpha\n'.length);
    expect(bootstrap.editorController.canUndo, isTrue);
  });

  testWidgets('deletes previous word from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'alpha beta';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'delete-word-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.length);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(bootstrap.editorController.document.text, 'alpha ');
    expect(bootstrap.editorController.selection.end, 'alpha '.length);
    expect(bootstrap.editorController.canUndo, isTrue);
  });

  testWidgets('moves to smart line start from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'fn main() {\n  value = 1\n}\n';
    final valueStart = text.indexOf('value');
    final lineStart = text.lastIndexOf('\n', valueStart) + 1;
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'smart-home-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(valueStart + 3);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    expect(bootstrap.editorController.selection.end, valueStart);

    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    expect(bootstrap.editorController.selection.end, lineStart);
    expect(bootstrap.editorController.canUndo, isFalse);
  });

  testWidgets('opens surround with lookup from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'fn main() {\n  value = 1\n  next = 2\n}\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'surround-with-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('value') + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(find.byKey(const ValueKey('source-surround-lookup')), findsOne);
    expect(find.text('Surround With'), findsOne);
    expect(find.text('task block'), findsOne);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      bootstrap.editorController.document.text,
      'fn main() {\n  ||> {\n    value = 1\n  }\n  next = 2\n}\n',
    );
    expect(bootstrap.editorController.canUndo, isTrue);
  });

  testWidgets('moves to matching brace from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'fn main() {\n  value = [1]\n}\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'matching-brace-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('['));

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(bootstrap.editorController.selection.end, text.indexOf(']') + 1);
    expect(bootstrap.editorController.canUndo, isFalse);
  });

  testWidgets('folds and expands semantic blocks from source keymap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'fn main() {\n  value = 1\n  next = 2\n}\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'semantic-fold-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('value') + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    expect(find.byKey(const ValueKey('source-fold-toggle-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('source-line-2')), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(find.byKey(const ValueKey('source-fold-summary-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('source-line-2')), findsNothing);
    expect(bootstrap.editorController.document.text, text);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(find.byKey(const ValueKey('source-fold-summary-0')), findsNothing);
    expect(find.byKey(const ValueKey('source-line-2')), findsOneWidget);
  });

  testWidgets('moves by word from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'alpha beta';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'word-navigation-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(1);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(bootstrap.editorController.selection.end, 'alpha'.length);
    expect(bootstrap.editorController.canUndo, isFalse);
  });

  testWidgets('inserts smart brace pair from source typing', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'fn main() ';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'smart-brace-pair.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.length);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await commitPlatformText(tester, '{');

    expect(bootstrap.editorController.document.text, 'fn main() {}');
    expect(bootstrap.editorController.selection.end, text.length + 1);
    expect(bootstrap.editorController.canUndo, isTrue);
  });

  testWidgets('splits smart brace pair from source enter keymap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'fn main() {}';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'smart-newline-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('{') + 1);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(bootstrap.editorController.document.text, 'fn main() {\n  \n}');
    expect(bootstrap.editorController.selection.end, 'fn main() {\n  '.length);
    expect(bootstrap.editorController.canUndo, isTrue);
  });

  testWidgets('indents and outdents current line from source keymap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'alpha\nbeta\n';
    final lineStart = text.indexOf('beta');
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'indent-line-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(lineStart);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(bootstrap.editorController.document.text, 'alpha\n  beta\n');
    expect(bootstrap.editorController.selection.end, lineStart + 2);
    expect(bootstrap.editorController.canUndo, isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(bootstrap.editorController.document.text, text);
    expect(bootstrap.editorController.selection.end, lineStart);
  });

  testWidgets('applies best completion from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'job = ||> { <| 42 }\njo';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'best-completion-keymap.styio',
        text: text,
        revision: 0,
      ),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(
      bootstrap.editorController.document.text,
      'job = ||> { <| 42 }\njob',
    );
  });

  testWidgets('opens parameter info from editor keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = '''
/// Blends price and tax inputs.
/// @param left Base price before tax.
/// @param right Tax component to add.
fn blend(left: f64, right: f64 = 0.0) {
  emit left
}
value = blend(right: tax, left: price)
''';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'parameter-info-keymap.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.lastIndexOf('tax') + 1);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('source-parameter-info-panel')),
      findsOneWidget,
    );
    expect(find.text('Parameter Info: blend'), findsOneWidget);
    expect(find.text('fn blend(left: f64, right: f64 = 0.0)'), findsOneWidget);
    expect(find.text('Blends price and tax inputs.'), findsOneWidget);
    expect(find.text('Argument 2 of 2: right: f64 = 0.0'), findsOneWidget);
    expect(find.text('Tax component to add.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('source-parameter-info-close')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('source-parameter-info-panel')),
      findsNothing,
    );
  });

  testWidgets('renders parameter inlay hints in source lines', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = '''
fn blend(left: f64, right: f64) {
  emit left
}
value = blend(price, tax)
''';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'parameter-inlay-source.styio',
        text: text,
        revision: 0,
      ),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));
    await tester.pump();
    await revealDesktopLanguagePane(tester);

    final callLine = bootstrap.editorController.document
        .positionForOffset(text.indexOf('value = blend'))
        .line;
    final callLineSpans = spanTextsOnLine(tester, lineIndex: callLine);
    final inlaySection = find.byKey(
      const ValueKey('language-desktop-section-inlays'),
    );

    expect(bootstrap.editorController.analysis.inlayHintCount, 2);
    expect(callLineSpans, containsAll(<String>['left: ', 'right: ']));
    await tester.scrollUntilVisible(
      inlaySection,
      120,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('language-pane-desktop')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(inlaySection, findsOneWidget);
  });

  testWidgets('renders type inlay hints in source lines', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = '''
fn blend(left: f64, right: f64): f64 {
  emit left
}
price = 12.5
value = blend(price, price)
''';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'type-inlay-source.styio',
        text: text,
        revision: 0,
      ),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));
    await tester.pump();

    final priceLine = bootstrap.editorController.document
        .positionForOffset(text.indexOf('price = 12.5'))
        .line;
    final valueLine = bootstrap.editorController.document
        .positionForOffset(text.indexOf('value = blend'))
        .line;

    expect(bootstrap.editorController.analysis.inlayHintCount, 4);
    expect(
      spanTextsOnLine(tester, lineIndex: priceLine),
      containsAll(<String>[': f64 ']),
    );
    expect(
      spanTextsOnLine(tester, lineIndex: valueLine),
      containsAll(<String>[': f64 ', 'left: ', 'right: ']),
    );
  });
}
