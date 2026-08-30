part of 'editor_surface.dart';

List<Widget> _buildPreviewChildren(
  BuildContext context, {
  required EditorSessionController controller,
  required ViewportProfile viewportProfile,
  required HoverPayload? hover,
  required List<CompletionItem> completions,
  required List<ReferenceSpan> activeReferences,
  required TokenSpan? activeToken,
  required SemanticKind? activeSemanticKind,
  required DocumentState document,
  required SelectionState selection,
  required StyioDocumentAnalysis analysis,
  required EditorRenderPlan renderPlan,
  required EditorSemanticThemeBinding semanticThemeBinding,
  required List<int> lineStarts,
  required List<_SemanticLineBlock> semanticBlocks,
  required EditorVirtualizedRowWindow renderWindow,
  required int maxRenderedLineCount,
  required Set<String> collapsedSemanticBlockKeys,
  required ValueChanged<_SemanticLineBlock> onToggleSemanticBlock,
  required void Function(int lineIndex, TapDownDetails details) onTapLine,
  required void Function(int lineIndex, DragStartDetails details)
  onPanStartLine,
  required void Function(int lineIndex, DragUpdateDetails details)
  onPanUpdateLine,
  required ValueChanged<DragEndDetails> onPanEnd,
  required bool showInlineLanguageFeedback,
  required bool compactInlineLanguageFeedback,
}) {
  final children = <Widget>[];
  final blockByStart = <int, _SemanticLineBlock>{
    for (final block in semanticBlocks) block.startLine: block,
  };
  final activeLineIndex = document
      .positionForOffset(selection.extentOffset)
      .line;
  final useScrollViewport =
      document.lineCount >= 10000 &&
      renderWindow.totalLineCount == document.lineCount &&
      renderWindow.renderLineCount <= maxRenderedLineCount;
  final boundedWindow = useScrollViewport
      ? renderWindow
      : document.lineCount <= maxRenderedLineCount
      ? renderWindow.totalLineCount == document.lineCount
            ? renderWindow
            : EditorVirtualizedRowWindow.fromViewport(
                totalLineCount: document.lineCount,
                firstVisibleLine: activeLineIndex,
                viewportLineCapacity: maxRenderedLineCount,
                overscanLineCount: 0,
              )
      : () {
          final renderStartLine = _previewRenderStartLine(
            totalLineCount: document.lineCount,
            maxRenderedLineCount: maxRenderedLineCount,
            activeLineIndex: activeLineIndex,
          );
          final renderEndLine =
              renderStartLine +
              (document.lineCount < maxRenderedLineCount
                  ? document.lineCount
                  : maxRenderedLineCount);
          return EditorVirtualizedRowWindow(
            totalLineCount: document.lineCount,
            startLine: renderStartLine,
            endLineExclusive: renderEndLine,
            viewportFirstLine: activeLineIndex.clamp(
              renderStartLine,
              renderEndLine == renderStartLine
                  ? renderStartLine
                  : renderEndLine - 1,
            ),
            viewportLineCapacity: maxRenderedLineCount,
            overscanLineCount: 0,
          );
        }();
  final renderStartLine = boundedWindow.startLine;
  final renderEndLine = boundedWindow.endLineExclusive;
  final renderedLineCount = renderEndLine - renderStartLine;
  final plainTextLines = document.lineCount >= 10000;
  final lineTokenIndex = plainTextLines
      ? const <int, List<TokenSpan>>{}
      : _indexTokenSpansForLineWindow(
          tokenSpans: analysis.tokenSpans,
          lineStarts: lineStarts,
          startLine: renderStartLine,
          endLineExclusive: renderEndLine,
        );
  var lineIndex = renderStartLine;

  while (lineIndex < renderEndLine) {
    final block = blockByStart[lineIndex];
    if (block != null) {
      final collapsed = collapsedSemanticBlockKeys.contains(
        _semanticBlockKey(block),
      );
      final visibleLimitEnd = renderEndLine - 1;
      final visibleBlockEnd = collapsed
          ? block.startLine
          : block.endLine < visibleLimitEnd
          ? block.endLine
          : visibleLimitEnd;
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: _SemanticBlockCard(
            block: block,
            label: block.label,
            collapsed: collapsed,
            onToggle: () => onToggleSemanticBlock(block),
            child: Column(
              children: [
                for (
                  var blockLine = block.startLine;
                  blockLine <= visibleBlockEnd;
                  blockLine += 1
                )
                  ..._buildLineWithInlineFeedback(
                    context,
                    controller: controller,
                    viewportProfile: viewportProfile,
                    hover: hover,
                    completions: completions,
                    activeReferences: activeReferences,
                    activeToken: activeToken,
                    activeSemanticKind: activeSemanticKind,
                    document: document,
                    selection: selection,
                    analysis: analysis,
                    lineIndex: blockLine,
                    activeLineIndex: activeLineIndex,
                    lineStarts: lineStarts,
                    renderPlan: renderPlan,
                    semanticThemeBinding: semanticThemeBinding,
                    lineTokens:
                        lineTokenIndex[blockLine] ?? const <TokenSpan>[],
                    plainTextLine: plainTextLines,
                    onTapLine: onTapLine,
                    onPanStartLine: onPanStartLine,
                    onPanUpdateLine: onPanUpdateLine,
                    onPanEnd: onPanEnd,
                    showInlineLanguageFeedback: showInlineLanguageFeedback,
                    compactInlineLanguageFeedback:
                        compactInlineLanguageFeedback,
                  ),
                if (collapsed)
                  _CollapsedBlockSummary(
                    key: ValueKey('source-fold-summary-${block.startLine}'),
                    hiddenLineCount: block.endLine - block.startLine,
                  ),
              ],
            ),
          ),
        ),
      );
      lineIndex = block.endLine + 1;
      continue;
    }

    children.addAll(
      _buildLineWithInlineFeedback(
        context,
        controller: controller,
        viewportProfile: viewportProfile,
        hover: hover,
        completions: completions,
        activeReferences: activeReferences,
        activeToken: activeToken,
        activeSemanticKind: activeSemanticKind,
        document: document,
        selection: selection,
        analysis: analysis,
        lineIndex: lineIndex,
        activeLineIndex: activeLineIndex,
        lineStarts: lineStarts,
        renderPlan: renderPlan,
        semanticThemeBinding: semanticThemeBinding,
        lineTokens: lineTokenIndex[lineIndex] ?? const <TokenSpan>[],
        plainTextLine: plainTextLines,
        onTapLine: onTapLine,
        onPanStartLine: onPanStartLine,
        onPanUpdateLine: onPanUpdateLine,
        onPanEnd: onPanEnd,
        showInlineLanguageFeedback: showInlineLanguageFeedback,
        compactInlineLanguageFeedback: compactInlineLanguageFeedback,
      ),
    );
    lineIndex += 1;
  }

  if (renderedLineCount < document.lineCount) {
    children.add(
      _LargeDocumentPreviewTruncationBanner(
        renderedLineCount: renderedLineCount,
        totalLineCount: document.lineCount,
        renderStartLine: renderStartLine,
        renderEndLine: renderEndLine,
        activeLineIndex: activeLineIndex,
      ),
    );
  }

  return children;
}

