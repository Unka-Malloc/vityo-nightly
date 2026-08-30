part of '../vityo_app_smoke_test.dart';

void _registerRefactorSmokeTests() {
  testWidgets('opens add-argument-names intention from editor keymap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = '''
fn blend(left: f64, right: f64) {
  emit left + right
}
price = 1.0
tax = 0.5
blend(price, tax) -> @stdout
''';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'argument-name-intention.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.lastIndexOf('price, tax'));

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('source-quick-fix-lookup')),
      findsOneWidget,
    );
    expect(find.text('Add argument names'), findsOneWidget);
    expect(find.text('Add left: to argument'), findsOneWidget);
    expect(find.text('Preview 2 edits'), findsOneWidget);
    expect(bootstrap.editorController.document.text, text);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(bootstrap.editorController.document.text, '''
fn blend(left: f64, right: f64) {
  emit left + right
}
price = 1.0
tax = 0.5
blend(left: price, right: tax) -> @stdout
''');
    expect(find.byKey(const ValueKey('source-quick-fix-lookup')), findsNothing);
  });

  testWidgets('applies unused parameter quick fix from editor keymap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text =
        'fn blend(left: f64, right: f64) {\n'
        '  emit left\n'
        '}\n'
        'value = blend(price, tax)\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'unused-parameter-quickfix.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('right') + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();

    final quickFixLookup = find.byKey(
      const ValueKey('source-quick-fix-lookup'),
    );
    expect(quickFixLookup, findsOne);
    expect(
      find.descendant(
        of: quickFixLookup,
        matching: find.text('Remove unused parameter'),
      ),
      findsOne,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      bootstrap.editorController.document.text,
      'fn blend(left: f64) {\n'
      '  emit left\n'
      '}\n'
      'value = blend(price)\n',
    );
  });

  testWidgets('opens safe delete blockers from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'used = 1\nused -> @stdout\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'safe-delete-blocked.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('used'));

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('source-safe-delete-panel')), findsOne);
    expect(find.text('Safe Delete: used'), findsOne);
    expect(find.byKey(const ValueKey('source-safe-delete-blockers')), findsOne);
    expect(
      find.textContaining('Symbol `used` is still used in this file.'),
      findsOne,
    );
    expect(bootstrap.editorController.document.text, text);
  });

  testWidgets('applies safe delete from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'used = 1\nunused = 2\nused -> @stdout\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'safe-delete-unused.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('unused'));

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('source-safe-delete-panel')), findsOne);
    expect(find.byKey(const ValueKey('source-safe-delete-preview')), findsOne);

    await tapVisibleKey(tester, 'source-safe-delete-apply');

    expect(
      bootstrap.editorController.document.text,
      'used = 1\nused -> @stdout\n',
    );
    expect(
      find.byKey(const ValueKey('source-safe-delete-panel')),
      findsNothing,
    );
  });

  testWidgets('opens inline variable blockers from source keymap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'let pending\npending -> @stdout\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'inline-variable-blocked.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('pending'));

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('source-inline-variable-panel')),
      findsOne,
    );
    expect(find.text('Inline Variable: pending'), findsOne);
    expect(
      find.byKey(const ValueKey('source-inline-variable-blockers')),
      findsOne,
    );
    expect(
      find.textContaining(
        'Inline variable requires a declaration initializer.',
      ),
      findsOne,
    );
    expect(bootstrap.editorController.document.text, text);
  });

  testWidgets('applies inline variable from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'seed = 40 + 2\nvalue = seed\nseed -> @stdout\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'inline-variable.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('seed'));

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('source-inline-variable-panel')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey('source-inline-variable-preview')),
      findsOne,
    );

    await tapVisibleKey(tester, 'source-inline-variable-apply');

    expect(
      bootstrap.editorController.document.text,
      'value = 40 + 2\n40 + 2 -> @stdout\n',
    );
    expect(
      find.byKey(const ValueKey('source-inline-variable-panel')),
      findsNothing,
    );
  });

  testWidgets('opens introduce variable blockers from source keymap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'value = 40 + 2\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'introduce-variable-blocked.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectRange(
      baseOffset: text.indexOf('value'),
      extentOffset: text.indexOf('value') + 'value'.length,
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('source-introduce-variable-panel')),
      findsOne,
    );
    expect(find.text('Introduce Variable'), findsOne);
    expect(
      find.textContaining(
        'Cannot introduce a variable from an assignment target.',
      ),
      findsOne,
    );
    expect(bootstrap.editorController.document.text, text);
  });

  testWidgets('applies introduce variable from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'value = 40 + 2\n';
    final start = text.indexOf('40 + 2');
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'introduce-variable.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectRange(
      baseOffset: start,
      extentOffset: start + '40 + 2'.length,
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('source-introduce-variable-panel')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey('source-introduce-variable-input')),
      findsOne,
    );

    await tapVisibleKey(tester, 'source-introduce-variable-apply');

    expect(
      bootstrap.editorController.document.text,
      'extractedValue = 40 + 2\nvalue = extractedValue\n',
    );
    expect(
      find.byKey(const ValueKey('source-introduce-variable-panel')),
      findsNothing,
    );
  });

  testWidgets('opens extract function blockers from source keymap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'value = 40 + 2\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'extract-function-blocked.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectRange(
      baseOffset: text.indexOf('value'),
      extentOffset: text.indexOf('value') + 'value'.length,
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('source-extract-function-panel')),
      findsOne,
    );
    expect(find.text('Extract Function'), findsOne);
    expect(
      find.textContaining(
        'Cannot extract a function from an assignment target.',
      ),
      findsOne,
    );
    expect(bootstrap.editorController.document.text, text);
  });

  testWidgets('applies extract function from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text =
        'fn main(user) {\n  first = user + 1\n  second = user + 1\n}\n';
    final start = text.indexOf('user + 1');
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'extract-function.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectRange(
      baseOffset: start,
      extentOffset: start + 'user + 1'.length,
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('source-extract-function-panel')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey('source-extract-function-preview')),
      findsOne,
    );
    expect(
      find.text(
        'Replace selection and 1 duplicate with `extractedFunction(user)`',
      ),
      findsOne,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      bootstrap.editorController.document.text,
      '#extractedFunction := (user) => {\n'
      '  <| user + 1\n'
      '}\n'
      '\n'
      'fn main(user) {\n'
      '  first = extractedFunction(user)\n'
      '  second = extractedFunction(user)\n'
      '}\n',
    );
    expect(
      find.byKey(const ValueKey('source-extract-function-panel')),
      findsNothing,
    );
  });

  testWidgets('applies change signature from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text =
        'fn blend(left: f64, right: f64) {\n'
        '  result = left + right\n'
        '}\n'
        'value = blend(price, tax)\n'
        'again = blend(right: fee, left: total)\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'change-signature.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('blend') + 1);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f6);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('source-change-signature-panel')),
      findsOne,
    );
    expect(find.text('Change Signature'), findsOne);
    expect(
      find.byKey(const ValueKey('source-change-signature-preview')),
      findsOne,
    );
    expect(
      find.text('Change `blend(left, right)` to `blend(left, right)`'),
      findsOne,
    );

    await tester.enterText(
      find.byKey(const ValueKey('source-change-signature-name-input')),
      'combine',
    );
    await tester.enterText(
      find.byKey(const ValueKey('source-change-signature-parameters-input')),
      'right, left',
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Change `blend(left, right)` to `combine(right, left)`'),
      findsOne,
    );

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(
      bootstrap.editorController.document.text,
      'fn combine(right: f64, left: f64) {\n'
      '  result = left + right\n'
      '}\n'
      'value = combine(tax, price)\n'
      'again = combine(right: fee, left: total)\n',
    );
    expect(
      find.byKey(const ValueKey('source-change-signature-panel')),
      findsNothing,
    );
  });

  testWidgets('removes a parameter from change signature', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text =
        'fn blend(left: f64, right: f64) {\n'
        '  emit left\n'
        '}\n'
        'value = blend(price, tax)\n'
        'again = blend(total, fee)\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'change-signature-remove-parameter.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('blend') + 1);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f6);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('source-change-signature-parameters-input')),
      'left',
    );
    await tester.pumpAndSettle();

    expect(find.text('Change `blend(left, right)` to `blend(left)`'), findsOne);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(
      bootstrap.editorController.document.text,
      'fn blend(left: f64) {\n'
      '  emit left\n'
      '}\n'
      'value = blend(price)\n'
      'again = blend(total)\n',
    );
  });

  testWidgets('dismisses editor refactor panels from keyboard', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<void> pumpDocument(
      DocumentState document,
      void Function(AppBootstrap bootstrap) configureSelection,
    ) async {
      final bootstrap = await createBootstrap(PlatformTarget.macos);
      bootstrap.editorController.loadDocument(document);
      configureSelection(bootstrap);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(VityoApp(bootstrap: bootstrap));
      await pumpKeyboardSurface(tester);
      await tester.focusEditorSource();
    }

    const renameText = 'value = value\n';
    await pumpDocument(
      const DocumentState(
        documentId: 'panel-inline-rename.styio',
        text: renameText,
        revision: 0,
      ),
      (bootstrap) {
        bootstrap.editorController.selectCollapsed(
          renameText.indexOf('value') + 2,
        );
      },
    );
    await sendShortcut(tester, LogicalKeyboardKey.f6, shift: true);
    await pumpKeyboardSurface(tester);
    expect(find.byKey(const ValueKey('source-inline-rename-panel')), findsOne);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('source-inline-rename-panel')),
      findsNothing,
    );

    const safeDeleteText = 'used = 1\nunused = 2\nused -> @stdout\n';
    await pumpDocument(
      const DocumentState(
        documentId: 'panel-safe-delete.styio',
        text: safeDeleteText,
        revision: 0,
      ),
      (bootstrap) {
        bootstrap.editorController.selectCollapsed(
          safeDeleteText.indexOf('unused') + 2,
        );
      },
    );
    await sendShortcut(tester, LogicalKeyboardKey.delete, alt: true);
    await pumpKeyboardSurface(tester);
    expect(find.byKey(const ValueKey('source-safe-delete-panel')), findsOne);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('source-safe-delete-panel')),
      findsNothing,
    );

    const inlineText = 'seed = 40 + 2\nvalue = seed\n';
    await pumpDocument(
      const DocumentState(
        documentId: 'panel-inline-variable.styio',
        text: inlineText,
        revision: 0,
      ),
      (bootstrap) {
        bootstrap.editorController.selectCollapsed(
          inlineText.indexOf('seed') + 2,
        );
      },
    );
    await sendShortcut(
      tester,
      LogicalKeyboardKey.keyN,
      control: true,
      alt: true,
    );
    await pumpKeyboardSurface(tester);
    expect(
      find.byKey(const ValueKey('source-inline-variable-panel')),
      findsOne,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('source-inline-variable-panel')),
      findsNothing,
    );

    const introduceText = 'value = 40 + 2\n';
    final introduceStart = introduceText.indexOf('40 + 2');
    await pumpDocument(
      const DocumentState(
        documentId: 'panel-introduce-variable.styio',
        text: introduceText,
        revision: 0,
      ),
      (bootstrap) {
        bootstrap.editorController.selectRange(
          baseOffset: introduceStart,
          extentOffset: introduceStart + '40 + 2'.length,
        );
      },
    );
    await sendShortcut(
      tester,
      LogicalKeyboardKey.keyV,
      control: true,
      alt: true,
    );
    await pumpKeyboardSurface(tester);
    expect(
      find.byKey(const ValueKey('source-introduce-variable-panel')),
      findsOne,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('source-introduce-variable-panel')),
      findsNothing,
    );

    const extractText = 'fn main(user) {\n  first = user + 1\n}\n';
    final extractStart = extractText.indexOf('user + 1');
    await pumpDocument(
      const DocumentState(
        documentId: 'panel-extract-function.styio',
        text: extractText,
        revision: 0,
      ),
      (bootstrap) {
        bootstrap.editorController.selectRange(
          baseOffset: extractStart,
          extentOffset: extractStart + 'user + 1'.length,
        );
      },
    );
    await sendShortcut(
      tester,
      LogicalKeyboardKey.keyM,
      control: true,
      alt: true,
    );
    await pumpKeyboardSurface(tester);
    expect(
      find.byKey(const ValueKey('source-extract-function-panel')),
      findsOne,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('source-extract-function-panel')),
      findsNothing,
    );

    const signatureText =
        'fn blend(left: f64, right: f64) {\n'
        '  result = left + right\n'
        '}\n'
        'value = blend(price, tax)\n';
    await pumpDocument(
      const DocumentState(
        documentId: 'panel-change-signature.styio',
        text: signatureText,
        revision: 0,
      ),
      (bootstrap) {
        bootstrap.editorController.selectCollapsed(
          signatureText.indexOf('blend') + 1,
        );
      },
    );
    await sendShortcut(tester, LogicalKeyboardKey.f6, control: true);
    await pumpKeyboardSurface(tester);
    expect(
      find.byKey(const ValueKey('source-change-signature-panel')),
      findsOne,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('source-change-signature-panel')),
      findsNothing,
    );
  });

  testWidgets('applies rename edits from language pane', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'value = value\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(documentId: 'rename.styio', text: text, revision: 0),
    );
    bootstrap.editorController.selectCollapsed(text.lastIndexOf('value') + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));
    await revealDesktopLanguagePane(tester);

    final languageScrollable = find.descendant(
      of: find.byKey(const ValueKey('language-pane-desktop')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('language-rename-input')),
      120,
      scrollable: languageScrollable,
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('language-rename-input')),
      'price',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language-apply-rename')));
    await tester.pump();

    expect(bootstrap.editorController.document.text, 'price = price\n');
  });

  testWidgets('opens inline rename from source keymap', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'value = value\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'inline-rename.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.lastIndexOf('value') + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f6);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('source-inline-rename-panel')), findsOne);
    final renameField = tester.widget<TextField>(
      find.byKey(const ValueKey('source-inline-rename-input')),
    );
    expect(renameField.controller!.text, 'value');

    await tester.enterText(
      find.byKey(const ValueKey('source-inline-rename-input')),
      'price',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(bootstrap.editorController.document.text, 'price = price\n');
    expect(
      find.byKey(const ValueKey('source-inline-rename-panel')),
      findsNothing,
    );
  });

  testWidgets('keeps inline rename open for invalid identifiers', (
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
        documentId: 'inline-rename-invalid.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('value') + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));
    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f6);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('source-inline-rename-input')),
      '1bad',
    );
    await tapVisibleKey(tester, 'source-inline-rename-apply');

    expect(bootstrap.editorController.document.text, text);
    expect(find.byKey(const ValueKey('source-inline-rename-panel')), findsOne);
    expect(find.text('Invalid rename target.'), findsOne);
  });

  testWidgets('keeps inline rename open for conflicting identifiers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'price = 1\ntotal = price\ntotal -> @stdout\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'inline-rename-conflict.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('price'));

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));
    await tester.focusEditorSource();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f6);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('source-inline-rename-input')),
      'total',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(bootstrap.editorController.document.text, text);
    expect(find.byKey(const ValueKey('source-inline-rename-panel')), findsOne);
    expect(
      find.text(
        'Name `total` already declares a current-file variable. '
        'Conflict at 2:1.',
      ),
      findsOne,
    );
  });

  testWidgets('applies inline diagnostic quick fix from the active line', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'broken.styio',
        text: 'fn broken() {\n  emit stream\n',
        revision: 0,
      ),
    );

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));

    await tester.focusEditorSource();
    await tester.tap(find.byKey(const ValueKey('source-line-0')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('inline-diagnostic-fix-0')),
      findsOneWidget,
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey('inline-diagnostic-fix-0')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('inline-diagnostic-fix-0')));
    await tester.pump();

    expect(bootstrap.editorController.document.text.endsWith('}'), isTrue);
    expect(
      bootstrap.editorController.analysis.diagnostics.where(
        (item) => item.code == 'unclosed-block',
      ),
      isEmpty,
    );
  });

  testWidgets('cycles mobile language inspector sections', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.ios);
    const text =
        'fn blend(left: f64, right: f64): f64 {\n'
        '  emit left + right\n'
        '}\n'
        'price: f64 = 12.5  \n'
        'tax = 0.5\n'
        'value = blend(price, tax)\n'
        'missingPrice -> @stdout\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'mobile-language-tabs.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('price, tax') + 2);

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));
    await revealMobileLanguagePane(tester);

    expect(
      find.byKey(
        const ValueKey('language-mobile-section-diagnostics'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    final mobilePane = find.byKey(
      const ValueKey('language-pane-mobile'),
      skipOffstage: false,
    );
    final tabScrollable = find
        .descendant(
          of: mobilePane,
          matching: find.byType(Scrollable, skipOffstage: false),
          skipOffstage: false,
        )
        .first;
    final sections = <String, String>{
      'Blocks': 'blocks',
      'Inlays': 'inlays',
      'Symbols': 'symbols',
      'Resolve': 'resolve',
      'Token': 'token',
      'Hover': 'hover',
      'Complete': 'completions',
      'Format': 'formatting',
    };

    for (final section in sections.entries) {
      final tabLabel = find.descendant(
        of: tabScrollable,
        matching: find.text(section.key, skipOffstage: false),
        skipOffstage: false,
      );
      final tab = find.ancestor(
        of: tabLabel.first,
        matching: find.byType(InkWell, skipOffstage: false),
      );
      expect(tab, findsOneWidget);
      tester.widget<InkWell>(tab).onTap!();
      await tester.pump();

      expect(
        find.byKey(
          ValueKey('language-mobile-section-${section.value}'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('applies language pane diagnostic and formatting actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'fn broken() {\n  emit stream  \n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'language-pane-actions.styio',
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
      find.byKey(const ValueKey('language-diagnostic-fix-0-0')),
      120,
      scrollable: languageScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language-diagnostic-fix-0-0')));
    await tester.pump();

    expect(bootstrap.editorController.document.text.endsWith('}'), isTrue);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('language-apply-formatting')),
      120,
      scrollable: languageScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language-apply-formatting')));
    await tester.pump();

    expect(bootstrap.editorController.document.text.contains('  \n'), isFalse);
  });

  testWidgets('applies completion from language pane preview', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'language-pane-completion.styio',
        text: '',
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
      find.byKey(const ValueKey('language-apply-completion-@import')),
      120,
      scrollable: languageScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('language-apply-completion-@import')),
    );
    await tester.pump();

    expect(
      bootstrap.editorController.document.text,
      startsWith('@import { styio/core }'),
    );
  });

  testWidgets('shows language pane rename conflicts', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bootstrap = await createBootstrap(PlatformTarget.macos);
    const text = 'price = 1\ntotal = price\ntotal -> @stdout\n';
    bootstrap.editorController.loadDocument(
      const DocumentState(
        documentId: 'language-pane-rename-conflict.styio',
        text: text,
        revision: 0,
      ),
    );
    bootstrap.editorController.selectCollapsed(text.indexOf('price'));

    await tester.pumpWidget(VityoApp(bootstrap: bootstrap));
    await revealDesktopLanguagePane(tester);

    final languageScrollable = find.descendant(
      of: find.byKey(const ValueKey('language-pane-desktop')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('language-rename-input')),
      120,
      scrollable: languageScrollable,
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('language-rename-input')),
      'total',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('language-rename-conflict')), findsOne);
  });
}
