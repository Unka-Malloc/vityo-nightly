import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vityo_app/src/ide/editor/editor.dart';
import 'package:vityo_app/src/view_ide/language/service/local_styio_language_service.dart';
import 'package:vityo_app/src/view_render/editor/editor.dart';
import 'package:vityo_app/src/view_render/platform/platform.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS virtual editor scrolls and reveals the full document', (
    tester,
  ) async {
    expect(Platform.isMacOS, isTrue, reason: 'run this lane on macOS');
    const lineCount = 100000;
    final controller = EditorSessionController(
      initialDocument: DocumentState(
        documentId: 'high-volume.styio',
        text: List<String>.generate(
          lineCount,
          (index) => 'value_$index := ${index * 2}',
        ).join('\n'),
        revision: 1,
      ),
      languageService: const LocalStyioLanguageService(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const ValueKey(
          'source-render-backend-${EditorRenderPipelinePlan.flutterVirtualListRenderer}',
        ),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    final source = find.byKey(const ValueKey('source-buffer-scroll'));
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: source, matching: find.byType(Scrollable)),
    );
    expect(_renderedLineIndexes(), isNotEmpty);
    await tester.tap(source);
    await tester.drag(source, const Offset(0, -420));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(300));

    scrollable.position.jumpTo(scrollable.position.maxScrollExtent / 2);
    await tester.pump();
    await tester.pump();
    final middleLines = _renderedLineIndexes();
    expect(middleLines, isNotEmpty);
    expect(middleLines.length, lessThan(120));
    expect(middleLines.reduce((a, b) => a < b ? a : b), greaterThan(45000));
    expect(middleLines.reduce((a, b) => a > b ? a : b), lessThan(55000));
    await tester.tap(
      find.byKey(
        ValueKey('source-line-${middleLines[middleLines.length ~/ 2]}'),
      ),
    );
    await tester.pump();
    await _captureEvidence(tester);

    controller.selectLineColumn(line: lineCount - 1, column: 0);
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('source-line-99999'), skipOffstage: false),
      findsOneWidget,
    );
    expect(_renderedLineIndexes().length, lessThan(120));
    expect(tester.takeException(), isNull);
  });
}

List<int> _renderedLineIndexes() {
  final indexes = find
      .byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> && key.value.startsWith('source-line-');
      }, skipOffstage: false)
      .evaluate()
      .map((element) => (element.widget.key! as ValueKey<String>).value)
      .map((value) => int.parse(value.substring('source-line-'.length)))
      .toList(growable: false);
  indexes.sort();
  return indexes;
}

Widget _harness(EditorSessionController controller) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 1200,
        height: 800,
        child: RepaintBoundary(
          key: const ValueKey('high-volume-editor-evidence'),
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
    find.byKey(const ValueKey('high-volume-editor-evidence')),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  expect(bytes, isNotNull);
  final output = Directory('build/integration_test')
    ..createSync(recursive: true);
  File(
    '${output.path}/vityo-editor-high-volume-macos.png',
  ).writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
}