Map<int, List<TokenSpan>> _indexTokenSpansForLineWindow({
  required List<TokenSpan> tokenSpans,
  required List<int> lineStarts,
  required int startLine,
  required int endLineExclusive,
}) {
  final buckets = <int, List<TokenSpan>>{
    for (var line = startLine; line < endLineExclusive; line += 1)
      line: <TokenSpan>[],
  };
  if (tokenSpans.isEmpty || buckets.isEmpty) {
    return buckets;
  }

  final windowStart = lineStarts[startLine];
  final lastLine = endLineExclusive - 1;
  final windowEnd = lastLine + 1 < lineStarts.length
      ? lineStarts[lastLine + 1]
      : lineStarts[lastLine];

  for (final token in tokenSpans) {
    if (token.range.end <= windowStart) {
      continue;
    }
    if (token.range.start >= windowEnd) {
      break;
    }
    final line = _lineIndexForOffset(lineStarts, token.range.start);
    final bucket = buckets[line];
    if (bucket != null) {
      bucket.add(token);
    }
  }
  return buckets;
}

int _previewRenderStartLine({
  required int totalLineCount,
  required int maxRenderedLineCount,
  required int activeLineIndex,
}) {
  if (totalLineCount <= maxRenderedLineCount) {
    return 0;
  }
  final maxStartLine = totalLineCount - maxRenderedLineCount;
  var startLine = activeLineIndex - (maxRenderedLineCount ~/ 2);
  if (startLine < 0) {
    return 0;
  }
  if (startLine > maxStartLine) {
    return maxStartLine;
  }
  return startLine;
}

