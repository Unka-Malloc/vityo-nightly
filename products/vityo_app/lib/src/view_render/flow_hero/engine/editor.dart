/// The SOURCE notation: a real buffer. A `TextEditingController` paints the
/// syntax, a 58px gutter rides the same 24px line grid, and the analyzer's
/// finding is drawn three ways — a wavy underline, a blinking gutter lamp and a
/// plain-language strip below the bed.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../flow_model.dart';
import 'machine.dart';
import '../palette.dart';
import '../tokens.dart';

const double kLineHeight = 24;
const double kEditorFontSize = 13;
const EdgeInsets kCodePadding = EdgeInsets.fromLTRB(16, 14, 16, 18);
const double kGutterWidth = 58;

class SourceEditor extends StatefulWidget {
  const SourceEditor({super.key, required this.controller});
  final WorkbenchController controller;

  @override
  State<SourceEditor> createState() => _SourceEditorState();
}

class _SourceEditorState extends State<SourceEditor> {
  late final HighlightController _text = HighlightController(widget.controller);
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode(debugLabel: 'source');
  bool _applying = false;
  int _epoch = 0;

  WorkbenchController get _host => widget.controller;

  @override
  void initState() {
    super.initState();
    _text.value = TextEditingValue(
      text: _host.activeFile.text,
      selection: const TextSelection.collapsed(offset: 0),
    );
    _epoch = _host.bufferEpoch;
    _text.addListener(_onBuffer);
    _host.addListener(_onHost);
    _reportCursor();
  }

