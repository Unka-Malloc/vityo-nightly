/// Flow Hero's slice of the real Styio language stack.
///
/// The shell builds its language layer in `app_bootstrap.dart`; Flow Hero does
/// not boot the full shell wiring by design, so this file mirrors the minimal
/// part it actually needs: discover `styio_lspd`, open the LSP-backed analysis
/// driver, and route synchronous reads through the cache the driver fills. When
/// no daemon is found (or boot fails) the runtime stays degraded and the engine
/// keeps its local heuristic — the same honest live/demo pattern the agent
/// bridge already follows.
library;

import '../../ide/editor/document_state.dart';
import '../../ide/local_service/vityod_client.dart';
import '../../ide/local_service/vityod_lsp_gateway.dart';
import '../backend_toolchain/adapter_contracts.dart';
import '../environment/configuration/host_environment.dart';
import '../environment/system_compatibility/platform_manager/platform_manager.dart';
import '../language/language.dart' as lang;
import '../toolchain/toolchain.dart';
import 'toolchain_store.dart';

/// Protocol version the LSP connector and the routed cache share.
const String kFlowHeroLspProtocolVersion = 'styio-lsp-3.17';

/// Honest state of Flow Hero's language-service route.
enum FlowHeroLanguageMode {
  /// A real `styio_lspd` session is the source of analysis facts.
  live,

  /// No daemon: analysis stays on Flow Hero's local heuristic.
  degraded,

  /// The language stack could not be built at all.
  unavailable,
}

/// Where a buffer's current diagnostics came from.
enum FlowHeroAnalysisOrigin { service, heuristic, none }

/// Result of one asynchronous analysis pass.
class FlowHeroLanguageResult {
  const FlowHeroLanguageResult({
    required this.analysis,
    required this.authoritative,
    this.providerVersion,
  });

  final lang.StyioDocumentAnalysis analysis;

  /// True only when `styio_lspd` itself produced this analysis for the exact
  /// document revision. A local fallback is never authoritative.
  final bool authoritative;

  final String? providerVersion;
}

/// The async half of a routed language service: keeps the result cache the
/// synchronous [lang.StyioLanguageService] reads from current.
///
/// The engine discovers this capability on the service instance it receives;
/// a plain [lang.StyioLanguageService] without it is used synchronously.
abstract class FlowHeroAsyncLanguageSource {
  /// True while a real daemon session backs the service.
  bool get live;

  /// Human-readable route label for the settings panel.
  String get statusLine;

  /// Runs one analysis pass and returns the merged facts, or null when the
  /// service is not live or the pass failed.
  Future<FlowHeroLanguageResult?> analyzeFresh(
    DocumentState document, {
    String? filePath,
  });
}

/// Language session exposed to the render controller by the feature runtime.
abstract interface class FlowHeroLanguageSession
    implements lang.StyioLanguageService, FlowHeroAsyncLanguageSource {
  FlowHeroLanguageMode get mode;

  String get providerId;

  String get workspaceRoot;

  String? get providerVersion;

  /// Publishes process-wide language availability only after this session is
  /// accepted as the current workspace route.
  void activateRoute();

  Future<void> dispose();
}

/// Boots the minimal language stack and, while live, doubles as the routed
/// [lang.StyioLanguageService] the engine holds.
class FlowHeroLanguageRuntime implements FlowHeroLanguageSession {
  FlowHeroLanguageRuntime._({
    required FlowHeroLanguageMode mode,
    required String statusLine,
    required this.providerId,
    required this.workspaceRoot,
    lang.StyioLanguageService? service,
    lang.StyioServiceAnalysisDriver? driver,
    lang.LspStyioServiceConnector? connector,
  }) : _mode = mode,
       _statusLine = statusLine,
       _service = service,
       _driver = driver,
       _connector = connector;

