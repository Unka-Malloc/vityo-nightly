import 'dart:async';

import '../contract/language_contract.dart';
import '../service/styio_service_capability.dart';
import '../service/styio_service_connector.dart';
import 'lsp_protocol.dart';
import 'lsp_transport.dart';
import 'styio_lsp_capabilities.dart';
import 'styio_lsp_client.dart';

/// Starts (or reuses) the byte channel that carries `styio_lspd` traffic for a
/// given workspace root.
typedef StyioLspTransportFactory =
    Future<LspByteTransport> Function(String workingDirectory);

/// Maps raw LSP 3.17 results into Vityo's StyioService payload model.
///
/// All ranges are converted from LSP UTF-16 positions to Dart string offsets
/// against the exact document text that was sent with `didOpen`/`didChange`.
class LspStyioServiceResponseMapper {
  const LspStyioServiceResponseMapper();

  List<StyioServiceDiagnosticDto> diagnosticsFrom(
    List<Object?> raw,
    String text,
  ) {
    final diagnostics = <StyioServiceDiagnosticDto>[];
    for (final entry in raw) {
      final map = _mapValue(entry);
      final range = _sourceRange(map['range'], text);
      if (range == null) {
        continue;
      }
      final message = _stringValue(map['message']) ?? '';
      if (message.isEmpty) {
        continue;
      }
      diagnostics.add(
        StyioServiceDiagnosticDto(
          severity: _diagnosticSeverity(map['severity']),
          code: _codeValue(map['code']),
          message: message,
          range: range,
        ),
      );
    }
    return diagnostics;
  }

  List<CompletionItem> completionsFrom(Object? result, String text) {
    final items = _listValue(result);
    final completions = <CompletionItem>[];
    for (final entry in items) {
      final map = _mapValue(entry);
      final label = _stringValue(map['label']);
      if (label == null || label.isEmpty) {
        continue;
      }
      final textEdit = _mapValue(map['textEdit']);
      final insertText =
          _stringValue(map['insertText']) ??
          _stringValue(textEdit['newText']) ??
          label;
      completions.add(
        CompletionItem(
          label: label,
          kind: _completionKind(map['kind']),
          insertText: insertText,
          detail: _stringValue(map['detail']) ?? '',
          documentation: _documentation(map['documentation']),
          replacementRange: textEdit.isEmpty
              ? null
              : _sourceRange(textEdit['range'], text),
        ),
      );
    }
    return completions;
  }

  HoverPayload? hoverFrom(
    Object? result,
    String text, {
    required int fallbackOffset,
  }) {
    final map = _mapValue(result);
    if (map.isEmpty) {
      return null;
    }
    final markdown = _documentation(map['contents']);
    if (markdown.isEmpty) {
      return null;
    }
    final range =
        _sourceRange(map['range'], text) ??
        SourceRange(start: fallbackOffset, end: fallbackOffset);
    return HoverPayload(range: range, markdown: markdown);
  }

  List<SemanticSpan> semanticSpansFrom(
    Object? result,
    String text,
    StyioLspCapabilities capabilities,
  ) {
    final data = _listValue(_mapValue(result)['data']);
    if (data.isEmpty) {
      return const <SemanticSpan>[];
    }
    final tokenTypes = capabilities.semanticTokenTypes;
    final spans = <SemanticSpan>[];
    var line = 0;
    var character = 0;
    for (var index = 0; index + 4 < data.length; index += 5) {
      final deltaLine = _intValue(data[index]) ?? 0;
      final deltaCharacter = _intValue(data[index + 1]) ?? 0;
      final length = _intValue(data[index + 2]) ?? 0;
      final tokenTypeIndex = _intValue(data[index + 3]) ?? -1;
      if (deltaLine > 0) {
        line += deltaLine;
        character = deltaCharacter;
      } else {
        character += deltaCharacter;
      }
      if (length <= 0) {
        continue;
      }
      final kind = tokenTypeIndex >= 0 && tokenTypeIndex < tokenTypes.length
          ? _semanticKindForTokenType(tokenTypes[tokenTypeIndex])
          : null;
      if (kind == null) {
        continue;
      }
      final start = LspTextCoordinates.offsetAt(text, line, character);
      final end = LspTextCoordinates.offsetAt(text, line, character + length);
      if (end <= start) {
        continue;
      }
      spans.add(
        SemanticSpan(
          range: SourceRange(start: start, end: end),
          kind: kind,
        ),
      );
    }
    return spans;
  }

