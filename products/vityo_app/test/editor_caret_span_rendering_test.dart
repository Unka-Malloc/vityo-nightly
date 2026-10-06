import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/editor/editor.dart' hide TextRange;
import 'package:vityo_app/src/view_ide/language/service/local_styio_language_service.dart';
import 'package:vityo_app/src/view_render/editor/editor.dart';
import 'package:vityo_app/src/view_render/platform/platform.dart';

const String _source = '''fn main() {
  let stream = source |> normalize -> sink
  emit stream
}''';
void main() {
  group('rendered caret span placement', () {
    testWidgets('paints exactly one caret, on the line that holds it', (
      tester,
    ) async {
      final controller = _controller(_source);
      addTearDown(controller.dispose);
      controller.selectCollapsed(_source.length);

      await tester.pumpWidget(_harness(controller));
      await tester.pumpAndSettle();

      // The document ends in a trailing empty line, so the caret legitimately
      // lands there. What matters is that it is the only one: this used to
      // paint one caret at the end of every rendered line.
      expect(_caretLines(tester), hasLength(1));
    });

    testWidgets('paints the caret on the first line when it leads the document', (
      tester,
    ) async {
      final controller = _controller(_source);
      addTearDown(controller.dispose);
      controller.selectCollapsed(0);

      await tester.pumpWidget(_harness(controller));
      await tester.pumpAndSettle();

      expect(_caretLines(tester), <String>['fn main() {']);
    });

    testWidgets('paints the caret mid line without adding a trailing one', (
      tester,
    ) async {
      final controller = _controller(_source);
      addTearDown(controller.dispose);
      final thirdLine = _source.indexOf('emit stream');
      controller.selectCollapsed(thirdLine + 2);

      await tester.pumpWidget(_harness(controller));
      await tester.pumpAndSettle();

      expect(_caretLines(tester), <String>['  emit stream']);
    });

    testWidgets('paints no caret while a range is selected', (tester) async {
      final controller = _controller(_source);
      addTearDown(controller.dispose);
      controller.selectRange(baseOffset: 4, extentOffset: 9);

      await tester.pumpWidget(_harness(controller));
      await tester.pumpAndSettle();

      expect(_caretLines(tester), isEmpty);
    });
  });
}

/// Returns the source text of every rendered line that carries a caret.
///
/// The caret is identified by its own span signature rather than by a
/// plain-text placeholder, because operator glyphs such as `|>` and `->` are
/// also rendered as widget spans.
List<String> _caretLines(WidgetTester tester) {
  final carriers = <String>[];
  for (final element in find.byType(RichText).evaluate()) {
    final rich = element.widget as RichText;
    if (_countCaretSpans(rich.text) == 0) {
      continue;
    }
    carriers.add(rich.text.toPlainText().replaceAll('￼', '').trimRight());
  }
  return carriers;
}

int _countCaretSpans(InlineSpan span) {
  var total = 0;
  if (span is WidgetSpan) {
    final child = span.child;
    if (child is Container &&
        child.margin == const EdgeInsets.symmetric(horizontal: 1)) {
      total += 1;
    }
  }
  final children = switch (span) {
    TextSpan(:final children?) => children,
    _ => const <InlineSpan>[],
  };
  for (final child in children) {
    total += _countCaretSpans(child);
  }
  return total;
}

EditorSessionController _controller(String text) {
  return EditorSessionController(
    initialDocument: DocumentState(
      documentId: 'caret-span-render.styio',
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
  );
}