class _LargeDocumentPreviewTruncationBanner extends StatelessWidget {
  const _LargeDocumentPreviewTruncationBanner({
    required this.renderedLineCount,
    required this.totalLineCount,
    required this.renderStartLine,
    required this.renderEndLine,
    required this.activeLineIndex,
  });

  final int renderedLineCount;
  final int totalLineCount;
  final int renderStartLine;
  final int renderEndLine;
  final int activeLineIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('source-large-document-truncation-banner'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Large document preview: rendering lines ${renderStartLine + 1}-$renderEndLine of $totalLineCount.',
            style: theme.textTheme.bodySmall,
          ),
          if (activeLineIndex < renderStartLine ||
              activeLineIndex >= renderEndLine) ...[
            const SizedBox(height: 4),
            Text(
              'Current caret line ${activeLineIndex + 1} is outside the rendered preview window.',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

List<Widget> _buildLineWithInlineFeedback(
  BuildContext context, {
  required EditorSessionController controller,
  required ViewportProfile viewportProfile,
  required HoverPayload? hover,
  required List<CompletionItem> completions,
  required List<ReferenceSpan> activeReferences,
  required TokenSpan? activeToken,
  required SemanticKind? activeSemanticKind,
  required DocumentState document,
  required SelectionState selection,
  required StyioDocumentAnalysis analysis,
  required int lineIndex,
  required int activeLineIndex,
  required List<int> lineStarts,
  required EditorRenderPlan renderPlan,
  required EditorSemanticThemeBinding semanticThemeBinding,
  required List<TokenSpan> lineTokens,
  required bool plainTextLine,
  required void Function(int lineIndex, TapDownDetails details) onTapLine,
  required void Function(int lineIndex, DragStartDetails details)
  onPanStartLine,
  required void Function(int lineIndex, DragUpdateDetails details)
  onPanUpdateLine,
  required ValueChanged<DragEndDetails> onPanEnd,
  required bool showInlineLanguageFeedback,
  required bool compactInlineLanguageFeedback,
}) {
  final widgets = <Widget>[
    _HighlightedLineRow(
      key: ValueKey('source-line-$lineIndex'),
      document: document,
      selection: selection,
      analysis: analysis,
      activeReferences: activeReferences,
      activeTokenRange: activeToken?.range,
      lineIndex: lineIndex,
      lineStarts: lineStarts,
      renderPlan: renderPlan,
      semanticThemeBinding: semanticThemeBinding,
      lineTokens: lineTokens,
      plainTextLine: plainTextLine,
      onTapDown: (details) => onTapLine(lineIndex, details),
      onPanStart: (details) => onPanStartLine(lineIndex, details),
      onPanUpdate: (details) => onPanUpdateLine(lineIndex, details),
      onPanEnd: onPanEnd,
    ),
  ];

  if (lineIndex != activeLineIndex) {
    return widgets;
  }

  final lineText = document.lineAt(lineIndex);
  final lineRange = SourceRange(
    start: lineStarts[lineIndex],
    end: lineStarts[lineIndex] + lineText.length,
  );
  final lineDiagnostics = analysis.diagnostics
      .where((diagnostic) => diagnostic.range.intersects(lineRange))
      .toList(growable: false);

  if (showInlineLanguageFeedback &&
      (!compactInlineLanguageFeedback || lineDiagnostics.isNotEmpty)) {
    widgets.add(
      _InlineLanguageFeedback(
        key: ValueKey(
          'inline-language-feedback-${viewportProfile.label.toLowerCase()}',
        ),
        controller: controller,
        viewportProfile: viewportProfile,
        diagnostics: lineDiagnostics,
        hover: hover,
        completions: completions,
        formattingEdits: analysis.formattingEdits,
        activeToken: activeToken,
        activeSemanticKind: activeSemanticKind,
        compact: compactInlineLanguageFeedback,
      ),
    );
  }

  return widgets;
}

List<InlineSpan> _buildLineSpans(
  BuildContext context,
  String source,
  SourceRange lineRange,
  StyioDocumentAnalysis analysis, {
  required List<ReferenceSpan> activeReferences,
  required SourceRange? activeTokenRange,
  required SelectionState selection,
  required EditorRenderPlan renderPlan,
  required EditorSemanticThemeBinding semanticThemeBinding,
  required List<TokenSpan> lineTokens,
  required bool plainTextLine,
  int sourceOffsetBase = 0,
  SourceRange? globalLineRange,
}) {
  final spans = <InlineSpan>[];
  final resolvedGlobalLineRange = globalLineRange ?? lineRange;
  final caretOffset = selection.isCollapsed
      ? selection.end - sourceOffsetBase
      : null;
  final selectionRange = selection.isCollapsed
      ? null
      : SourceRange(
          start: selection.start - sourceOffsetBase,
          end: selection.end - sourceOffsetBase,
        );
  final lineInlayHints =
      analysis.inlayHints
          .where(
            (hint) =>
                hint.position >= resolvedGlobalLineRange.start &&
                hint.position <= resolvedGlobalLineRange.end,
          )
          .toList(growable: false)
        ..sort((left, right) => left.position.compareTo(right.position));
  var inlayHintIndex = 0;

  // Collapse caret/selection paint anchors to scalar boundaries so WidgetSpan
  // carets never force TextSpan splits inside surrogate pairs.
  final paintCaretOffset = caretOffset == null
      ? null
      : _utf16ScalarFloor(source, caretOffset);
  final paintSelectionRange = selectionRange == null
      ? null
      : SourceRange(
          start: _utf16ScalarFloor(source, selectionRange.start),
          end: _utf16ScalarCeil(source, selectionRange.end),
        );

  void appendInlayHintsThrough(int boundary) {
    while (inlayHintIndex < lineInlayHints.length &&
        lineInlayHints[inlayHintIndex].position - sourceOffsetBase <=
            boundary) {
      final hint = lineInlayHints[inlayHintIndex];
      final localPosition = (hint.position - sourceOffsetBase).clamp(
        lineRange.start,
        lineRange.end,
      );
      _appendCaretIfNeeded(
        spans,
        context,
        caretOffset: paintCaretOffset,
        boundary: localPosition,
      );
      spans.add(_inlayHintSpan(hint));
      inlayHintIndex += 1;
    }
  }

  if (plainTextLine) {
    final slice = _utf16SafeSlice(source, lineRange.start, lineRange.end);
    _appendCaretIfNeeded(
      spans,
      context,
      caretOffset: paintCaretOffset,
      boundary: lineRange.start,
    );
    _appendCaretAwareText(
      spans,
      context,
      text: slice.text,
      start: slice.start,
      style: _textStyleForToken(
        context,
        tokenKind: TokenKind.identifier,
        semanticKind: null,
        diagnosticSeverity: null,
        semanticThemeBinding: semanticThemeBinding,
      ),
      caretOffset: paintCaretOffset,
      selectionRange: paintSelectionRange,
    );
    return spans;
  }

  if (lineTokens.isEmpty) {
    _appendCaretIfNeeded(
      spans,
      context,
      caretOffset: paintCaretOffset,
      boundary: lineRange.start,
    );
    spans.add(
      TextSpan(
        text: ' ',
        style: _textStyleForToken(
          context,
          tokenKind: TokenKind.whitespace,
          semanticKind: null,
          diagnosticSeverity: null,
          semanticThemeBinding: semanticThemeBinding,
        ),
      ),
    );
    if (lineRange.end != lineRange.start) {
      _appendCaretIfNeeded(
        spans,
        context,
        caretOffset: paintCaretOffset,
        boundary: lineRange.end,
      );
    }
    return spans;
  }

  var cursor = lineRange.start;
  for (final token in lineTokens) {
    final start = (token.range.start - sourceOffsetBase).clamp(
      lineRange.start,
      lineRange.end,
    );
    final end = (token.range.end - sourceOffsetBase).clamp(
      lineRange.start,
      lineRange.end,
    );

    if (start > cursor) {
      final style = _textStyleForToken(
        context,
        tokenKind: TokenKind.whitespace,
        semanticKind: null,
        diagnosticSeverity: null,
        semanticThemeBinding: semanticThemeBinding,
      );
      _appendCaretIfNeeded(
        spans,
        context,
        caretOffset: paintCaretOffset,
        boundary: cursor,
      );
      final gap = _utf16SafeSlice(source, cursor, start);
      _appendCaretAwareText(
        spans,
        context,
        text: gap.text,
        start: gap.start,
        style: style,
        caretOffset: paintCaretOffset,
        selectionRange: paintSelectionRange,
      );
    }

    if (end > start) {
      appendInlayHintsThrough(start);
      final localTokenRange = SourceRange(start: start, end: end);
      final slice = _utf16SafeSlice(source, start, end);
      _appendCaretIfNeeded(
        spans,
        context,
        caretOffset: paintCaretOffset,
        boundary: start,
      );
      spans.addAll(
        _inlineSpansForToken(
          context,
          token: token,
          lineSlice: slice.text,
          segmentStart: slice.start,
          caretOffset: paintCaretOffset,
          selectionRange: paintSelectionRange,
          semanticKind: _semanticKindForRange(
            analysis.semanticSpans,
            token.range,
          ),
          diagnosticSeverity: _diagnosticSeverityForRange(
            analysis.diagnostics,
            token.range,
          ),
          activeReference: _referenceForRange(activeReferences, token.range),
          activeToken:
              activeTokenRange != null &&
              _sameRange(activeTokenRange, token.range),
          semanticThemeBinding: semanticThemeBinding,
          enableGlyphSubstitution:
              renderPlan.activeLayers.contains(EditorRenderLayer.decoration) &&
              renderPlan.glyphSubstitutionEnabled &&
              !_selectionTouchesRange(
                paintSelectionRange,
                paintCaretOffset,
                localTokenRange,
              ),
        ),
      );
      cursor = end;
    }
  }

  if (cursor < lineRange.end) {
    final style = _textStyleForToken(
      context,
      tokenKind: TokenKind.whitespace,
      semanticKind: null,
      diagnosticSeverity: null,
      semanticThemeBinding: semanticThemeBinding,
    );
    final trailing = _utf16SafeSlice(source, cursor, lineRange.end);
    _appendCaretIfNeeded(
      spans,
      context,
      caretOffset: paintCaretOffset,
      boundary: cursor,
    );
    _appendCaretAwareText(
      spans,
      context,
      text: trailing.text,
      start: trailing.start,
      style: style,
      caretOffset: paintCaretOffset,
      selectionRange: paintSelectionRange,
    );
  }

  _appendCaretIfNeeded(
    spans,
    context,
    caretOffset: paintCaretOffset,
    boundary: lineRange.end,
  );
  appendInlayHintsThrough(lineRange.end);

  return spans;
}

InlineSpan _inlayHintSpan(InlayHint hint) {
  return TextSpan(
    text: '${hint.label} ',
    style: const TextStyle(
      color: Color(0xFF6E5F49),
      backgroundColor: Color(0xFFECE4D8),
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
    ),
  );
}

List<InlineSpan> _inlineSpansForToken(
  BuildContext context, {
  required TokenSpan token,
  required String lineSlice,
  required int segmentStart,
  required int? caretOffset,
  required SourceRange? selectionRange,
  required SemanticKind? semanticKind,
  required DiagnosticSeverity? diagnosticSeverity,
  required ReferenceSpan? activeReference,
  required bool activeToken,
  required EditorSemanticThemeBinding semanticThemeBinding,
  required bool enableGlyphSubstitution,
}) {
  final style = _textStyleForToken(
    context,
    tokenKind: token.kind,
    semanticKind: semanticKind,
    diagnosticSeverity: diagnosticSeverity,
    semanticThemeBinding: semanticThemeBinding,
  );
  final referenceHighlightColor = _referenceHighlightColor(activeReference);

  if (enableGlyphSubstitution && token.kind == TokenKind.operator) {
    final glyph = _glyphForOperator(token.lexeme);
    if (glyph != null) {
      return [
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: activeToken
                  ? const Color(0xFFE6E0F5)
                  : referenceHighlightColor ?? Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              child: Icon(glyph, size: 16, color: style.color),
            ),
          ),
        ),
      ];
    }
  }