  List<InlayHint> inlayHintsFrom(Object? result, String text) {
    final hints = <InlayHint>[];
    for (final entry in _listValue(result)) {
      final map = _mapValue(entry);
      final label = _stringValue(map['label']);
      final position = _mapValue(map['position']);
      if (label == null || label.isEmpty || position.isEmpty) {
        continue;
      }
      final offset = LspTextCoordinates.offsetAt(
        text,
        _intValue(position['line']) ?? 0,
        _intValue(position['character']) ?? 0,
      );
      hints.add(
        InlayHint(
          label: label,
          kind: _inlayHintKind(map['kind']),
          position: offset,
          range: SourceRange(start: offset, end: offset),
        ),
      );
    }
    return hints;
  }

  List<DocumentSymbol> documentSymbolsFrom(Object? result, String text) {
    final symbols = <DocumentSymbol>[];
    for (final entry in _listValue(result)) {
      final symbol = documentSymbolFromLsp(entry, text);
      if (symbol != null) {
        symbols.add(symbol);
      }
    }
    return symbols;
  }

  DocumentSymbol? documentSymbolFromLsp(Object? value, String text) {
    final map = _mapValue(value);
    final name = _stringValue(map['name']);
    if (name == null || name.isEmpty) {
      return null;
    }
    final declarationRange =
        _sourceRange(map['range'], text) ?? _sourceRange(map['location'], text);
    final nameRange =
        _sourceRange(map['selectionRange'], text) ?? declarationRange;
    if (declarationRange == null || nameRange == null) {
      return null;
    }
    return DocumentSymbol(
      name: name,
      kind: _symbolKind(map['kind']),
      nameRange: nameRange,
      declarationRange: declarationRange,
      detail: _stringValue(map['detail']) ?? '',
    );
  }

  List<DefinitionTarget> definitionTargetsFrom(
    Object? result,
    String text, {
    required int originOffset,
    List<DocumentSymbol> symbols = const <DocumentSymbol>[],
  }) {
    final originRange = SourceRange(start: originOffset, end: originOffset);
    final targets = <DefinitionTarget>[];
    for (final entry in _listValue(result)) {
      final map = _mapValue(entry);
      final range = _sourceRange(map['range'], text);
      if (range == null) {
        continue;
      }
      final name = _textAtRange(text, range);
      targets.add(
        DefinitionTarget(
          symbol: DocumentSymbol(
            name: name,
            kind: _symbolKindForRange(symbols, range),
            nameRange: range,
            declarationRange: range,
            detail: 'definition',
          ),
          originRange: originRange,
        ),
      );
    }
    return targets;
  }

  List<ReferenceSpan> referenceSpansFrom(
    Object? result,
    String text, {
    List<DocumentSymbol> symbols = const <DocumentSymbol>[],
    SourceRange? fallbackTarget,
  }) {
    final locations = <({SourceRange range, String name})>[];
    for (final entry in _listValue(result)) {
      final map = _mapValue(entry);
      final range = _sourceRange(map['range'], text);
      if (range == null) {
        continue;
      }
      locations.add((range: range, name: _textAtRange(text, range)));
    }
    if (locations.isEmpty) {
      return const <ReferenceSpan>[];
    }
    final declaration = locations.firstWhere(
      (location) => _isDeclarationRange(symbols, location.range),
      orElse: () => locations.first,
    );
    final targetRange = fallbackTarget ?? declaration.range;
    final references = <ReferenceSpan>[];
    for (final location in locations) {
      final kind = _symbolKindForRange(symbols, location.range);
      references.add(
        ReferenceSpan(
          name: location.name.isEmpty ? declaration.name : location.name,
          kind: kind,
          range: location.range,
          targetRange: targetRange,
          isDeclaration: _sameRange(location.range, targetRange),
          access: ReferenceAccess.read,
        ),
      );
    }
    return references;
  }