  /// Probes for `styio_lspd` and opens the LSP-backed analysis driver.
  ///
  /// Never throws: any failure yields a degraded/unavailable runtime so the
  /// caller can always hand the engine an honest state.
  /// [toolchainSelection] carries the Styio compiler the user stored in the
  /// install dialog. Styio discovery only understands "environment, bundled,
  /// candidate list", so a stored pick is delivered as that probe's explicit
  /// override when the real environment set none — the slot between the
  /// environment and the bundled copy that `candidatePaths` cannot express.
  ///
  /// [vityodClient] is the app-shared local-service client. It is used both for
  /// the discovery bundle (whose file-system manager cannot see anything
  /// without a client) and for the LSP transport's vityod gateway, so the
  /// daemon runs as a vityod child through the same connection the execution
  /// route uses. The client is never disposed here — the holder owns it.
  static Future<FlowHeroLanguageRuntime> boot({
    required String workspaceRoot,
    FlowHeroToolchainSelection toolchainSelection =
        const FlowHeroToolchainSelection(),
    VityodClient? vityodClient,
  }) async {
    if (workspaceRoot.trim().isEmpty) {
      return FlowHeroLanguageRuntime._(
        mode: FlowHeroLanguageMode.degraded,
        statusLine: '未配置工作区 · 本地启发式分析',
        providerId: '',
        workspaceRoot: workspaceRoot,
      );
    }
    try {
      final managers = await createDetectedPlatformManagerBundle(
        workspaceRoot: workspaceRoot,
        vityodClient: vityodClient,
      );
      final environment = Map<String, String>.of(readHostEnvironment());
      if (toolchainSelection.styioPath.isNotEmpty &&
          (environment['VITYO_STYIO_BIN'] ?? '').isEmpty) {
        environment['VITYO_STYIO_BIN'] = toolchainSelection.styioPath;
      }
      final catalog = await createPlatformStyioLanguageToolchainCatalog(
        platformManagers: managers,
        environment: environment,
      );
      final daemon = catalog.lookup(styioLspDaemonToolchainId);
      if (daemon == null) {
        return FlowHeroLanguageRuntime._(
          mode: FlowHeroLanguageMode.degraded,
          statusLine: '未发现 styio_lspd · 本地启发式分析',
          providerId: '',
          workspaceRoot: workspaceRoot,
        );
      }
      final connector = lang.LspStyioServiceConnector(
        executablePath: daemon.executablePath,
        transportFactory: (String workingDirectory) => _lspTransport(
          vityodClient: vityodClient,
          executablePath: daemon.executablePath,
          workingDirectory: workingDirectory,
        ),
      );
      final cache = lang.StyioServiceResultCache();
      final driver = lang.StyioServiceAnalysisDriver(
        connector: connector,
        resultCache: cache,
      );
      final service = lang.createRoutedStyioLanguageService(
        resultCache: cache,
        protocolVersion: kFlowHeroLspProtocolVersion,
        toolchainId: connector.toolchainId,
        workingDirectory: workspaceRoot,
      );
      late final bool sessionStarted;
      try {
        sessionStarted = await connector.startSession(
          workingDirectory: workspaceRoot,
        );
      } on Object {
        await connector.close();
        rethrow;
      }
      if (!sessionStarted) {
        await connector.close();
        return FlowHeroLanguageRuntime._(
          mode: FlowHeroLanguageMode.degraded,
          statusLine: 'styio_lspd 会话未就绪 · 本地启发式分析',
          providerId: '',
          workspaceRoot: workspaceRoot,
        );
      }
      return FlowHeroLanguageRuntime._(
        mode: FlowHeroLanguageMode.live,
        statusLine: 'styio_lspd',
        providerId: 'styio_lspd',
        workspaceRoot: workspaceRoot,
        service: service,
        driver: driver,
        connector: connector,
      );
    } on Object {
      return FlowHeroLanguageRuntime._(
        mode: FlowHeroLanguageMode.unavailable,
        statusLine: '语言服务不可用 · 本地启发式分析',
        providerId: '',
        workspaceRoot: workspaceRoot,
      );
    }
  }

  @override
  FlowHeroLanguageMode get mode => _mode == FlowHeroLanguageMode.live && !live
      ? FlowHeroLanguageMode.degraded
      : _mode;

  final FlowHeroLanguageMode _mode;
  @override
  final String providerId;
  @override
  final String workspaceRoot;

  @override
  String get statusLine => _mode == FlowHeroLanguageMode.live && !live
      ? 'styio_lspd 会话不可用 · 本地启发式分析'
      : _statusLine;

  String _statusLine;

  lang.StyioLanguageService? _service;
  lang.StyioServiceAnalysisDriver? _driver;
  lang.LspStyioServiceConnector? _connector;
  final Map<String, int> _revisions = <String, int>{};
  Object? _probeOwner;
  bool _disposed = false;

