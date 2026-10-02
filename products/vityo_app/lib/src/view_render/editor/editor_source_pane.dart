part of 'editor_surface.dart';

class _SourcePreviewPane extends StatefulWidget {
  const _SourcePreviewPane({
    required this.controller,
    required this.viewportProfile,
    required this.hover,
    required this.completions,
    required this.activeReferences,
    required this.activeToken,
    required this.activeSemanticKind,
    required this.semanticThemeBinding,
    this.showDebugChrome = true,
    this.showSemanticBlockCards = true,
    this.showInlineLanguageFeedback = true,
    this.compactInlineLanguageFeedback = false,
  });

  final EditorSessionController controller;
  final ViewportProfile viewportProfile;
  final HoverPayload? hover;
  final List<CompletionItem> completions;
  final List<ReferenceSpan> activeReferences;
  final TokenSpan? activeToken;
  final SemanticKind? activeSemanticKind;
  final EditorSemanticThemeBinding semanticThemeBinding;
  final bool showDebugChrome;
  final bool showSemanticBlockCards;
  final bool showInlineLanguageFeedback;
  final bool compactInlineLanguageFeedback;

  DocumentState get document => controller.document;
  SelectionState get selection => controller.selection;
  StyioDocumentAnalysis get analysis => controller.analysis;
  EditorRenderPlan get renderPlan => controller.renderPlan;

  @override
  State<_SourcePreviewPane> createState() => _SourcePreviewPaneState();
}

class _SourcePreviewPaneState extends State<_SourcePreviewPane> {
  static const double _gutterWidth = 62;
  static const double _estimatedCharacterWidth = 8.4;
  static const double _estimatedLineHeight = 26;
  static const int _maxRenderedPreviewLines = 400;

  late final FocusNode _focusNode;
  late final EditorTextInputClient _textInputClient;
  late final FocusNode _inlineRenameFocusNode;
  late final FocusNode _introduceVariableFocusNode;
  late final FocusNode _extractFunctionFocusNode;
  late final FocusNode _changeSignatureNameFocusNode;
  late final FocusNode _changeSignatureParametersFocusNode;
  late final ScrollController _sourceScrollController;
  late final TextEditingController _inlineRenameController;
  late final TextEditingController _introduceVariableController;
  late final TextEditingController _extractFunctionController;
  late final TextEditingController _changeSignatureNameController;
  late final TextEditingController _changeSignatureParametersController;
  int? _dragBaseOffset;
  bool _inlineRenameOpen = false;
  bool _introduceVariablePanelOpen = false;
  bool _extractFunctionPanelOpen = false;
  bool _changeSignaturePanelOpen = false;
  bool _usagesPanelOpen = false;
  bool _safeDeletePanelOpen = false;
  bool _inlineVariablePanelOpen = false;
  bool _quickDocumentationOpen = false;
  bool _quickDocumentationForCompletion = false;
  bool _parameterInfoOpen = false;
  bool _quickFixLookupOpen = false;
  int _quickFixLookupIndex = 0;
  bool _symbolLookupOpen = false;
  int _symbolLookupIndex = 0;
  String _symbolLookupQuery = '';
  bool _completionLookupOpen = false;
  bool _surroundLookupOpen = false;
  int _completionLookupIndex = 0;
  int _surroundLookupIndex = 0;
  final Set<String> _collapsedSemanticBlockKeys = <String>{};
  String? _inlineRenameError;
  String? _introduceVariableError;
  String? _extractFunctionError;
  String? _changeSignatureError;
  int _observedInputCommitSerial = 0;
  int _observedCaretLine = 0;
  int _observedScrollLine = 0;
  int? _pendingCaretRevealLine;
  bool _caretRevealScheduled = false;