  List<DiagnosticQuickFix> codeActionsFrom(
    Object? result, {
    required String uri,
    required String text,
  }) {
    final fixes = <DiagnosticQuickFix>[];
    for (final entry in _listValue(result)) {
      final map = _mapValue(entry);
      final title = _stringValue(map['title']);
      if (title == null || title.isEmpty) {
        continue;
      }
      final disabled = _mapValue(map['disabled']);
      final reason = _stringValue(disabled['reason']);
      final kind = _stringValue(map['kind']) ?? 'quickfix';
      fixes.add(
        DiagnosticQuickFix(
          label: title,
          edits: _workspaceEditsForUri(map['edit'], uri, text),
          detail: reason == null || reason.isEmpty ? kind : '$kind: $reason',
        ),
      );
    }
    return fixes;
  }

  RenamePlan? renamePlanFrom(
    Object? result, {
    required String uri,
    required String text,
    required String newName,
    required int originOffset,
    List<DocumentSymbol> symbols = const <DocumentSymbol>[],
    List<ReferenceSpan> references = const <ReferenceSpan>[],
  }) {
    final map = _mapValue(result);
    final edit = _mapValue(map['edit']);
    final workspaceEdit = edit.isEmpty ? map : edit;
    final changes = _mapValue(workspaceEdit['changes']);
    if (changes.isEmpty) {
      return null;
    }
    final edits = _workspaceEditsForUri(workspaceEdit, uri, text);
    final otherDocuments = changes.keys
        .map((key) => key.toString())
        .where((candidate) => candidate != uri)
        .toList(growable: false);
    final conflicts = <RenameConflict>[
      if (otherDocuments.isNotEmpty)
        RenameConflict(
          message:
              'Rename also edits ${otherDocuments.length} other document(s) '
              'not representable in this document-scoped plan.',
          range: SourceRange(start: originOffset, end: originOffset),
        ),
    ];
    final targetName = _textAtOrigin(text, edits, originOffset);
    return RenamePlan(
      target: DocumentSymbol(
        name: targetName,
        kind: _symbolKindForRange(
          symbols,
          SourceRange(start: originOffset, end: originOffset),
        ),
        nameRange: SourceRange(start: originOffset, end: originOffset),
        declarationRange: SourceRange(start: originOffset, end: originOffset),
        detail: 'rename target',
      ),
      newName: newName,
      references: references,
      edits: edits,
      conflicts: conflicts,
    );
  }

  List<FormattingEdit> _workspaceEditsForUri(
    Object? editValue,
    String uri,
    String text,
  ) {
    final edit = _mapValue(editValue);
    final changes = _mapValue(edit['changes']);
    final rawEdits = changes[uri];
    final formattingEdits = <FormattingEdit>[];
    for (final entry in _listValue(rawEdits)) {
      final map = _mapValue(entry);
      final range = _sourceRange(map['range'], text);
      if (range == null) {
        continue;
      }
      formattingEdits.add(
        FormattingEdit(
          range: range,
          newText: _stringValue(map['newText']) ?? '',
        ),
      );
    }
    return formattingEdits;
  }

  SourceRange? _sourceRange(Object? value, String text) {
    final map = _mapValue(value);
    if (map.isEmpty || !map.containsKey('start') || !map.containsKey('end')) {
      return null;
    }
    final range = LspRange.fromJson(map);
    final start = LspTextCoordinates.startOffset(text, range);
    final end = LspTextCoordinates.endOffset(text, range);
    return SourceRange(start: start, end: end);
  }

  String _textAtRange(String text, SourceRange range) {
    if (range.start < 0 || range.end > text.length || range.end < range.start) {
      return '';
    }
    return text.substring(range.start, range.end);
  }

  String _textAtOrigin(
    String text,
    List<FormattingEdit> edits,
    int originOffset,
  ) {
    for (final edit in edits) {
      if (edit.range.start <= originOffset && originOffset <= edit.range.end) {
        return _textAtRange(text, edit.range);
      }
    }
    return '';
  }

  bool _isDeclarationRange(List<DocumentSymbol> symbols, SourceRange range) {
    for (final symbol in symbols) {
      if (_sameRange(symbol.nameRange, range) ||
          _sameRange(symbol.declarationRange, range)) {
        return true;
      }
    }
    return false;
  }

  bool _sameRange(SourceRange left, SourceRange right) {
    return left.start == right.start && left.end == right.end;
  }

  SymbolKind _symbolKindForRange(
    List<DocumentSymbol> symbols,
    SourceRange range,
  ) {
    for (final symbol in symbols) {
      if (_sameRange(symbol.nameRange, range) ||
          _sameRange(symbol.declarationRange, range) ||
          symbol.declarationRange.intersects(range)) {
        return symbol.kind;
      }
    }
    return SymbolKind.variable;
  }

