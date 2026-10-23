import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/editor/editor.dart';
import 'package:vityo_app/src/view_ide/language/service/local_styio_language_service.dart';
import 'package:vityo_app/src/view_render/editor/editor.dart';
import 'package:vityo_app/src/view_render/platform/platform.dart';

void main() {
  for (final platform in <TargetPlatform>[
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  ]) {
    testWidgets('${platform.name} virtual editor reaches the final line', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final controller = EditorSessionController(
        initialDocument: DocumentState(
          documentId: '${platform.name}-large.styio',
          text: List<String>.generate(
            EditorRenderPipelinePlan.highVolumeLineThreshold,
            (index) => 'line_$index := $index',
          ).join('\n'),
          revision: 1,
        ),
        languageService: const LocalStyioLanguageService(),
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
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
          ),
        );
        await tester.pump();

        final source = find.byKey(const ValueKey('source-buffer-scroll'));
        final scrollable = tester.state<ScrollableState>(
          find.descendant(of: source, matching: find.byType(Scrollable)),
        );
        expect(scrollable.position.maxScrollExtent, greaterThan(200000));
        scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
        await tester.pump();

        expect(
          find.byKey(const ValueKey('source-line-9999'), skipOffstage: false),
          findsOneWidget,
        );
        expect(_renderedLineCount(), lessThan(120));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}

int _renderedLineCount() {
  return find
      .byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> && key.value.startsWith('source-line-');
      }, skipOffstage: false)
      .evaluate()
      .length;
}
