import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_render/editor/editor.dart';

/// Gives the source editor keyboard focus without synthesizing a pointer
/// gesture. Pointer taps intentionally reposition the caret; input transport
/// tests invoke the independent `EditableText.requestKeyboard`-style action so
/// a preconfigured multi-selection remains intact and a closed connection can
/// reopen while the editor remains focused.
extension EditorWidgetTester on WidgetTester {
  Future<void> focusEditorSource() async {
    final focusTarget = find.byKey(const ValueKey('source-buffer-focus'));
    expect(focusTarget, findsOneWidget);

    Actions.invoke(element(focusTarget), const EditorRequestKeyboardIntent());
    await pump();
    await pump();
  }
}
