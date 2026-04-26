import 'package:flutter_test/flutter_test.dart';
import 'package:styio_view_app/src/editor/document_state.dart';
import 'package:styio_view_app/src/editor/editor_controller.dart';
import 'package:styio_view_app/src/editor/selection_state.dart';
import 'package:styio_view_app/src/language/language_contract.dart';
import 'package:styio_view_app/src/language/simple_styio_language_service.dart';

void main() {
  test('backspace decomposes substituted operator source', () {
    final controller = EditorSessionController(
      initialDocument: const DocumentState(
        documentId: 'sample.styio',
        text: 'let flow = source |> sink',
        revision: 0,
      ),
      languageService: const SimpleStyioLanguageService(),
    );

    final operatorEnd = controller.document.text.indexOf('|>') + 2;
    controller.selectCollapsed(operatorEnd);
    controller.backspace();

    expect(controller.document.text, 'let flow = source | sink');
    expect(controller.selection.end, operatorEnd - 1);
  });

  test('supports vertical caret movement with column clamping', () {
    final controller = EditorSessionController(
      initialDocument: const DocumentState(
        documentId: 'sample.styio',
        text: 'ab\ncdef\nxy',
        revision: 0,
      ),
      languageService: const SimpleStyioLanguageService(),
      initialSelection: const SelectionState.collapsed(6),
    );

    controller.moveCaretVertically(1);
    expect(controller.selection.end, 10);

    controller.moveCaretVertically(-1);
    expect(controller.selection.end, 5);

    controller.moveCaretToLineBoundary(end: false);
    expect(controller.selection.end, 3);
  });

  test('inserts and deletes forward at the caret', () {
    final controller = EditorSessionController(
      initialDocument: const DocumentState(
        documentId: 'sample.styio',
        text: 'abc',
        revision: 0,
      ),
      languageService: const SimpleStyioLanguageService(),
      initialSelection: const SelectionState.collapsed(1),
    );

    controller.insertText('Z');
    expect(controller.document.text, 'aZbc');
    expect(controller.selection.end, 2);

    controller.deleteForward();
    expect(controller.document.text, 'aZc');
    expect(controller.selection.end, 2);
  });

  test('expands selection with shifted caret movement', () {
    final controller = EditorSessionController(
      initialDocument: const DocumentState(
        documentId: 'sample.styio',
        text: 'alpha beta',
        revision: 0,
      ),
      languageService: const SimpleStyioLanguageService(),
      initialSelection: const SelectionState.collapsed(5),
    );

    controller.moveCaretHorizontally(3, expandSelection: true);
    expect(controller.selection.baseOffset, 5);
    expect(controller.selection.extentOffset, 8);
    expect(controller.selection.isCollapsed, isFalse);

    controller.insertText('|>');
    expect(controller.document.text, 'alpha|>ta');
    expect(controller.selection.isCollapsed, isTrue);
  });

  test(
    'applies completion item by replacing the active token at caret edge',
    () {
      final controller = EditorSessionController(
        initialDocument: const DocumentState(
          documentId: 'sample.styio',
          text: 'pip',
          revision: 0,
        ),
        languageService: const SimpleStyioLanguageService(),
        initialSelection: const SelectionState.collapsed(3),
      );

      const pipelineCompletion = CompletionItem(
        label: 'pipeline',
        kind: CompletionItemKind.keyword,
        insertText: 'pipeline ',
        detail: 'Declare a pipeline.',
      );

      controller.applyCompletionItem(pipelineCompletion);

      expect(controller.document.text, 'pipeline ');
      expect(controller.selection.end, 'pipeline '.length);
      expect(controller.canUndo, isTrue);
    },
  );

  test('applies formatting edits and preserves collapsed caret position', () {
    final controller = EditorSessionController(
      initialDocument: const DocumentState(
        documentId: 'sample.styio',
        text: 'let stream = source  \nemit stream  ',
        revision: 0,
      ),
      languageService: const SimpleStyioLanguageService(),
      initialSelection: const SelectionState.collapsed(19),
    );

    final edits = controller.analysis.formattingEdits;
    controller.applyFormattingEdits(edits);

    expect(controller.document.text, 'let stream = source\nemit stream');
    expect(controller.selection.end, 19);
    expect(controller.analysis.formattingEdits, isEmpty);
  });

  test('applies diagnostic quick fix returned by the language service', () {
    final controller = EditorSessionController(
      initialDocument: const DocumentState(
        documentId: 'sample.styio',
        text: 'let stream\n',
        revision: 0,
      ),
      languageService: const SimpleStyioLanguageService(),
    );

    final diagnostic = controller.analysis.diagnostics.singleWhere(
      (item) => item.code == 'missing-assignment',
    );
    final quickFix = controller.quickFixesForDiagnostics([diagnostic]).single;

    controller.applyDiagnosticQuickFix(quickFix);

    expect(controller.document.text, 'let stream = value\n');
    expect(controller.analysis.diagnostics, isEmpty);
  });

  test('resolves active token when caret lands on token boundary', () {
    final controller = EditorSessionController(
      initialDocument: const DocumentState(
        documentId: 'sample.styio',
        text: 'pipeline renderFlow',
        revision: 0,
      ),
      languageService: const SimpleStyioLanguageService(),
      initialSelection: const SelectionState.collapsed(8),
    );

    expect(controller.tokenAtSelection?.lexeme, 'pipeline');
    expect(controller.semanticKindAtSelection, isNull);

    controller.selectCollapsed(18);
    expect(controller.tokenAtSelection?.lexeme, 'renderFlow');
    expect(controller.semanticKindAtSelection, SemanticKind.pipeline);
  });
}