  @override
  bool get live =>
      _mode == FlowHeroLanguageMode.live &&
      !_disposed &&
      _service != null &&
      (_connector?.isSessionActive ?? false);

  /// The server version advertised at `initialize`, once observed.
  @override
  String? get providerVersion {
    final version = _connector?.capabilities?.serverVersion;
    return version == null || version.isEmpty ? null : version;
  }

  @override
  void activateRoute() {
    if (!live || _probeOwner != null) return;
    _probeOwner = StyioLanguageServiceProbe.report(
      StyioLanguageServiceProbe(
        realServiceAvailable: true,
        providerId: 'styio_lspd',
        version: providerVersion ?? '',
      ),
    );
  }

  /// The routed service handed to the engine, or null when not live.
  lang.StyioLanguageService? get service => _service;

  /// Runs one analysis pass against the live daemon.
  ///
  /// The driver writes the report to the shared cache, so a follow-up
  /// synchronous [analyzeDocument] on the same revision reads it back.
  @override
  Future<FlowHeroLanguageResult?> analyzeFresh(
    DocumentState document, {
    String? filePath,
  }) async {
    final driver = _driver;
    if (_disposed || !live || driver == null) {
      return null;
    }
    final path = (filePath ?? document.documentId).trim();
    if (path.isEmpty) {
      return null;
    }
    final revision = nextRevision(path);
    final request = DocumentState(
      documentId: path,
      text: document.text,
      revision: revision,
    );
    try {
      final report = await driver.analyzeDocumentWithReport(
        request,
        filePath: path,
        workingDirectory: workspaceRoot,
      );
      final response = report.response;
      final authoritative =
          report.usedFreshStyioServiceResponse &&
          response.succeeded &&
          response.parserEngine == 'styio-lspd' &&
          lang.lookupStyioServiceCapabilityValue(
                response.capabilityStates,
                lang.StyioServiceCapability.diagnostics,
              ) ==
              'available' &&
          (_connector?.isSessionActive ?? false);
      final version = providerVersion;
      if (version != null && version.isNotEmpty) {
        _statusLine = 'styio_lspd $version';
      }
      return FlowHeroLanguageResult(
        analysis: report.analysis,
        authoritative: authoritative,
        providerVersion: version,
      );
    } on Object {
      return null;
    }
  }

  /// Next monotonic revision for [path], so the daemon never sees a rewind.
  int nextRevision(String path) {
    final next = (_revisions[path] ?? 0) + 1;
    _revisions[path] = next;
    return next;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final Object? probeOwner = _probeOwner;
    _probeOwner = null;
    if (probeOwner != null) StyioLanguageServiceProbe.clear(owner: probeOwner);
    await _connector?.close();
    _service = null;
    _driver = null;
    _connector = null;
  }

  // ---- routed StyioLanguageService delegation --------------------------------

  static const lang.StyioDocumentAnalysis _emptyAnalysis =
      lang.StyioDocumentAnalysis(
        tokenSpans: <lang.TokenSpan>[],
        semanticSpans: <lang.SemanticSpan>[],
        diagnostics: <lang.Diagnostic>[],
        formattingEdits: <lang.FormattingEdit>[],
        semanticBlocks: <lang.SemanticBlockRange>[],
        inlayHints: <lang.InlayHint>[],
        documentSymbols: <lang.DocumentSymbol>[],
        referenceSpans: <lang.ReferenceSpan>[],
      );

  @override
  lang.StyioDocumentAnalysis analyzeDocument(DocumentState document) =>
      _service?.analyzeDocument(document) ?? _emptyAnalysis;

  @override
  List<lang.FormattingEdit> formatDocument(DocumentState document) =>
      _service?.formatDocument(document) ?? const <lang.FormattingEdit>[];

  @override
  List<lang.InlayHint> inlayHints(DocumentState document) =>
      _service?.inlayHints(document) ?? const <lang.InlayHint>[];

  @override
  List<lang.CompletionItem> completeAt(DocumentState document, int offset) =>
      _service?.completeAt(document, offset) ?? const <lang.CompletionItem>[];

  @override
  List<lang.SurroundTemplate> surroundTemplatesAt(
    DocumentState document,
    lang.SourceRange range,
  ) =>
      _service?.surroundTemplatesAt(document, range) ??
      const <lang.SurroundTemplate>[];

  @override
  lang.HoverPayload? hoverAt(DocumentState document, int offset) =>
      _service?.hoverAt(document, offset);