  DiagnosticSeverity _diagnosticSeverity(Object? value) {
    switch (_intValue(value)) {
      case 1:
        return DiagnosticSeverity.error;
      case 2:
        return DiagnosticSeverity.warning;
      case 3:
      case 4:
      default:
        return DiagnosticSeverity.hint;
    }
  }

  CompletionItemKind _completionKind(Object? value) {
    switch (_intValue(value)) {
      case 3:
        return CompletionItemKind.function;
      case 6:
        return CompletionItemKind.variable;
      case 15:
        return CompletionItemKind.snippet;
      case 14:
      default:
        return CompletionItemKind.keyword;
    }
  }

  InlayHintKind _inlayHintKind(Object? value) {
    return _intValue(value) == 1 ? InlayHintKind.type : InlayHintKind.parameter;
  }

  SymbolKind _symbolKind(Object? value) {
    switch (_intValue(value)) {
      case 6:
      case 9:
      case 12:
        return SymbolKind.function;
      case 13:
      case 14:
      case 7:
      case 8:
      case 22:
      default:
        return SymbolKind.variable;
    }
  }

  SemanticKind? _semanticKindForTokenType(String tokenType) {
    switch (tokenType) {
      case 'function':
      case 'method':
      case 'macro':
        return SemanticKind.function;
      case 'parameter':
        return SemanticKind.parameter;
      case 'variable':
      case 'property':
      case 'enumMember':
      case 'event':
        return SemanticKind.variable;
      case 'namespace':
      case 'type':
      case 'class':
      case 'enum':
      case 'interface':
      case 'struct':
      case 'typeParameter':
        return SemanticKind.typeName;
      default:
        // comment/string/number/keyword/operator/modifier have no faithful
        // SemanticKind mapping; skipping avoids mislabelled highlights.
        return null;
    }
  }

  String _codeValue(Object? value) {
    if (value == null) {
      return '';
    }
    return value.toString();
  }

  String _documentation(Object? value) {
    if (value == null) {
      return '';
    }
    if (value is String) {
      return value;
    }
    if (value is List) {
      return value
          .map((entry) => _documentation(entry))
          .where((entry) => entry.isNotEmpty)
          .join('\n\n');
    }
    final map = _mapValue(value);
    if (map.isNotEmpty) {
      return _stringValue(map['value']) ?? '';
    }
    return value.toString();
  }
}

/// [StyioServiceConnector] backed by a long-lived `styio_lspd` session.
///
/// The connector owns one client for the lifetime of the asset, keeping open
/// documents synchronized through `didOpen`/`didChange`. Document-scoped
/// analysis is served by `analyzeDocument`; position-scoped queries are exposed
/// through the explicit `*At` methods.
class LspStyioServiceConnector implements StyioServiceConnector {
  LspStyioServiceConnector({
    required this.executablePath,
    required this.transportFactory,
    this.toolchainId = 'local-styio-lsp-daemon',
    this.protocolVersion = 'styio-lsp-3.17',
    this.mapper = const LspStyioServiceResponseMapper(),
    this.diagnosticsTimeout = const Duration(seconds: 3),
    this.requestTimeout = const Duration(seconds: 15),
  });

  final String executablePath;
  final StyioLspTransportFactory transportFactory;
  final String toolchainId;
  final String protocolVersion;
  final LspStyioServiceResponseMapper mapper;
  final Duration diagnosticsTimeout;
  final Duration requestTimeout;

  StyioLspClient? _client;
  Future<StyioLspClient?>? _starting;
  String? _rootPath;
  final Map<String, int> _openVersions = <String, int>{};
  final Map<String, String> _openTexts = <String, String>{};
  final Map<String, List<Object?>> _latestDiagnostics =
      <String, List<Object?>>{};
  final Map<String, Completer<List<Object?>>> _diagnosticWaiters =
      <String, Completer<List<Object?>>>{};
  StreamSubscription<StyioLspDiagnosticNotification>? _diagnosticsSubscription;
  var _closed = false;

  StyioLspConnectorStatus get status => _status;
  StyioLspConnectorStatus _status = StyioLspConnectorStatus.dormant;

