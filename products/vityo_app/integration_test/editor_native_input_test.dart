import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vityo_app/src/ide/editor/editor.dart' hide TextRange;
import 'package:vityo_app/src/view_ide/language/service/local_styio_language_service.dart';
import 'package:vityo_app/src/view_render/editor/editor.dart';
import 'package:vityo_app/src/view_render/platform/platform.dart';

import '../test/support/editor_widget_test_driver.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS engine closes the editor input and semantics journey', (
    tester,
  ) async {
    expect(Platform.isMacOS, isTrue, reason: 'run this lane on macOS');

    final semantics = tester.ensureSemantics();
    final controller = _controller('A B');
    addTearDown(controller.dispose);

    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    // Exercise the real rendered hit-test path before transport-level input.
    await tester.tap(find.byKey(const ValueKey('source-buffer-surface')));
    await tester.pump();
    expect(find.text('input connected'), findsOneWidget);

    var node = tester.getSemantics(
      find.byKey(const ValueKey('source-buffer-semantics')),
    );
    var data = node.getSemanticsData();
    expect(node.flagsCollection.isTextField, isTrue);
    expect(node.flagsCollection.isFocused, ui.Tristate.isTrue);
    expect(data.hasAction(SemanticsAction.setText), isTrue);

    tester.semantics.setText(
      find.semantics.byFlag(SemanticsFlag.isTextField),
      '日本é🙂',
    );
    await tester.pump();
    expect(controller.document.text, '日本é🙂');

    const emoji = '👨‍👩‍👧‍👦';
    controller.loadDocument(
      const DocumentState(
        documentId: 'native-input.styio',
        text: 'x${emoji}y',
        revision: 0,
      ),
    );
    controller.selectCollapsed(1 + emoji.length);
    await tester.pump();
    await tester.focusEditorSource();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(controller.document.text, 'xy');
    expect(controller.selectionSet.primarySelection.extentOffset, 1);

    controller.loadDocument(
      const DocumentState(
        documentId: 'native-semantics.styio',
        text: 'left אב right',
        revision: 0,
      ),
    );
    controller.selectSelections(const <SelectionState>[
      SelectionState.collapsed(0),
      SelectionState(baseOffset: 5, extentOffset: 7),
      SelectionState.collapsed(13),
    ], primaryIndex: 1);
    await tester.pump();
    await tester.focusEditorSource();

    node = tester.getSemantics(
      find.byKey(const ValueKey('source-buffer-semantics')),
    );
    data = node.getSemanticsData();
    expect(node.flagsCollection.isTextField, isTrue);
    expect(node.flagsCollection.isFocused, ui.Tristate.isTrue);
    expect(data.textSelection, isNotNull);
    expect('${data.label} ${data.hint}', contains('3 selections'));
    expect(data.hasAction(SemanticsAction.setSelection), isTrue);
    expect(data.hasAction(SemanticsAction.setText), isTrue);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(find.text('input disconnected'), findsOneWidget);
    await tester.focusEditorSource();
    expect(find.text('input connected'), findsOneWidget);

    semantics.dispose();
    await _captureEvidence(tester);
    expect(tester.takeException(), isNull);
  });
}

EditorSessionController _controller(String text) {
  return EditorSessionController(
    initialDocument: DocumentState(
      documentId: 'native-input.styio',
      text: text,
      revision: 0,
    ),
    languageService: const LocalStyioLanguageService(),
  );
}

Widget _harness(EditorSessionController controller) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 1200,
        height: 800,
        child: RepaintBoundary(
          key: const ValueKey('native-input-evidence'),
          child: EditorSurface(
            controller: controller,
            viewportProfile: const ViewportProfile(
              family: ViewportFamily.desktop,
              width: 1200,
              height: 800,
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _captureEvidence(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('native-input-evidence')),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  expect(bytes, isNotNull);
  final output = Directory('build/integration_test')
    ..createSync(recursive: true);
  File(
    '${output.path}/vityo-editor-native-input-macos.png',
  ).writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
}
