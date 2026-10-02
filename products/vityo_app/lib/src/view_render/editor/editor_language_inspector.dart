part of 'editor_surface.dart';

class _HighlightedLineRow extends StatelessWidget {
  const _HighlightedLineRow({
    super.key,
    required this.document,
    required this.selection,
    required this.analysis,
    required this.activeReferences,
    required this.activeTokenRange,
    required this.lineIndex,
    required this.lineStarts,
    required this.renderPlan,
    required this.semanticThemeBinding,
    required this.lineTokens,
    required this.plainTextLine,
    required this.onTapDown,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
  });

  final DocumentState document;
  final SelectionState selection;
  final StyioDocumentAnalysis analysis;
  final List<ReferenceSpan> activeReferences;
  final SourceRange? activeTokenRange;
  final int lineIndex;
  final List<int> lineStarts;
  final EditorRenderPlan renderPlan;
  final EditorSemanticThemeBinding semanticThemeBinding;
  final List<TokenSpan> lineTokens;
  final bool plainTextLine;
  final ValueChanged<TapDownDetails> onTapDown;
  final ValueChanged<DragStartDetails> onPanStart;
  final ValueChanged<DragUpdateDetails> onPanUpdate;
  final ValueChanged<DragEndDetails> onPanEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lineText = document.lineAt(lineIndex);
    final lineStart = lineStarts[lineIndex];
    final lineEnd = lineStart + lineText.length;
    final lineRange = SourceRange(start: lineStart, end: lineEnd);
    final caretOnLine =
        selection.isCollapsed &&
        selection.end >= lineStart &&
        selection.end <= lineEnd;
    final lineDiagnostics = analysis.diagnostics
        .where((diagnostic) => diagnostic.range.intersects(lineRange))
        .toList(growable: false);

