part of 'editor_surface.dart';

/// Requests keyboard ownership without applying pointer-selection semantics.
///
/// Like Flutter's `EditableTextState.requestKeyboard`, this focuses an idle
/// editor or explicitly reopens the text-input connection when it is already
/// focused.
final class EditorRequestKeyboardIntent extends Intent {
  const EditorRequestKeyboardIntent();
}

List<CompletionItem> mergeCompletionItems(
  Iterable<CompletionItem> primary,
  Iterable<CompletionItem> fallback,
) {
  final completions = <CompletionItem>[];
  final seen = <String>{};
  for (final completion in [...primary, ...fallback]) {
    final key =
        '${completion.kind.name}:${completion.label}:${completion.insertText}';
    if (seen.add(key)) {
      completions.add(completion);
    }
  }
  return List<CompletionItem>.unmodifiable(completions);
}

class EditorSurface extends StatelessWidget {
  const EditorSurface({
    super.key,
    required this.controller,
    required this.viewportProfile,
    this.languageServiceStatus,
    this.fileBindingSnapshot,
    this.closeRequestSurface,
    this.semanticThemeBinding,
    this.onAcceptExternalChange,
    this.onSaveLocalChanges,
    this.onDiscardLocalChanges,
    this.onSaveAndCloseRequest,
    this.onDiscardAndCloseRequest,
    this.onSwitchToCloseRequestFile,
    this.onCancelCloseRequest,
    this.projectHoverAtSelection,
    this.projectCompletionsAtSelection = const <CompletionItem>[],
    this.openDocumentIds = const <String>[],
    this.dirtyDocumentIds = const <String>[],
    this.activeDocumentId,
    this.onSelectDocument,
    this.onCloseDocument,
    this.onRefreshLanguageService,
    this.showDevelopmentChrome = true,
    this.languageInspectorVisible = true,
    this.onToggleLanguageInspector,
  });