  final spans = <InlineSpan>[];
  _appendCaretAwareText(
    spans,
    context,
    text: lineSlice,
    start: segmentStart,
    style: selectionRange == null
        ? style.copyWith(
            backgroundColor: activeToken
                ? const Color(0xFFE6E0F5)
                : referenceHighlightColor,
          )
        : style,
    caretOffset: caretOffset,
    selectionRange: selectionRange,
  );
  return spans;
}

bool _sameRange(SourceRange left, SourceRange right) {
  return left.start == right.start && left.end == right.end;
}

ReferenceSpan? _referenceForRange(
  List<ReferenceSpan> references,
  SourceRange range,
) {
  for (final reference in references) {
    if (_sameRange(reference.range, range)) {
      return reference;
    }
  }
  return null;
}

Color? _referenceHighlightColor(ReferenceSpan? reference) {
  if (reference == null) {
    return null;
  }
  if (reference.isDeclaration) {
    return const Color(0xFFF5DA91);
  }
  return switch (reference.access) {
    ReferenceAccess.declaration => const Color(0xFFF5DA91),
    ReferenceAccess.read => const Color(0xFFDDEACB),
    ReferenceAccess.write => const Color(0xFFD8EAF6),
  };
}

bool _selectionTouchesRange(
  SourceRange? selectionRange,
  int? caretOffset,
  SourceRange range,
) {
  if (selectionRange != null && selectionRange.intersects(range)) {
    return true;
  }
  if (caretOffset == null) {
    return false;
  }
  return caretOffset > range.start && caretOffset < range.end;
}

