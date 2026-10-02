part of 'editor_surface.dart';

/// A fixed-extent, lazily built viewport for documents whose complete line
/// range must remain scrollable without materializing every line widget.
class _EditorHighVolumeViewport extends StatelessWidget {
  const _EditorHighVolumeViewport({
    required this.controller,
    required this.lineCount,
    required this.lineExtent,
    required this.cacheLineCount,
    required this.lineBuilder,
    required this.stateMarkers,
    required this.overlayChildren,
  });

  final ScrollController controller;
  final int lineCount;
  final double lineExtent;
  final int cacheLineCount;
  final IndexedWidgetBuilder lineBuilder;
  final List<Widget> stateMarkers;
  final List<Widget> overlayChildren;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Scrollbar(
          controller: controller,
          interactive: true,
          thumbVisibility: true,
          child: ListView.builder(
            key: const ValueKey('source-buffer-scroll'),
            controller: controller,
            itemCount: lineCount,
            itemExtent: lineExtent,
            scrollCacheExtent: ScrollCacheExtent.pixels(
              lineExtent * cacheLineCount,
            ),
            semanticChildCount: lineCount,
            itemBuilder: lineBuilder,
          ),
        ),
        Offstage(
          offstage: true,
          child: Column(
            key: const ValueKey('source-high-volume-render-state'),
            mainAxisSize: MainAxisSize.min,
            children: stateMarkers,
          ),
        ),
        if (overlayChildren.isNotEmpty)
          Positioned(
            top: 6,
            left: 62,
            right: 20,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: Material(
                elevation: 12,
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(10),
                child: SingleChildScrollView(
                  key: const ValueKey('source-high-volume-overlay'),
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: overlayChildren,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

extension _HighVolumeViewportBuilder on _SourcePreviewPaneState {
  Widget _buildHighVolumeViewport(
    BuildContext context, {
    required List<int> lineStarts,
    required EditorLargeFileDegradation degradationState,
    required EditorRenderViewportBinding viewportBinding,
    required int cacheLineCount,
  }) {
    final theme = Theme.of(context);
    final stateMarkers = <Widget>[
      KeyedSubtree(
        key: ValueKey('source-editor-degradation-${degradationState.label}'),
        child: const SizedBox.shrink(),
      ),
      for (
        var index = 0;
        index < widget.controller.selectionSet.selections.length;
        index += 1
      )
        SizedBox.shrink(key: ValueKey('source-selection-item-$index')),
      KeyedSubtree(
        key: ValueKey(
          viewportBinding.boundToScrollController
              ? 'source-viewport-binding-bound'
              : 'source-viewport-binding-unbound',
        ),
        child: const SizedBox.shrink(),
      ),
      const KeyedSubtree(
        key: ValueKey(
          'source-render-backend-${EditorRenderPipelinePlan.flutterVirtualListRenderer}',
        ),
        child: SizedBox.shrink(),
      ),
      KeyedSubtree(
        key: ValueKey(
          'source-high-volume-line-count-${widget.document.lineCount}',
        ),
        child: const SizedBox.shrink(),
      ),
    ];
    final overlayChildren = <Widget>[
      if (_textInputClient.isComposing) ...[
        Text(
          _textInputClient.provisionalText,
          key: const ValueKey('source-composition-range'),
          style: theme.textTheme.bodyMedium?.copyWith(
            backgroundColor: VityoWorkbenchTokens.of(context).selection,
            decoration: TextDecoration.underline,
          ),
        ),
        const SizedBox(height: 12),
      ],
      if (_inlineRenameOpen) ...[
        _buildInlineRenamePanel(context),
        const SizedBox(height: 12),
      ],
      if (_introduceVariablePanelOpen) ...[
        _buildIntroduceVariablePanel(context),
        const SizedBox(height: 12),
      ],
      if (_extractFunctionPanelOpen) ...[
        _buildExtractFunctionPanel(context),
        const SizedBox(height: 12),
      ],
      if (_changeSignaturePanelOpen) ...[
        _buildChangeSignaturePanel(context),
        const SizedBox(height: 12),
      ],
      if (_surroundLookupOpen) ...[
        _buildSurroundLookupPanel(context),
        const SizedBox(height: 12),
      ],
      if (_completionLookupOpen) ...[
        _buildCompletionLookupPanel(context),
        const SizedBox(height: 12),
      ],
      if (_symbolLookupOpen) ...[
        _buildSymbolLookupPanel(context),
        const SizedBox(height: 12),
      ],
      if (_quickFixLookupOpen) ...[
        _buildQuickFixLookupPanel(context),
        const SizedBox(height: 12),
      ],
      if (_quickDocumentationOpen) ...[
        _buildQuickDocumentationPanel(context),
        const SizedBox(height: 12),
      ],
      if (_parameterInfoOpen) ...[
        _buildParameterInfoPanel(context),
        const SizedBox(height: 12),
      ],
      if (_usagesPanelOpen) ...[
        _buildUsagesPanel(context),
        const SizedBox(height: 12),
      ],
      if (_safeDeletePanelOpen) ...[
        _buildSafeDeletePanel(context),
        const SizedBox(height: 12),
      ],
      if (_inlineVariablePanelOpen) ...[
        _buildInlineVariablePanel(context),
        const SizedBox(height: 12),
      ],
    ];
    return _EditorHighVolumeViewport(
      controller: _sourceScrollController,
      lineCount: widget.document.lineCount,
      lineExtent: _SourcePreviewPaneState._estimatedLineHeight,
      cacheLineCount: cacheLineCount,
      stateMarkers: stateMarkers,
      overlayChildren: overlayChildren,
      lineBuilder: (context, lineIndex) => _HighlightedLineRow(
        key: ValueKey('source-line-$lineIndex'),
        document: widget.document,
        selection: widget.selection,
        analysis: widget.analysis,
        activeReferences: widget.activeReferences,
        activeTokenRange: widget.activeToken?.range,
        lineIndex: lineIndex,
        lineStarts: lineStarts,
        renderPlan: widget.renderPlan,
        semanticThemeBinding: widget.semanticThemeBinding,
        lineTokens: const <TokenSpan>[],
        plainTextLine: true,
        onTapDown: (details) => _handleLineTapDown(lineIndex, details),
        onPanStart: (details) => _handleLinePanStart(lineIndex, details),
        onPanUpdate: (details) => _handleLinePanUpdate(lineIndex, details),
        onPanEnd: _handleLinePanEnd,
      ),
    );
  }
}