  StyioLspCapabilities? get capabilities => _client?.capabilities;

  bool get isSessionActive => _client != null && !_closed;

  @override
  Future<StyioServiceResponse> analyzeDocument(
    StyioServiceDocument document,
  ) async {
    final filePath = document.filePath;
    if (filePath == null || filePath.trim().isEmpty) {
      return _unavailable(
        document,
        'styio_lspd analysis requires a document file path.',
      );
    }
    final uri = _fileUri(filePath);
    try {
      final client = await _ensureClient(document.workingDirectory, filePath);
      if (client == null) {
        return _unavailable(
          document,
          'styio_lspd session is unavailable for $filePath.',
        );
      }
      final capabilities = client.capabilities;
      final diagnostics = await _syncAndAwaitDiagnostics(
        client,
        uri,
        filePath: filePath,
        text: document.text,
        revision: document.revision,
        languageId: document.languageId,
      );

      Object? semanticTokens;
      Object? symbols;
      Object? hints;
      final capabilityStates = <String, String>{'analysis': 'available'};
      final capabilityMessages = <String, String>{};
      capabilityStates[StyioServiceCapability.diagnostics.wireValue] =
          'available';

      if (capabilities?.semanticTokensProvider == true) {
        try {
          semanticTokens = await client.semanticTokensFull(uri: uri);
          capabilityStates[StyioServiceCapability.semanticTokens.wireValue] =
              'available';
        } on Object catch (error) {
          capabilityStates[StyioServiceCapability.semanticTokens.wireValue] =
              'unavailable';
          capabilityMessages[StyioServiceCapability.semanticTokens.wireValue] =
              'semanticTokens/full failed: $error';
        }
      } else {
        capabilityStates[StyioServiceCapability.semanticTokens.wireValue] =
            'unsupported';
      }

      if (capabilities?.documentSymbolProvider == true) {
        try {
          symbols = await client.documentSymbol(uri: uri);
          capabilityStates[StyioServiceCapability.documentSymbols.wireValue] =
              'available';
        } on Object catch (error) {
          capabilityStates[StyioServiceCapability.documentSymbols.wireValue] =
              'unavailable';
          capabilityMessages[StyioServiceCapability.documentSymbols.wireValue] =
              'documentSymbol failed: $error';
        }
      } else {
        capabilityStates[StyioServiceCapability.documentSymbols.wireValue] =
            'unsupported';
      }

      if (capabilities?.inlayHintProvider == true) {
        try {
          hints = await client.inlayHint(
            uri: uri,
            range: _wholeDocumentRange(document.text),
          );
          capabilityStates[StyioServiceCapability.inlayHints.wireValue] =
              'available';
        } on Object catch (error) {
          capabilityStates[StyioServiceCapability.inlayHints.wireValue] =
              'unavailable';
          capabilityMessages[StyioServiceCapability.inlayHints.wireValue] =
              'inlayHint failed: $error';
        }
      } else {
        capabilityStates[StyioServiceCapability.inlayHints.wireValue] =
            'unsupported';
      }

      _recordPositionScopedCapabilities(
        capabilities,
        capabilityStates,
        capabilityMessages,
      );

      final mappedDiagnostics = mapper.diagnosticsFrom(
        diagnostics,
        document.text,
      );
      final mappedSymbols = symbols == null
          ? const <DocumentSymbol>[]
          : mapper.documentSymbolsFrom(symbols, document.text);
      final mappedSpans = semanticTokens == null
          ? const <SemanticSpan>[]
          : mapper.semanticSpansFrom(
              semanticTokens,
              document.text,
              capabilities ?? const StyioLspCapabilities(),
            );
      final mappedHints = hints == null
          ? const <InlayHint>[]
          : mapper.inlayHintsFrom(hints, document.text);

      return StyioServiceResponse(
        status: StyioServiceStatus.succeeded,
        documentId: document.documentId,
        revision: document.revision,
        diagnostics: mappedDiagnostics,
        semanticSpans: mappedSpans,
        inlayHints: mappedHints,
        documentSymbols: mappedSymbols,
        protocolVersion: protocolVersion,
        parserEngine: 'styio-lspd',
        toolchainId: toolchainId,
        configPath: document.configPath,
        workingDirectory: document.workingDirectory,
        capabilityStates: Map<String, String>.unmodifiable(capabilityStates),
        capabilityMessages: Map<String, String>.unmodifiable(
          capabilityMessages,
        ),
        message: 'styio_lspd analyzed $uri.',
      );
    } on Object catch (error) {
      _status = StyioLspConnectorStatus.failed;
      return _unavailable(
        document,
        'styio_lspd analysis failed: $error',
        status: StyioServiceStatus.failed,
      );
    }
  }

