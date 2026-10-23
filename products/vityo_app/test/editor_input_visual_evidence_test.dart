import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/editor/editor.dart' hide TextRange;
import 'package:vityo_app/src/view_ide/language/service/local_styio_language_service.dart';
import 'package:vityo_app/src/view_render/editor/editor.dart';
import 'package:vityo_app/src/view_render/platform/platform.dart';

import 'support/editor_widget_test_driver.dart';

const _writeEvidenceEnabled = bool.fromEnvironment(
  'VITYO_WRITE_EDITOR_INPUT_EVIDENCE',
);

/// Bounded Visual Verifier evidence capture for REQ-INPUT-003.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'capture declared desktop input states',
    (tester) async {
      await _loadEvidenceFonts();
      final outDir = _evidenceDir();
      outDir.createSync(recursive: true);

      for (final size in const <Size>[Size(1200, 800), Size(1600, 1200)]) {
        final tag = '${size.width.toInt()}x${size.height.toInt()}';
        final controller = _controller('A\tB\n\nleft אב 👨‍👩‍👧');
        addTearDown(controller.dispose);
        final emojiStart = controller.document.text.indexOf('👨');
        final emojiEnd = emojiStart + '👨‍👩‍👧'.length;
        controller.selectSelections([
          const SelectionState.collapsed(0),
          SelectionState(baseOffset: emojiEnd, extentOffset: emojiStart),
          SelectionState.collapsed(controller.document.text.length),
        ], primaryIndex: 1);

        await tester.pumpWidget(_harness(controller, size));
        await tester.pump(const Duration(milliseconds: 16));
        await tester.focusEditorSource();
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.takeException(), isNull);
        await _capture(tester, outDir, 'multi-selection-$tag.png');

        controller.selectSelections(const [
          SelectionState.collapsed(0),
          SelectionState.collapsed(3),
        ], primaryIndex: 0);
        await tester.pump(const Duration(milliseconds: 16));

        final composing = _replaceRemoteSelection(
          _remoteEditingValue(tester),
          '日本',
          composing: true,
        );
        tester.testTextInput.updateEditingValue(composing);
        await tester.pump(const Duration(milliseconds: 16));
        expect(controller.document.revision, 0);
        expect(
          find.byKey(const ValueKey('source-composition-range')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await _capture(tester, outDir, 'composition-active-$tag.png');

        tester.testTextInput.updateEditingValue(
          composing.copyWith(composing: TextRange.empty),
        );
        await tester.pump(const Duration(milliseconds: 16));
        expect(controller.document.revision, 1);
        await _capture(tester, outDir, 'composition-committed-$tag.png');

        controller.undo();
        await tester.pump(const Duration(milliseconds: 16));
        await _capture(tester, outDir, 'after-undo-$tag.png');

        final canceling = _replaceRemoteSelection(
          _remoteEditingValue(tester),
          '候',
          composing: true,
        );
        tester.testTextInput.updateEditingValue(canceling);
        await tester.pump(const Duration(milliseconds: 16));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          find.byKey(const ValueKey('source-input-status')),
          findsOneWidget,
        );
        await _capture(tester, outDir, 'composition-canceled-$tag.png');

        controller.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !_writeEvidenceEnabled,
  );
}

Directory _evidenceDir() {
  final packageRoot = Directory.current;
  return Directory(
    '${packageRoot.parent.parent.path}/docs/review/interactive-editor-input',
  );
}

Future<void> _capture(
  WidgetTester tester,
  Directory outDir,
  String name,
) async {
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('visual-evidence-boundary')),
    );
    final image = await boundary.toImage(pixelRatio: 1.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(bytes, isNotNull);
    File('${outDir.path}/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

EditorSessionController _controller(String text) {
  return EditorSessionController(
    initialDocument: DocumentState(
      documentId: 'visual-evidence.styio',
      text: text,
      revision: 0,
    ),
    languageService: const LocalStyioLanguageService(),
  );
}

Widget _harness(EditorSessionController controller, Size size) {
  return MaterialApp(
    theme: ThemeData(fontFamily: 'Roboto'),
    home: Scaffold(
      body: Center(
        child: RepaintBoundary(
          key: const ValueKey('visual-evidence-boundary'),
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: ColoredBox(
              color: const Color(0xFF101418),
              child: EditorSurface(
                controller: controller,
                viewportProfile: ViewportProfile(
                  family: ViewportFamily.desktop,
                  width: size.width,
                  height: size.height,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _loadEvidenceFonts() async {
  final flutterRoot = Directory(_flutterRootPath());
  final sans = File(
    '${flutterRoot.path}/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
  );
  final mono = File(
    '${flutterRoot.path}/bin/cache/dart-sdk/bin/resources/devtools/assets/'
    'fonts/Roboto_Mono/RobotoMono-Regular.ttf',
  );
  for (final font in <File>[sans, mono]) {
    expect(font.existsSync(), isTrue, reason: 'missing evidence font');
  }

  await _loadFontFamily('Roboto', <File>[sans]);
  await _loadFontFamily('monospace', <File>[mono]);
}

String _flutterRootPath() {
  final configured = Platform.environment['FLUTTER_ROOT']?.trim();
  if (configured != null && configured.isNotEmpty) return configured;
  final lookup = Process.runSync('which', const <String>['flutter']);
  expect(lookup.exitCode, 0, reason: 'Flutter SDK is not on PATH');
  final executable = File((lookup.stdout as String).trim());
  return File(executable.resolveSymbolicLinksSync()).parent.parent.path;
}

Future<void> _loadFontFamily(String family, List<File> files) async {
  final loader = FontLoader(family);
  for (final file in files) {
    final bytes = file.readAsBytesSync();
    loader.addFont(Future<ByteData>.value(bytes.buffer.asByteData()));
  }
  await loader.load();
}

TextEditingValue _remoteEditingValue(WidgetTester tester) {
  final state = tester.testTextInput.editingState!;
  return TextEditingValue(
    text: state['text'] as String,
    selection: TextSelection(
      baseOffset: state['selectionBase'] as int,
      extentOffset: state['selectionExtent'] as int,
    ),
    composing: TextRange(
      start: state['composingBase'] as int,
      end: state['composingExtent'] as int,
    ),
  );
}

TextEditingValue _replaceRemoteSelection(
  TextEditingValue current,
  String replacement, {
  required bool composing,
}) {
  final start = current.selection.start;
  final end = current.selection.end;
  final nextText = current.text.replaceRange(start, end, replacement);
  final nextOffset = start + replacement.length;
  return TextEditingValue(
    text: nextText,
    selection: TextSelection.collapsed(offset: nextOffset),
    composing: composing
        ? TextRange(start: start, end: nextOffset)
        : TextRange.empty,
  );
}