  final EditorSessionController controller;
  final ViewportProfile viewportProfile;
  final LanguageServiceStatusSurface? languageServiceStatus;
  final DocumentResourceBindingSnapshot? fileBindingSnapshot;
  final EditorCloseRequestSurface? closeRequestSurface;
  final EditorSemanticThemeBinding? semanticThemeBinding;
  final VoidCallback? onAcceptExternalChange;
  final VoidCallback? onSaveLocalChanges;
  final VoidCallback? onDiscardLocalChanges;
  final VoidCallback? onSaveAndCloseRequest;
  final VoidCallback? onDiscardAndCloseRequest;
  final VoidCallback? onSwitchToCloseRequestFile;
  final VoidCallback? onCancelCloseRequest;
  final HoverPayload? projectHoverAtSelection;
  final List<CompletionItem> projectCompletionsAtSelection;
  final List<String> openDocumentIds;
  final List<String> dirtyDocumentIds;
  final String? activeDocumentId;
  final ValueChanged<String>? onSelectDocument;
  final ValueChanged<String>? onCloseDocument;
  final VoidCallback? onRefreshLanguageService;
  final bool showDevelopmentChrome;
  final bool languageInspectorVisible;
  final VoidCallback? onToggleLanguageInspector;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget buildShell(BuildContext context) {
      final document = controller.document;
      final selection = controller.selection;
      final renderPlan = controller.renderPlan;
      final semanticThemeBinding =
          this.semanticThemeBinding ??
          EditorSemanticThemeBinding.fromTheme(
            EditorSemanticTheme.foundation(),
          );
      final analysis = controller.analysis;
      final deferExpensiveLanguageQueries = document.lineCount >= 10000;
      final hover = deferExpensiveLanguageQueries
          ? null
          : projectHoverAtSelection ?? controller.hoverAtSelection;
      final completions = deferExpensiveLanguageQueries
          ? const <CompletionItem>[]
          : mergeCompletionItems(
              controller.completionsAtSelection,
              projectCompletionsAtSelection,
            );
      final activeReferences = deferExpensiveLanguageQueries
          ? const <ReferenceSpan>[]
          : controller.referencesAtSelection;
      final activeToken = deferExpensiveLanguageQueries
          ? null
          : controller.tokenAtSelection;
      final activeSemanticKind = deferExpensiveLanguageQueries
          ? null
          : controller.semanticKindAtSelection;
      final serviceStatus = languageServiceStatus;
      final fileBindingStatus = _fileBindingStatusFor(fileBindingSnapshot);
      final closeRequest = closeRequestSurface;
      final activeOpenDocumentId = activeDocumentId ?? document.documentId;
      final visibleOpenDocumentIds = openDocumentIds.isEmpty
          ? <String>[document.documentId]
          : openDocumentIds;
      final visibleServiceStatus = serviceStatus;
      if (!showDevelopmentChrome) {
        final notice = closeRequest != null && closeRequest.requiresUserChoice
            ? _CloseRequestBanner(
                request: closeRequest,
                onSaveLocalChanges: onSaveAndCloseRequest ?? onSaveLocalChanges,
                onDiscardLocalChanges:
                    onDiscardAndCloseRequest ?? onDiscardLocalChanges,
                onSwitchToCloseRequestFile: onSwitchToCloseRequestFile,
                onCancelCloseRequest: onCancelCloseRequest,
              )
            : fileBindingStatus != null
            ? _FileBindingStatusBanner(
                status: fileBindingStatus,
                onAcceptExternalChange: onAcceptExternalChange,
                onSaveLocalChanges: onSaveLocalChanges,
                onDiscardLocalChanges: onDiscardLocalChanges,
              )
            : null;
        return _IdeEditorSurface(
          controller: controller,
          viewportProfile: viewportProfile,
          document: document,
          selection: selection,
          analysis: analysis,
          renderPlan: renderPlan,
          semanticThemeBinding: semanticThemeBinding,
          hover: hover,
          completions: completions,
          activeReferences: activeReferences,
          activeToken: activeToken,
          activeSemanticKind: activeSemanticKind,
          languageServiceStatus: visibleServiceStatus,
          onRefreshLanguageService: onRefreshLanguageService,
          documentIds: visibleOpenDocumentIds,
          dirtyDocumentIds: dirtyDocumentIds,
          activeDocumentId: activeOpenDocumentId,
          onSelectDocument: onSelectDocument,
          onCloseDocument: onCloseDocument,
          notice: notice,
          languageInspectorVisible: languageInspectorVisible,
          onToggleLanguageInspector: onToggleLanguageInspector,
        );
      }
      final summaryPills = <String>[
        'lines ${document.lineCount}',
        'chars ${document.length}',
        'tokens ${analysis.tokenCount}',
        'semantic ${analysis.semanticCount}',
        'symbols ${analysis.symbolCount}',
        'diagnostics ${analysis.diagnosticCount}',
        if (visibleServiceStatus != null)
          'service ${visibleServiceStatus.severity.name}',
        selection.isCollapsed
            ? 'caret ${selection.end}'
            : 'selection ${selection.start}-${selection.end}',
        'undo ${controller.canUndo ? "on" : "off"}',
        'redo ${controller.canRedo ? "on" : "off"}',
      ];

      return LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              viewportProfile.isMobile ||
              constraints.maxWidth < 780 ||
              constraints.maxHeight < 560;
          final dense =
              (viewportProfile.isMobile && constraints.maxWidth < 640) ||
              constraints.maxWidth < 560 ||
              constraints.maxHeight < 430;
          final outerPadding = dense ? 16.0 : 24.0;
          final innerPadding = dense ? 14.0 : 18.0;
          final visibleSummaryPills = dense
              ? summaryPills.take(4).toList(growable: false)
              : summaryPills;

          return Card(
            key: ValueKey(
              'editor-viewport-${viewportProfile.label.toLowerCase()}',
            ),
            child: Padding(
              padding: EdgeInsets.all(outerPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          document.documentId,
                          style: theme.textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Chip(label: Text('rev ${document.revision}')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _OpenDocumentTabStrip(
                    documentIds: visibleOpenDocumentIds,
                    dirtyDocumentIds: dirtyDocumentIds,
                    activeDocumentId: activeOpenDocumentId,
                    onSelectDocument: onSelectDocument,
                    onCloseDocument: onCloseDocument,
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: visibleSummaryPills
                        .map((label) => _CapabilityPill(label: label))
                        .toList(growable: false),
                  ),
                  if (closeRequest != null &&
                      closeRequest.requiresUserChoice) ...[
                    const SizedBox(height: 12),
                    _CloseRequestBanner(
                      request: closeRequest,
                      onSaveLocalChanges:
                          onSaveAndCloseRequest ?? onSaveLocalChanges,
                      onDiscardLocalChanges:
                          onDiscardAndCloseRequest ?? onDiscardLocalChanges,
                      onSwitchToCloseRequestFile: onSwitchToCloseRequestFile,
                      onCancelCloseRequest: onCancelCloseRequest,
                    ),
                  ] else if (fileBindingStatus != null) ...[
                    const SizedBox(height: 12),
                    _FileBindingStatusBanner(
                      status: fileBindingStatus,
                      onAcceptExternalChange: onAcceptExternalChange,
                      onSaveLocalChanges: onSaveLocalChanges,
                      onDiscardLocalChanges: onDiscardLocalChanges,
                    ),
                  ],
                  if (!dense && fileBindingStatus == null) ...[
                    const SizedBox(height: 14),
                    Text(
                      compact
                          ? 'Token, semantic, diagnostic, and formatting layers stay isolated while sharing one editor surface.'
                          : 'M2/M3 editor anchor: token layer drives base highlighting, semantic layer overlays meaning, diagnostics stay separate, and formatting returns patch-like edits.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: VityoWorkbenchTokens.of(context).editor,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: theme.dividerColor),
                      ),
                      padding: EdgeInsets.all(innerPadding),
                      child: LayoutBuilder(
                        builder: (context, sourceConstraints) {
                          final showLayerToolbar =
                              !dense && sourceConstraints.maxHeight >= 128;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (showLayerToolbar) ...[
                                _HorizontalChipStrip(
                                  height: 44,
                                  children: [
                                    ...renderPlan.activeLayers.map(
                                      (layer) => _CapabilityPill(
                                        label: 'layer ${layer.name}',
                                      ),
                                    ),
                                    FilterChip(
                                      key: const ValueKey(
                                        'editor-glyph-substitution-toggle',
                                      ),
                                      selected:
                                          renderPlan.glyphSubstitutionEnabled,
                                      label: Text(
                                        renderPlan.glyphSubstitutionEnabled
                                            ? 'glyph substitution on'
                                            : 'glyph substitution off',
                                      ),
                                      onSelected: (_) {
                                        controller.toggleGlyphSubstitution();
                                      },
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                              ],
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    final mobileFamily =
                                        viewportProfile.isMobile;
                                    final scrollStackedPane =
                                        mobileFamily &&
                                        constraints.maxHeight < 460;
                                    final inspectorHeight =
                                        constraints.maxHeight >= 720
                                        ? 240.0
                                        : constraints.maxHeight >= 560
                                        ? 200.0
                                        : 160.0;

                                    if (scrollStackedPane) {
                                      return KeyedSubtree(
                                        key: const ValueKey(
                                          'editor-language-family-mobile',
                                        ),
                                        child: SingleChildScrollView(
                                          key: ValueKey(
                                            'editor-language-layout-scroll-${viewportProfile.label.toLowerCase()}',
                                          ),
                                          child: Column(
                                            children: [
                                              SizedBox(
                                                height: 320,
                                                child: _SourcePreviewPane(
                                                  controller: controller,
                                                  viewportProfile:
                                                      viewportProfile,
                                                  hover: hover,
                                                  completions: completions,
                                                  activeReferences:
                                                      activeReferences,
                                                  activeToken: activeToken,
                                                  activeSemanticKind:
                                                      activeSemanticKind,
                                                  semanticThemeBinding:
                                                      semanticThemeBinding,
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              SizedBox(
                                                height: 180,
                                                child: _LanguageServicePane(
                                                  controller: controller,
                                                  viewportProfile:
                                                      viewportProfile,
                                                  analysis: analysis,
                                                  hover: hover,
                                                  completions: completions,
                                                  activeToken: activeToken,
                                                  activeSemanticKind:
                                                      activeSemanticKind,
                                                  languageServiceStatus:
                                                      visibleServiceStatus,
                                                  onRefreshLanguageService:
                                                      onRefreshLanguageService,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    }

                                    if (mobileFamily) {
                                      return KeyedSubtree(
                                        key: const ValueKey(
                                          'editor-language-family-mobile',
                                        ),
                                        child: Column(
                                          key: const ValueKey(
                                            'editor-language-layout-mobile',
                                          ),
                                          children: [
                                            Expanded(
                                              child: _SourcePreviewPane(
                                                controller: controller,
                                                viewportProfile:
                                                    viewportProfile,
                                                hover: hover,
                                                completions: completions,
                                                activeReferences:
                                                    activeReferences,
                                                activeToken: activeToken,
                                                activeSemanticKind:
                                                    activeSemanticKind,
                                                semanticThemeBinding:
                                                    semanticThemeBinding,
                                              ),
                                            ),
                                            const SizedBox(height: 16),
                                            SizedBox(
                                              height: inspectorHeight,
                                              child: _LanguageServicePane(
                                                controller: controller,
                                                viewportProfile:
                                                    viewportProfile,
                                                analysis: analysis,
                                                hover: hover,
                                                completions: completions,
                                                activeToken: activeToken,
                                                activeSemanticKind:
                                                    activeSemanticKind,
                                                languageServiceStatus:
                                                    visibleServiceStatus,
                                                onRefreshLanguageService:
                                                    onRefreshLanguageService,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    }

                                    return KeyedSubtree(
                                      key: const ValueKey(
                                        'editor-language-family-desktop',
                                      ),
                                      child: Row(
                                        key: const ValueKey(
                                          'editor-language-layout-desktop',
                                        ),
                                        children: [
                                          Expanded(
                                            flex: 5,
                                            child: _SourcePreviewPane(
                                              controller: controller,
                                              viewportProfile: viewportProfile,
                                              hover: hover,
                                              completions: completions,
                                              activeReferences:
                                                  activeReferences,
                                              activeToken: activeToken,
                                              activeSemanticKind:
                                                  activeSemanticKind,
                                              semanticThemeBinding:
                                                  semanticThemeBinding,
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          SizedBox(
                                            width: constraints.maxWidth >= 760
                                                ? 300
                                                : 248,
                                            child: _LanguageServicePane(
                                              controller: controller,
                                              viewportProfile: viewportProfile,
                                              analysis: analysis,
                                              hover: hover,
                                              completions: completions,
                                              activeToken: activeToken,
                                              activeSemanticKind:
                                                  activeSemanticKind,
                                              languageServiceStatus:
                                                  visibleServiceStatus,
                                              onRefreshLanguageService:
                                                  onRefreshLanguageService,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    if (controller.document.lineCount >= 10000) {
      return buildShell(context);
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => buildShell(context),
    );
  }
}

class _IdeEditorSurface extends StatelessWidget {
  const _IdeEditorSurface({
    required this.controller,
    required this.viewportProfile,
    required this.document,
    required this.selection,
    required this.analysis,
    required this.renderPlan,
    required this.semanticThemeBinding,
    required this.hover,
    required this.completions,
    required this.activeReferences,
    required this.activeToken,
    required this.activeSemanticKind,
    required this.languageServiceStatus,
    required this.onRefreshLanguageService,
    required this.documentIds,
    required this.dirtyDocumentIds,
    required this.activeDocumentId,
    required this.onSelectDocument,
    required this.onCloseDocument,
    required this.notice,
    required this.languageInspectorVisible,
    required this.onToggleLanguageInspector,
  });

  final EditorSessionController controller;
  final ViewportProfile viewportProfile;
  final DocumentState document;
  final SelectionState selection;
  final StyioDocumentAnalysis analysis;
  final EditorRenderPlan renderPlan;
  final EditorSemanticThemeBinding semanticThemeBinding;
  final HoverPayload? hover;
  final List<CompletionItem> completions;
  final List<ReferenceSpan> activeReferences;
  final TokenSpan? activeToken;
  final SemanticKind? activeSemanticKind;
  final LanguageServiceStatusSurface? languageServiceStatus;
  final VoidCallback? onRefreshLanguageService;
  final List<String> documentIds;
  final List<String> dirtyDocumentIds;
  final String activeDocumentId;
  final ValueChanged<String>? onSelectDocument;
  final ValueChanged<String>? onCloseDocument;
  final Widget? notice;
  final bool languageInspectorVisible;
  final VoidCallback? onToggleLanguageInspector;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = VityoWorkbenchTokens.of(context);
    final serviceStatus = languageServiceStatus;
    final serviceColor = switch (serviceStatus?.severity) {
      LanguageServiceStatusSeverity.ready => tokens.success,
      LanguageServiceStatusSeverity.refreshing => tokens.warning,
      LanguageServiceStatusSeverity.degraded => tokens.warning,
      LanguageServiceStatusSeverity.unavailable => tokens.blocked,
      LanguageServiceStatusSeverity.failed => tokens.error,
      null => theme.disabledColor,
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final showInspector =
            languageInspectorVisible && constraints.maxWidth >= 720;
        return Container(
          key: ValueKey(
            'editor-viewport-${viewportProfile.label.toLowerCase()}',
          ),
          color: theme.colorScheme.surface,
          child: Column(
            children: [
              Container(
                height: 38,
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: theme.dividerColor)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _OpenDocumentTabStrip(
                        documentIds: documentIds,
                        dirtyDocumentIds: dirtyDocumentIds,
                        activeDocumentId: activeDocumentId,
                        onSelectDocument: onSelectDocument,
                        onCloseDocument: onCloseDocument,
                      ),
                    ),
                    if (analysis.diagnosticCount > 0)
                      Tooltip(
                        message: '${analysis.diagnosticCount} diagnostics',
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.error_outline_rounded,
                                size: 15,
                                color: theme.colorScheme.error,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${analysis.diagnosticCount}',
                                style: theme.textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    Tooltip(
                      message: renderPlan.glyphSubstitutionEnabled
                          ? 'Show literal operators'
                          : 'Show operator glyphs',
                      child: IconButton(
                        key: const ValueKey('editor-glyph-substitution-toggle'),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 34,
                          height: 34,
                        ),
                        onPressed: controller.toggleGlyphSubstitution,
                        icon: Icon(
                          Icons.functions_rounded,
                          size: 17,
                          color: renderPlan.glyphSubstitutionEnabled
                              ? theme.colorScheme.primary
                              : theme.disabledColor,
                        ),
                      ),
                    ),
                    Tooltip(
                      message: showInspector
                          ? 'Hide language inspector'
                          : serviceStatus?.title ?? 'Show language inspector',
                      child: IconButton(
                        key: const ValueKey('editor-language-inspector-toggle'),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 36,
                          height: 34,
                        ),
                        onPressed: onToggleLanguageInspector,
                        icon: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Icon(
                              showInspector
                                  ? Icons.view_sidebar_rounded
                                  : Icons.view_sidebar_outlined,
                              size: 18,
                            ),
                            Positioned(
                              right: -2,
                              top: -2,
                              child: Icon(
                                Icons.circle,
                                size: 7,
                                color: serviceColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
              if (notice case final visibleNotice?)
                Padding(padding: const EdgeInsets.all(8), child: visibleNotice),
              Expanded(
                child: KeyedSubtree(
                  key: const ValueKey('editor-language-family-desktop'),
                  child: Row(
                    key: const ValueKey('editor-language-layout-desktop'),
                    children: [
                      Expanded(
                        child: _SourcePreviewPane(
                          controller: controller,
                          viewportProfile: viewportProfile,
                          hover: hover,
                          completions: completions,
                          activeReferences: activeReferences,
                          activeToken: activeToken,
                          activeSemanticKind: activeSemanticKind,
                          semanticThemeBinding: semanticThemeBinding,
                          showDebugChrome: false,
                          showSemanticBlockCards: true,
                          showInlineLanguageFeedback: true,
                          compactInlineLanguageFeedback: true,
                        ),
                      ),
                      if (showInspector) ...[
                        const VerticalDivider(width: 1, thickness: 1),
                        SizedBox(
                          width: constraints.maxWidth >= 1100 ? 320 : 280,
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: _LanguageServicePane(
                              controller: controller,
                              viewportProfile: viewportProfile,
                              analysis: analysis,
                              hover: hover,
                              completions: completions,
                              activeToken: activeToken,
                              activeSemanticKind: activeSemanticKind,
                              languageServiceStatus: languageServiceStatus,
                              onRefreshLanguageService:
                                  onRefreshLanguageService,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CloseRequestBanner extends StatelessWidget {
  const _CloseRequestBanner({
    required this.request,
    required this.onSaveLocalChanges,
    required this.onDiscardLocalChanges,
    required this.onSwitchToCloseRequestFile,
    required this.onCancelCloseRequest,
  });

  final EditorCloseRequestSurface request;
  final VoidCallback? onSaveLocalChanges;
  final VoidCallback? onDiscardLocalChanges;
  final VoidCallback? onSwitchToCloseRequestFile;
  final VoidCallback? onCancelCloseRequest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('editor-close-request-banner'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.36),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.secondary.withValues(alpha: 0.36),
        ),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Close blocked', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(request.message, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          if (request.canSwitchToFile)
            OutlinedButton(
              key: const ValueKey('editor-close-request-switch'),
              onPressed: onSwitchToCloseRequestFile,
              child: const Text('Switch to file'),
            ),
          OutlinedButton(
            key: const ValueKey('editor-close-request-save'),
            onPressed: request.canSave ? onSaveLocalChanges : null,
            child: const Text('Save changes'),
          ),
          TextButton(
            key: const ValueKey('editor-close-request-discard'),
            onPressed: request.canDiscard ? onDiscardLocalChanges : null,
            child: const Text('Discard changes'),
          ),
          TextButton(
            key: const ValueKey('editor-close-request-cancel'),
            onPressed: onCancelCloseRequest,
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

class _OpenDocumentTabStrip extends StatelessWidget {
  const _OpenDocumentTabStrip({
    required this.documentIds,
    required this.dirtyDocumentIds,
    required this.activeDocumentId,
    required this.onSelectDocument,
    required this.onCloseDocument,
  });

  final List<String> documentIds;
  final List<String> dirtyDocumentIds;
  final String activeDocumentId;
  final ValueChanged<String>? onSelectDocument;
  final ValueChanged<String>? onCloseDocument;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      key: const ValueKey('editor-open-file-tab-strip'),
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: documentIds.length,
        separatorBuilder: (context, index) => const SizedBox.shrink(),
        itemBuilder: (context, index) {
          final documentId = documentIds[index];
          final active = documentId == activeDocumentId;
          final dirty = dirtyDocumentIds.contains(documentId);
          return _OpenDocumentTab(
            documentId: documentId,
            active: active,
            dirty: dirty,
            onSelectDocument: onSelectDocument,
            onCloseDocument: onCloseDocument,
            color: active
                ? theme.scaffoldBackgroundColor
                : theme.colorScheme.surface,
          );
        },
      ),
    );
  }
}

class _OpenDocumentTab extends StatelessWidget {
  const _OpenDocumentTab({
    required this.documentId,
    required this.active,
    required this.dirty,
    required this.onSelectDocument,
    required this.onCloseDocument,
    required this.color,
  });

  final String documentId;
  final bool active;
  final bool dirty;
  final ValueChanged<String>? onSelectDocument;
  final ValueChanged<String>? onCloseDocument;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: ValueKey('editor-open-file-tab-$documentId'),
      color: color,
      child: InkWell(
        onTap: active ? null : () => onSelectDocument?.call(documentId),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              right: BorderSide(color: theme.dividerColor),
              bottom: BorderSide(
                color: active ? theme.colorScheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          padding: const EdgeInsets.only(left: 14, right: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  _documentTabLabel(documentId),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    color: active
                        ? theme.colorScheme.onSurface
                        : theme.textTheme.bodySmall?.color,
                  ),
                ),
              ),
              if (dirty) ...[
                const SizedBox(width: 6),
                Text(
                  '•',
                  key: ValueKey('editor-open-file-tab-dirty-$documentId'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
              const SizedBox(width: 4),
              IconButton(
                key: ValueKey('editor-open-file-tab-close-$documentId'),
                tooltip: 'Close $documentId',
                icon: const Icon(Icons.close_rounded, size: 16),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                onPressed: onCloseDocument == null
                    ? null
                    : () => onCloseDocument!(documentId),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _documentTabLabel(String documentId) {
  final normalized = documentId.replaceAll('\\', '/');
  final segments = normalized.split('/').where((segment) => segment.isNotEmpty);
  return segments.isEmpty ? documentId : segments.last;
}

class _FileBindingStatus {
  const _FileBindingStatus({
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.actionEnabled,
    required this.action,
    this.secondaryActionLabel,
    this.secondaryActionEnabled = false,
    this.secondaryAction,
  });

  final String title;
  final String message;
  final String actionLabel;
  final bool actionEnabled;
  final _FileBindingStatusAction action;
  final String? secondaryActionLabel;
  final bool secondaryActionEnabled;
  final _FileBindingStatusAction? secondaryAction;
}

enum _FileBindingStatusAction {
  acceptExternal,
  saveLocal,
  discardLocal,
  unavailable,
}

_FileBindingStatus? _fileBindingStatusFor(
  DocumentResourceBindingSnapshot? snapshot,
) {
  return switch (snapshot?.state) {
    DocumentResourceBindingState.boundDirty => const _FileBindingStatus(
      title: 'Unsaved local changes',
      message:
          'Save this file or discard local changes before closing the tab.',
      actionLabel: 'Save changes',
      actionEnabled: true,
      action: _FileBindingStatusAction.saveLocal,
      secondaryActionLabel: 'Discard changes',
      secondaryActionEnabled: true,
      secondaryAction: _FileBindingStatusAction.discardLocal,
    ),
    DocumentResourceBindingState.externalChanged => const _FileBindingStatus(
      title: 'External file change',
      message:
          'The backing file changed on disk. Reload to use the external revision.',
      actionLabel: 'Reload external',
      actionEnabled: true,
      action: _FileBindingStatusAction.acceptExternal,
    ),
    DocumentResourceBindingState.conflicted => const _FileBindingStatus(
      title: 'External file conflict',
      message:
          'The backing file changed while this editor has unsaved local edits.',
      actionLabel: 'Use external version',
      actionEnabled: true,
      action: _FileBindingStatusAction.acceptExternal,
    ),
    DocumentResourceBindingState.deletedOnDisk => const _FileBindingStatus(
      title: 'Backing file deleted',
      message: 'The backing file was deleted or became unavailable.',
      actionLabel: 'Reload unavailable',
      actionEnabled: false,
      action: _FileBindingStatusAction.unavailable,
    ),
    DocumentResourceBindingState.readonly => const _FileBindingStatus(
      title: 'Backing file is read-only',
      message: 'The current file cannot be saved until it becomes writable.',
      actionLabel: 'Read-only',
      actionEnabled: false,
      action: _FileBindingStatusAction.unavailable,
    ),
    DocumentResourceBindingState.providerUnavailable =>
      const _FileBindingStatus(
        title: 'File provider unavailable',
        message: 'The current file provider is unavailable.',
        actionLabel: 'Provider unavailable',
        actionEnabled: false,
        action: _FileBindingStatusAction.unavailable,
      ),
    _ => null,
  };
}

class _FileBindingStatusBanner extends StatelessWidget {
  const _FileBindingStatusBanner({
    required this.status,
    required this.onAcceptExternalChange,
    required this.onSaveLocalChanges,
    required this.onDiscardLocalChanges,
  });

  final _FileBindingStatus status;
  final VoidCallback? onAcceptExternalChange;
  final VoidCallback? onSaveLocalChanges;
  final VoidCallback? onDiscardLocalChanges;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actionCallback = switch (status.action) {
      _FileBindingStatusAction.acceptExternal => onAcceptExternalChange,
      _FileBindingStatusAction.saveLocal => onSaveLocalChanges,
      _FileBindingStatusAction.discardLocal => onDiscardLocalChanges,
      _FileBindingStatusAction.unavailable => null,
    };
    final secondaryActionCallback = switch (status.secondaryAction) {
      _FileBindingStatusAction.acceptExternal => onAcceptExternalChange,
      _FileBindingStatusAction.saveLocal => onSaveLocalChanges,
      _FileBindingStatusAction.discardLocal => onDiscardLocalChanges,
      _FileBindingStatusAction.unavailable => null,
      null => null,
    };
    return Container(
      key: const ValueKey('editor-file-binding-status-banner'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.36),
        ),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(status.title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(status.message, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          OutlinedButton(
            key: const ValueKey('editor-file-binding-accept-external'),
            onPressed: status.actionEnabled ? actionCallback : null,
            child: Text(status.actionLabel),
          ),
          if (status.secondaryActionLabel case final label?)
            TextButton(
              key: const ValueKey('editor-file-binding-secondary-action'),
              onPressed: status.secondaryActionEnabled
                  ? secondaryActionCallback
                  : null,
              child: Text(label),
            ),
        ],
      ),
    );
  }
}