WidgetSpan _caretSpan(BuildContext context) {
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: Container(
      width: 2,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface,
        borderRadius: BorderRadius.circular(999),
      ),
    ),
  );
}

void _appendCaretIfNeeded(
  List<InlineSpan> spans,
  BuildContext context, {
  required int? caretOffset,
  required int boundary,
}) {
  if (caretOffset == boundary) {
    spans.add(_caretSpan(context));
  }
}

bool _isUtf16ScalarBoundary(String value, int offset) {
  if (offset <= 0 || offset >= value.length) {
    return true;
  }
  final before = value.codeUnitAt(offset - 1);
  final after = value.codeUnitAt(offset);
  return !(before >= 0xD800 &&
      before <= 0xDBFF &&
      after >= 0xDC00 &&
      after <= 0xDFFF);
}

/// Snaps [offset] left so TextSpan slices never begin/end inside a surrogate pair.
int _utf16ScalarFloor(String value, int offset) {
  if (offset <= 0) {
    return 0;
  }
  if (offset >= value.length) {
    return value.length;
  }
  return _isUtf16ScalarBoundary(value, offset) ? offset : offset - 1;
}

/// Snaps [offset] right so TextSpan slices never begin/end inside a surrogate pair.
int _utf16ScalarCeil(String value, int offset) {
  if (offset <= 0) {
    return 0;
  }
  if (offset >= value.length) {
    return value.length;
  }
  return _isUtf16ScalarBoundary(value, offset) ? offset : offset + 1;
}

