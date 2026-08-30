# REQ-INPUT-003 Visual Evidence

**Purpose:** Record bounded rendered evidence for the interactive editor input acceptance workflow.

**Last updated:** 2026-08-31

Platform family: Flutter desktop widget harness (macOS host family)
Build mode: flutter test debug
Viewports: 1200×800 and 1600×1200
Tool: Flutter `RepaintBoundary.toImage` via `test/editor_input_visual_evidence_test.dart`

Regenerate explicitly from `products/vityo_app`:

```sh
flutter test --dart-define=VITYO_WRITE_EDITOR_INPUT_EVIDENCE=true test/editor_input_visual_evidence_test.dart
```

Normal regression runs skip evidence generation so tracked images remain unchanged.

Run the real macOS Flutter-engine lane from `products/vityo_app`:

```sh
flutter test -d macos integration_test/editor_native_input_test.dart
```

This lane uses the rendered hit-test path, native semantics dispatch, Unicode
whole-value replacement, emoji grapheme deletion, selection semantics, focus
loss/reconnect, and a real render-tree screenshot. It writes the screenshot to
`build/integration_test/vityo-editor-native-input-macos.png`.

Attach the reproducible Flutter Inspector snapshot tool to a running debug VM:

```sh
dart run tool/flutter_inspector_snapshot.dart "$VITYO_VM_SERVICE_WS_URI"
```

## Captured states

| State | 1200×800 | 1600×1200 |
|---|---|---|
| Multi-selection / reverse range over tab + emoji cluster | `multi-selection-1200x800.png` | `multi-selection-1600x1200.png` |
| Active CJK composition (provisional; revision unchanged) | `composition-active-1200x800.png` | `composition-active-1600x1200.png` |
| Composition committed (one revision) | `composition-committed-1200x800.png` | `composition-committed-1600x1200.png` |
| After undo | `after-undo-1200x800.png` | `after-undo-1600x1200.png` |
| Composition canceled + input status | `composition-canceled-1200x800.png` | `composition-canceled-1600x1200.png` |

Native macOS evidence in this directory:

- `native-input-macos.png`: Flutter macOS engine render after editable
  semantics, Unicode replacement, emoji deletion, multi-selection, and input
  reconnect assertions pass.
- `live-window-macos.jpg`: actual Vityo application window captured without
  foreground interaction; Explorer, editor, collapsed tool panel, and status
  bar are visible.

## Visual Verifier repairs

- Surrogate-safe TextSpan splitting and painting sanitization in `editor_surface.dart`
- Tokenizer emits complete UTF-16 scalar pairs for non-BMP characters in `styio_syntax_highlighter.dart`
- Focus-only widget validation invokes the editor's `requestKeyboard`-style action; pointer taps remain reserved for caret placement and never stand in for keyboard acquisition or reconnection.
- Accessibility `setText` now replaces the complete semantic field value, and
  `setSelection` maps the published composition window back to the canonical
  document selection instead of mutating transport-only state.
- Regression: `test/editor_emoji_selection_render_test.dart`

## Notes

- Evidence uses generated non-private fixture text only.
- No machine identity, absolute local paths, or source secrets are recorded here.
- Widget composition coverage and the real macOS engine lane are intentionally
  separate: Flutter disables `TestTextInput` under `integration_test`, so CJK
  provisional composition is verified at the platform-channel boundary while
  native rendering, hit testing, accessibility dispatch, and reconnect are
  verified in the macOS application process.