  @override
  lang.DefinitionTarget? definitionAt(DocumentState document, int offset) =>
      _service?.definitionAt(document, offset);

  @override
  List<lang.ReferenceSpan> referencesAt(DocumentState document, int offset) =>
      _service?.referencesAt(document, offset) ?? const <lang.ReferenceSpan>[];

  @override
  lang.RenamePlan? renameAt(
    DocumentState document,
    int offset,
    String newName,
  ) => _service?.renameAt(document, offset, newName);

  @override
  lang.SafeDeletePlan? safeDeleteAt(DocumentState document, int offset) =>
      _service?.safeDeleteAt(document, offset);

  @override
  lang.InlineVariablePlan? inlineVariableAt(
    DocumentState document,
    int offset,
  ) => _service?.inlineVariableAt(document, offset);

  @override
  lang.IntroduceVariablePlan? introduceVariable(
    DocumentState document,
    lang.SourceRange range,
    String name,
  ) => _service?.introduceVariable(document, range, name);

  @override
  lang.ExtractFunctionPlan? extractFunction(
    DocumentState document,
    lang.SourceRange range,
    String name,
  ) => _service?.extractFunction(document, range, name);

  @override
  lang.ChangeSignaturePlan? changeSignatureAt(
    DocumentState document,
    int offset, {
    required String newName,
    required List<lang.ChangeSignatureParameterUpdate> parameters,
  }) => _service?.changeSignatureAt(
    document,
    offset,
    newName: newName,
    parameters: parameters,
  );

  @override
  lang.ParameterInfoPayload? parameterInfoAt(
    DocumentState document,
    int offset,
  ) => _service?.parameterInfoAt(document, offset);

  @override
  List<lang.DiagnosticQuickFix> intentionsAt(
    DocumentState document,
    int offset,
  ) =>
      _service?.intentionsAt(document, offset) ??
      const <lang.DiagnosticQuickFix>[];

  @override
  List<lang.DiagnosticQuickFix> quickFixesForDiagnostic(
    DocumentState document,
    lang.Diagnostic diagnostic,
  ) =>
      _service?.quickFixesForDiagnostic(document, diagnostic) ??
      const <lang.DiagnosticQuickFix>[];
}

/// Builds the `styio_lspd` byte transport over the shared vityod client.
///
/// When the shared client is live the daemon session is opened through it — the
/// same connection the execution boot and file-system manager use, so the
/// language route adds no second daemon connection and no second launch. When
/// the shared client is absent or disconnected the transport goes straight to a
/// direct child process: the holder is the single source of the vityod
/// connection, so this must not try to establish another one.
Future<lang.LspByteTransport> _lspTransport({
  required VityodClient? vityodClient,
  required String executablePath,
  required String workingDirectory,
}) {
  final VityodClient? client = vityodClient;
  if (client == null || !client.state.canDispatch) {
    return lang.createPlatformStyioLspTransport(
      executablePath: executablePath,
      workingDirectory: workingDirectory,
      preferVityod: false,
    );
  }
  return _connectSharedLspTransport(
    client: client,
    executablePath: executablePath,
    workingDirectory: workingDirectory,
  );
}

Future<lang.LspByteTransport> _connectSharedLspTransport({
  required VityodClient client,
  required String executablePath,
  required String workingDirectory,
}) async {
  try {
    final session = await VityodLspGateway(
      client: client,
    ).start(executable: executablePath, workingDirectory: workingDirectory);
    return _SharedVityodLspTransport(
      inner: lang.VityodLspTransport(session: session),
    );
  } on Object {
    // The shared client could not open the session; a direct child process is
    // the honest fallback and must not open a second daemon connection.
    return lang.createPlatformStyioLspTransport(
      executablePath: executablePath,
      workingDirectory: workingDirectory,
      preferVityod: false,
    );
  }
}

/// An LSP transport over a vityod session on a *borrowed* client: closing the
/// transport stops the daemon session but never disposes the shared client.
class _SharedVityodLspTransport implements lang.LspByteTransport {
  _SharedVityodLspTransport({required this.inner});

  final lang.VityodLspTransport inner;

  @override
  Stream<List<int>> get input => inner.input;

  @override
  Future<void> write(List<int> bytes) => inner.write(bytes);

  @override
  Future<void> close() => inner.close();
}