({int start, int end, String text}) _utf16SafeSlice(
  String value,
  int start,
  int end,
) {
  final safeStart = _utf16ScalarCeil(value, start);
  final safeEnd = _utf16ScalarFloor(value, end);
  if (safeEnd <= safeStart) {
    return (start: safeStart, end: safeStart, text: '');
  }
  return (
    start: safeStart,
    end: safeEnd,
    text: _sanitizeUtf16ForPainting(value.substring(safeStart, safeEnd)),
  );
}

/// Replaces unpaired UTF-16 surrogates so ParagraphBuilder never rejects spans.
String _sanitizeUtf16ForPainting(String value) {
  final units = value.codeUnits;
  if (units.isEmpty) {
    return value;
  }
  final out = <int>[];
  for (var index = 0; index < units.length; index += 1) {
    final unit = units[index];
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (index + 1 < units.length) {
        final next = units[index + 1];
        if (next >= 0xDC00 && next <= 0xDFFF) {
          out.add(unit);
          out.add(next);
          index += 1;
          continue;
        }
      }
      out.add(0xFFFD);
      continue;
    }
    if (unit >= 0xDC00 && unit <= 0xDFFF) {
      out.add(0xFFFD);
      continue;
    }
    out.add(unit);
  }
  return String.fromCharCodes(out);
}

