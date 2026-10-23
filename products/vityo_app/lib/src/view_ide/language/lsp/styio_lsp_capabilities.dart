/// Parsed subset of the `initialize` result advertised by `styio_lspd`.
///
/// Capability presence here is the only source of truth for what the daemon
/// supports; nothing is inferred or assumed.
class StyioLspCapabilities {
  const StyioLspCapabilities({
    this.serverName = '',
    this.serverVersion = '',
    this.completionProvider = false,
    this.hoverProvider = false,
    this.definitionProvider = false,
    this.referencesProvider = false,
    this.renameProvider = false,
    this.codeActionProvider = false,
    this.inlayHintProvider = false,
    this.documentSymbolProvider = false,
    this.workspaceSymbolProvider = false,
    this.formattingProvider = false,
    this.semanticTokensProvider = false,
    this.semanticTokenTypes = const <String>[],
    this.semanticTokenModifiers = const <String>[],
    this.textDocumentSyncKind = 0,
    this.workspaceFoldersSupported = false,
    this.raw = const <String, Object?>{},
  });

  factory StyioLspCapabilities.fromInitializeResult(
    Map<String, Object?> result,
  ) {
    final capabilities = _mapValue(result['capabilities']);
    final serverInfo = _mapValue(result['serverInfo']);
    final semanticTokens = _mapValue(capabilities['semanticTokensProvider']);
    final legend = _mapValue(semanticTokens['legend']);
    final workspace = _mapValue(capabilities['workspace']);
    final workspaceFolders = _mapValue(workspace['workspaceFolders']);
    final textDocumentSync = _mapValue(capabilities['textDocumentSync']);
    return StyioLspCapabilities(
      serverName: _stringValue(serverInfo['name']) ?? '',
      serverVersion: _stringValue(serverInfo['version']) ?? '',
      completionProvider: _hasCapability(capabilities['completionProvider']),
      hoverProvider: _flagValue(capabilities['hoverProvider']),
      definitionProvider: _flagValue(capabilities['definitionProvider']),
      referencesProvider: _flagValue(capabilities['referencesProvider']),
      renameProvider: _hasCapability(capabilities['renameProvider']),
      codeActionProvider: _hasCapability(capabilities['codeActionProvider']),
      inlayHintProvider: _flagValue(capabilities['inlayHintProvider']),
      documentSymbolProvider: _flagValue(
        capabilities['documentSymbolProvider'],
      ),
      workspaceSymbolProvider: _flagValue(
        capabilities['workspaceSymbolProvider'],
      ),
      formattingProvider: _hasCapability(
        capabilities['documentFormattingProvider'],
      ),
      semanticTokensProvider: _hasCapability(
        capabilities['semanticTokensProvider'],
      ),
      semanticTokenTypes: _stringList(legend['tokenTypes']),
      semanticTokenModifiers: _stringList(legend['tokenModifiers']),
      textDocumentSyncKind:
          _intValue(capabilities['textDocumentSync']) ??
          _intValue(textDocumentSync['change']) ??
          0,
      workspaceFoldersSupported: _flagValue(workspaceFolders['supported']),
      raw: capabilities,
    );
  }

  final String serverName;
  final String serverVersion;
  final bool completionProvider;
  final bool hoverProvider;
  final bool definitionProvider;
  final bool referencesProvider;
  final bool renameProvider;
  final bool codeActionProvider;
  final bool inlayHintProvider;
  final bool documentSymbolProvider;
  final bool workspaceSymbolProvider;
  final bool formattingProvider;
  final bool semanticTokensProvider;
  final List<String> semanticTokenTypes;
  final List<String> semanticTokenModifiers;
  final int textDocumentSyncKind;
  final bool workspaceFoldersSupported;
  final Map<String, Object?> raw;

  bool get supportsIncrementalSync => textDocumentSyncKind == 2;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (serverName.isNotEmpty) 'serverName': serverName,
      if (serverVersion.isNotEmpty) 'serverVersion': serverVersion,
      'completionProvider': completionProvider,
      'hoverProvider': hoverProvider,
      'definitionProvider': definitionProvider,
      'referencesProvider': referencesProvider,
      'renameProvider': renameProvider,
      'codeActionProvider': codeActionProvider,
      'inlayHintProvider': inlayHintProvider,
      'documentSymbolProvider': documentSymbolProvider,
      'workspaceSymbolProvider': workspaceSymbolProvider,
      'formattingProvider': formattingProvider,
      'semanticTokensProvider': semanticTokensProvider,
      'textDocumentSyncKind': textDocumentSyncKind,
      'workspaceFoldersSupported': workspaceFoldersSupported,
    };
  }
}

bool _hasCapability(Object? value) {
  if (value == null || value == false) {
    return false;
  }
  return true;
}

bool _flagValue(Object? value) => value == true;

Map<String, Object?> _mapValue(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, entry) => MapEntry(key.toString(), entry));
  }
  return const <String, Object?>{};
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

List<String> _stringList(Object? value) {
  if (value is List) {
    return value.map((entry) => entry.toString()).toList(growable: false);
  }
  return const <String>[];
}