    return Padding(
      padding: EdgeInsets.zero,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: onTapDown,
        onPanStart: onPanStart,
        onPanUpdate: onPanUpdate,
        onPanEnd: onPanEnd,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: caretOnLine
                ? theme.colorScheme.onSurface.withValues(alpha: 0.04)
                : Colors.transparent,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 40,
                  child: Text(
                    '${lineIndex + 1}',
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: VityoTheme.monoFontFamily,
                    ),
                  ),
                ),
                Container(
                  width: 2,
                  height: 20,
                  margin: const EdgeInsets.only(left: 10, right: 10),
                  decoration: BoxDecoration(
                    color: _diagnosticStripeColor(context, lineDiagnostics),
                  ),
                ),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: _buildLineSpans(
                        context,
                        lineText,
                        SourceRange(start: 0, end: lineText.length),
                        analysis,
                        activeReferences: activeReferences,
                        activeTokenRange: activeTokenRange,
                        selection: selection,
                        renderPlan: renderPlan,
                        semanticThemeBinding: semanticThemeBinding,
                        lineTokens: lineTokens,
                        plainTextLine: plainTextLine,
                        sourceOffsetBase: lineStart,
                        globalLineRange: lineRange,
                      ),
                    ),
                    softWrap: false,
                    overflow: TextOverflow.visible,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InlineLanguageFeedback extends StatelessWidget {
  const _InlineLanguageFeedback({
    super.key,
    required this.controller,
    required this.viewportProfile,
    required this.diagnostics,
    required this.hover,
    required this.completions,
    required this.formattingEdits,
    required this.activeToken,
    required this.activeSemanticKind,
    this.compact = false,
  });

  final EditorSessionController controller;
  final ViewportProfile viewportProfile;
  final List<Diagnostic> diagnostics;
  final HoverPayload? hover;
  final List<CompletionItem> completions;
  final List<FormattingEdit> formattingEdits;
  final TokenSpan? activeToken;
  final SemanticKind? activeSemanticKind;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compactCompletions = completions.take(3).toList(growable: false);
    final quickFixes = controller.quickFixesForDiagnostics(diagnostics);
    const fallbackMessage =
        'Caret context ready. Move across tokens to inspect hover and completion results.';

    if (compact) {
      final diagnostic = diagnostics.first;
      final severityColor = _severityColor(context, diagnostic.severity);
      return Padding(
        padding: const EdgeInsets.only(left: 60, right: 10, bottom: 4),
        child: Container(
          constraints: const BoxConstraints(minHeight: 28),
          decoration: BoxDecoration(
            color: severityColor.withValues(alpha: 0.06),
            border: Border(left: BorderSide(color: severityColor, width: 2)),
          ),
          padding: const EdgeInsets.only(left: 8, right: 2),
          child: Row(
            children: [
              Icon(Icons.error_outline_rounded, size: 14, color: severityColor),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  diagnostic.message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
                  ),
                ),
              ),
              if (quickFixes.isNotEmpty)
                Tooltip(
                  message: quickFixes.first.label,
                  child: IconButton(
                    key: const ValueKey('inline-diagnostic-fix-0'),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.lightbulb_outline_rounded, size: 16),
                    onPressed: () =>
                        controller.applyDiagnosticQuickFix(quickFixes.first),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 68, right: 8, bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          color: VityoWorkbenchTokens.of(context).region,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        padding: const EdgeInsets.all(12),
        child: viewportProfile.isMobile
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _InlineFeedbackHeader(
                    diagnostics: diagnostics,
                    hover: hover,
                    completions: compactCompletions,
                    formattingEdits: formattingEdits,
                    quickFixes: quickFixes,
                    activeToken: activeToken,
                  ),
                  if (activeToken != null) ...[
                    Text(
                      'Token `${_sanitizeUtf16ForPainting(activeToken!.lexeme)}` · ${activeToken!.kind.name}'
                      '${activeSemanticKind != null ? ' · ${activeSemanticKind!.name}' : ''}'
                      ' · ${activeToken!.range.start}-${activeToken!.range.end}',
                      key: const ValueKey('active-token-context'),
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (diagnostics.isNotEmpty) ...[
                    Text(
                      diagnostics.first.message,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  if (hover != null) ...[
                    if (diagnostics.isNotEmpty) const SizedBox(height: 10),
                    Text(hover!.markdown, style: theme.textTheme.bodySmall),
                  ],
                  if (compactCompletions.isNotEmpty ||
                      formattingEdits.isNotEmpty ||
                      quickFixes.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (
                          var index = 0;
                          index < quickFixes.length;
                          index += 1
                        )
                          _InlineActionChip(
                            key: ValueKey('inline-diagnostic-fix-$index'),
                            icon: Icons.build_circle_rounded,
                            label: quickFixes[index].label,
                            onTap: () => controller.applyDiagnosticQuickFix(
                              quickFixes[index],
                            ),
                          ),
                        for (
                          var index = 0;
                          index < compactCompletions.length;
                          index += 1
                        )
                          _InlineActionChip(
                            key: ValueKey(
                              'inline-completion-action-$index-${compactCompletions[index].label}',
                            ),
                            icon: Icons.auto_awesome_rounded,
                            label: compactCompletions[index].label,
                            onTap: () => controller.applyCompletionItem(
                              compactCompletions[index],
                            ),
                          ),
                        if (formattingEdits.isNotEmpty)
                          _InlineActionChip(
                            key: const ValueKey('inline-format-action'),
                            icon: Icons.auto_fix_high_rounded,
                            label: 'Apply format',
                            onTap: () => controller.applyFormattingEdits(
                              formattingEdits,
                            ),
                          ),
                      ],
                    ),
                  ] else if (diagnostics.isEmpty && hover == null) ...[
                    const SizedBox(height: 10),
                    Text(fallbackMessage, style: theme.textTheme.bodySmall),
                  ],
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: _InlineFeedbackHeader(
                      diagnostics: diagnostics,
                      hover: hover,
                      completions: compactCompletions,
                      formattingEdits: formattingEdits,
                      quickFixes: quickFixes,
                      activeToken: activeToken,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (activeToken != null)
                          Text(
                            'Token `${_sanitizeUtf16ForPainting(activeToken!.lexeme)}` · ${activeToken!.kind.name}'
                            '${activeSemanticKind != null ? ' · ${activeSemanticKind!.name}' : ''}'
                            ' · ${activeToken!.range.start}-${activeToken!.range.end}',
                            key: const ValueKey('active-token-context'),
                            style: theme.textTheme.bodySmall,
                          ),
                        if (activeToken != null &&
                            (diagnostics.isNotEmpty ||
                                hover != null ||
                                compactCompletions.isNotEmpty ||
                                formattingEdits.isNotEmpty ||
                                quickFixes.isNotEmpty))
                          const SizedBox(height: 10),
                        if (diagnostics.isNotEmpty)
                          Text(
                            diagnostics.first.message,
                            style: theme.textTheme.bodySmall,
                          )
                        else if (hover != null)
                          Text(
                            hover!.markdown,
                            style: theme.textTheme.bodySmall,
                          )
                        else if (compactCompletions.isEmpty &&
                            formattingEdits.isEmpty &&
                            quickFixes.isEmpty)
                          Text(
                            fallbackMessage,
                            style: theme.textTheme.bodySmall,
                          ),
                        if (compactCompletions.isNotEmpty ||
                            formattingEdits.isNotEmpty ||
                            quickFixes.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (
                                var index = 0;
                                index < quickFixes.length;
                                index += 1
                              )
                                _InlineActionChip(
                                  key: ValueKey('inline-diagnostic-fix-$index'),
                                  icon: Icons.build_circle_rounded,
                                  label: quickFixes[index].label,
                                  onTap: () =>
                                      controller.applyDiagnosticQuickFix(
                                        quickFixes[index],
                                      ),
                                ),
                              for (
                                var index = 0;
                                index < compactCompletions.length;
                                index += 1
                              )
                                _InlineActionChip(
                                  key: ValueKey(
                                    'inline-completion-action-$index-${compactCompletions[index].label}',
                                  ),
                                  icon: Icons.auto_awesome_rounded,
                                  label:
                                      '${compactCompletions[index].label} · ${compactCompletions[index].kind.name}',
                                  onTap: () => controller.applyCompletionItem(
                                    compactCompletions[index],
                                  ),
                                ),
                              if (formattingEdits.isNotEmpty)
                                _InlineActionChip(
                                  key: const ValueKey('inline-format-action'),
                                  icon: Icons.auto_fix_high_rounded,
                                  label: 'Apply format',
                                  onTap: () => controller.applyFormattingEdits(
                                    formattingEdits,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _InlineFeedbackHeader extends StatelessWidget {
  const _InlineFeedbackHeader({
    required this.diagnostics,
    required this.hover,
    required this.completions,
    required this.formattingEdits,
    required this.quickFixes,
    required this.activeToken,
  });

  final List<Diagnostic> diagnostics;
  final HoverPayload? hover;
  final List<CompletionItem> completions;
  final List<FormattingEdit> formattingEdits;
  final List<DiagnosticQuickFix> quickFixes;
  final TokenSpan? activeToken;

  @override
  Widget build(BuildContext context) {
    final tokens = VityoWorkbenchTokens.of(context);
    final pills = <Widget>[];

    if (diagnostics.isNotEmpty) {
      pills.add(
        _InlineFeedbackBadge(
          label: diagnostics.first.severity.name,
          color: _severityColor(context, diagnostics.first.severity),
        ),
      );
    }

    if (hover != null) {
      pills.add(_InlineFeedbackBadge(label: 'hover', color: tokens.accent));
    }

    if (completions.isNotEmpty) {
      pills.add(
        _InlineFeedbackBadge(
          label: '${completions.length} suggestions',
          color: tokens.success,
        ),
      );
    }

    if (formattingEdits.isNotEmpty) {
      pills.add(
        _InlineFeedbackBadge(
          label: '${formattingEdits.length} format edit',
          color: tokens.warning,
        ),
      );
    }

    if (quickFixes.isNotEmpty) {
      pills.add(
        _InlineFeedbackBadge(
          label: '${quickFixes.length} quick fix',
          color: tokens.error,
        ),
      );
    }

    if (activeToken != null) {
      pills.add(
        _InlineFeedbackBadge(
          label: 'token ${activeToken!.kind.name}',
          color: tokens.muted,
        ),
      );
    }

    if (pills.isEmpty) {
      pills.add(
        _InlineFeedbackBadge(label: 'active line', color: tokens.muted),
      );
    }

    return Wrap(spacing: 8, runSpacing: 8, children: pills);
  }
}

class _InlineActionChip extends StatelessWidget {
  const _InlineActionChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Ink(
        decoration: BoxDecoration(
          color: VityoWorkbenchTokens.of(context).elevated,
          borderRadius: BorderRadius.circular(999),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: theme.colorScheme.onSurface),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineFeedbackBadge extends StatelessWidget {
  const _InlineFeedbackBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall!.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

enum _LanguageInspectorSection {
  diagnostics,
  blocks,
  inlays,
  symbols,
  resolve,
  token,
  hover,
  completions,
  formatting,
}

extension on _LanguageInspectorSection {
  String get label {
    switch (this) {
      case _LanguageInspectorSection.diagnostics:
        return 'Diagnostics';
      case _LanguageInspectorSection.blocks:
        return 'Blocks';
      case _LanguageInspectorSection.inlays:
        return 'Inlays';
      case _LanguageInspectorSection.symbols:
        return 'Symbols';
      case _LanguageInspectorSection.resolve:
        return 'Resolve';
      case _LanguageInspectorSection.token:
        return 'Token';
      case _LanguageInspectorSection.hover:
        return 'Hover';
      case _LanguageInspectorSection.completions:
        return 'Complete';
      case _LanguageInspectorSection.formatting:
        return 'Format';
    }
  }
}

class _LanguageServicePane extends StatefulWidget {
  const _LanguageServicePane({
    required this.controller,
    required this.viewportProfile,
    required this.analysis,
    required this.hover,
    required this.completions,
    required this.activeToken,
    required this.activeSemanticKind,
    required this.languageServiceStatus,
    required this.onRefreshLanguageService,
  });

  final EditorSessionController controller;
  final ViewportProfile viewportProfile;
  final StyioDocumentAnalysis analysis;
  final HoverPayload? hover;
  final List<CompletionItem> completions;
  final TokenSpan? activeToken;
  final SemanticKind? activeSemanticKind;
  final LanguageServiceStatusSurface? languageServiceStatus;
  final VoidCallback? onRefreshLanguageService;

  @override
  State<_LanguageServicePane> createState() => _LanguageServicePaneState();
}

class _LanguageServicePaneState extends State<_LanguageServicePane> {
  _LanguageInspectorSection _selectedSection =
      _LanguageInspectorSection.diagnostics;
  final TextEditingController _renameController = TextEditingController();
  String? _renameSeedKey;

  @override
  void dispose() {
    _renameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final analysis = widget.analysis;
    final showServiceStatusCard = widget.languageServiceStatus != null;
    final lineCount = widget.controller.document.lineCount;
    final deferLanguageLists = lineCount >= 10000;

    if (deferLanguageLists) {
      return KeyedSubtree(
        key: const ValueKey('language-pane-deferred-large-file'),
        child: ListView(
          children: [
            if (showServiceStatusCard) ...[
              _InspectorCard(
                key: const ValueKey('language-service-status-card'),
                title: 'StyioService Status',
                child: _buildServiceStatusContent(context),
              ),
              const SizedBox(height: 12),
            ],
            _InspectorCard(
              title: 'Language Layers',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _CapabilityPill(label: 'token ${analysis.tokenCount}'),
                      _CapabilityPill(
                        label: 'semantic ${analysis.semanticCount}',
                      ),
                      _CapabilityPill(label: 'symbols ${analysis.symbolCount}'),
                      _CapabilityPill(
                        label: 'diag ${analysis.diagnosticCount}',
                      ),
                      _CapabilityPill(
                        label: 'inlays ${analysis.inlayHintCount}',
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Language inspector lists are deferred for $lineCount-line '
                    'documents while input, scrolling, and selection stay live.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (widget.viewportProfile.isMobile) {
      return KeyedSubtree(
        key: const ValueKey('language-pane-mobile'),
        child: ListView(
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _CapabilityPill(label: 'token ${analysis.tokenCount}'),
                _CapabilityPill(label: 'diag ${analysis.diagnosticCount}'),
                _CapabilityPill(
                  label: 'blocks ${analysis.semanticBlocks.length}',
                ),
                _CapabilityPill(label: 'symbols ${analysis.symbolCount}'),
                if (widget.languageServiceStatus != null)
                  _CapabilityPill(
                    label:
                        'service ${widget.languageServiceStatus!.severity.name}',
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (
                    var index = 0;
                    index < _LanguageInspectorSection.values.length;
                    index += 1
                  ) ...[
                    if (index > 0) const SizedBox(width: 8),
                    _InspectorTabChip(
                      label: _LanguageInspectorSection.values[index].label,
                      active:
                          _selectedSection ==
                          _LanguageInspectorSection.values[index],
                      onTap: () {
                        setState(() {
                          _selectedSection =
                              _LanguageInspectorSection.values[index];
                        });
                      },
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            _InspectorCard(
              key: ValueKey('language-mobile-section-${_selectedSection.name}'),
              title: _selectedSection.label,
              child: _buildSectionContent(context, section: _selectedSection),
            ),
          ],
        ),
      );
    }

    return KeyedSubtree(
      key: const ValueKey('language-pane-desktop'),
      child: ListView(
        children: [
          if (showServiceStatusCard) ...[
            _InspectorCard(
              key: const ValueKey('language-service-status-card'),
              title: 'StyioService Status',
              child: _buildServiceStatusContent(context),
            ),
            const SizedBox(height: 12),
          ],
          _InspectorCard(
            title: 'Language Layers',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _CapabilityPill(label: 'token ${analysis.tokenCount}'),
                _CapabilityPill(label: 'semantic ${analysis.semanticCount}'),
                _CapabilityPill(label: 'symbols ${analysis.symbolCount}'),
                _CapabilityPill(label: 'refs ${analysis.referenceCount}'),
                _CapabilityPill(label: 'diag ${analysis.diagnosticCount}'),
                _CapabilityPill(
                  label: 'format ${analysis.formattingEdits.length}',
                ),
                _CapabilityPill(
                  label: 'blocks ${analysis.semanticBlocks.length}',
                ),
                _CapabilityPill(label: 'inlays ${analysis.inlayHintCount}'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _InspectorCard(
            key: const ValueKey('language-desktop-section-diagnostics'),
            title: 'Diagnostics',
            child: _buildDiagnosticsContent(context),
          ),
          const SizedBox(height: 12),
          _InspectorCard(
            key: const ValueKey('language-desktop-section-blocks'),
            title: 'Semantic Blocks',
            child: _buildSemanticBlocksContent(context),
          ),
          const SizedBox(height: 12),
          _InspectorCard(
            key: const ValueKey('language-desktop-section-inlays'),
            title: 'Inlay Hints',
            child: _buildInlayHintsContent(context),
          ),
          const SizedBox(height: 12),
          _InspectorCard(
            key: const ValueKey('language-desktop-section-symbols'),
            title: 'Document Symbols',
            child: _buildDocumentSymbolsContent(context),
          ),
          const SizedBox(height: 12),
          _InspectorCard(
            key: const ValueKey('language-desktop-section-resolve'),
            title: 'Resolve @ Caret',
            child: _buildResolveContent(context),
          ),
          const SizedBox(height: 12),
          _InspectorCard(
            key: const ValueKey('language-desktop-section-token'),
            title: 'Token @ Caret',
            child: _buildTokenContent(context),
          ),
          const SizedBox(height: 12),
          _InspectorCard(
            key: const ValueKey('language-desktop-section-hover'),
            title: 'Hover @ Caret',
            child: _buildHoverContent(context),
          ),
          const SizedBox(height: 12),
          _InspectorCard(
            key: const ValueKey('language-desktop-section-completions'),
            title: 'Completion Preview',
            child: _buildCompletionContent(context),
          ),
          const SizedBox(height: 12),
          _InspectorCard(
            key: const ValueKey('language-desktop-section-formatting'),
            title: 'Formatting Contract',
            child: _buildFormattingContent(context),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionContent(
    BuildContext context, {
    required _LanguageInspectorSection section,
  }) {
    switch (section) {
      case _LanguageInspectorSection.diagnostics:
        return _buildDiagnosticsContent(context);
      case _LanguageInspectorSection.blocks:
        return _buildSemanticBlocksContent(context);
      case _LanguageInspectorSection.inlays:
        return _buildInlayHintsContent(context);
      case _LanguageInspectorSection.symbols:
        return _buildDocumentSymbolsContent(context);
      case _LanguageInspectorSection.resolve:
        return _buildResolveContent(context);
      case _LanguageInspectorSection.token:
        return _buildTokenContent(context);
      case _LanguageInspectorSection.hover:
        return _buildHoverContent(context);
      case _LanguageInspectorSection.completions:
        return _buildCompletionContent(context);
      case _LanguageInspectorSection.formatting:
        return _buildFormattingContent(context);
    }
  }

  Widget _buildServiceStatusContent(BuildContext context) {
    final theme = Theme.of(context);
    final status = widget.languageServiceStatus!;
    final primaryStates = status.primaryCapabilityStates.entries
        .take(4)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(status.title, style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        Text(status.message, style: theme.textTheme.bodySmall),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _CapabilityPill(label: 'runtime ${status.runtimeState}'),
            _CapabilityPill(label: 'severity ${status.severity.name}'),
            _CapabilityPill(label: 'health ${status.capabilityHealth}'),
            _CapabilityPill(label: 'usable ${status.usableCapabilityCount}'),
            _CapabilityPill(label: 'fresh ${status.freshCapabilityCount}'),
            _CapabilityPill(label: 'missing ${status.missingCapabilityCount}'),
            _CapabilityPill(label: 'blocked ${status.blockedCapabilityCount}'),
            if (status.cacheLookupCount > 0) ...[
              _CapabilityPill(
                label: 'cache lookups ${status.cacheLookupCount}',
              ),
              _CapabilityPill(label: 'cache hits ${status.cacheLookupHits}'),
              _CapabilityPill(
                label: 'cache misses ${status.cacheLookupMisses}',
              ),
            ],
            for (final entry in primaryStates)
              _CapabilityPill(label: '${entry.key} ${entry.value}'),
          ],
        ),
        if (status.refreshRecommended) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const ValueKey('language-service-refresh-action'),
            onPressed: widget.onRefreshLanguageService,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Refresh language service'),
          ),
        ],
      ],
    );
  }

  Widget _buildDiagnosticsContent(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.analysis.diagnostics.isEmpty) {
      return Text(
        'No diagnostics from the linter layer.',
        style: theme.textTheme.bodySmall,
      );
    }

    return Column(
      key: const ValueKey('language-problems-list'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (
          var index = 0;
          index < widget.analysis.diagnostics.length;
          index += 1
        ) ...[
          Builder(
            builder: (context) {
              final diagnostic = widget.analysis.diagnostics[index];
              final quickFixes = widget.controller.quickFixesForDiagnostics([
                diagnostic,
              ]);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: _isRangeSelected(diagnostic.range)
                      ? VityoWorkbenchTokens.of(context).selection
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    key: ValueKey('language-diagnostic-$index'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => widget.controller.selectDiagnostic(diagnostic),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                _diagnosticIcon(diagnostic.severity),
                                size: 16,
                                color: _diagnosticColor(diagnostic.severity),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '[${diagnostic.severity.name}] '
                                  '${diagnostic.message} · '
                                  '${_formatRange(diagnostic.range)}',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                          if (quickFixes.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (
                                  var fixIndex = 0;
                                  fixIndex < quickFixes.length;
                                  fixIndex += 1
                                )
                                  _InlineActionChip(
                                    key: ValueKey(
                                      'language-diagnostic-fix-$index-$fixIndex',
                                    ),
                                    icon: Icons.build_circle_rounded,
                                    label: quickFixes[fixIndex].label,
                                    onTap: () => widget.controller
                                        .applyDiagnosticQuickFix(
                                          quickFixes[fixIndex],
                                        ),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ],
    );
  }

  IconData _diagnosticIcon(DiagnosticSeverity severity) {
    switch (severity) {
      case DiagnosticSeverity.error:
        return Icons.error_rounded;
      case DiagnosticSeverity.warning:
        return Icons.warning_rounded;
      case DiagnosticSeverity.hint:
        return Icons.info_rounded;
    }
  }

  Color _diagnosticColor(DiagnosticSeverity severity) {
    final tokens = VityoWorkbenchTokens.of(context);
    switch (severity) {
      case DiagnosticSeverity.error:
        return tokens.error;
      case DiagnosticSeverity.warning:
        return tokens.warning;
      case DiagnosticSeverity.hint:
        return tokens.muted;
    }
  }

  Widget _buildSemanticBlocksContent(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.analysis.semanticBlocks.isEmpty) {
      return Text(
        'No semantic block surfaces resolved yet.',
        style: theme.textTheme.bodySmall,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widget.analysis.semanticBlocks
          .take(4)
          .map(
            (block) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${block.label} · ${_formatRange(block.range)}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildInlayHintsContent(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.analysis.inlayHints.isEmpty) {
      return Text(
        'No inlay hints for the current document.',
        style: theme.textTheme.bodySmall,
      );
    }

    return Column(
      key: const ValueKey('language-inlay-hints-list'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (
          var index = 0;
          index < widget.analysis.inlayHints.length;
          index += 1
        )
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '${widget.analysis.inlayHints[index].label} · '
              '${widget.analysis.inlayHints[index].kind.name} · '
              '${_formatRange(widget.analysis.inlayHints[index].range)}',
              key: ValueKey('language-inlay-hint-$index'),
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _buildDocumentSymbolsContent(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.analysis.documentSymbols.isEmpty) {
      return Text(
        'No document symbols resolved yet.',
        style: theme.textTheme.bodySmall,
      );
    }

    return Column(
      key: const ValueKey('language-document-symbols-tree'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widget.analysis.documentSymbols
          .map(
            (symbol) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Material(
                color: _isSymbolSelected(symbol)
                    ? VityoWorkbenchTokens.of(context).selection
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  key: ValueKey(
                    'language-document-symbol-${symbol.kind.name}-'
                    '${symbol.name}-${symbol.nameRange.start}',
                  ),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => widget.controller.selectDocumentSymbol(symbol),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 7,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _symbolIcon(symbol.kind),
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${symbol.name} · ${symbol.kind.name} · '
                            '${_formatRange(symbol.nameRange)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  bool _isSymbolSelected(DocumentSymbol symbol) {
    return _isRangeSelected(symbol.nameRange);
  }

  bool _isRangeSelected(SourceRange range) {
    final selection = widget.controller.selection;
    if (selection.isCollapsed) {
      return range.contains(selection.end) || range.end == selection.end;
    }
    final selectionRange = SourceRange(
      start: selection.start,
      end: selection.end,
    );
    return range.intersects(selectionRange);
  }

  IconData _symbolIcon(SymbolKind kind) {
    switch (kind) {
      case SymbolKind.function:
        return Icons.functions_rounded;
      case SymbolKind.pipeline:
        return Icons.account_tree_rounded;
      case SymbolKind.state:
        return Icons.flag_rounded;
      case SymbolKind.resource:
        return Icons.storage_rounded;
      case SymbolKind.variable:
        return Icons.label_rounded;
      case SymbolKind.parameter:
        return Icons.input_rounded;
      case SymbolKind.task:
        return Icons.task_alt_rounded;
    }
  }

  Widget _buildResolveContent(BuildContext context) {
    final theme = Theme.of(context);
    final definition = widget.controller.definitionAtSelection;
    final references = widget.controller.referencesAtSelection;
    if (definition == null) {
      return Text(
        'No definition target at the current caret.',
        style: theme.textTheme.bodySmall,
      );
    }
    final renameSeedKey =
        '${definition.symbol.name}:${definition.symbol.nameRange.start}:'
        '${definition.symbol.nameRange.end}';
    if (_renameSeedKey != renameSeedKey) {
      _renameSeedKey = renameSeedKey;
      _renameController.text = '${definition.symbol.name}_next';
    }
    final renameText = _renameController.text.trim();
    final renamePreview = widget.controller.renamePlanAtSelection(renameText);

    return Column(
      key: const ValueKey('language-resolve-context'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${definition.symbol.name} · ${definition.symbol.kind.name}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Definition ${_formatRange(definition.symbol.nameRange)} · '
          'origin ${_formatRange(definition.originRange)}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        _InlineActionChip(
          key: const ValueKey('language-go-to-definition'),
          icon: Icons.subdirectory_arrow_left_rounded,
          label: 'Go to definition',
          onTap: widget.controller.selectDefinitionAtSelection,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _InlineActionChip(
              key: const ValueKey('language-previous-usage'),
              icon: Icons.keyboard_arrow_up_rounded,
              label: 'Previous usage',
              onTap: widget.controller.selectPreviousReferenceAtSelection,
            ),
            _InlineActionChip(
              key: const ValueKey('language-next-usage'),
              icon: Icons.keyboard_arrow_down_rounded,
              label: 'Next usage',
              onTap: widget.controller.selectNextReferenceAtSelection,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${references.length} current-file usage'
          '${references.length == 1 ? '' : 's'}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('language-rename-input'),
          controller: _renameController,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            labelText: 'Rename',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        if (renamePreview != null && renamePreview.hasConflicts) ...[
          Text(
            _formatRenameConflict(renamePreview.conflicts.first),
            key: const ValueKey('language-rename-conflict'),
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.error,
              fontWeight: FontWeight.w700,
            ),
          ),
        ] else if (renamePreview != null) ...[
          Text(
            'Rename preview ${renamePreview.edits.length} edit'
            '${renamePreview.edits.length == 1 ? '' : 's'}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          _InlineActionChip(
            key: const ValueKey('language-apply-rename'),
            icon: Icons.drive_file_rename_outline_rounded,
            label: 'Apply rename',
            onTap: () => widget.controller.applyRename(renameText),
          ),
        ],
        const SizedBox(height: 8),
        ...references
            .take(4)
            .map(
              (reference) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${_referenceAccessLabel(reference)} · '
                  '${_formatRange(reference.range)}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
      ],
    );
  }

  String _formatRenameConflict(RenameConflict conflict) {
    final position = widget.controller.document.positionForOffset(
      conflict.range.start,
    );
    return '${conflict.message} Conflict at '
        '${position.line + 1}:${position.column + 1}.';
  }

  Widget _buildHoverContent(BuildContext context) {
    return Text(
      widget.hover?.markdown ?? 'No hover payload at the current caret.',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }

  Widget _buildTokenContent(BuildContext context) {
    final theme = Theme.of(context);
    final token = widget.activeToken;
    if (token == null) {
      return Text(
        'No token resolved at the current caret.',
        style: theme.textTheme.bodySmall,
      );
    }

    return Column(
      key: const ValueKey('language-token-context'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Lexeme `${token.lexeme}`', style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        Text('Kind ${token.kind.name}', style: theme.textTheme.bodySmall),
        if (widget.activeSemanticKind != null) ...[
          const SizedBox(height: 8),
          Text(
            'Semantic ${widget.activeSemanticKind!.name}',
            style: theme.textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'Range ${_formatRange(token.range)}',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildCompletionContent(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.completions.isEmpty) {
      return Text(
        'No completion items at the current caret.',
        style: theme.textTheme.bodySmall,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widget.completions
          .take(4)
          .map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      '${item.label} · ${item.kind.name} · ${item.detail}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _InlineActionChip(
                    key: ValueKey('language-apply-completion-${item.label}'),
                    icon: Icons.auto_awesome_rounded,
                    label: 'Apply',
                    onTap: () => widget.controller.applyCompletionItem(item),
                  ),
                ],
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildFormattingContent(BuildContext context) {
    final theme = Theme.of(context);
    final edits = widget.analysis.formattingEdits;
    if (edits.isEmpty) {
      return Text(
        'Formatter returned no TextEdit patches.',
        style: theme.textTheme.bodySmall,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Formatter returns ${edits.length} TextEdit patch item(s), not direct document mutation.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        ...edits
            .take(3)
            .map(
              (edit) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${_formatRange(edit.range)} -> ${edit.newText.replaceAll('\n', r'\n')}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
        _InlineActionChip(
          key: const ValueKey('language-apply-formatting'),
          icon: Icons.auto_fix_high_rounded,
          label: 'Apply format edits',
          onTap: () => widget.controller.applyFormattingEdits(edits),
        ),
      ],
    );
  }

  String _formatRange(SourceRange range) {
    return '${range.start}-${range.end}';
  }
}

class _InspectorCard extends StatelessWidget {
  const _InspectorCard({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.42,
        ),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.dividerColor),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _InspectorTabChip extends StatelessWidget {
  const _InspectorTabChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Ink(
        decoration: BoxDecoration(
          color: active
              ? theme.colorScheme.primary.withValues(alpha: 0.12)
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.34,
                ),
          borderRadius: BorderRadius.circular(4),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Text(label, style: theme.textTheme.labelMedium),
      ),
    );
  }
}

class _HorizontalChipStrip extends StatelessWidget {
  const _HorizontalChipStrip({required this.height, required this.children});

  final double height;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final separated = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        separated.add(const SizedBox(width: 10));
      }
      separated.add(children[i]);
    }
    return SizedBox(
      height: height,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: separated,
        ),
      ),
    );
  }
}

class _CapabilityPill extends StatelessWidget {
  const _CapabilityPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Text(label, style: theme.textTheme.labelSmall),
      ),
    );
  }
}