void _appendCaretAwareText(
  List<InlineSpan> spans,
  BuildContext context, {
  required String text,
  required int start,
  required TextStyle style,
  required int? caretOffset,
  required SourceRange? selectionRange,
}) {
  if (text.isEmpty) {
    return;
  }

  final boundaries = <int>{0, text.length};
  if (caretOffset != null &&
      caretOffset > start &&
      caretOffset < start + text.length) {
    boundaries.add(_utf16ScalarFloor(text, caretOffset - start));
  }
  if (selectionRange != null) {
    final selectionStart = selectionRange.start - start;
    final selectionEnd = selectionRange.end - start;
    if (selectionStart > 0 && selectionStart < text.length) {
      boundaries.add(_utf16ScalarFloor(text, selectionStart));
    }
    if (selectionEnd > 0 && selectionEnd < text.length) {
      boundaries.add(_utf16ScalarCeil(text, selectionEnd));
    }
  }

  final ordered = boundaries.toList()..sort();
  for (var index = 0; index < ordered.length - 1; index += 1) {
    final segmentStart = ordered[index];
    final segmentEnd = ordered[index + 1];
    if (segmentEnd <= segmentStart) {
      continue;
    }

    final absoluteStart = start + segmentStart;
    final absoluteEnd = start + segmentEnd;
    final selected =
        selectionRange != null &&
        absoluteStart < selectionRange.end &&
        selectionRange.start < absoluteEnd;

    final slice = _utf16SafeSlice(text, segmentStart, segmentEnd).text;
    if (slice.isEmpty) {
      continue;
    }
    spans.add(
      TextSpan(
        text: slice,
        style: selected
            ? style.copyWith(backgroundColor: const Color(0xFFCFD8F8))
            : style,
      ),
    );

    if (caretOffset != null &&
        caretOffset == absoluteEnd &&
        caretOffset < start + text.length) {
      spans.add(_caretSpan(context));
    }
  }
}

IconData? _glyphForOperator(String lexeme) {
  switch (lexeme) {
    case '->':
      return Icons.arrow_right_alt_rounded;
    case '|>':
      return Icons.play_arrow_rounded;
    default:
      return null;
  }
}

SemanticKind? _semanticKindForRange(
  List<SemanticSpan> spans,
  SourceRange range,
) {
  for (final span in spans) {
    if (span.range.intersects(range)) {
      return span.kind;
    }
  }
  return null;
}

DiagnosticSeverity? _diagnosticSeverityForRange(
  List<Diagnostic> diagnostics,
  SourceRange range,
) {
  for (final diagnostic in diagnostics) {
    if (diagnostic.range.intersects(range)) {
      return diagnostic.severity;
    }
  }
  return null;
}

Color _diagnosticStripeColor(
  BuildContext context,
  List<Diagnostic> diagnostics,
) {
  if (diagnostics.any((item) => item.severity == DiagnosticSeverity.error)) {
    return _severityColor(DiagnosticSeverity.error);
  }
  if (diagnostics.any((item) => item.severity == DiagnosticSeverity.warning)) {
    return _severityColor(DiagnosticSeverity.warning);
  }
  if (diagnostics.any((item) => item.severity == DiagnosticSeverity.hint)) {
    return _severityColor(DiagnosticSeverity.hint);
  }
  return Colors.transparent;
}

Color _severityColor(DiagnosticSeverity severity) {
  switch (severity) {
    case DiagnosticSeverity.error:
      return const Color(0xFFCB4D45);
    case DiagnosticSeverity.warning:
      return const Color(0xFFD5962A);
    case DiagnosticSeverity.hint:
      return const Color(0xFF6980B5);
  }
}