  Future<List<CompletionItem>> completeAt(
    StyioServiceDocument document,
    int offset,
  ) async {
    return _withPosition(document, offset, (client, uri, text) async {
      final result = await client.completion(
        uri: uri,
        position: LspTextCoordinates.positionAtOffset(text, offset),
      );
      return mapper.completionsFrom(result, text);
    }, const <CompletionItem>[]);
  }

  Future<HoverPayload?> hoverAt(
    StyioServiceDocument document,
    int offset,
  ) async {
    return _withPosition(document, offset, (client, uri, text) async {
      final result = await client.hover(
        uri: uri,
        position: LspTextCoordinates.positionAtOffset(text, offset),
      );
      return mapper.hoverFrom(result, text, fallbackOffset: offset);
    }, null);
  }

  Future<List<DefinitionTarget>> definitionAt(
    StyioServiceDocument document,
    int offset,
  ) async {
    return _withPosition(document, offset, (client, uri, text) async {
      final symbols = mapper.documentSymbolsFrom(
        await client.documentSymbol(uri: uri),
        text,
      );
      final result = await client.definition(
        uri: uri,
        position: LspTextCoordinates.positionAtOffset(text, offset),
      );
      return mapper.definitionTargetsFrom(
        result,
        text,
        originOffset: offset,
        symbols: symbols,
      );
    }, const <DefinitionTarget>[]);
  }

  Future<List<ReferenceSpan>> referencesAt(
    StyioServiceDocument document,
    int offset,
  ) async {
    return _withPosition(document, offset, (client, uri, text) async {
      final symbols = mapper.documentSymbolsFrom(
        await client.documentSymbol(uri: uri),
        text,
      );
      final result = await client.references(
        uri: uri,
        position: LspTextCoordinates.positionAtOffset(text, offset),
      );
      return mapper.referenceSpansFrom(
        result,
        text,
        symbols: symbols,
        fallbackTarget: SourceRange(start: offset, end: offset),
      );
    }, const <ReferenceSpan>[]);
  }

  Future<List<DiagnosticQuickFix>> codeActionsAt(
    StyioServiceDocument document,
    SourceRange range,
  ) async {
    final filePath = document.filePath;
    if (filePath == null || filePath.trim().isEmpty) {
      return const <DiagnosticQuickFix>[];
    }
    final uri = _fileUri(filePath);
    try {
      final client = await _ensureClient(document.workingDirectory, filePath);
      if (client == null) {
        return const <DiagnosticQuickFix>[];
      }
      await _syncDocument(
        client,
        uri,
        filePath: filePath,
        text: document.text,
        revision: document.revision,
        languageId: document.languageId,
      );
      final result = await client.codeAction(
        uri: uri,
        range: LspRange(
          start: LspTextCoordinates.positionAtOffset(
            document.text,
            range.start,
          ),
          end: LspTextCoordinates.positionAtOffset(document.text, range.end),
        ),
      );
      return mapper.codeActionsFrom(result, uri: uri, text: document.text);
    } on Object {
      return const <DiagnosticQuickFix>[];
    }
  }

  Future<RenamePlan?> renameAt(
    StyioServiceDocument document,
    int offset,
    String newName,
  ) async {
    final result = await _withPosition(document, offset, (
      client,
      uri,
      text,
    ) async {
      final symbols = mapper.documentSymbolsFrom(
        await client.documentSymbol(uri: uri),
        text,
      );
      final position = LspTextCoordinates.positionAtOffset(text, offset);
      final references = mapper.referenceSpansFrom(
        await client.references(uri: uri, position: position),
        text,
        symbols: symbols,
      );
      final workspaceEdit = await client.rename(
        uri: uri,
        position: position,
        newName: newName,
      );
      return mapper.renamePlanFrom(
        workspaceEdit,
        uri: uri,
        text: text,
        newName: newName,
        originOffset: offset,
        symbols: symbols,
        references: references,
      );
    }, null);
    return result;
  }