  @override
  void dispose() {
    _host.removeListener(_onHost);
    _text.removeListener(_onBuffer);
    _text.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onHost() {
    // The editor leads while the same buffer is open; the buffer only replaces
    // what is on screen when the host actually changes file.
    if (_host.bufferEpoch == _epoch) return;
    _epoch = _host.bufferEpoch;
    _applying = true;
    _text.value = TextEditingValue(
      text: _host.activeFile.text,
      selection: const TextSelection.collapsed(offset: 0),
    );
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _applying = false;
    _reportCursor();
  }

  void _onBuffer() {
    if (_applying) return;
    _host.onBufferChanged(
      _text.text,
      line: _cursorLine,
      column: _cursorColumn,
    );
  }

  int get _cursorLine => _text.value.text
      .substring(0, _text.selection.baseOffset.clamp(0, _text.text.length))
      .split('\n')
      .length;

  int get _cursorColumn {
    final String upto =
        _text.value.text.substring(0, _text.selection.baseOffset.clamp(0, _text.text.length));
    return _text.selection.baseOffset - (upto.lastIndexOf('\n') + 1) + 1;
  }

  void _reportCursor() {
    _host.updateCursor(_text.selection.baseOffset < 0 ? 1 : _cursorLine, _cursorColumn);
  }

  void _insert(String text) {
    final TextEditingValue v = _text.value;
    final TextSelection sel = v.selection;
    final int start = sel.start < 0 ? v.text.length : sel.start;
    final int end = sel.end < 0 ? v.text.length : sel.end;
    final String next = v.text.replaceRange(start, end, text);
    _text.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  /// Enter carries the current line's indent forward, like a real editor.
  void _newline() {
    final TextEditingValue v = _text.value;
    final int s = v.selection.start < 0 ? v.text.length : v.selection.start;
    final String before = v.text.substring(0, s);
    final String lineStart =
        before.substring(before.lastIndexOf('\n') + 1);
    final RegExpMatch? m = RegExp(r'^\s*').firstMatch(lineStart);
    _insert('\n${m?.group(0) ?? ''}');
  }

  @override
  Widget build(BuildContext context) {
    final List<String> lines = _text.text.split('\n');
    final TextPainter tp = TextPainter(
      text: TextSpan(text: _text.text, style: T.code),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _Gutter(
                lines: lines.length,
                diags: _host.activeDiags,
                scroll: _scroll,
              ),
              Expanded(
                child: _editArea(tp.width + kCodePadding.horizontal + 24),
              ),
            ],
          ),
        ),
        if (_host.activeDiags.isNotEmpty) _DiagStrip(diags: _host.activeDiags),
      ],
    );
  }

  Widget _editArea(double contentWidth) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double width = contentWidth > c.maxWidth ? contentWidth : c.maxWidth;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: width > c.maxWidth
              ? const ClampingScrollPhysics()
              : const NeverScrollableScrollPhysics(),
          child: SizedBox(
            width: width,
            height: c.maxHeight,
            child: Shortcuts(
              shortcuts: const <ShortcutActivator, Intent>{
                SingleActivator(LogicalKeyboardKey.tab): _IndentIntent(),
                SingleActivator(LogicalKeyboardKey.enter): _NewlineIntent(),
                SingleActivator(LogicalKeyboardKey.keyS, meta: true): _SaveIntent(),
              },
              child: Actions(
                actions: <Type, Action<Intent>>{
                  _IndentIntent: CallbackAction<_IndentIntent>(
                    onInvoke: (_) {
                      _insert('  ');
                      return null;
                    },
                  ),
                  _NewlineIntent: CallbackAction<_NewlineIntent>(
                    onInvoke: (_) {
                      _newline();
                      return null;
                    },
                  ),
                  _SaveIntent: CallbackAction<_SaveIntent>(
                    onInvoke: (_) {
                      unawaited(_host.saveActive());
                      return null;
                    },
                  ),
                },
                child: DefaultSelectionStyle(
                  cursorColor: P.red,
                  selectionColor: C.selection,
                  child: TextField(
                    controller: _text,
                    focusNode: _focus,
                    scrollController: _scroll,
                    autofocus: true,
                    maxLines: null,
                    expands: true,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
                    cursorWidth: 1.6,
                    cursorColor: P.red,
                    style: T.code,
                    strutStyle: const StrutStyle(
                      fontFamily: kMono,
                      height: 24 / 13,
                      fontSize: kEditorFontSize,
                      forceStrutHeight: true,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: kCodePadding,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _IndentIntent extends Intent {
  const _IndentIntent();
}

class _NewlineIntent extends Intent {
  const _NewlineIntent();
}

class _SaveIntent extends Intent {
  const _SaveIntent();
}

/// The gutter rides the same integer line grid as the buffer, and the wheel
/// over it falls through to the buffer it numbers.
class _Gutter extends StatelessWidget {
  const _Gutter({required this.lines, required this.diags, required this.scroll});

  final int lines;
  final List<Diagnostic> diags;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: kGutterWidth,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: P.gutterRule)),
      ),
      child: ClipRect(
        child: AnimatedBuilder(
          animation: scroll,
          builder: (BuildContext context, Widget? _) {
            final double offset = scroll.hasClients ? scroll.offset : 0;
            return Transform.translate(
              offset: Offset(0, -offset),
              child: Padding(
                padding: const EdgeInsets.only(top: 14, bottom: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (int i = 0; i < lines; i++)
                      SizedBox(
                        height: kLineHeight,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: <Widget>[
                            if (diags.any((Diagnostic d) => d.line == i))
                              const Led(on: true, size: 5, blink: true),
                            const SizedBox(width: 8),
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: Text('${i + 1}', style: T.gutter),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A 27px strip at the bottom of the editor well — the analyzer's voice on the
/// panel, outside the text flow so the line grid never breaks.
class _DiagStrip extends StatelessWidget {
  const _DiagStrip({required this.diags});
  final List<Diagnostic> diags;

  @override
  Widget build(BuildContext context) {
    final Diagnostic d0 = diags.first;
    final String more = diags.length > 1 ? ' · +${diags.length - 1} more' : '';
    return Container(
      constraints: const BoxConstraints(minHeight: 27),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      // Opaque panel face with its own top seam — SeamTop's inner lip trick
      // needs an opaque child, and a transparent one shows the shadow sheet.
      decoration: BoxDecoration(
        color: P.panel,
        border: Border(top: BorderSide(color: P.seamLo)),
      ),
      child: Row(
        children: <Widget>[
          const SizedBox(
            width: 11,
            height: 10,
            child: CustomPaint(painter: _WarnPainter()),
          ),
          const SizedBox(width: 8),
          Text(
            '${d0.ident} 从未被消费 · analyze · step 06 · warning$more',
            style: T.diagStrip.copyWith(color: P.red),
          ),
        ],
      ),
    );
  }
}

class _WarnPainter extends CustomPainter {
  const _WarnPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 12, size.height / 11);
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = P.red;
    canvas.drawPath(
      Path()
        ..moveTo(6, 1)
        ..lineTo(11, 10)
        ..lineTo(1, 10)
        ..close(),
      stroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(6, 4.5)
        ..lineTo(6, 7.1)
        ..moveTo(6, 8.5)
        ..lineTo(6, 8.7),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.round
        ..color = P.red,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WarnPainter old) => false;
}

/// ------------------------------------------------------- the highlight layer ---
/// The buffer colours itself: a real lexer for Styio and TOML, and the
/// analyzer's finding as a 1px red wavy underline under the identifier.
class HighlightController extends TextEditingController {
  HighlightController(this.host);

  final WorkbenchController host;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final bool toml = host.activeFile.lang == 'toml';
    if (host.activeFile.lang == 'plain') {
      return TextSpan(style: style ?? T.code, text: text);
    }
    final List<Diagnostic> diags = host.activeDiags;
    final List<String> lines = text.split('\n');
    final List<TextSpan> out = <TextSpan>[];
    for (int i = 0; i < lines.length; i++) {
      final Diagnostic? d = _diagOn(diags, i);
      bool marked = false;
      for (final Token t in (toml ? lexToml(lines[i]) : lexStyio(lines[i]))) {
        TextStyle? s = T.code.copyWith(color: _colorOf(t.kind));
        if (t.kind == TokenKind.keyword) s = s.copyWith(fontWeight: FontWeight.w600);
        if (d != null && !marked && t.kind == TokenKind.plain && t.text == d.ident) {
          s = s.copyWith(
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.wavy,
            decorationColor: C.red,
            decorationThickness: 1,
          );
          marked = true;
        }
        out.add(TextSpan(text: t.text, style: s));
      }
      if (i < lines.length - 1) out.add(const TextSpan(text: '\n', style: T.code));
    }
    return TextSpan(style: style ?? T.code, children: out);
  }

  Color _colorOf(TokenKind kind) {
    if (!P.dark) {
      // Paper mode: deep cuts and warm inks that read on cream.
      switch (kind) {
        case TokenKind.keyword:
          return P.paper;
        case TokenKind.name:
          return C.orangeDeep;
        case TokenKind.literal:
          return C.yellowDeep;
        case TokenKind.operator:
          return P.silkHi;
        case TokenKind.punct:
          return P.silk;
        case TokenKind.comment:
          return P.silkDim;
        case TokenKind.plain:
          return P.bone;
      }
    }
    switch (kind) {
      case TokenKind.keyword:
        return C.paper;
      case TokenKind.name:
        return C.orange;
      case TokenKind.literal:
        return C.yellow;
      case TokenKind.operator:
        return C.silkHi;
      case TokenKind.punct:
        return C.silk;
      case TokenKind.comment:
        return C.gutterGrey;
      case TokenKind.plain:
        return C.bone;
    }
  }
}

Diagnostic? _diagOn(List<Diagnostic> diags, int line) {
  for (final Diagnostic d in diags) {
    if (d.line == line) return d;
  }
  return null;
}