TextStyle _textStyleForToken(
  BuildContext context, {
  required TokenKind tokenKind,
  required SemanticKind? semanticKind,
  required DiagnosticSeverity? diagnosticSeverity,
  required EditorSemanticThemeBinding semanticThemeBinding,
}) {
  return EditorFlutterTextStyleBinding(
    semanticThemeBinding: semanticThemeBinding,
  ).styleForToken(
    baseStyle: Theme.of(context).textTheme.bodyMedium!.copyWith(
      fontFamily: 'monospace',
      fontSize: 13.5,
      height: 1.5,
    ),
    tokenKind: tokenKind,
    semanticKind: semanticKind,
    diagnosticSeverity: diagnosticSeverity,
  );
}

List<_SemanticLineBlock> _resolveLineBlocks({
  required DocumentState document,
  required List<int> lineStarts,
  required List<SemanticBlockRange> blocks,
}) {
  if (blocks.isEmpty) {
    return const <_SemanticLineBlock>[];
  }

  final resolved = <_SemanticLineBlock>[];
  for (final block in blocks) {
    final startLine = _lineIndexForOffset(lineStarts, block.range.start);
    final endLine = _lineIndexForOffset(
      lineStarts,
      (block.range.end - 1).clamp(0, document.length),
    );
    if (startLine <= endLine) {
      resolved.add(
        _SemanticLineBlock(
          startLine: startLine,
          endLine: endLine,
          label: block.label,
        ),
      );
    }
  }

  resolved.sort((left, right) => left.startLine.compareTo(right.startLine));
  return resolved;
}

int _lineIndexForOffset(List<int> lineStarts, int offset) {
  for (var index = lineStarts.length - 1; index >= 0; index -= 1) {
    if (offset >= lineStarts[index]) {
      return index;
    }
  }
  return 0;
}

class _SemanticBlockCard extends StatelessWidget {
  const _SemanticBlockCard({
    required this.block,
    required this.label,
    required this.collapsed,
    required this.onToggle,
    required this.child,
  });

  final _SemanticLineBlock block;
  final String label;
  final bool collapsed;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: theme.dividerColor.withValues(alpha: 0.72)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 24,
            child: Row(
              children: [
                Tooltip(
                  message: collapsed ? 'Expand block' : 'Collapse block',
                  child: IconButton(
                    key: ValueKey('source-fold-toggle-${block.startLine}'),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 24,
                    ),
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      collapsed
                          ? Icons.keyboard_arrow_right_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 17,
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.54,
                      ),
                    ),
                    onPressed: onToggle,
                  ),
                ),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.48,
                      ),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _CollapsedBlockSummary extends StatelessWidget {
  const _CollapsedBlockSummary({super.key, required this.hiddenLineCount});

  final int hiddenLineCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(left: 62, top: 2, bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F2E9),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0xFFD8D0C2)),
        ),
        child: Text(
          '$hiddenLineCount folded ${hiddenLineCount == 1 ? 'line' : 'lines'}',
          style: theme.textTheme.bodySmall,
        ),
      ),
    );
  }
}

String _semanticBlockKey(_SemanticLineBlock block) {
  return '${block.startLine}:${block.endLine}:${block.label}';
}

class _SemanticLineBlock {
  const _SemanticLineBlock({
    required this.startLine,
    required this.endLine,
    required this.label,
  });

  final int startLine;
  final int endLine;
  final String label;
}

class _SourceBufferTextSelectionSemantics
    extends SingleChildRenderObjectWidget {
  const _SourceBufferTextSelectionSemantics({
    required this.textSelection,
    required super.child,
  });

  final TextSelection textSelection;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderSourceBufferTextSelectionSemantics(textSelection);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSourceBufferTextSelectionSemantics renderObject,
  ) {
    renderObject.textSelection = textSelection;
  }
}

class _RenderSourceBufferTextSelectionSemantics extends RenderProxyBox {
  _RenderSourceBufferTextSelectionSemantics(this._textSelection);

  TextSelection _textSelection;

  set textSelection(TextSelection value) {
    if (_textSelection == value) return;
    _textSelection = value;
    markNeedsSemanticsUpdate();
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    if (_textSelection.isValid) {
      config.textSelection = _textSelection;
    }
  }
}