  Future<T> _withPosition<T>(
    StyioServiceDocument document,
    int offset,
    Future<T> Function(StyioLspClient client, String uri, String text) action,
    T fallback,
  ) async {
    final filePath = document.filePath;
    if (filePath == null || filePath.trim().isEmpty) {
      return fallback;
    }
    final uri = _fileUri(filePath);
    try {
      final client = await _ensureClient(document.workingDirectory, filePath);
      if (client == null) {
        return fallback;
      }
      await _syncDocument(
        client,
        uri,
        filePath: filePath,
        text: document.text,
        revision: document.revision,
        languageId: document.languageId,
      );
      return await action(client, uri, document.text);
    } on Object {
      return fallback;
    }
  }

  Future<List<Object?>> _syncAndAwaitDiagnostics(
    StyioLspClient client,
    String uri, {
    required String filePath,
    required String text,
    required int revision,
    required String languageId,
  }) async {
    final waiter = Completer<List<Object?>>();
    _diagnosticWaiters[uri] = waiter;
    try {
      await _syncDocument(
        client,
        uri,
        filePath: filePath,
        text: text,
        revision: revision,
        languageId: languageId,
      );
      return await waiter.future.timeout(
        diagnosticsTimeout,
        onTimeout: () => _latestDiagnostics[uri] ?? const <Object?>[],
      );
    } finally {
      _diagnosticWaiters.remove(uri);
    }
  }

  Future<void> _syncDocument(
    StyioLspClient client,
    String uri, {
    required String filePath,
    required String text,
    required int revision,
    required String languageId,
  }) async {
    final previousVersion = _openVersions[uri];
    if (previousVersion == null) {
      _openVersions[uri] = revision;
      _openTexts[uri] = text;
      client.didOpen(
        uri: uri,
        languageId: languageId,
        version: revision,
        text: text,
      );
      return;
    }
    final previousText = _openTexts[uri];
    if (previousText == text && previousVersion == revision) {
      return;
    }
    final nextVersion = revision > previousVersion
        ? revision
        : previousVersion + 1;
    _openVersions[uri] = nextVersion;
    _openTexts[uri] = text;
    client.didChange(
      uri: uri,
      version: nextVersion,
      contentChanges: <Map<String, Object?>>[
        <String, Object?>{'text': text},
      ],
    );
  }

  Future<StyioLspClient?> _ensureClient(
    String? workingDirectory,
    String? filePath,
  ) async {
    if (_closed) {
      return null;
    }
    final rootPath = _resolveRootPath(workingDirectory, filePath);
    if (_client != null) {
      if (rootPath == _rootPath) {
        return _client;
      }
      await _stopClient();
    }
    final inFlight = _starting;
    if (inFlight != null) {
      return inFlight;
    }
    final starting = _startClient(rootPath);
    _starting = starting;
    try {
      return await starting;
    } finally {
      if (identical(_starting, starting)) {
        _starting = null;
      }
    }
  }

  Future<StyioLspClient?> _startClient(String rootPath) async {
    _status = StyioLspConnectorStatus.starting;
    try {
      final transport = await transportFactory(rootPath);
      final client = StyioLspClient(
        transport: transport,
        requestTimeout: requestTimeout,
      );
      await client.initialize(
        rootUri: Uri.parse(_fileUri(rootPath)),
        rootPath: rootPath,
        clientName: 'Vityo',
      );
      await client.sendInitialized();
      _diagnosticsSubscription = client.diagnostics.listen(
        _acceptDiagnosticsNotification,
        onError: (Object _) {},
      );
      _client = client;
      _rootPath = rootPath;
      _status = StyioLspConnectorStatus.active;
      return client;
    } on Object {
      _status = StyioLspConnectorStatus.failed;
      return null;
    }
  }