  bool get _usesHighVolumeRenderBackend =>
      widget.document.lineCount >=
      EditorRenderPipelinePlan.highVolumeLineThreshold;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'editor-source-pane');
    _focusNode.addListener(_handleFocusChanged);
    _textInputClient = EditorTextInputClient(
      controller: widget.controller,
      onChanged: _handleTextInputChanged,
    );
    _inlineRenameFocusNode = FocusNode(debugLabel: 'editor-inline-rename');
    _introduceVariableFocusNode = FocusNode(
      debugLabel: 'editor-introduce-variable',
    );
    _extractFunctionFocusNode = FocusNode(debugLabel: 'editor-extract-method');
    _changeSignatureNameFocusNode = FocusNode(
      debugLabel: 'editor-change-signature-name',
    );
    _changeSignatureParametersFocusNode = FocusNode(
      debugLabel: 'editor-change-signature-parameters',
    );
    _sourceScrollController = ScrollController()
      ..addListener(_handleSourceScrollChanged);
    widget.controller.addListener(_handleControllerChanged);
    _observedCaretLine = _primaryCaretLine;
    if (_usesHighVolumeRenderBackend) {
      _pendingCaretRevealLine = _observedCaretLine;
    }
    _inlineRenameController = TextEditingController();
    _introduceVariableController = TextEditingController();
    _extractFunctionController = TextEditingController();
    _changeSignatureNameController = TextEditingController();
    _changeSignatureParametersController = TextEditingController();
  }

  @override
  void didUpdateWidget(covariant _SourcePreviewPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
      _observedCaretLine = _primaryCaretLine;
      _pendingCaretRevealLine = _usesHighVolumeRenderBackend
          ? _observedCaretLine
          : null;
    }
    _textInputClient.synchronizeCommittedState();
  }

  void _handleControllerChanged() {
    _textInputClient.synchronizeCommittedState();
    final caretLine = _primaryCaretLine;
    if (caretLine != _observedCaretLine) {
      _observedCaretLine = caretLine;
      if (_usesHighVolumeRenderBackend) {
        _pendingCaretRevealLine = caretLine;
      }
    }
    if (mounted) {
      setState(() {});
    }
  }

  int get _primaryCaretLine => widget.document
      .positionForOffset(
        widget.controller.selectionSet.primarySelection.extentOffset,
      )
      .line;

  void _schedulePendingCaretReveal() {
    if (_pendingCaretRevealLine == null || _caretRevealScheduled) {
      return;
    }
    _caretRevealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _caretRevealScheduled = false;
      if (!mounted ||
          !_usesHighVolumeRenderBackend ||
          !_sourceScrollController.hasClients) {
        return;
      }
      final line = _pendingCaretRevealLine;
      if (line == null) {
        return;
      }
      final position = _sourceScrollController.position;
      final firstVisibleLine =
          (_sourceScrollController.offset / _estimatedLineHeight).floor();
      final visibleLineCount =
          (position.viewportDimension / _estimatedLineHeight).floor().clamp(
            1,
            widget.document.lineCount,
          );
      final lastVisibleLine = firstVisibleLine + visibleLineCount - 1;
      _pendingCaretRevealLine = null;
      if (line >= firstVisibleLine && line <= lastVisibleLine) {
        return;
      }
      final contextLineCount = visibleLineCount ~/ 3;
      final targetOffset =
          ((line - contextLineCount).clamp(0, widget.document.lineCount - 1) *
                  _estimatedLineHeight)
              .clamp(position.minScrollExtent, position.maxScrollExtent)
              .toDouble();
      _sourceScrollController.jumpTo(targetOffset);
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _textInputClient.dispose();
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    _inlineRenameFocusNode.dispose();
    _introduceVariableFocusNode.dispose();
    _extractFunctionFocusNode.dispose();
    _changeSignatureNameFocusNode.dispose();
    _changeSignatureParametersFocusNode.dispose();
    _sourceScrollController
      ..removeListener(_handleSourceScrollChanged)
      ..dispose();
    _inlineRenameController.dispose();
    _introduceVariableController.dispose();
    _extractFunctionController.dispose();
    _changeSignatureNameController.dispose();
    _changeSignatureParametersController.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (_focusNode.hasFocus) {
      _textInputClient.attach(explicit: true);
    } else {
      _textInputClient.detach();
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _handleTextInputChanged() {
    if (!mounted) {
      return;
    }
    final commitSerial = _textInputClient.acceptedCommitSerial;
    final newlyCommittedText = commitSerial == _observedInputCommitSerial
        ? null
        : _textInputClient.lastAcceptedCommitText;
    _observedInputCommitSerial = commitSerial;
    setState(() {
      if (newlyCommittedText != null) {
        _openCompletionLookupAfterTyping(newlyCommittedText);
      }
    });
  }

  void _focusSourcePane({required bool attachInput}) {
    _focusNode.requestFocus();
    if (attachInput) {
      _textInputClient.attach(explicit: true);
    }
  }

  void _focusAndAttachInput() => _focusSourcePane(attachInput: true);

  void _handleSourceScrollChanged() {
    final visibleLine = (_sourceScrollController.offset / _estimatedLineHeight)
        .floor();
    if (visibleLine == _observedScrollLine) {
      return;
    }
    _observedScrollLine = visibleLine;
    if (mounted) {
      setState(() {});
    }
  }

  KeyEventResult _handleStructuralTextKey(bool Function() mutate) {
    if (_textInputClient.isComposing) {
      return KeyEventResult.ignored;
    }
    if (!_textInputClient.isAttached) {
      _textInputClient.attach(explicit: true);
    }
    return mutate() ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    final commandPressed =
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;

    if (event.logicalKey == LogicalKeyboardKey.escape &&
        _textInputClient.cancelComposition()) {
      return KeyEventResult.handled;
    }
    final shiftPressed = HardwareKeyboard.instance.isShiftPressed;
    final altPressed = HardwareKeyboard.instance.isAltPressed;
    if (_inlineRenameFocusNode.hasFocus) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.numpadEnter:
          return _applyInlineRename()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        case LogicalKeyboardKey.escape:
          _closeInlineRename();
          return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (_introduceVariableFocusNode.hasFocus) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.numpadEnter:
          return _applyIntroduceVariable()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        case LogicalKeyboardKey.escape:
          _closeIntroduceVariablePanel();
          return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (_extractFunctionFocusNode.hasFocus) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.numpadEnter:
          return _applyExtractFunction()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        case LogicalKeyboardKey.escape:
          _closeExtractFunctionPanel();
          return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (_changeSignatureNameFocusNode.hasFocus ||
        _changeSignatureParametersFocusNode.hasFocus) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.numpadEnter:
          return _applyChangeSignature()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        case LogicalKeyboardKey.escape:
          _closeChangeSignaturePanel();
          return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (_usagesPanelOpen && event.logicalKey == LogicalKeyboardKey.escape) {
      _closeUsagesPanel();
      return KeyEventResult.handled;
    }
    if (_safeDeletePanelOpen) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.escape:
          _closeSafeDeletePanel();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.numpadEnter:
          return _applySafeDelete()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
      }
    }
    if (_inlineVariablePanelOpen) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.escape:
          _closeInlineVariablePanel();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.numpadEnter:
          return _applyInlineVariable()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
      }
    }
    if (_introduceVariablePanelOpen) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.escape:
          _closeIntroduceVariablePanel();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.numpadEnter:
          return _applyIntroduceVariable()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
      }
    }
    if (_extractFunctionPanelOpen) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.escape:
          _closeExtractFunctionPanel();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.numpadEnter:
          return _applyExtractFunction()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
      }
    }
    if (_changeSignaturePanelOpen) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.escape:
          _closeChangeSignaturePanel();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.numpadEnter:
          return _applyChangeSignature()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
      }
    }
    if (_quickDocumentationOpen &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _closeQuickDocumentation();
      return KeyEventResult.handled;
    }
    if (_parameterInfoOpen && event.logicalKey == LogicalKeyboardKey.escape) {
      _closeParameterInfo();
      return KeyEventResult.handled;
    }
    if (_quickFixLookupOpen) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.escape:
          _closeQuickFixLookup();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          _moveQuickFixLookupSelection(1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp:
          _moveQuickFixLookupSelection(-1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.numpadEnter:
        case LogicalKeyboardKey.tab:
          return _applySelectedQuickFix()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        default:
          if (!commandPressed && _isPlainTextCharacter(event.character)) {
            setState(() {
              _quickFixLookupOpen = false;
              _quickFixLookupIndex = 0;
            });
          }
      }
    }
    if (_symbolLookupOpen) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.escape:
          _closeSymbolLookup();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          _moveSymbolLookupSelection(1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp:
          _moveSymbolLookupSelection(-1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.numpadEnter:
        case LogicalKeyboardKey.tab:
          return _applySelectedSymbol()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        case LogicalKeyboardKey.backspace:
          if (_symbolLookupQuery.isEmpty) {
            return KeyEventResult.handled;
          }
          setState(() {
            _symbolLookupQuery = _symbolLookupQuery.substring(
              0,
              _symbolLookupQuery.length - 1,
            );
            _symbolLookupIndex = 0;
          });
          return KeyEventResult.handled;
        default:
          if (!commandPressed && _isPlainTextCharacter(event.character)) {
            setState(() {
              _symbolLookupQuery += event.character!;
              _symbolLookupIndex = 0;
            });
            return KeyEventResult.handled;
          }
      }
    }
    if (_surroundLookupOpen) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.escape:
          _closeSurroundLookup();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          _moveSurroundLookupSelection(1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp:
          _moveSurroundLookupSelection(-1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.numpadEnter:
        case LogicalKeyboardKey.tab:
          return _applySelectedSurroundTemplate()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        default:
          if (!commandPressed && _isPlainTextCharacter(event.character)) {
            setState(() {
              _surroundLookupOpen = false;
            });
          }
      }
    }
    if (_completionLookupOpen) {
      if (event.logicalKey == LogicalKeyboardKey.keyQ &&
          (commandPressed || !_isPlainTextCharacter(event.character))) {
        return _openCompletionQuickDocumentation()
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      }
      switch (event.logicalKey) {
        case LogicalKeyboardKey.escape:
          _closeCompletionLookup();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          _moveCompletionLookupSelection(1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp:
          _moveCompletionLookupSelection(-1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.numpadEnter:
        case LogicalKeyboardKey.tab:
          return _applySelectedCompletion()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        default:
          if (!commandPressed && _isPlainTextCharacter(event.character)) {
            setState(() {
              _completionLookupOpen = false;
            });
          }
      }
    }

    if ((commandPressed || altPressed) &&
        (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight)) {
      widget.controller.moveCaretByWord(
        forward: event.logicalKey == LogicalKeyboardKey.arrowRight,
        expandSelection: shiftPressed,
      );
      return KeyEventResult.handled;
    }

    if (commandPressed &&
        altPressed &&
        event.logicalKey == LogicalKeyboardKey.keyT) {
      return _openSurroundLookup()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    if (commandPressed &&
        altPressed &&
        !shiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyV) {
      return _openIntroduceVariablePanel()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    if (commandPressed &&
        altPressed &&
        !shiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyM) {
      return _openExtractFunctionPanel()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    if (commandPressed &&
        altPressed &&
        !shiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyN) {
      return _openInlineVariablePanel()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    if (commandPressed &&
        altPressed &&
        shiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyN) {
      return _openSymbolLookup()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    if (!commandPressed &&
        altPressed &&
        event.logicalKey == LogicalKeyboardKey.delete) {
      final opened = _openSafeDeletePanel();
      if (opened) {
        return KeyEventResult.handled;
      }
    }

    if ((commandPressed || altPressed) &&
        (event.logicalKey == LogicalKeyboardKey.backspace ||
            event.logicalKey == LogicalKeyboardKey.delete)) {
      return widget.controller.deleteToWordBoundary(
            forward: event.logicalKey == LogicalKeyboardKey.delete,
          )
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    if (commandPressed &&
        (event.logicalKey == LogicalKeyboardKey.minus ||
            event.logicalKey == LogicalKeyboardKey.numpadSubtract)) {
      return _toggleSemanticBlockAtSelection()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    if (commandPressed &&
        !altPressed &&
        !shiftPressed &&
        event.logicalKey == LogicalKeyboardKey.f6) {
      return _openChangeSignaturePanel()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    if (commandPressed) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.keyB:
          return widget.controller.selectDefinitionAtSelection()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        case LogicalKeyboardKey.keyC:
          return _copySelectionToClipboard()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        case LogicalKeyboardKey.keyD:
          return widget.controller.duplicateLineOrSelection()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        case LogicalKeyboardKey.space:
          return _openCompletionLookup()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        case LogicalKeyboardKey.keyJ:
          return (shiftPressed
                  ? widget.controller.joinLinesAtSelection()
                  : widget.controller.applyBestCompletionAtSelection())
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        case LogicalKeyboardKey.keyM:
          if (!shiftPressed) {
            return KeyEventResult.ignored;
          }
          return widget.controller.moveCaretToMatchingBrace()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        case LogicalKeyboardKey.keyQ:
          return _openQuickDocumentation()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        case LogicalKeyboardKey.keyP:
          return _openParameterInfo()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        case LogicalKeyboardKey.slash:
        case LogicalKeyboardKey.numpadDivide:
          return widget.controller.toggleLineComment()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        case LogicalKeyboardKey.keyW:
          return (shiftPressed
                  ? widget.controller.shrinkSelectionStructurally()
                  : widget.controller.extendSelectionStructurally())
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        case LogicalKeyboardKey.keyY:
          if (shiftPressed) {
            return KeyEventResult.ignored;
          }
          return widget.controller.deleteLineAtSelection()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
      }
      return KeyEventResult.ignored;
    }

    if (altPressed && event.logicalKey == LogicalKeyboardKey.f7) {
      return _openUsagesPanel()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (altPressed &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      return _openQuickFixLookup()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (shiftPressed && event.logicalKey == LogicalKeyboardKey.f6) {
      return _openInlineRename()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (altPressed && shiftPressed) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowUp:
          return widget.controller.moveLineOrSelection(down: false)
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        case LogicalKeyboardKey.arrowDown:
          return widget.controller.moveLineOrSelection(down: true)
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
      }
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        widget.controller.moveCaretHorizontally(
          -1,
          expandSelection: shiftPressed,
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        widget.controller.moveCaretHorizontally(
          1,
          expandSelection: shiftPressed,
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        widget.controller.moveCaretVertically(
          -1,
          expandSelection: shiftPressed,
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        widget.controller.moveCaretVertically(1, expandSelection: shiftPressed);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.home:
        widget.controller.moveCaretToSmartLineStart(
          expandSelection: shiftPressed,
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.end:
        widget.controller.moveCaretToLineBoundary(
          end: true,
          expandSelection: shiftPressed,
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.backspace:
        return _handleStructuralTextKey(
          () => _textInputClient.deleteBackward(),
        );
      case LogicalKeyboardKey.delete:
        return _handleStructuralTextKey(() => _textInputClient.deleteForward());
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        return _handleStructuralTextKey(() => _textInputClient.insertNewline());
      case LogicalKeyboardKey.tab:
        if (shiftPressed) {
          return widget.controller.outdentLineOrSelection()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        }
        if (widget.controller.shouldIndentLineAtSelection &&
            widget.controller.indentLineOrSelection()) {
          return KeyEventResult.handled;
        }
        if (!shiftPressed &&
            widget.controller.applyTokenCompletionAtSelection()) {
          return KeyEventResult.handled;
        }
        return _handleStructuralTextKey(
          () => _textInputClient.insertPlainText('  '),
        );
      case LogicalKeyboardKey.f2:
        return (shiftPressed
                ? widget.controller.selectPreviousDiagnosticAtSelection()
                : widget.controller.selectNextDiagnosticAtSelection())
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      case LogicalKeyboardKey.f3:
        return (shiftPressed
                ? widget.controller.selectPreviousReferenceAtSelection()
                : widget.controller.selectNextReferenceAtSelection())
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      default:
        return KeyEventResult.ignored;
    }
  }

  bool _copySelectionToClipboard() {
    final selectedSourceText = widget.controller.selectedSourceText;
    if (selectedSourceText == null) {
      return false;
    }
    Clipboard.setData(ClipboardData(text: selectedSourceText));
    return true;
  }

  bool _isPlainTextCharacter(String? character) {
    if (character == null || character.isEmpty) {
      return false;
    }

    final codeUnit = character.codeUnitAt(0);
    if (codeUnit < 0x20 || codeUnit == 0x7F) {
      return false;
    }

    return character != '\n' && character != '\r';
  }

  void _openCompletionLookupAfterTyping(String character) {
    if (!_shouldAutoPopupCompletion(character)) {
      return;
    }
    final completions = widget.completions;
    if (completions.isEmpty) {
      return;
    }
    final activeSpan = widget.controller.tokenAtSelection;
    if (activeSpan == null ||
        activeSpan.kind == TokenKind.comment ||
        activeSpan.kind == TokenKind.string ||
        activeSpan.kind == TokenKind.number ||
        activeSpan.kind == TokenKind.whitespace) {
      return;
    }
    _completionLookupOpen = true;
    _completionLookupIndex = 0;
    _surroundLookupOpen = false;
    _symbolLookupOpen = false;
    _quickFixLookupOpen = false;
  }

  bool _shouldAutoPopupCompletion(String character) {
    if (character.length != 1) {
      return false;
    }
    final codeUnit = character.codeUnitAt(0);
    return (codeUnit >= 0x30 && codeUnit <= 0x39) ||
        (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
        (codeUnit >= 0x61 && codeUnit <= 0x7A) ||
        character == '_' ||
        character == '@' ||
        character == '#';
  }

  CompletionItem? _selectedCompletionItem() {
    if (widget.completions.isEmpty) {
      return null;
    }
    final selectedIndex = _completionLookupIndex
        .clamp(0, widget.completions.length - 1)
        .toInt();
    return widget.completions[selectedIndex];
  }

  bool _toggleSemanticBlockAtSelection() {
    final semanticBlock = _semanticBlockAtSelection();
    if (semanticBlock == null) {
      return false;
    }
    _toggleSemanticBlock(semanticBlock);
    return true;
  }

  _SemanticLineBlock? _semanticBlockAtSelection() {
    if (!widget.renderPlan.activeLayers.contains(EditorRenderLayer.overlay)) {
      return null;
    }

    final lineStarts = widget.document.lineStarts;
    final selectionLine = widget.document
        .positionForOffset(widget.selection.extentOffset)
        .line;
    final candidates =
        _resolveLineBlocks(
              document: widget.document,
              lineStarts: lineStarts,
              blocks: widget.analysis.semanticBlocks,
            )
            .where(
              (block) =>
                  block.startLine <= selectionLine &&
                  selectionLine <= block.endLine &&
                  block.endLine > block.startLine,
            )
            .toList(growable: false);
    if (candidates.isEmpty) {
      return null;
    }

    candidates.sort((left, right) {
      final leftSpan = left.endLine - left.startLine;
      final rightSpan = right.endLine - right.startLine;
      return leftSpan.compareTo(rightSpan);
    });
    return candidates.first;
  }

  void _toggleSemanticBlock(_SemanticLineBlock block) {
    final key = _semanticBlockKey(block);
    setState(() {
      if (!_collapsedSemanticBlockKeys.add(key)) {
        _collapsedSemanticBlockKeys.remove(key);
      }
    });
  }

  bool _openInlineRename() {
    final definition = widget.controller.definitionAtSelection;
    if (definition == null) {
      return false;
    }

    setState(() {
      _inlineRenameOpen = true;
      _inlineRenameError = null;
      _inlineRenameController.text = definition.symbol.name;
      _inlineRenameController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: definition.symbol.name.length,
      );
      _introduceVariablePanelOpen = false;
      _extractFunctionPanelOpen = false;
      _changeSignaturePanelOpen = false;
      _safeDeletePanelOpen = false;
      _inlineVariablePanelOpen = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _inlineRenameOpen) {
        _inlineRenameFocusNode.requestFocus();
      }
    });
    return true;
  }

  void _closeInlineRename() {
    setState(() {
      _inlineRenameOpen = false;
      _inlineRenameError = null;
    });
    _focusNode.requestFocus();
  }

  bool _applyInlineRename() {
    final newName = _inlineRenameController.text.trim();
    final renamePlan = widget.controller.renamePlanAtSelection(newName);
    if (renamePlan != null &&
        !renamePlan.hasConflicts &&
        widget.controller.applyRename(newName)) {
      setState(() {
        _inlineRenameOpen = false;
        _inlineRenameError = null;
      });
      _focusNode.requestFocus();
      return true;
    }

    setState(() {
      _inlineRenameError = _renameUnavailableMessage(newName, renamePlan);
    });
    return false;
  }

  String _renameUnavailableMessage(String newName, RenamePlan? renamePlan) {
    if (newName.isEmpty) {
      return 'Enter a Styio identifier.';
    }
    if (renamePlan != null && renamePlan.hasConflicts) {
      return _formatRenameConflict(renamePlan.conflicts.first);
    }
    return 'Invalid rename target.';
  }

  bool _openIntroduceVariablePanel() {
    if (widget.selection.isCollapsed) {
      return false;
    }
    final initialName = _availableIntroduceVariableName();
    if (widget.controller.introduceVariablePlanAtSelection(initialName) ==
        null) {
      return false;
    }
    setState(() {
      _introduceVariablePanelOpen = true;
      _introduceVariableError = null;
      _introduceVariableController.text = initialName;
      _introduceVariableController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: initialName.length,
      );
      _extractFunctionPanelOpen = false;
      _changeSignaturePanelOpen = false;
      _inlineVariablePanelOpen = false;
      _safeDeletePanelOpen = false;
      _completionLookupOpen = false;
      _completionLookupIndex = 0;
      _quickFixLookupOpen = false;
      _quickFixLookupIndex = 0;
      _symbolLookupOpen = false;
      _symbolLookupIndex = 0;
      _symbolLookupQuery = '';
      _surroundLookupOpen = false;
      _surroundLookupIndex = 0;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _introduceVariablePanelOpen) {
        _introduceVariableFocusNode.requestFocus();
      }
    });
    return true;
  }

  void _closeIntroduceVariablePanel() {
    setState(() {
      _introduceVariablePanelOpen = false;
      _introduceVariableError = null;
    });
    _focusNode.requestFocus();
  }

  bool _applyIntroduceVariable() {
    final name = _introduceVariableController.text.trim();
    final plan = widget.controller.introduceVariablePlanAtSelection(name);
    if (plan != null &&
        !plan.hasConflicts &&
        widget.controller.applyIntroduceVariableAtSelection(name)) {
      setState(() {
        _introduceVariablePanelOpen = false;
        _introduceVariableError = null;
      });
      _focusNode.requestFocus();
      return true;
    }

    setState(() {
      _introduceVariableError = _introduceVariableUnavailableMessage(plan);
    });
    return false;
  }

  String _introduceVariableUnavailableMessage(IntroduceVariablePlan? plan) {
    if (plan != null && plan.hasConflicts) {
      return _formatIntroduceVariableConflict(plan.conflicts.first);
    }
    return 'Select a Styio expression.';
  }

  String _formatIntroduceVariableConflict(IntroduceVariableConflict conflict) {
    return '${conflict.message} Conflict at '
        '${_formatUsageLocationForRange(conflict.range)}.';
  }

  String _availableIntroduceVariableName() {
    const baseName = 'extractedValue';
    final existingNames = {
      for (final symbol in widget.analysis.documentSymbols) symbol.name,
    };
    if (!existingNames.contains(baseName)) {
      return baseName;
    }
    for (var suffix = 2; suffix < 100; suffix += 1) {
      final candidate = '$baseName$suffix';
      if (!existingNames.contains(candidate)) {
        return candidate;
      }
    }
    return '${baseName}100';
  }

  bool _openExtractFunctionPanel() {
    if (widget.selection.isCollapsed) {
      return false;
    }
    final initialName = _availableExtractFunctionName();
    if (widget.controller.extractFunctionPlanAtSelection(initialName) == null) {
      return false;
    }
    setState(() {
      _extractFunctionPanelOpen = true;
      _extractFunctionError = null;
      _extractFunctionController.text = initialName;
      _extractFunctionController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: initialName.length,
      );
      _introduceVariablePanelOpen = false;
      _changeSignaturePanelOpen = false;
      _inlineVariablePanelOpen = false;
      _safeDeletePanelOpen = false;
      _completionLookupOpen = false;
      _completionLookupIndex = 0;
      _quickFixLookupOpen = false;
      _quickFixLookupIndex = 0;
      _symbolLookupOpen = false;
      _symbolLookupIndex = 0;
      _symbolLookupQuery = '';
      _surroundLookupOpen = false;
      _surroundLookupIndex = 0;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _extractFunctionPanelOpen) {
        _extractFunctionFocusNode.requestFocus();
      }
    });
    return true;
  }

  void _closeExtractFunctionPanel() {
    setState(() {
      _extractFunctionPanelOpen = false;
      _extractFunctionError = null;
    });
    _focusNode.requestFocus();
  }

  bool _applyExtractFunction() {
    final name = _extractFunctionController.text.trim();
    final plan = widget.controller.extractFunctionPlanAtSelection(name);
    if (plan != null &&
        !plan.hasConflicts &&
        widget.controller.applyExtractFunctionAtSelection(name)) {
      setState(() {
        _extractFunctionPanelOpen = false;
        _extractFunctionError = null;
      });
      _focusNode.requestFocus();
      return true;
    }

    setState(() {
      _extractFunctionError = _extractFunctionUnavailableMessage(plan);
    });
    return false;
  }

  String _extractFunctionUnavailableMessage(ExtractFunctionPlan? plan) {
    if (plan != null && plan.hasConflicts) {
      return _formatExtractFunctionConflict(plan.conflicts.first);
    }
    return 'Select Styio code.';
  }

  String _formatExtractFunctionConflict(ExtractFunctionConflict conflict) {
    return '${conflict.message} Conflict at '
        '${_formatUsageLocationForRange(conflict.range)}.';
  }

  String _availableExtractFunctionName() {
    const baseName = 'extractedFunction';
    final existingNames = {
      for (final symbol in widget.analysis.documentSymbols) symbol.name,
    };
    if (!existingNames.contains(baseName)) {
      return baseName;
    }
    for (var suffix = 2; suffix < 100; suffix += 1) {
      final candidate = '$baseName$suffix';
      if (!existingNames.contains(candidate)) {
        return candidate;
      }
    }
    return '${baseName}100';
  }

  bool _openChangeSignaturePanel() {
    final seedPlan = _changeSignatureSeedPlan();
    if (seedPlan == null) {
      return false;
    }
    final parameterText = seedPlan.originalParameters
        .map((parameter) => parameter.name)
        .join(', ');
    setState(() {
      _changeSignaturePanelOpen = true;
      _changeSignatureError = null;
      _changeSignatureNameController.text = seedPlan.originalName;
      _changeSignatureNameController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: seedPlan.originalName.length,
      );
      _changeSignatureParametersController.text = parameterText;
      _changeSignatureParametersController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: parameterText.length,
      );
      _inlineRenameOpen = false;
      _introduceVariablePanelOpen = false;
      _extractFunctionPanelOpen = false;
      _inlineVariablePanelOpen = false;
      _safeDeletePanelOpen = false;
      _completionLookupOpen = false;
      _completionLookupIndex = 0;
      _quickFixLookupOpen = false;
      _quickFixLookupIndex = 0;
      _symbolLookupOpen = false;
      _symbolLookupIndex = 0;
      _symbolLookupQuery = '';
      _surroundLookupOpen = false;
      _surroundLookupIndex = 0;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _changeSignaturePanelOpen) {
        _changeSignatureNameFocusNode.requestFocus();
      }
    });
    return true;
  }

  void _closeChangeSignaturePanel() {
    setState(() {
      _changeSignaturePanelOpen = false;
      _changeSignatureError = null;
    });
    _focusNode.requestFocus();
  }

  bool _applyChangeSignature() {
    final seedPlan = _changeSignatureSeedPlan();
    final parameterUpdates = seedPlan == null
        ? null
        : _changeSignatureParameterUpdates(seedPlan);
    final newName = _changeSignatureNameController.text.trim();
    final plan = parameterUpdates == null
        ? null
        : widget.controller.changeSignaturePlanAtSelection(
            newName: newName,
            parameters: parameterUpdates,
          );
    final updatesToApply = parameterUpdates;
    if (updatesToApply != null &&
        plan != null &&
        !plan.hasConflicts &&
        widget.controller.applyChangeSignatureAtSelection(
          newName: newName,
          parameters: updatesToApply,
        )) {
      setState(() {
        _changeSignaturePanelOpen = false;
        _changeSignatureError = null;
      });
      _focusNode.requestFocus();
      return true;
    }

    setState(() {
      _changeSignatureError = _changeSignatureUnavailableMessage(
        seedPlan: seedPlan,
        parameterUpdates: parameterUpdates,
        plan: plan,
      );
    });
    return false;
  }

  ChangeSignaturePlan? _changeSignatureSeedPlan() {
    final definition = widget.controller.definitionAtSelection;
    if (definition == null || definition.symbol.kind != SymbolKind.function) {
      return null;
    }
    return widget.controller.changeSignaturePlanAtSelection(
      newName: definition.symbol.name,
      parameters: const <ChangeSignatureParameterUpdate>[],
    );
  }

  List<ChangeSignatureParameterUpdate>? _changeSignatureParameterUpdates(
    ChangeSignaturePlan seedPlan,
  ) {
    final originalNames = seedPlan.originalParameters
        .map((parameter) => parameter.name)
        .toList(growable: false);
    final enteredNames = _changeSignatureParametersController.text
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);

    final originalNameSet = originalNames.toSet();
    final enteredNameSet = enteredNames.toSet();
    final reusesExistingParameters =
        enteredNameSet.length == enteredNames.length &&
        enteredNameSet.every(originalNameSet.contains);
    if (reusesExistingParameters) {
      return [
        for (final name in enteredNames)
          ChangeSignatureParameterUpdate(originalName: name, name: name),
      ];
    }

    if (enteredNames.length != originalNames.length) {
      return null;
    }

    return [
      for (var index = 0; index < originalNames.length; index += 1)
        ChangeSignatureParameterUpdate(
          originalName: originalNames[index],
          name: enteredNames[index],
        ),
    ];
  }

  String _changeSignatureUnavailableMessage({
    required ChangeSignaturePlan? seedPlan,
    required List<ChangeSignatureParameterUpdate>? parameterUpdates,
    required ChangeSignaturePlan? plan,
  }) {
    if (seedPlan == null) {
      return 'Place the caret on a Styio function.';
    }
    if (parameterUpdates == null) {
      return 'Enter up to ${seedPlan.originalParameters.length} comma-separated '
          'parameter${seedPlan.originalParameters.length == 1 ? '' : 's'}.';
    }
    if (plan != null && plan.hasConflicts) {
      return _formatChangeSignatureConflict(plan.conflicts.first);
    }
    return 'Enter a changed Styio function signature.';
  }

  String _formatChangeSignatureConflict(ChangeSignatureConflict conflict) {
    return '${conflict.message} Conflict at '
        '${_formatUsageLocationForRange(conflict.range)}.';
  }

  String _formatRenameConflict(RenameConflict conflict) {
    return '${conflict.message} Conflict at '
        '${_formatUsageLocationForRange(conflict.range)}.';
  }

  bool _openUsagesPanel() {
    if (widget.controller.definitionAtSelection == null ||
        widget.controller.referencesAtSelection.isEmpty) {
      return false;
    }
    setState(() {
      _usagesPanelOpen = true;
    });
    return true;
  }

  void _closeUsagesPanel() {
    setState(() {
      _usagesPanelOpen = false;
    });
    _focusNode.requestFocus();
  }

  bool _openSafeDeletePanel() {
    if (widget.controller.safeDeletePlanAtSelection == null) {
      return false;
    }
    setState(() {
      _safeDeletePanelOpen = true;
      _extractFunctionPanelOpen = false;
      _introduceVariablePanelOpen = false;
      _changeSignaturePanelOpen = false;
      _inlineVariablePanelOpen = false;
      _completionLookupOpen = false;
      _completionLookupIndex = 0;
      _quickFixLookupOpen = false;
      _quickFixLookupIndex = 0;
      _symbolLookupOpen = false;
      _symbolLookupIndex = 0;
      _symbolLookupQuery = '';
      _surroundLookupOpen = false;
      _surroundLookupIndex = 0;
    });
    return true;
  }

  void _closeSafeDeletePanel() {
    setState(() {
      _safeDeletePanelOpen = false;
    });
    _focusNode.requestFocus();
  }

  bool _applySafeDelete() {
    final applied = widget.controller.applySafeDeleteAtSelection();
    if (!applied) {
      return false;
    }
    setState(() {
      _safeDeletePanelOpen = false;
    });
    _focusNode.requestFocus();
    return true;
  }

  bool _openInlineVariablePanel() {
    if (widget.controller.inlineVariablePlanAtSelection == null) {
      return false;
    }
    setState(() {
      _inlineVariablePanelOpen = true;
      _extractFunctionPanelOpen = false;
      _introduceVariablePanelOpen = false;
      _changeSignaturePanelOpen = false;
      _safeDeletePanelOpen = false;
      _completionLookupOpen = false;
      _completionLookupIndex = 0;
      _quickFixLookupOpen = false;
      _quickFixLookupIndex = 0;
      _symbolLookupOpen = false;
      _symbolLookupIndex = 0;
      _symbolLookupQuery = '';
      _surroundLookupOpen = false;
      _surroundLookupIndex = 0;
    });
    return true;
  }

  void _closeInlineVariablePanel() {
    setState(() {
      _inlineVariablePanelOpen = false;
    });
    _focusNode.requestFocus();
  }

  bool _applyInlineVariable() {
    final applied = widget.controller.applyInlineVariableAtSelection();
    if (!applied) {
      return false;
    }
    setState(() {
      _inlineVariablePanelOpen = false;
    });
    _focusNode.requestFocus();
    return true;
  }

  bool _openQuickDocumentation() {
    if (widget.hover == null &&
        widget.controller.definitionAtSelection == null &&
        widget.activeToken == null) {
      return false;
    }
    setState(() {
      _quickDocumentationOpen = true;
      _quickDocumentationForCompletion = false;
    });
    return true;
  }

  bool _openCompletionQuickDocumentation() {
    if (_selectedCompletionItem() == null) {
      return false;
    }
    setState(() {
      _quickDocumentationOpen = true;
      _quickDocumentationForCompletion = true;
    });
    return true;
  }

  void _closeQuickDocumentation() {
    setState(() {
      _quickDocumentationOpen = false;
      _quickDocumentationForCompletion = false;
    });
    _focusNode.requestFocus();
  }

  bool _openParameterInfo() {
    if (widget.controller.parameterInfoAtSelection == null) {
      return false;
    }
    setState(() {
      _parameterInfoOpen = true;
    });
    return true;
  }

  void _closeParameterInfo() {
    setState(() {
      _parameterInfoOpen = false;
    });
    _focusNode.requestFocus();
  }

  bool _openCompletionLookup() {
    if (widget.completions.isEmpty) {
      return false;
    }
    setState(() {
      _completionLookupOpen = true;
      _completionLookupIndex = 0;
      _symbolLookupOpen = false;
      _symbolLookupIndex = 0;
      _symbolLookupQuery = '';
      _quickFixLookupOpen = false;
      _quickFixLookupIndex = 0;
    });
    return true;
  }

  void _closeCompletionLookup() {
    setState(() {
      _completionLookupOpen = false;
      if (_quickDocumentationForCompletion) {
        _quickDocumentationOpen = false;
        _quickDocumentationForCompletion = false;
      }
    });
    _focusNode.requestFocus();
  }

  void _moveCompletionLookupSelection(int delta) {
    if (widget.completions.isEmpty) {
      _closeCompletionLookup();
      return;
    }
    setState(() {
      _completionLookupIndex =
          (_completionLookupIndex + delta) % widget.completions.length;
      if (_completionLookupIndex < 0) {
        _completionLookupIndex += widget.completions.length;
      }
    });
  }

  bool _applySelectedCompletion() {
    if (widget.completions.isEmpty) {
      _closeCompletionLookup();
      return false;
    }
    final selectedIndex = _completionLookupIndex
        .clamp(0, widget.completions.length - 1)
        .toInt();
    widget.controller.applyCompletionItem(widget.completions[selectedIndex]);
    setState(() {
      _completionLookupOpen = false;
      _completionLookupIndex = 0;
      if (_quickDocumentationForCompletion) {
        _quickDocumentationOpen = false;
        _quickDocumentationForCompletion = false;
      }
    });
    _focusNode.requestFocus();
    return true;
  }

  void _applyCompletionFromLookup(CompletionItem item) {
    widget.controller.applyCompletionItem(item);
    setState(() {
      _completionLookupOpen = false;
      _completionLookupIndex = 0;
      if (_quickDocumentationForCompletion) {
        _quickDocumentationOpen = false;
        _quickDocumentationForCompletion = false;
      }
    });
    _focusNode.requestFocus();
  }

  bool _openSurroundLookup() {
    if (widget.controller.surroundTemplatesAtSelection.isEmpty) {
      return false;
    }
    setState(() {
      _surroundLookupOpen = true;
      _surroundLookupIndex = 0;
      _symbolLookupOpen = false;
      _symbolLookupIndex = 0;
      _symbolLookupQuery = '';
      _quickFixLookupOpen = false;
      _quickFixLookupIndex = 0;
    });
    return true;
  }

  void _closeSurroundLookup() {
    setState(() {
      _surroundLookupOpen = false;
    });
    _focusNode.requestFocus();
  }

  void _moveSurroundLookupSelection(int delta) {
    final templates = widget.controller.surroundTemplatesAtSelection;
    if (templates.isEmpty) {
      _closeSurroundLookup();
      return;
    }
    setState(() {
      _surroundLookupIndex = (_surroundLookupIndex + delta) % templates.length;
      if (_surroundLookupIndex < 0) {
        _surroundLookupIndex += templates.length;
      }
    });
  }

  bool _applySelectedSurroundTemplate() {
    final templates = widget.controller.surroundTemplatesAtSelection;
    if (templates.isEmpty) {
      _closeSurroundLookup();
      return false;
    }
    final selectedIndex = _surroundLookupIndex
        .clamp(0, templates.length - 1)
        .toInt();
    widget.controller.applySurroundTemplateAtSelection(
      templates[selectedIndex],
    );
    setState(() {
      _surroundLookupOpen = false;
      _surroundLookupIndex = 0;
    });
    _focusNode.requestFocus();
    return true;
  }

  bool _openSymbolLookup() {
    if (widget.analysis.documentSymbols.isEmpty) {
      return false;
    }
    setState(() {
      _symbolLookupOpen = true;
      _symbolLookupIndex = 0;
      _symbolLookupQuery = '';
      _completionLookupOpen = false;
      _completionLookupIndex = 0;
      _surroundLookupOpen = false;
      _surroundLookupIndex = 0;
      _quickFixLookupOpen = false;
      _quickFixLookupIndex = 0;
    });
    return true;
  }

  void _closeSymbolLookup() {
    setState(() {
      _symbolLookupOpen = false;
      _symbolLookupIndex = 0;
      _symbolLookupQuery = '';
    });
    _focusNode.requestFocus();
  }

  List<DocumentSymbol> _symbolLookupMatches() {
    final query = _symbolLookupQuery.trim();
    if (query.isEmpty) {
      return widget.analysis.documentSymbols;
    }
    return widget.analysis.documentSymbols
        .where((symbol) => _matchesSymbolLookupQuery(symbol, query))
        .toList(growable: false);
  }

  bool _matchesSymbolLookupQuery(DocumentSymbol symbol, String query) {
    final normalizedQuery = query.toLowerCase();
    final normalizedName = symbol.name.toLowerCase();
    return normalizedName.contains(normalizedQuery) ||
        _charactersAppearInOrder(normalizedQuery, normalizedName);
  }

  bool _charactersAppearInOrder(String needle, String haystack) {
    if (needle.isEmpty) {
      return true;
    }
    var needleIndex = 0;
    for (var index = 0; index < haystack.length; index += 1) {
      if (haystack.codeUnitAt(index) == needle.codeUnitAt(needleIndex)) {
        needleIndex += 1;
        if (needleIndex == needle.length) {
          return true;
        }
      }
    }
    return false;
  }

  void _moveSymbolLookupSelection(int delta) {
    final symbols = _symbolLookupMatches();
    if (symbols.isEmpty) {
      return;
    }
    setState(() {
      _symbolLookupIndex = (_symbolLookupIndex + delta) % symbols.length;
      if (_symbolLookupIndex < 0) {
        _symbolLookupIndex += symbols.length;
      }
    });
  }

  bool _applySelectedSymbol() {
    final symbols = _symbolLookupMatches();
    if (symbols.isEmpty) {
      return false;
    }
    final selectedIndex = _symbolLookupIndex
        .clamp(0, symbols.length - 1)
        .toInt();
    final applied = widget.controller.selectDocumentSymbol(
      symbols[selectedIndex],
    );
    if (!applied) {
      return false;
    }
    setState(() {
      _symbolLookupOpen = false;
      _symbolLookupIndex = 0;
      _symbolLookupQuery = '';
    });
    _focusNode.requestFocus();
    return true;
  }

  void _selectSymbolFromLookup(DocumentSymbol symbol) {
    if (!widget.controller.selectDocumentSymbol(symbol)) {
      return;
    }
    setState(() {
      _symbolLookupOpen = false;
      _symbolLookupIndex = 0;
      _symbolLookupQuery = '';
    });
    _focusNode.requestFocus();
  }

  List<DiagnosticQuickFix> _quickFixLookupItems() {
    return widget.controller.contextActionsAtSelection;
  }

  bool _openQuickFixLookup() {
    if (_quickFixLookupItems().isEmpty) {
      return false;
    }
    setState(() {
      _quickFixLookupOpen = true;
      _quickFixLookupIndex = 0;
      _completionLookupOpen = false;
      _completionLookupIndex = 0;
      _surroundLookupOpen = false;
      _surroundLookupIndex = 0;
      _symbolLookupOpen = false;
      _symbolLookupIndex = 0;
      _symbolLookupQuery = '';
    });
    return true;
  }

  void _closeQuickFixLookup() {
    setState(() {
      _quickFixLookupOpen = false;
      _quickFixLookupIndex = 0;
    });
    _focusNode.requestFocus();
  }

  void _moveQuickFixLookupSelection(int delta) {
    final quickFixes = _quickFixLookupItems();
    if (quickFixes.isEmpty) {
      _closeQuickFixLookup();
      return;
    }
    setState(() {
      _quickFixLookupIndex = (_quickFixLookupIndex + delta) % quickFixes.length;
      if (_quickFixLookupIndex < 0) {
        _quickFixLookupIndex += quickFixes.length;
      }
    });
  }

  bool _applySelectedQuickFix() {
    final quickFixes = _quickFixLookupItems();
    if (quickFixes.isEmpty) {
      _closeQuickFixLookup();
      return false;
    }
    final selectedIndex = _quickFixLookupIndex
        .clamp(0, quickFixes.length - 1)
        .toInt();
    widget.controller.applyDiagnosticQuickFix(quickFixes[selectedIndex]);
    setState(() {
      _quickFixLookupOpen = false;
      _quickFixLookupIndex = 0;
    });
    _focusNode.requestFocus();
    return true;
  }

  void _applyQuickFixFromLookup(DiagnosticQuickFix quickFix) {
    widget.controller.applyDiagnosticQuickFix(quickFix);
    setState(() {
      _quickFixLookupOpen = false;
      _quickFixLookupIndex = 0;
    });
    _focusNode.requestFocus();
  }

  void _applySurroundTemplateFromLookup(SurroundTemplate template) {
    widget.controller.applySurroundTemplateAtSelection(template);
    setState(() {
      _surroundLookupOpen = false;
      _surroundLookupIndex = 0;
    });
    _focusNode.requestFocus();
  }

  void _handleLineTapDown(int lineIndex, TapDownDetails details) {
    _focusAndAttachInput();
    _dragBaseOffset = null;
    widget.controller.selectCollapsed(
      _offsetForLocalPosition(
        originLineIndex: lineIndex,
        localPosition: details.localPosition,
      ),
    );
  }

  void _handleLinePanStart(int lineIndex, DragStartDetails details) {
    _focusAndAttachInput();
    final offset = _offsetForLocalPosition(
      originLineIndex: lineIndex,
      localPosition: details.localPosition,
    );
    _dragBaseOffset = offset;
    widget.controller.selectRange(baseOffset: offset, extentOffset: offset);
  }

  void _handleLinePanUpdate(int lineIndex, DragUpdateDetails details) {
    final baseOffset = _dragBaseOffset;
    if (baseOffset == null) {
      return;
    }
    widget.controller.selectRange(
      baseOffset: baseOffset,
      extentOffset: _offsetForLocalPosition(
        originLineIndex: lineIndex,
        localPosition: details.localPosition,
      ),
    );
  }

  void _handleLinePanEnd(DragEndDetails details) {
    _dragBaseOffset = null;
  }

  int _offsetForLocalPosition({
    required int originLineIndex,
    required Offset localPosition,
  }) {
    final lineDelta = (localPosition.dy / _estimatedLineHeight).floor();
    final targetLine = (originLineIndex + lineDelta).clamp(
      0,
      widget.document.lineCount - 1,
    );
    final lineText = widget.document.lineAt(targetLine);
    final relativeDx = (localPosition.dx - _gutterWidth).clamp(
      0.0,
      double.infinity,
    );
    final column = (relativeDx / _estimatedCharacterWidth).round().clamp(
      0,
      lineText.length,
    );
    return widget.document.offsetForLineColumn(
      line: targetLine,
      column: column,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lineStarts = widget.document.lineStarts;
    final semanticBlocks =
        !_usesHighVolumeRenderBackend &&
            widget.showSemanticBlockCards &&
            widget.renderPlan.activeLayers.contains(EditorRenderLayer.overlay)
        ? _resolveLineBlocks(
            document: widget.document,
            lineStarts: lineStarts,
            blocks: widget.analysis.semanticBlocks,
          )
        : const <_SemanticLineBlock>[];
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            widget.viewportProfile.isMobile ||
            constraints.maxWidth < 480 ||
            constraints.maxHeight < 300;
        final dense =
            (widget.viewportProfile.isMobile && constraints.maxWidth < 520) ||
            constraints.maxWidth < 380 ||
            constraints.maxHeight < 240;
        final cramped = constraints.maxHeight < 120;
        final contentPadding = widget.showDebugChrome
            ? dense
                  ? 12.0
                  : 18.0
            : 8.0;
        final scrollOffset = _sourceScrollController.hasClients
            ? _sourceScrollController.offset
            : _sourceScrollController.initialScrollOffset;
        final viewportBinding =
            EditorRenderViewportBinding.fromScrollControllerFacts(
              scrollOffsetPixels: scrollOffset,
              viewportHeightPixels: constraints.maxHeight,
              lineHeightPixels: _estimatedLineHeight,
              overscanLineCount: dense ? 4 : 8,
              totalLineCount: widget.document.lineCount,
            );
        final renderPipelinePlan = EditorRenderPipelinePlan.fromRenderFacts(
          renderPlan: widget.renderPlan,
          lineCount: widget.document.lineCount,
          viewportBinding: viewportBinding,
          maxRenderedLines: _maxRenderedPreviewLines,
        );
        final degradationState = EditorLargeFileDegradation.forLineCount(
          widget.document.lineCount,
        );
        final viewportLineCap =
            EditorRenderedInputSampleProtocol.viewportLineCap(
              viewportLineCapacity: viewportBinding.viewportLineCapacity,
              overscanLineCount: dense ? 4 : 8,
              hardCap: _maxRenderedPreviewLines,
            );
        final effectiveSemanticBlocks =
            degradationState ==
                EditorLargeFileDegradation.largeFileReducedDecorations
            ? const <_SemanticLineBlock>[]
            : semanticBlocks;
        if (_usesHighVolumeRenderBackend) {
          _schedulePendingCaretReveal();
        }

        final primary = widget.controller.selectionSet.primarySelection;
        final primaryPosition = widget.document.positionForOffset(
          primary.extentOffset,
        );
        final semanticsValue = _textInputClient.currentTextEditingValue!;
        final semanticsDocumentValue = widget.document.lineCount >= 10000
            ? '${widget.document.lineCount}-line generated document'
            : semanticsValue.text;
        return Actions(
          actions: <Type, Action<Intent>>{
            EditorRequestKeyboardIntent:
                CallbackAction<EditorRequestKeyboardIntent>(
                  onInvoke: (_) {
                    _focusAndAttachInput();
                    return null;
                  },
                ),
          },
          child: Focus(
            key: const ValueKey('source-buffer-focus'),
            focusNode: _focusNode,
            onKeyEvent: _handleKeyEvent,
            child: KeyedSubtree(
              key: const ValueKey('source-input-status'),
              child: Semantics(
                key: const ValueKey('source-buffer-semantics'),
                container: true,
                explicitChildNodes: false,
                textField: true,
                multiline: true,
                focusable: true,
                focused: _focusNode.hasFocus,
                value: semanticsDocumentValue,
                textDirection: Directionality.of(context),
                label:
                    '${widget.controller.selectionSet.selections.length} selections, '
                    'primary line ${primaryPosition.line + 1} column ${primaryPosition.column + 1}',
                hint:
                    '${_textInputClient.isComposing ? 'composition active' : 'composition idle'}, '
                    '${_textInputClient.status}',
                onSetText: _textInputClient.replaceAllText,
                onSetSelection: _textInputClient.selectFromSemantics,
                onMoveCursorForwardByCharacter: (extend) {
                  widget.controller.moveCaretHorizontally(
                    1,
                    expandSelection: extend,
                  );
                },
                onMoveCursorBackwardByCharacter: (extend) {
                  widget.controller.moveCaretHorizontally(
                    -1,
                    expandSelection: extend,
                  );
                },
                onFocus: () => _focusSourcePane(attachInput: false),
                child: _SourceBufferTextSelectionSemantics(
                  textSelection: semanticsValue.selection,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _focusAndAttachInput,
                    child: Container(
                      key: const ValueKey('source-buffer-surface'),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(
                          widget.showDebugChrome ? 18 : 0,
                        ),
                        border: Border.all(
                          color: _focusNode.hasFocus
                              ? VityoWorkbenchTokens.of(context).focus
                              : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      padding: widget.showDebugChrome
                          ? EdgeInsets.all(cramped ? 8 : contentPadding)
                          : EdgeInsets.symmetric(vertical: contentPadding),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          KeyedSubtree(
                            key: ValueKey(
                              'source-document-revision-${widget.document.revision}',
                            ),
                            child: const SizedBox.shrink(),
                          ),
                          if (widget.showDebugChrome && !cramped)
                            _HorizontalChipStrip(
                              height: 36,
                              children: [
                                Text(
                                  'Source Buffer',
                                  style: theme.textTheme.titleMedium,
                                ),
                                _CapabilityPill(
                                  label: _focusNode.hasFocus
                                      ? 'editing'
                                      : 'click to focus',
                                ),
                                _CapabilityPill(label: _textInputClient.status),
                                _CapabilityPill(
                                  label: viewportBinding.boundToScrollController
                                      ? 'viewport bound'
                                      : 'viewport unbound',
                                ),
                                _CapabilityPill(
                                  label:
                                      'visible ${viewportBinding.viewportFirstLine + 1}+${viewportBinding.viewportLineCapacity}',
                                ),
                                _CapabilityPill(
                                  label:
                                      'renderer ${renderPipelinePlan.rendererKind}',
                                ),
                              ],
                            ),
                          if (widget.showDebugChrome && !dense && !cramped) ...[
                            const SizedBox(height: 6),
                            Text(
                              compact
                                  ? 'Glyph substitution stays display-only while one editor surface owns input.'
                                  : 'Platform text input is live. Token spans color the buffer, semantic ranges add structure, and glyph substitution stays display-only.',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                          if (widget.showDebugChrome && !cramped)
                            const SizedBox(height: 14),
                          Expanded(
                            child: _usesHighVolumeRenderBackend
                                ? _buildHighVolumeViewport(
                                    context,
                                    lineStarts: lineStarts,
                                    degradationState: degradationState,
                                    viewportBinding: viewportBinding,
                                    cacheLineCount: dense ? 8 : 16,
                                  )
                                : ListView(
                                    key: const ValueKey('source-buffer-scroll'),
                                    controller: _sourceScrollController,
                                    children: [
                                      KeyedSubtree(
                                        key: ValueKey(
                                          'source-editor-degradation-${degradationState.label}',
                                        ),
                                        child: const SizedBox.shrink(),
                                      ),
                                      if (_textInputClient.isComposing)
                                        Text(
                                          _textInputClient.provisionalText,
                                          key: const ValueKey(
                                            'source-composition-range',
                                          ),
                                          style: theme.textTheme.bodyMedium
                                              ?.copyWith(
                                                backgroundColor: const Color(
                                                  0x337A65B3,
                                                ),
                                                decoration:
                                                    TextDecoration.underline,
                                              ),
                                        ),
                                      for (
                                        var index = 0;
                                        index <
                                            widget
                                                .controller
                                                .selectionSet
                                                .selections
                                                .length;
                                        index += 1
                                      )
                                        SizedBox.shrink(
                                          key: ValueKey(
                                            'source-selection-item-$index',
                                          ),
                                        ),
                                      KeyedSubtree(
                                        key: ValueKey(
                                          viewportBinding
                                                  .boundToScrollController
                                              ? 'source-viewport-binding-bound'
                                              : 'source-viewport-binding-unbound',
                                        ),
                                        child: const SizedBox.shrink(),
                                      ),
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
                                      ..._buildPreviewChildren(
                                        context,
                                        controller: widget.controller,
                                        viewportProfile: widget.viewportProfile,
                                        hover: widget.hover,
                                        completions: widget.completions,
                                        activeReferences:
                                            widget.activeReferences,
                                        activeToken: widget.activeToken,
                                        activeSemanticKind:
                                            widget.activeSemanticKind,
                                        document: widget.document,
                                        selection: widget.selection,
                                        analysis: widget.analysis,
                                        renderPlan: widget.renderPlan,
                                        semanticThemeBinding:
                                            widget.semanticThemeBinding,
                                        lineStarts: lineStarts,
                                        semanticBlocks: effectiveSemanticBlocks,
                                        renderWindow:
                                            renderPipelinePlan.renderWindow,
                                        maxRenderedLineCount: viewportLineCap,
                                        collapsedSemanticBlockKeys:
                                            _collapsedSemanticBlockKeys,
                                        onToggleSemanticBlock:
                                            _toggleSemanticBlock,
                                        onTapLine: _handleLineTapDown,
                                        onPanStartLine: _handleLinePanStart,
                                        onPanUpdateLine: _handleLinePanUpdate,
                                        onPanEnd: _handleLinePanEnd,
                                        showInlineLanguageFeedback:
                                            widget.showInlineLanguageFeedback,
                                        compactInlineLanguageFeedback: widget
                                            .compactInlineLanguageFeedback,
                                      ),
                                    ],
                                  ),
                          ),
                        ],
                      ),
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

  Widget _buildQuickFixLookupPanel(BuildContext context) {
    final theme = Theme.of(context);
    final quickFixes = _quickFixLookupItems();
    final diagnostics = widget.controller.diagnosticsAtSelection;
    final actionCount = quickFixes.length;
    final selectedIndex = quickFixes.isEmpty
        ? -1
        : _quickFixLookupIndex.clamp(0, quickFixes.length - 1).toInt();
    final selectedQuickFix = selectedIndex < 0
        ? null
        : quickFixes[selectedIndex];

    return Material(
      key: const ValueKey('source-quick-fix-lookup'),
      color: VityoWorkbenchTokens.of(context).elevated,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.tips_and_updates_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Context Actions',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _InlineActionChip(
                  key: const ValueKey('source-quick-fix-close'),
                  icon: Icons.close_rounded,
                  label: 'Close',
                  onTap: _closeQuickFixLookup,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${diagnostics.length} diagnostic'
              '${diagnostics.length == 1 ? '' : 's'} at caret, '
              '$actionCount context action'
              '${actionCount == 1 ? '' : 's'}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (quickFixes.isEmpty)
              Text(
                'No context actions at the current caret.',
                style: theme.textTheme.bodySmall,
              )
            else
              for (var index = 0; index < quickFixes.length; index += 1) ...[
                _QuickFixLookupTile(
                  key: ValueKey('source-quick-fix-item-$index'),
                  quickFix: quickFixes[index],
                  selected: index == selectedIndex,
                  onTap: () => _applyQuickFixFromLookup(quickFixes[index]),
                ),
                if (index < quickFixes.length - 1) const SizedBox(height: 6),
              ],
            if (selectedQuickFix != null) ...[
              const SizedBox(height: 10),
              _buildQuickFixPreviewPanel(context, selectedQuickFix),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildQuickFixPreviewPanel(
    BuildContext context,
    DiagnosticQuickFix quickFix,
  ) {
    final theme = Theme.of(context);
    final edits = quickFix.edits;
    return Container(
      key: const ValueKey('source-quick-fix-preview'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: VityoWorkbenchTokens.of(context).region,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: VityoWorkbenchTokens.of(context).divider),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Preview ${edits.length} edit${edits.length == 1 ? '' : 's'}',
            style: theme.textTheme.bodySmall!.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          for (var index = 0; index < edits.length; index += 1) ...[
            Text(
              _formatQuickFixEditPreview(edits[index]),
              key: ValueKey('source-quick-fix-preview-edit-$index'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            if (index < edits.length - 1) const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }

  String _formatQuickFixEditPreview(FormattingEdit edit) {
    final start = edit.range.start.clamp(0, widget.document.length);
    final end = edit.range.end.clamp(start, widget.document.length);
    final range = SourceRange(start: start, end: end);
    final location = _formatUsageLocationForRange(range);
    final newText = _formatPreviewText(edit.newText);
    if (range.isCollapsed) {
      return 'Insert $newText at $location';
    }
    final oldText = _formatPreviewText(
      widget.document.text.substring(start, end),
    );
    if (edit.newText.isEmpty) {
      return 'Delete $oldText at $location';
    }
    return 'Replace $oldText with $newText at $location';
  }

  String _formatPreviewText(String text) {
    final escaped = _sanitizeUtf16ForPainting(text.replaceAll('\n', r'\n'));
    if (escaped.isEmpty) {
      return 'empty text';
    }
    const maxLength = 40;
    if (escaped.length <= maxLength) {
      return '`$escaped`';
    }
    final cut = _utf16ScalarFloor(escaped, maxLength - 1);
    return '`${escaped.substring(0, cut)}...`';
  }

  Widget _buildSymbolLookupPanel(BuildContext context) {
    final theme = Theme.of(context);
    final symbols = _symbolLookupMatches();
    final selectedIndex = symbols.isEmpty
        ? -1
        : _symbolLookupIndex.clamp(0, symbols.length - 1).toInt();
    final queryLabel = _symbolLookupQuery.isEmpty
        ? 'All current-file symbols'
        : _symbolLookupQuery;

    return Material(
      key: const ValueKey('source-symbol-lookup'),
      color: VityoWorkbenchTokens.of(context).elevated,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.manage_search_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Go to Symbol',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _InlineActionChip(
                  key: const ValueKey('source-symbol-lookup-close'),
                  icon: Icons.close_rounded,
                  label: 'Close',
                  onTap: _closeSymbolLookup,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              key: const ValueKey('source-symbol-lookup-query'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              decoration: BoxDecoration(
                color: VityoWorkbenchTokens.of(context).region,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: VityoWorkbenchTokens.of(context).divider,
                ),
              ),
              child: Text(
                queryLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall!.copyWith(
                  fontWeight: _symbolLookupQuery.isEmpty
                      ? FontWeight.w500
                      : FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (symbols.isEmpty)
              Text(
                'No current-file symbols match.',
                style: theme.textTheme.bodySmall,
              )
            else ...[
              Text(
                '${symbols.length} current-file symbol'
                '${symbols.length == 1 ? '' : 's'}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (var index = 0; index < symbols.length; index += 1) ...[
                _SymbolLookupTile(
                  key: ValueKey('source-symbol-lookup-item-$index'),
                  symbol: symbols[index],
                  selected: index == selectedIndex,
                  location: _formatUsageLocationForRange(
                    symbols[index].nameRange,
                  ),
                  onTap: () => _selectSymbolFromLookup(symbols[index]),
                ),
                if (index < symbols.length - 1) const SizedBox(height: 6),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInlineRenamePanel(BuildContext context) {
    final theme = Theme.of(context);
    final renameText = _inlineRenameController.text.trim();
    final renamePreview = widget.controller.renamePlanAtSelection(renameText);
    final definition = widget.controller.definitionAtSelection;
    final usageCount = widget.controller.referencesAtSelection.length;
    final helperText = renamePreview == null
        ? _inlineRenameError
        : renamePreview.hasConflicts
        ? _formatRenameConflict(renamePreview.conflicts.first)
        : 'Preview ${renamePreview.edits.length} edit'
              '${renamePreview.edits.length == 1 ? '' : 's'} across '
              '$usageCount current-file usage'
              '${usageCount == 1 ? '' : 's'}';

    return Material(
      key: const ValueKey('source-inline-rename-panel'),
      color: VityoWorkbenchTokens.of(context).elevated,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.drive_file_rename_outline_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    definition == null
                        ? 'Rename symbol'
                        : 'Rename ${definition.symbol.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('source-inline-rename-input'),
              focusNode: _inlineRenameFocusNode,
              controller: _inlineRenameController,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                labelText: 'New name',
                helperText: renamePreview == null || renamePreview.hasConflicts
                    ? null
                    : helperText,
                errorText: renamePreview == null || renamePreview.hasConflicts
                    ? helperText
                    : null,
              ),
              onChanged: (_) {
                setState(() {
                  _inlineRenameError = null;
                });
              },
              onSubmitted: (_) => _applyInlineRename(),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _InlineActionChip(
                  key: const ValueKey('source-inline-rename-apply'),
                  icon: Icons.check_rounded,
                  label: 'Refactor',
                  onTap: _applyInlineRename,
                ),
                _InlineActionChip(
                  key: const ValueKey('source-inline-rename-cancel'),
                  icon: Icons.close_rounded,
                  label: 'Cancel',
                  onTap: _closeInlineRename,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIntroduceVariablePanel(BuildContext context) {
    final theme = Theme.of(context);
    final variableName = _introduceVariableController.text.trim();
    final plan = widget.controller.introduceVariablePlanAtSelection(
      variableName,
    );
    final helperText = plan == null
        ? _introduceVariableError
        : plan.hasConflicts
        ? _formatIntroduceVariableConflict(plan.conflicts.first)
        : 'Preview ${plan.edits.length} edit'
              '${plan.edits.length == 1 ? '' : 's'} for '
              '` ${plan.expressionText} `';

    return Material(
      key: const ValueKey('source-introduce-variable-panel'),
      color: VityoWorkbenchTokens.of(context).elevated,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.add_box_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Introduce Variable',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('source-introduce-variable-input'),
              focusNode: _introduceVariableFocusNode,
              controller: _introduceVariableController,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                labelText: 'Variable name',
                helperText: plan == null || plan.hasConflicts
                    ? null
                    : helperText,
                errorText: plan == null || plan.hasConflicts
                    ? helperText
                    : null,
              ),
              onChanged: (_) {
                setState(() {
                  _introduceVariableError = null;
                });
              },
              onSubmitted: (_) => _applyIntroduceVariable(),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _InlineActionChip(
                  key: const ValueKey('source-introduce-variable-apply'),
                  icon: Icons.check_rounded,
                  label: 'Introduce',
                  onTap: _applyIntroduceVariable,
                ),
                _InlineActionChip(
                  key: const ValueKey('source-introduce-variable-cancel'),
                  icon: Icons.close_rounded,
                  label: 'Cancel',
                  onTap: _closeIntroduceVariablePanel,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExtractFunctionPanel(BuildContext context) {
    final theme = Theme.of(context);
    final functionName = _extractFunctionController.text.trim();
    final plan = widget.controller.extractFunctionPlanAtSelection(functionName);
    final duplicateCount = plan?.duplicateOccurrences.length ?? 0;
    final duplicateLabel = duplicateCount == 1 ? 'duplicate' : 'duplicates';
    final duplicateHelperSuffix = duplicateCount == 0
        ? ''
        : ', $duplicateCount $duplicateLabel';
    final duplicatePreviewSuffix = duplicateCount == 0
        ? ''
        : ' and $duplicateCount $duplicateLabel';
    final helperText = plan == null
        ? _extractFunctionError
        : plan.hasConflicts
        ? _formatExtractFunctionConflict(plan.conflicts.first)
        : 'Preview ${plan.edits.length} edit'
              '${plan.edits.length == 1 ? '' : 's'} and '
              '${plan.parameters.length} parameter'
              '${plan.parameters.length == 1 ? '' : 's'}'
              '$duplicateHelperSuffix';

    return Material(
      key: const ValueKey('source-extract-function-panel'),
      color: VityoWorkbenchTokens.of(context).elevated,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.functions_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Extract Function',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('source-extract-function-input'),
              focusNode: _extractFunctionFocusNode,
              controller: _extractFunctionController,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                labelText: 'Function name',
                helperText: plan == null || plan.hasConflicts
                    ? null
                    : helperText,
                errorText: plan == null || plan.hasConflicts
                    ? helperText
                    : null,
              ),
              onChanged: (_) {
                setState(() {
                  _extractFunctionError = null;
                });
              },
              onSubmitted: (_) => _applyExtractFunction(),
            ),
            if (plan != null && !plan.hasConflicts) ...[
              const SizedBox(height: 8),
              Text(
                'Replace selection'
                '$duplicatePreviewSuffix '
                'with `${plan.callText}`',
                key: const ValueKey('source-extract-function-preview'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _InlineActionChip(
                  key: const ValueKey('source-extract-function-apply'),
                  icon: Icons.check_rounded,
                  label: 'Extract',
                  onTap: _applyExtractFunction,
                ),
                _InlineActionChip(
                  key: const ValueKey('source-extract-function-cancel'),
                  icon: Icons.close_rounded,
                  label: 'Cancel',
                  onTap: _closeExtractFunctionPanel,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChangeSignaturePanel(BuildContext context) {
    final theme = Theme.of(context);
    final seedPlan = _changeSignatureSeedPlan();
    final parameterUpdates = seedPlan == null
        ? null
        : _changeSignatureParameterUpdates(seedPlan);
    final functionName = _changeSignatureNameController.text.trim();
    final plan = parameterUpdates == null
        ? null
        : widget.controller.changeSignaturePlanAtSelection(
            newName: functionName,
            parameters: parameterUpdates,
          );
    final helperText = plan == null
        ? _changeSignatureError ??
              _changeSignatureUnavailableMessage(
                seedPlan: seedPlan,
                parameterUpdates: parameterUpdates,
                plan: plan,
              )
        : plan.hasConflicts
        ? _formatChangeSignatureConflict(plan.conflicts.first)
        : 'Preview ${plan.edits.length} edit'
              '${plan.edits.length == 1 ? '' : 's'} across '
              '${plan.references.length} reference'
              '${plan.references.length == 1 ? '' : 's'}';
    final originalSignature = seedPlan == null
        ? ''
        : '${seedPlan.originalName}'
              '(${seedPlan.originalParameters.map((item) => item.name).join(', ')})';
    final nextSignature = plan == null
        ? ''
        : '${plan.newName}'
              '(${plan.newParameters.map((item) => item.name).join(', ')})';

    return Material(
      key: const ValueKey('source-change-signature-panel'),
      color: VityoWorkbenchTokens.of(context).elevated,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.tune_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Change Signature',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('source-change-signature-name-input'),
              focusNode: _changeSignatureNameFocusNode,
              controller: _changeSignatureNameController,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                labelText: 'Function name',
                helperText: plan == null || plan.hasConflicts
                    ? null
                    : helperText,
                errorText: plan == null || plan.hasConflicts
                    ? helperText
                    : null,
              ),
              onChanged: (_) {
                setState(() {
                  _changeSignatureError = null;
                });
              },
              onSubmitted: (_) {
                _changeSignatureParametersFocusNode.requestFocus();
              },
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('source-change-signature-parameters-input'),
              focusNode: _changeSignatureParametersFocusNode,
              controller: _changeSignatureParametersController,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: 'Parameters',
                helperText:
                    'Rename in place, reorder, or remove existing names.',
              ),
              onChanged: (_) {
                setState(() {
                  _changeSignatureError = null;
                });
              },
              onSubmitted: (_) => _applyChangeSignature(),
            ),
            if (plan != null && !plan.hasConflicts) ...[
              const SizedBox(height: 8),
              Text(
                'Change `$originalSignature` to `$nextSignature`',
                key: const ValueKey('source-change-signature-preview'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _InlineActionChip(
                  key: const ValueKey('source-change-signature-apply'),
                  icon: Icons.check_rounded,
                  label: 'Change',
                  onTap: _applyChangeSignature,
                ),
                _InlineActionChip(
                  key: const ValueKey('source-change-signature-cancel'),
                  icon: Icons.close_rounded,
                  label: 'Cancel',
                  onTap: _closeChangeSignaturePanel,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUsagesPanel(BuildContext context) {
    final theme = Theme.of(context);
    final definition = widget.controller.definitionAtSelection;
    final references = widget.controller.referencesAtSelection;
    return Material(
      key: const ValueKey('source-usages-panel'),
      color: VityoWorkbenchTokens.of(context).elevated,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.manage_search_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    definition == null
                        ? 'Find Usages'
                        : 'Find Usages: ${definition.symbol.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _InlineActionChip(
                  key: const ValueKey('source-usages-close'),
                  icon: Icons.close_rounded,
                  label: 'Close',
                  onTap: _closeUsagesPanel,
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
            for (var index = 0; index < references.length; index += 1) ...[
              _UsageResultTile(
                key: ValueKey('source-usage-$index'),
                reference: references[index],
                selected: _isRangeSelected(references[index].range),
                location: _formatUsageLocation(references[index]),
                preview: _usageLinePreview(references[index]),
                onTap: () =>
                    widget.controller.selectReference(references[index]),
              ),
              if (index < references.length - 1) const SizedBox(height: 6),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSafeDeletePanel(BuildContext context) {
    final theme = Theme.of(context);
    final plan = widget.controller.safeDeletePlanAtSelection;
    final conflicts = plan?.conflicts ?? const <SafeDeleteConflict>[];
    return Material(
      key: const ValueKey('source-safe-delete-panel'),
      color: VityoWorkbenchTokens.of(context).elevated,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.delete_sweep_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    plan == null
                        ? 'Safe Delete'
                        : 'Safe Delete: ${plan.target.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _InlineActionChip(
                  key: const ValueKey('source-safe-delete-close'),
                  icon: Icons.close_rounded,
                  label: 'Close',
                  onTap: _closeSafeDeletePanel,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (plan == null)
              Text(
                'No symbol target at the current caret.',
                style: theme.textTheme.bodySmall,
              )
            else if (conflicts.isNotEmpty) ...[
              Text(
                '${conflicts.length} blocker'
                '${conflicts.length == 1 ? '' : 's'} found',
                key: const ValueKey('source-safe-delete-blockers'),
                style: theme.textTheme.bodySmall!.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              for (var index = 0; index < conflicts.length; index += 1) ...[
                _SafeDeleteConflictTile(
                  key: ValueKey('source-safe-delete-conflict-$index'),
                  conflict: conflicts[index],
                  location: _formatUsageLocationForRange(
                    conflicts[index].range,
                  ),
                  preview: _linePreviewForRange(conflicts[index].range),
                  onTap: () => widget.controller.selectRange(
                    baseOffset: conflicts[index].range.start,
                    extentOffset: conflicts[index].range.end,
                  ),
                ),
                if (index < conflicts.length - 1) const SizedBox(height: 6),
              ],
            ] else ...[
              Text(
                'Delete declaration with ${plan.edits.length} edit'
                '${plan.edits.length == 1 ? '' : 's'}',
                key: const ValueKey('source-safe-delete-preview'),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              _InlineActionChip(
                key: const ValueKey('source-safe-delete-apply'),
                icon: Icons.check_rounded,
                label: 'Delete safely',
                onTap: _applySafeDelete,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInlineVariablePanel(BuildContext context) {
    final theme = Theme.of(context);
    final plan = widget.controller.inlineVariablePlanAtSelection;
    final conflicts = plan?.conflicts ?? const <InlineVariableConflict>[];
    return Material(
      key: const ValueKey('source-inline-variable-panel'),
      color: VityoWorkbenchTokens.of(context).elevated,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.call_merge_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    plan == null
                        ? 'Inline Variable'
                        : 'Inline Variable: ${plan.target.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _InlineActionChip(
                  key: const ValueKey('source-inline-variable-close'),
                  icon: Icons.close_rounded,
                  label: 'Close',
                  onTap: _closeInlineVariablePanel,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (plan == null)
              Text(
                'No variable target at the current caret.',
                style: theme.textTheme.bodySmall,
              )
            else if (conflicts.isNotEmpty) ...[
              Text(
                '${conflicts.length} blocker'
                '${conflicts.length == 1 ? '' : 's'} found',
                key: const ValueKey('source-inline-variable-blockers'),
                style: theme.textTheme.bodySmall!.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              for (var index = 0; index < conflicts.length; index += 1) ...[
                _InlineVariableConflictTile(
                  key: ValueKey('source-inline-variable-conflict-$index'),
                  conflict: conflicts[index],
                  location: _formatUsageLocationForRange(
                    conflicts[index].range,
                  ),
                  preview: _linePreviewForRange(conflicts[index].range),
                  onTap: () => widget.controller.selectRange(
                    baseOffset: conflicts[index].range.start,
                    extentOffset: conflicts[index].range.end,
                  ),
                ),
                if (index < conflicts.length - 1) const SizedBox(height: 6),
              ],
            ] else ...[
              Text(
                'Replace ${plan.references.length} usage'
                '${plan.references.length == 1 ? '' : 's'} with '
                '` ${plan.initializerText} ` and delete the declaration',
                key: const ValueKey('source-inline-variable-preview'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              _InlineActionChip(
                key: const ValueKey('source-inline-variable-apply'),
                icon: Icons.check_rounded,
                label: 'Inline all',
                onTap: _applyInlineVariable,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildQuickDocumentationPanel(BuildContext context) {
    final theme = Theme.of(context);
    final completionItem = _quickDocumentationForCompletion
        ? _selectedCompletionItem()
        : null;
    final hover = widget.hover;
    final token = widget.activeToken;
    final definition = widget.controller.definitionAtSelection;
    final references = widget.controller.referencesAtSelection;
    final title = completionItem != null
        ? 'Quick Documentation: ${completionItem.label}'
        : definition == null
        ? token == null
              ? 'Quick Documentation'
              : 'Quick Documentation: ${token.lexeme}'
        : 'Quick Documentation: ${definition.symbol.name}';
    final body = completionItem == null
        ? hover?.markdown ?? 'No documentation payload at the caret.'
        : completionItem.documentation.isNotEmpty
        ? completionItem.documentation
        : completionItem.detail.isEmpty
        ? '${completionItem.kind.name} completion'
        : completionItem.detail;

    return Material(
      key: const ValueKey('source-quick-doc-panel'),
      color: VityoWorkbenchTokens.of(context).elevated,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.article_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _InlineActionChip(
                  key: const ValueKey('source-quick-doc-close'),
                  icon: Icons.close_rounded,
                  label: 'Close',
                  onTap: _closeQuickDocumentation,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              body,
              key: const ValueKey('source-quick-doc-body'),
              style: theme.textTheme.bodySmall,
            ),
            if (completionItem != null) ...[
              const SizedBox(height: 8),
              Text(
                'Completion ${completionItem.kind.name} · '
                'insert ${_formatPreviewText(completionItem.insertText)}',
                key: const ValueKey('source-quick-doc-completion-insert'),
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (completionItem == null && token != null) ...[
              const SizedBox(height: 8),
              Text(
                'Token ${token.kind.name} · ${_formatRange(token.range)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (completionItem == null && definition != null) ...[
              const SizedBox(height: 8),
              Text(
                'Definition ${_formatUsageLocationForRange(definition.symbol.nameRange)} '
                '· ${definition.symbol.kind.name}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Text(
                '${references.length} current-file usage'
                '${references.length == 1 ? '' : 's'}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _InlineActionChip(
                    key: const ValueKey('source-quick-doc-definition'),
                    icon: Icons.subdirectory_arrow_left_rounded,
                    label: 'Go to definition',
                    onTap: widget.controller.selectDefinitionAtSelection,
                  ),
                  _InlineActionChip(
                    key: const ValueKey('source-quick-doc-usages'),
                    icon: Icons.manage_search_rounded,
                    label: 'Find usages',
                    onTap: _openUsagesPanel,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCompletionLookupPanel(BuildContext context) {
    final theme = Theme.of(context);
    final completions = widget.completions;
    final selectedIndex = completions.isEmpty
        ? -1
        : _completionLookupIndex.clamp(0, completions.length - 1).toInt();
    final selectedCompletion = selectedIndex < 0
        ? null
        : completions[selectedIndex];

    return Material(
      key: const ValueKey('source-completion-lookup'),
      color: VityoWorkbenchTokens.of(context).elevated,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Code Completion',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _InlineActionChip(
                  key: const ValueKey('source-completion-close'),
                  icon: Icons.close_rounded,
                  label: 'Close',
                  onTap: _closeCompletionLookup,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (completions.isEmpty)
              Text(
                'No completion items at the current caret.',
                style: theme.textTheme.bodySmall,
              )
            else ...[
              Text(
                '${completions.length} current-file suggestion'
                '${completions.length == 1 ? '' : 's'}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (var index = 0; index < completions.length; index += 1) ...[
                _CompletionLookupTile(
                  key: ValueKey('source-completion-item-$index'),
                  item: completions[index],
                  selected: index == selectedIndex,
                  onTap: () => _applyCompletionFromLookup(completions[index]),
                ),
                if (index < completions.length - 1) const SizedBox(height: 6),
              ],
              if (selectedCompletion != null) ...[
                const SizedBox(height: 10),
                _buildCompletionPreviewPanel(context, selectedCompletion),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCompletionPreviewPanel(
    BuildContext context,
    CompletionItem item,
  ) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('source-completion-preview'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: VityoWorkbenchTokens.of(context).region,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: VityoWorkbenchTokens.of(context).divider),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.label,
            key: const ValueKey('source-completion-preview-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall!.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            item.detail.isEmpty ? '${item.kind.name} completion' : item.detail,
            key: const ValueKey('source-completion-preview-detail'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Insert ${_formatPreviewText(item.insertText)}',
            key: const ValueKey('source-completion-preview-insert'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          _InlineActionChip(
            key: const ValueKey('source-completion-preview-doc'),
            icon: Icons.article_rounded,
            label: 'Documentation',
            onTap: _openCompletionQuickDocumentation,
          ),
        ],
      ),
    );
  }

  Widget _buildSurroundLookupPanel(BuildContext context) {
    final theme = Theme.of(context);
    final templates = widget.controller.surroundTemplatesAtSelection;
    final selectedIndex = templates.isEmpty
        ? -1
        : _surroundLookupIndex.clamp(0, templates.length - 1).toInt();

    return Material(
      key: const ValueKey('source-surround-lookup'),
      color: VityoWorkbenchTokens.of(context).elevated,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.data_object_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Surround With',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _InlineActionChip(
                  key: const ValueKey('source-surround-close'),
                  icon: Icons.close_rounded,
                  label: 'Close',
                  onTap: _closeSurroundLookup,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (templates.isEmpty)
              Text(
                'No surround templates at the current selection.',
                style: theme.textTheme.bodySmall,
              )
            else ...[
              Text(
                '${templates.length} Styio surround template'
                '${templates.length == 1 ? '' : 's'}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (var index = 0; index < templates.length; index += 1) ...[
                _SurroundTemplateTile(
                  key: ValueKey('source-surround-template-$index'),
                  template: templates[index],
                  selected: index == selectedIndex,
                  onTap: () =>
                      _applySurroundTemplateFromLookup(templates[index]),
                ),
                if (index < templates.length - 1) const SizedBox(height: 6),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildParameterInfoPanel(BuildContext context) {
    final theme = Theme.of(context);
    final parameterInfo = widget.controller.parameterInfoAtSelection;
    final activeParameter = parameterInfo?.activeParameter;

    return Material(
      key: const ValueKey('source-parameter-info-panel'),
      color: VityoWorkbenchTokens.of(context).elevated,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.functions_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    parameterInfo == null
                        ? 'Parameter Info'
                        : 'Parameter Info: ${parameterInfo.callableName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _InlineActionChip(
                  key: const ValueKey('source-parameter-info-close'),
                  icon: Icons.close_rounded,
                  label: 'Close',
                  onTap: _closeParameterInfo,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (parameterInfo == null)
              Text(
                'No parameter info at the current caret.',
                style: theme.textTheme.bodySmall,
              )
            else ...[
              Text(
                parameterInfo.signature,
                style: theme.textTheme.bodySmall!.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (parameterInfo.documentation.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  parameterInfo.documentation,
                  key: const ValueKey('source-parameter-info-doc'),
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                activeParameter == null
                    ? 'No active parameter'
                    : 'Argument ${parameterInfo.activeParameterIndex + 1} of '
                          '${parameterInfo.parameters.length}: '
                          '${activeParameter.displayText}',
                style: theme.textTheme.bodySmall,
              ),
              if (activeParameter?.documentation.isNotEmpty ?? false) ...[
                const SizedBox(height: 6),
                Text(
                  activeParameter!.documentation,
                  key: const ValueKey('source-parameter-info-active-doc'),
                  style: theme.textTheme.bodySmall!.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              for (
                var index = 0;
                index < parameterInfo.parameters.length;
                index += 1
              ) ...[
                _ParameterInfoParameterTile(
                  key: ValueKey('source-parameter-info-param-$index'),
                  parameter: parameterInfo.parameters[index],
                  active: index == parameterInfo.activeParameterIndex,
                ),
                if (index < parameterInfo.parameters.length - 1)
                  const SizedBox(height: 6),
              ],
            ],
          ],
        ),
      ),
    );
  }

  String _formatUsageLocation(ReferenceSpan reference) {
    return _formatUsageLocationForRange(reference.range);
  }

  String _formatUsageLocationForRange(SourceRange range) {
    final position = widget.document.positionForOffset(range.start);
    return '${position.line + 1}:${position.column + 1}';
  }

  String _formatRange(SourceRange range) {
    return '${range.start}-${range.end}';
  }

  String _usageLinePreview(ReferenceSpan reference) {
    return _linePreviewForRange(reference.range);
  }

  String _linePreviewForRange(SourceRange range) {
    final position = widget.document.positionForOffset(range.start);
    if (position.line < 0 || position.line >= widget.document.lineCount) {
      return '';
    }
    return widget.document.lineAt(position.line).trim();
  }

  bool _isRangeSelected(SourceRange range) {
    final selection = widget.selection;
    if (selection.isCollapsed) {
      return range.contains(selection.end) || range.end == selection.end;
    }
    final selectionRange = SourceRange(
      start: selection.start,
      end: selection.end,
    );
    return range.intersects(selectionRange);
  }
}

class _UsageResultTile extends StatelessWidget {
  const _UsageResultTile({
    super.key,
    required this.reference,
    required this.selected,
    required this.location,
    required this.preview,
    required this.onTap,
  });

  final ReferenceSpan reference;
  final bool selected;
  final String location;
  final String preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accessLabel = _referenceAccessLabel(reference);
    return Material(
      color: selected
          ? VityoWorkbenchTokens.of(context).selection
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _referenceAccessIcon(reference),
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$accessLabel · ${reference.kind.name} · $location',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall!.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SafeDeleteConflictTile extends StatelessWidget {
  const _SafeDeleteConflictTile({
    super.key,
    required this.conflict,
    required this.location,
    required this.preview,
    required this.onTap,
  });

  final SafeDeleteConflict conflict;
  final String location;
  final String preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${conflict.message} · $location',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall!.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineVariableConflictTile extends StatelessWidget {
  const _InlineVariableConflictTile({
    super.key,
    required this.conflict,
    required this.location,
    required this.preview,
    required this.onTap,
  });

  final InlineVariableConflict conflict;
  final String location;
  final String preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${conflict.message} · $location',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall!.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _referenceAccessLabel(ReferenceSpan reference) {
  if (reference.isDeclaration) {
    return 'declaration';
  }
  return switch (reference.access) {
    ReferenceAccess.declaration => 'declaration',
    ReferenceAccess.read => 'read',
    ReferenceAccess.write => 'write',
  };
}

IconData _referenceAccessIcon(ReferenceSpan reference) {
  if (reference.isDeclaration) {
    return Icons.radio_button_checked_rounded;
  }
  return switch (reference.access) {
    ReferenceAccess.declaration => Icons.radio_button_checked_rounded,
    ReferenceAccess.read => Icons.radio_button_unchecked_rounded,
    ReferenceAccess.write => Icons.output_rounded,
  };
}

class _QuickFixLookupTile extends StatelessWidget {
  const _QuickFixLookupTile({
    super.key,
    required this.quickFix,
    required this.selected,
    required this.onTap,
  });

  final DiagnosticQuickFix quickFix;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? VityoWorkbenchTokens.of(context).selection
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.keyboard_return_rounded
                    : Icons.tips_and_updates_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      quickFix.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall!.copyWith(
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    if (quickFix.detail.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        quickFix.detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SymbolLookupTile extends StatelessWidget {
  const _SymbolLookupTile({
    super.key,
    required this.symbol,
    required this.selected,
    required this.location,
    required this.onTap,
  });

  final DocumentSymbol symbol;
  final bool selected;
  final String location;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? VityoWorkbenchTokens.of(context).selection
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.keyboard_return_rounded
                    : _symbolLookupIcon(symbol.kind),
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${symbol.name} · ${symbol.kind.name} · $location',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall!.copyWith(
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    if (symbol.detail.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        symbol.detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

IconData _symbolLookupIcon(SymbolKind kind) {
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

class _CompletionLookupTile extends StatelessWidget {
  const _CompletionLookupTile({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final CompletionItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? VityoWorkbenchTokens.of(context).selection
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.keyboard_return_rounded
                    : Icons.auto_awesome_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${item.label} · ${item.kind.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall!.copyWith(
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    if (item.detail.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        item.detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SurroundTemplateTile extends StatelessWidget {
  const _SurroundTemplateTile({
    super.key,
    required this.template,
    required this.selected,
    required this.onTap,
  });

  final SurroundTemplate template;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? VityoWorkbenchTokens.of(context).selection
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.keyboard_return_rounded
                    : Icons.data_object_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      template.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall!.copyWith(
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    if (template.detail.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        template.detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ParameterInfoParameterTile extends StatelessWidget {
  const _ParameterInfoParameterTile({
    super.key,
    required this.parameter,
    required this.active,
  });

  final ParameterInfoParameter parameter;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: active
            ? VityoWorkbenchTokens.of(context).selection
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: Row(
        children: [
          Icon(
            active ? Icons.chevron_right_rounded : Icons.input_rounded,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              parameter.displayText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall!.copyWith(
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