  void _acceptDiagnosticsNotification(
    StyioLspDiagnosticNotification notification,
  ) {
    _latestDiagnostics[notification.uri] = notification.diagnostics;
    final waiter = _diagnosticWaiters[notification.uri];
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(notification.diagnostics);
    }
  }

  Future<void> _stopClient() async {
    final subscription = _diagnosticsSubscription;
    _diagnosticsSubscription = null;
    await subscription?.cancel();
    final client = _client;
    _client = null;
    _rootPath = null;
    _openVersions.clear();
    _openTexts.clear();
    _latestDiagnostics.clear();
    if (client != null) {
      await client.close();
    }
    _status = StyioLspConnectorStatus.dormant;
  }

  Future<void> close() async {
    _closed = true;
    await _stopClient();
  }

  void _recordPositionScopedCapabilities(
    StyioLspCapabilities? capabilities,
    Map<String, String> states,
    Map<String, String> messages,
  ) {
    const positionScoped =
        <StyioServiceCapability, bool Function(StyioLspCapabilities)>{
          StyioServiceCapability.completion: _supportsCompletion,
          StyioServiceCapability.hover: _supportsHover,
          StyioServiceCapability.definition: _supportsDefinition,
          StyioServiceCapability.references: _supportsReferences,
          StyioServiceCapability.codeActions: _supportsCodeActions,
          StyioServiceCapability.rename: _supportsRename,
        };
    for (final entry in positionScoped.entries) {
      final advertised = capabilities != null && entry.value(capabilities);
      states[entry.key.wireValue] = advertised ? 'unavailable' : 'unsupported';
      messages[entry.key.wireValue] = advertised
          ? 'styio_lspd advertises ${entry.key.wireValue}; query it through the '
                'position-scoped LSP connector methods.'
          : 'styio_lspd did not advertise ${entry.key.wireValue}.';
    }
    states[StyioServiceCapability.formatting.wireValue] = 'unavailable';
    messages[StyioServiceCapability.formatting.wireValue] =
        'styio_lspd does not implement textDocument/formatting.';
  }

  StyioServiceResponse _unavailable(
    StyioServiceDocument document,
    String message, {
    StyioServiceStatus status = StyioServiceStatus.unavailable,
  }) {
    return StyioServiceResponse(
      status: status,
      documentId: document.documentId,
      revision: document.revision,
      message: message,
      protocolVersion: protocolVersion,
      toolchainId: toolchainId,
      configPath: document.configPath,
      workingDirectory: document.workingDirectory,
      capabilityStates: const <String, String>{'formatting': 'unavailable'},
      capabilityMessages: <String, String>{
        StyioServiceCapability.formatting.wireValue:
            'styio_lspd does not implement textDocument/formatting.',
      },
    );
  }

  String _resolveRootPath(String? workingDirectory, String? filePath) {
    if (workingDirectory != null && workingDirectory.trim().isNotEmpty) {
      return workingDirectory;
    }
    final directory = _directoryOf(filePath ?? '');
    return directory.isEmpty ? '/' : directory;
  }
}

enum StyioLspConnectorStatus { dormant, starting, active, failed }

bool _supportsCompletion(StyioLspCapabilities capabilities) =>
    capabilities.completionProvider;
bool _supportsHover(StyioLspCapabilities capabilities) =>
    capabilities.hoverProvider;
bool _supportsDefinition(StyioLspCapabilities capabilities) =>
    capabilities.definitionProvider;
bool _supportsReferences(StyioLspCapabilities capabilities) =>
    capabilities.referencesProvider;
bool _supportsCodeActions(StyioLspCapabilities capabilities) =>
    capabilities.codeActionProvider;
bool _supportsRename(StyioLspCapabilities capabilities) =>
    capabilities.renameProvider;

LspRange _wholeDocumentRange(String text) {
  final end = LspTextCoordinates.positionAtOffset(text, text.length);
  return LspRange(start: const LspPosition(line: 0, character: 0), end: end);
}

String _fileUri(String path) {
  final normalized = path.replaceAll('\\', '/');
  if (normalized.startsWith('/')) {
    return Uri(scheme: 'file', path: normalized).toString();
  }
  return Uri(scheme: 'file', path: '/$normalized').toString();
}

String _directoryOf(String path) {
  final normalized = path.replaceAll('\\', '/');
  final separator = normalized.lastIndexOf('/');
  if (separator < 0) {
    return normalized;
  }
  if (separator == 0) {
    return '/';
  }
  return normalized.substring(0, separator);
}

Map<String, Object?> _mapValue(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, entry) => MapEntry(key.toString(), entry));
  }
  return const <String, Object?>{};
}

List<Object?> _listValue(Object? value) {
  if (value is List) {
    return value.toList(growable: false);
  }
  return const <Object?>[];
}

String? _stringValue(Object? value) => value?.toString();

int? _intValue(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return null;
}
