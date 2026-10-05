/// Flow Hero controller: graph state, dock/tree/view/theme toggles and the run
/// ticker. The canvas graph is a projection of the engine's real active buffer
/// — never a hand-written demo graph. Demo-only content is injected through
/// explicit timers, gated to demo mode, and marked as demo wherever it shows.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../view_ide/flow_hero/flow_hero.dart';
import '../../view_ide/language/contract/language_contract.dart' as lang;
import 'agent_bridge.dart';
import 'engine/machine.dart';
import 'flow_model.dart';
import 'palette.dart';
import 'workspace_picker.dart';

/// Boots the execution route for a given stored toolchain selection. Injected
/// so the controller can re-boot after the user saves a binary.
typedef FlowHeroExecutionBoot =
    Future<FlowHeroExecutionSource> Function(
      FlowHeroToolchainSelection selection,
    );

/// Boots the language service for a given stored toolchain selection.
typedef FlowHeroLanguageBoot =
    Future<FlowHeroLanguageSession> Function(
      FlowHeroToolchainSelection selection,
    );

/// Rebuilds the workspace file index for a new root.
/// Opens the platform directory chooser, seeded at the current root. Returns
/// the chosen absolute path, or null when the user cancels.
typedef FlowHeroWorkspacePicker = Future<String?> Function(String currentRoot);

/// Resolves the workspace root Flow Hero starts with.
///
/// An explicit selection (persisted or injected) outranks the build-time
/// `VITYO_WORKSPACE`; an empty result means no workspace is configured, which
/// keeps the demo / package-root fallback behaviour.
String resolveFlowHeroWorkspaceRoot({
  String? selected,
  String configured = AgentBridge.workspaceDir,
}) {
  final String chosen = (selected ?? '').trim();
  if (chosen.isNotEmpty) return chosen;
  return configured.trim();
}

enum NodeStatus { idle, running, done }

/// Where the canvas projection came from. Mirrors the settings panel's
/// language-service row: the same live/degraded split, named on the canvas.
enum FlowHeroProjectionSource {
  /// A live `styio_lspd` route informed the projection.
  semanticService,

  /// No daemon: the local engine parse backs the projection.
  localParse,

  /// No real workspace buffer is open; nothing is projected.
  none,
}

class HeroNode {
  HeroNode({
    required this.id,
    required this.name,
    required this.sig,
    required this.pos,
    this.status = NodeStatus.idle,
    this.span,
    this.demo = false,
    this.serviceConfirmed = false,
  });

  final String id;
  final String name;
  final String sig;
  Offset pos;
  NodeStatus status;

  /// Source span of this node's declaration in the active buffer, when known.
  final TextRange? span;

  /// True for content injected by the demo timers — always marked on screen.
  final bool demo;

  /// True when a real document symbol from the live service confirmed this
  /// node's identity.
  final bool serviceConfirmed;
}

class HeroEdge {
  const HeroEdge(this.a, this.b, {this.hot = false});
  final String a;
  final String b;
  final bool hot;
}

class ChatMsg {
  const ChatMsg(this.who, this.text, {this.receipt = false, this.demo = false});
  final String who;
  final String text;
  final bool receipt;

  /// True for demo-only scripted text, never presented as a live Agent reply.
  final bool demo;
}

/// One real source line shown by the dock, numbered from the active buffer.
class SourceDockLine {
  const SourceDockLine({required this.lineNo, required this.text});
  final int lineNo;
  final String text;
}

class FlowHeroController extends ChangeNotifier {
  FlowHeroController({
    FlowHeroExecutionSource? executionSource,
    FlowHeroThemeStore? themeStore,
    FlowHeroWorkspaceFileIndex? workspaceFileIndex,
    FlowHeroWorkspaceFileIndexFactory? workspaceFileIndexFactory,
    FlowHeroWorkspaceStore? workspaceStore,
    FlowHeroWorkspacePicker? workspacePicker,
    String initialWorkspaceRoot = '',
    FlowHeroModelConfigStore? modelConfigStore,
    FlowHeroProviderConfigWriter? providerConfigWriter,
    FlowHeroAgentSecretStore? agentSecretStore,
    FlowHeroToolchainStore? toolchainStore,
    FlowHeroExecutionBoot? executionBoot,
    FlowHeroLanguageBoot? languageBoot,
    FlowHeroToolchainProbe? toolchainProbe,
    this.localServices,
  }) : _workspaceFileIndexFactory =
           workspaceFileIndexFactory ?? _defaultWorkspaceFileIndexFactory,
       workspaceFileIndex =
           workspaceFileIndex ??
           (workspaceFileIndexFactory ?? _defaultWorkspaceFileIndexFactory)(
             resolveFlowHeroWorkspaceRoot(selected: initialWorkspaceRoot),
           ) {
    _execution = executionSource;
    _themeStore = themeStore;
    _modelConfigStore = modelConfigStore;
    _providerConfigWriter = providerConfigWriter;
    _agentSecretStore = agentSecretStore;
    _toolchainStore = toolchainStore;
    _executionBoot = executionBoot;
    _languageBoot = languageBoot;
    _toolchainProbe = toolchainProbe;
    _workspaceStore = workspaceStore;
    _workspacePicker = workspacePicker ?? pickFlowHeroWorkspaceDirectory;
    _workspaceRoot = resolveFlowHeroWorkspaceRoot(
      selected: initialWorkspaceRoot,
    );
    bridge.setWorkspaceRoot(_workspaceRoot);
    // The agent runtime must not be spawned without a provider configuration:
    // it would exit 78 and the link would be red for an invisible reason. The
    // probe resolves after the (possibly deferred) store boot, so a slow
    // platform bundle is not mistaken for "unconfigured".
    bridge.modelConfigured = _modelRouteReady;
    engine.addListener(_onEngineChanged);
    bridge.addListener(_onBridgeChanged);
    unawaited(
      bridge.attach(
        engine: engine,
        onText: _agentText,
        onReceipt: _agentReceipt,
      ),
    );
    unawaited(_bootModelConfig());
    _toolchainStartInFlight = _startToolchain();
    workspaceBootSettled = _bootWorkspaceSelection();
    refreshProjection();
  }

  /// The real workbench engine: buffers, FLOW board geometry, run state.
  final WorkbenchController engine = WorkbenchController();

  /// The one vityod connection every Flow Hero local service boots with: the
  /// agent bridge, the execution route, the toolchain probe, the language
  /// service, and every store bundle. Created here unless the app injects one;
  /// the creator owns disposal.
  final FlowHeroLocalServiceOwner? localServices;

  /// The real agent link (vityod gateway → registry → session). Demo mode
  /// until attach() proves otherwise. It borrows [localServices]' client — the
  /// bridge never disposes the shared connection.
  late final AgentBridge bridge = AgentBridge(
    clientProvider: () async => localServices?.client(),
  );
  bool _liveTranscript = false;

  // ── language service ─────────────────────────────────────────
  /// The real Styio language stack when FlowHeroApp booted one. Null until the
  /// async probe answers; the engine stays on its heuristic meanwhile.
  FlowHeroLanguageSession? _languageRuntime;

  FlowHeroLanguageMode get languageMode =>
      _languageRuntime?.mode ?? FlowHeroLanguageMode.unavailable;

  String get languageStatusLine =>
      _languageRuntime?.statusLine ?? '未接线 · 本地启发式分析';

  String? get languageProviderVersion => _languageRuntime?.providerVersion;

  bool get languageLive => _languageRuntime?.live ?? false;

  /// Called by FlowHeroApp once its startup probe returns. The engine always
  /// receives the runtime so it can mark the heuristic as a degraded route.
  void attachLanguageService(
    FlowHeroLanguageSession runtime, {
    FlowHeroToolchainSelection? selection,
  }) {
    final FlowHeroLanguageSession? previous = _languageRuntime;
    if (previous != null) unawaited(previous.dispose());
    _languageRuntime = runtime;
    _languageBootedSelection = selection ?? _toolchainSelection;
    engine.attachLanguageService(runtime);
    notifyListeners();
  }

  // ── graph ────────────────────────────────────────────────────
  /// The canvas nodes: the active buffer's real projection, plus any
  /// demo-marked content. Rebuilt from [engine] on every real change.
  final List<HeroNode> nodes = <HeroNode>[];
  final List<HeroEdge> edges = <HeroEdge>[];
  final List<HeroNode> _demoNodes = <HeroNode>[];

  FlowHeroProjectionSource projectionSource = FlowHeroProjectionSource.none;
  String projectionEmptyReason = '';

  String get projectionBadgeLabel => switch (projectionSource) {
    FlowHeroProjectionSource.semanticService => '语义服务投影',
    FlowHeroProjectionSource.localParse => '本地解析投影',
    FlowHeroProjectionSource.none => '',
  };

  /// Explicit demo mode: no workspace is configured, no real buffer is open,
  /// and the Agent link is not live. Only here may the scripted demo timers
  /// inject content.
  bool get demoModeActive =>
      _workspaceRoot.isEmpty &&
      bridge.mode == AgentLinkMode.demo &&
      !engine.hasWorkspaceDocumentStore &&
      engine.activeFile.path == null;

  String? _projectionSignature;
  final List<Timer> _demoTimers = <Timer>[];
  bool _demoScheduled = false;

  HeroNode? byId(String id) {
    for (final HeroNode n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// Real source lines for [nodeId]'s span in the active buffer. Empty when the
  /// node has no real source location — the dock says so instead of inventing
  /// a snippet.
  List<SourceDockLine> sourceLinesFor(String? nodeId) {
    if (nodeId == null) return const <SourceDockLine>[];
    final TextRange? span = byId(nodeId)?.span;
    final BufferFile f = engine.activeFile;
    if (span == null || f.path == null) return const <SourceDockLine>[];
    final String text = f.text;
    if (span.start < 0 || span.end > text.length || span.start >= span.end) {
      return const <SourceDockLine>[];
    }
    final List<String> lines = text.split('\n');
    final int first = _lineIndexOf(text, span.start);
    final int last = _lineIndexOf(text, span.end - 1);
    final int limit = first + 12;
    return <SourceDockLine>[
      for (int i = first; i <= last && i < lines.length && i < limit; i++)
        SourceDockLine(lineNo: i + 1, text: lines[i]),
    ];
  }

  static int _lineIndexOf(String text, int offset) {
    int line = 0;
    final int limit = offset < text.length ? offset : text.length;
    for (int i = 0; i < limit; i++) {
      if (text.codeUnitAt(i) == 10) line++;
    }
    return line;
  }

  /// Rebuilds the canvas projection from the engine's real active buffer and
  /// syncs demo-mode content. Public so a caller can force it after a direct
  /// engine mutation; normal updates arrive through the engine listener.
  void refreshProjection() {
    _syncDemoMode();
    _rebuildProjection();
    _projectionSignature = _signature();
    notifyListeners();
  }

  void _onEngineChanged() {
    _syncDemoMode();
    final String signature = _signature();
    if (signature != _projectionSignature) {
      _rebuildProjection();
      _projectionSignature = signature;
    }
    notifyListeners();
  }

  void _onBridgeChanged() => _onEngineChanged();

  String _signature() =>
      '${engine.activeFile.path}|${engine.activeFile.name}'
      '|${engine.activeFile.sourceRevision}|${engine.bufferEpoch}'
      '|${engine.languageServiceLive}|$executionPhase'
      '|${identityHashCode(engine.graph)}'
      '|$demoModeActive|${_demoNodes.length}';

  void _rebuildProjection() {
    final BufferFile f = engine.activeFile;
    final Map<String, HeroNode> previous = <String, HeroNode>{
      for (final HeroNode n in nodes)
        if (!n.demo) n.id: n,
    };
    final List<HeroNode> projected = <HeroNode>[];
    final List<HeroEdge> projectedEdges = <HeroEdge>[];
    FlowHeroProjectionSource source = FlowHeroProjectionSource.none;
    String reason;

    if (f.path == null || !f.drawable) {
      reason = f.path != null
          ? '当前文件不是 Styio 程序 · 无法生成流程图'
          : (demoModeActive ? '演示模式 · 打开工作区文件以生成真实图' : '打开工作区文件以生成真实图');
    } else {
      final GraphBoard board = engine.graph;
      final Map<String, lang.DocumentSymbol> symbols =
          <String, lang.DocumentSymbol>{
            for (final lang.DocumentSymbol s in engine.activeDocumentSymbols)
              s.name: s,
          };
      final Set<String> ids = <String>{};
      for (final GraphModule m in board.modules) {
        final lang.DocumentSymbol? symbol = symbols[m.name];
        final TextRange? span = symbol != null
            ? TextRange(
                start: symbol.declarationRange.start,
                end: symbol.declarationRange.end,
              )
            : _findIdentifierSpan(f.text, m.name);
        final HeroNode? prev = previous[m.name];
        projected.add(
          HeroNode(
            id: m.name,
            name: m.name,
            sig: _signatureFor(f.text, m, span),
            pos: prev?.pos ?? Offset(m.x, m.y),
            span: span,
            serviceConfirmed: symbol != null,
          ),
        );
        ids.add(m.name);
      }
      for (final BoardCable c in board.cables) {
        if (!ids.contains(c.from) || !ids.contains(c.to)) continue;
        projectedEdges.add(HeroEdge(c.from, c.to, hot: executionBusy));
      }
      source = engine.languageServiceLive
          ? FlowHeroProjectionSource.semanticService
          : FlowHeroProjectionSource.localParse;
      reason = projected.isEmpty ? '缓冲区中没有可投影的流程结构' : '';
    }

    nodes
      ..clear()
      ..addAll(projected)
      ..addAll(_demoNodes);
    edges
      ..clear()
      ..addAll(projectedEdges);
    projectionSource = source;
    projectionEmptyReason = reason;
    if (selectedId != null && byId(selectedId!) == null) selectedId = null;
    if (flashingId != null && byId(flashingId!) == null) flashingId = null;
  }

  /// The node's signature line: the real declaration text when the span lands
  /// on source, otherwise the parsed module kind.
  String _signatureFor(String text, GraphModule m, TextRange? span) {
    if (span != null) {
      final String line = _lineTextAt(text, span.start).trim();
      if (line.isNotEmpty) return line;
    }
    return m.kindText.isEmpty ? (m.kind ?? '') : m.kindText;
  }

  static String _lineTextAt(String text, int offset) {
    final int start = text.lastIndexOf('\n', offset - 1) + 1;
    int end = text.indexOf('\n', offset);
    if (end < 0) end = text.length;
    return text.substring(start, end);
  }

  /// Locates [name] in the real buffer: a declaration site first, then any
  /// standalone occurrence. Returns null when the name is not in the source.
  static TextRange? _findIdentifierSpan(String text, String name) {
    if (name.isEmpty) return null;
    final String escaped = RegExp.escape(name);
    final RegExpMatch? decl = RegExp(
      '^[ \\t]*(?:fn|let|state|pipeline|const|channel)\\s+$escaped\\b',
      multiLine: true,
    ).firstMatch(text);
    if (decl != null) {
      final int at = text.indexOf(name, decl.start);
      if (at >= 0) return TextRange(start: at, end: at + name.length);
    }
    final RegExpMatch? any = RegExp('\\b$escaped\\b').firstMatch(text);
    if (any != null) return TextRange(start: any.start, end: any.end);
    return null;
  }

  // ── demo content ─────────────────────────────────────────────
  /// Starts the scripted demo timers only in explicit demo mode, and stops
  /// them (dropping any injected content) the moment we leave it.
  void _syncDemoMode() {
    if (demoModeActive) {
      _scheduleDemoInjection();
      return;
    }
    for (final Timer t in _demoTimers) {
      t.cancel();
    }
    _demoTimers.clear();
    _demoScheduled = false;
    _demoNodes.clear();
    messages.removeWhere((m) => m.demo);
  }

  void _scheduleDemoInjection() {
    if (_demoScheduled) return;
    _demoScheduled = true;
    _demoTimers.add(
      Timer(const Duration(milliseconds: 2600), () {
        if (!demoModeActive) return;
        _demoNodes.add(
          HeroNode(
            id: 'enrich',
            name: 'enrich',
            sig: '演示 · fn enrich(u: User) -> User+Profile',
            pos: const Offset(470, 330),
            demo: true,
          ),
        );
        flashingId = 'enrich';
        _rebuildProjection();
        _projectionSignature = _signature();
        postAgentNote('演示内容 · 已写入 fn enrich，接入 dedupe → emit 之间。', demo: true);
      }),
    );
    _demoTimers.add(
      Timer(const Duration(milliseconds: 4200), () {
        if (!demoModeActive) return;
        postAgentNote(
          '演示内容 · 回执 · +9 行 user_sync.sty · 测试通过',
          receipt: true,
          demo: true,
        );
      }),
    );
  }

  // ── chat ─────────────────────────────────────────────────────
  final List<ChatMsg> messages = <ChatMsg>[];

  // ── ui state ─────────────────────────────────────────────────
  String? selectedId;
  String? flashingId;
  bool dockExpanded = false;
  bool treeVisible = false;
  bool editorMode = false;
  String activeFile = 'user_sync.sty';
  Offset pan = Offset.zero;

  // ── agent column ─────────────────────────────────────────────
  /// Width of the right agent column; the split handle drags it.
  static const double minChatWidth = 240;
  static const double maxChatWidth = 560;
  double chatWidth = 300;

  /// Drag-by-delta: the column sits on the right edge, so dragging the handle
  /// left (negative dx) widens it.
  void resizeChatBy(double dx) {
    final double next = (chatWidth - dx).clamp(minChatWidth, maxChatWidth);
    if (next == chatWidth) return;
    chatWidth = next;
    notifyListeners();
  }

  // ── workspace drawer ─────────────────────────────────────────
  /// Width of the workspace drawer; the split handle on its right edge drags
  /// it (the drawer grows rightward, so positive dx widens).
  static const double minTreeWidth = 160;
  static const double maxTreeWidth = 420;
  double treeWidth = 200;

  /// True while the drawer sash is being dragged: the drawer's reveal
  /// animation must not smooth (and lag) a live drag.
  bool treeDragging = false;

  void resizeTreeBy(double dx) {
    final double next = (treeWidth + dx).clamp(minTreeWidth, maxTreeWidth);
    if (next == treeWidth) return;
    treeWidth = next;
    notifyListeners();
  }

  void setTreeDragging(bool value) {
    if (value == treeDragging) return;
    treeDragging = value;
    notifyListeners();
  }

  // ── real execution (RUN / TEST) ──────────────────────────────
  /// The real pafio route when FlowHeroApp booted one. Null until the async
  /// probe answers; the RUN/TEST controls disable themselves and name the
  /// reason whenever this route is not live.
  FlowHeroExecutionSource? _execution;

  /// Where the real execution has reached. Driven only by process events, not
  /// by a timer — there is no animated stand-in for progress.
  FlowHeroExecutionPhase executionPhase = FlowHeroExecutionPhase.idle;

  FlowHeroExecutionOutcome? lastExecutionOutcome;

  /// The real workspace file index the quick-open overlay reads. Re-rooted by
  /// [switchWorkspace]; an injected index is replaced on the next switch.
  FlowHeroWorkspaceFileIndex workspaceFileIndex;

  bool quickOpenVisible = false;
  bool _disposed = false;

  FlowHeroExecutionSource? get executionSource => _execution;

  bool get executionLive => _execution?.live ?? false;

  /// True while the route is being probed and nothing is known yet: the strip
  /// must say so instead of presenting the unwired state as a resolved failure.
  /// A re-boot keeps the previous route visible, so no dead frame flashes.
  bool get executionProbing => _executionBootInFlight && _execution == null;

  bool get executionBusy =>
      executionPhase == FlowHeroExecutionPhase.pending ||
      executionPhase == FlowHeroExecutionPhase.running;

  /// True only when a real pafio invocation can start right now.
  bool get canExecute => executionLive && !executionBusy;

  /// Why RUN/TEST cannot start; empty while [canExecute].
  String get executionUnavailableReason {
    final FlowHeroExecutionSource? source = _execution;
    if (source == null) return '未接线 · 未配置执行服务';
    if (source.live) return executionBusy ? '已有一次执行在进行' : '';
    return source.unavailableReason.isEmpty
        ? '执行服务不可用'
        : source.unavailableReason;
  }

  /// The strip's readout: a real phase or an honest unavailable reason.
  String get executionStatusLabel => switch (executionPhase) {
    FlowHeroExecutionPhase.pending => '启动中…',
    FlowHeroExecutionPhase.running => '执行中…',
    FlowHeroExecutionPhase.succeeded =>
      lastExecutionOutcome?.statusLine ?? '通过',
    FlowHeroExecutionPhase.failed => lastExecutionOutcome?.statusLine ?? '失败',
    FlowHeroExecutionPhase.idle =>
      executionLive
          ? (_execution?.statusLine ?? '就绪')
          : executionUnavailableReason,
  };

  /// Called by FlowHeroApp once its startup probe returns.
  void attachExecutionSource(FlowHeroExecutionSource? source) {
    _execution = source;
    executionPhase = FlowHeroExecutionPhase.idle;
    lastExecutionOutcome = null;
    notifyListeners();
  }

  /// Runs [kind] through the real route and posts the real receipt.
  Future<void> runExecution(FlowHeroExecutionKind kind) async {
    final FlowHeroExecutionSource? source = _execution;
    if (source == null || !source.live || executionBusy || _disposed) {
      return;
    }
    executionPhase = FlowHeroExecutionPhase.pending;
    lastExecutionOutcome = null;
    notifyListeners();
    final FlowHeroExecutionOutcome outcome = await source.execute(
      kind,
      onStarted: () {
        if (_disposed || executionPhase != FlowHeroExecutionPhase.pending) {
          return;
        }
        executionPhase = FlowHeroExecutionPhase.running;
        notifyListeners();
      },
    );
    if (_disposed) return;
    lastExecutionOutcome = outcome;
    executionPhase = outcome.phase;
    // The receipt is written by pafio; the chat rail echoes the real summary.
    postAgentNote(outcome.receiptText, receipt: true);
  }

  /// Asks the running child to stop. Says so when the route cannot cancel.
  Future<void> cancelExecution() async {
    final FlowHeroExecutionSource? source = _execution;
    if (source == null || !executionBusy) return;
    final bool accepted = await source.cancel();
    if (!accepted && !_disposed) {
      postAgentNote('无法中断 · 本地进程管理器不支持取消。');
    }
  }

  void clearExecution() {
    if (executionPhase == FlowHeroExecutionPhase.idle &&
        lastExecutionOutcome == null) {
      return;
    }
    executionPhase = FlowHeroExecutionPhase.idle;
    lastExecutionOutcome = null;
    notifyListeners();
  }

  // ── local toolchain (install flow) ───────────────────────────
  FlowHeroToolchainStore? _toolchainStore;
  FlowHeroExecutionBoot? _executionBoot;
  FlowHeroLanguageBoot? _languageBoot;
  FlowHeroToolchainProbe? _toolchainProbe;
  FlowHeroToolchainSelection _toolchainSelection =
      const FlowHeroToolchainSelection();

  /// Whether the install dialog is on screen.
  bool toolchainInstallVisible = false;

  /// True only when a stored selection survives a restart.
  bool get toolchainStorePersistent => _toolchainStore?.persistent ?? false;

  /// The user's stored binary selection, once the store has been read.
  FlowHeroToolchainSelection get toolchainSelection => _toolchainSelection;

  /// The tools the attached route could not resolve. Empty when the route
  /// carries no toolchain detail (or is live).
  Set<FlowHeroToolchainKind> get missingToolchains {
    // Declared as Object? so the unrelated diagnosis interface can promote.
    final Object? source = _execution;
    if (source is FlowHeroToolchainDiagnosis) return source.missingToolchains;
    return const <FlowHeroToolchainKind>{};
  }

  /// Where the last boot looked for each tool.
  Map<FlowHeroToolchainKind, List<FlowHeroToolchainCheck>> get toolchainChecks {
    final Object? source = _execution;
    if (source is FlowHeroToolchainDiagnosis) return source.toolchainChecks;
    return const <FlowHeroToolchainKind, List<FlowHeroToolchainCheck>>{};
  }

  /// The route's own classification of why it is unavailable; null while live
  /// or when the attached route carries no diagnosis.
  FlowHeroExecutionUnavailableCause? get executionUnavailableCause {
    final Object? source = _execution;
    if (source is FlowHeroToolchainDiagnosis) return source.unavailableCause;
    return null;
  }

  void openToolchainInstall() {
    if (toolchainInstallVisible) return;
    toolchainInstallVisible = true;
    notifyListeners();
  }

  void closeToolchainInstall() {
    if (!toolchainInstallVisible) return;
    toolchainInstallVisible = false;
    notifyListeners();
  }

  /// Boots the route with what is known now, then adopts a stored selection.
  ///
  /// Booting first keeps startup honest and fast: an empty workspace already
  /// answers without touching the store. A stored selection that the boot did
  /// not already use re-boots exactly once.
  Future<void> _startToolchain() async {
    await _rebootExecution();
    await _adoptStoredToolchainSelection();
  }

  Future<void> _adoptStoredToolchainSelection() async {
    FlowHeroToolchainSelection? loaded;
    try {
      loaded = await _toolchainStore?.load();
    } on Object {
      // A failed read leaves the selection empty; the dialog still works.
      loaded = null;
    }
    if (loaded == null || _disposed) return;
    _toolchainSelection = loaded;
    notifyListeners();
    if (_bootedSelection != loaded) await _rebootExecution();
    // A stored Styio compiler also belongs to the language service; re-probe
    // it unless that route already booted with this exact selection.
    if (loaded.styioPath.isNotEmpty &&
        _languageBoot != null &&
        _languageBootedSelection != loaded) {
      await _rebootLanguageService();
    }
  }

  /// Re-probes the execution route with the current selection. A no-op when no
  /// boot route was injected (the caller owns the source).
  Future<void> retryExecutionBoot() => _rebootExecution();

  FlowHeroToolchainSelection? _bootedSelection;
  FlowHeroToolchainSelection? _languageBootedSelection;
  bool _executionBootInFlight = false;

  /// The constructor's execution/toolchain startup. A workspace adoption waits
  /// for it so the switch is the last route change, not a race.
  Future<void>? _toolchainStartInFlight;

  Future<void> _rebootExecution() async {
    final FlowHeroExecutionBoot? boot = _executionBoot;
    if (boot == null || _disposed) return;
    final FlowHeroToolchainSelection selection = _toolchainSelection;
    // Nothing is known until this boot answers: announce the probe so the strip
    // does not present the unwired state as a resolved failure.
    _executionBootInFlight = true;
    notifyListeners();
    try {
      final FlowHeroExecutionSource source = await boot(selection);
      if (_disposed) {
        unawaited(source.dispose());
        return;
      }
      _bootedSelection = selection;
      final FlowHeroExecutionSource? previous = _execution;
      attachExecutionSource(source);
      if (previous != null && previous != source) unawaited(previous.dispose());
    } on Object {
      if (!_disposed) {
        postAgentNote('执行服务重新探测失败 · 无法启动本地工具链探测。');
      }
    } finally {
      _executionBootInFlight = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Runs the real verification for [path]. Never throws: a probe that fails to
  /// start is reported as a failure result.
  Future<FlowHeroToolchainProbeResult> probeToolchainCandidate(
    FlowHeroToolchainKind kind,
    String path,
  ) async {
    final FlowHeroToolchainProbe? probe = _toolchainProbe;
    if (probe == null) {
      return const FlowHeroToolchainProbeResult(
        ok: false,
        detail: '本地工具探测服务不可用',
        failure: '本地工具探测服务不可用',
      );
    }
    try {
      return await probe(kind, path.trim());
    } on Object catch (error) {
      return FlowHeroToolchainProbeResult(
        ok: false,
        detail: '无法探测该二进制 · $error',
        failure: '无法探测该二进制',
      );
    }
  }

  /// Persists [path], re-boots the execution route, and — when Styio was the
  /// fixed tool — re-probes the language service so it uses the new binary.
  Future<FlowHeroToolchainSaveResult> saveToolchainOverride(
    FlowHeroToolchainKind kind,
    String path,
  ) async {
    final String trimmed = path.trim();
    if (trimmed.isEmpty) {
      return const FlowHeroToolchainSaveResult.failed('未填写二进制路径');
    }
    try {
      await _toolchainStore?.savePath(kind, trimmed);
    } on Object {
      return const FlowHeroToolchainSaveResult.failed(
        '保存失败 · 无法写入 toolchain.json',
      );
    }
    _toolchainSelection = _toolchainSelection.withPath(kind, trimmed);
    notifyListeners();
    final bool owned = _executionBoot != null;
    await _rebootExecution();
    final String languageNote = kind == FlowHeroToolchainKind.styio
        ? await _rebootLanguageService()
        : '';
    if (!owned) {
      return FlowHeroToolchainSaveResult(
        saved: true,
        stateLine: '已保存 · 当前执行路由由宿主提供，重启后生效',
        languageNote: languageNote,
      );
    }
    final String stateLine = executionLive
        ? (_execution?.statusLine ?? '执行服务已就绪')
        : executionUnavailableReason;
    return FlowHeroToolchainSaveResult(
      saved: true,
      stateLine: stateLine,
      languageNote: languageNote,
    );
  }

  Future<String> _rebootLanguageService() async {
    final FlowHeroLanguageBoot? boot = _languageBoot;
    if (boot == null) return '语言服务将在重启后使用新工具链';
    try {
      final FlowHeroLanguageSession runtime = await boot(_toolchainSelection);
      if (_disposed) {
        unawaited(runtime.dispose());
        return '';
      }
      _languageBootedSelection = _toolchainSelection;
      attachLanguageService(runtime, selection: _toolchainSelection);
      return '语言服务已重新探测 · ${runtime.statusLine}';
    } on Object {
      return '语言服务将在重启后使用新工具链';
    }
  }

  // ── theme ────────────────────────────────────────────────────
  FlowHeroThemeStore? _themeStore;

  /// True only when the light/dark choice survives a restart.
  bool get themePersistent => _themeStore?.persistent ?? false;

  void attachThemeStore(FlowHeroThemeStore store) => _themeStore = store;

  /// Flips the palette and persists it when a store is attached.
  Future<void> setDark(bool dark) async {
    if (P.dark == dark) return;
    P.dark = dark;
    notifyListeners();
    await _themeStore?.saveDark(dark);
  }

  /// Applies a restored choice without writing it back.
  void applyRestoredDark(bool dark) {
    if (P.dark == dark) return;
    P.dark = dark;
    notifyListeners();
  }

  // ── model configuration ──────────────────────────────────────
  FlowHeroModelConfigStore? _modelConfigStore;
  FlowHeroProviderConfigWriter? _providerConfigWriter;
  FlowHeroAgentSecretStore? _agentSecretStore;
  final Completer<void> _modelConfigBooted = Completer<void>();

  FlowHeroModelConfig? _modelConfig;
  bool _hasModelApiKey = false;

  /// The user's provider configuration, or null while nothing is configured.
  FlowHeroModelConfig? get modelConfig => _modelConfig;

  /// True only when a saved configuration passed the same rules the runtime
  /// enforces — an invalid file is not reported as configured.
  bool get modelConfigSaved =>
      _modelConfig != null && _modelConfig!.validate().isEmpty;

  /// Whether a bearer token exists in the keychain. The value itself is never
  /// read back into the workbench.
  bool get hasModelApiKey => _hasModelApiKey;

  Future<bool> _modelRouteReady() async {
    await _modelConfigBooted.future;
    final FlowHeroProviderConfigWriter? writer = _providerConfigWriter;
    // No writer only happens for tests and bare embeddings, where the caller
    // owns the launch route; nothing is gated then.
    if (writer == null) return true;
    try {
      return await writer.exists();
    } on Object {
      return false;
    }
  }

  Future<void> _bootModelConfig() async {
    try {
      final FlowHeroModelConfigStore? store = _modelConfigStore;
      if (store != null) {
        final FlowHeroModelConfig? loaded = await store.load();
        if (loaded != null) _modelConfig = loaded;
      }
      final FlowHeroAgentSecretStore? secrets = _agentSecretStore;
      if (secrets != null) {
        _hasModelApiKey = await secrets.hasKey();
      }
    } on Object {
      // A failed read leaves the route unconfigured; the panel says so.
    } finally {
      if (!_modelConfigBooted.isCompleted) _modelConfigBooted.complete();
      if (!_disposed) notifyListeners();
    }
  }

  /// Validates, persists the non-secret half, materializes `provider.json` at
  /// the launch-contract path, stores or clears the key, and rebuilds the
  /// agent link. Nothing is reported as saved unless all of it happened.
  Future<FlowHeroModelConfigSaveResult> saveModelConfig(
    FlowHeroModelConfig config, {
    String? apiKey,
  }) async {
    final String key = apiKey?.trim() ?? '';
    final Map<String, String> errors = config.validateForSave(
      hasStoredApiKey: _hasModelApiKey || key.isNotEmpty,
    );
    if (errors.isNotEmpty) {
      return FlowHeroModelConfigSaveResult.invalid(errors);
    }
    try {
      await _modelConfigStore?.save(config);
      final FlowHeroProviderConfigWriter? writer = _providerConfigWriter;
      if (writer != null) await writer.write(config);
      final FlowHeroAgentSecretStore? secrets = _agentSecretStore;
      if (secrets != null) {
        if (config.authMode == FlowHeroModelAuthMode.none) {
          await secrets.deleteKey();
          _hasModelApiKey = false;
        } else if (key.isNotEmpty) {
          await secrets.saveKey(key);
          _hasModelApiKey = true;
        }
      }
    } on Object {
      return FlowHeroModelConfigSaveResult.failed('保存失败 · 无法写入模型配置');
    }
    _modelConfig = config;
    notifyListeners();
    try {
      await bridge.reconnect();
    } on Object {
      // The configuration is on disk; a failed rewire is reported by the
      // bridge's own mode/status line, not as a failed save.
    }
    return FlowHeroModelConfigSaveResult.saved();
  }

  // ── quick open ───────────────────────────────────────────────
  void toggleQuickOpen() {
    quickOpenVisible = !quickOpenVisible;
    notifyListeners();
  }

  void closeQuickOpen() {
    if (!quickOpenVisible) return;
    quickOpenVisible = false;
    notifyListeners();
  }

  void select(String id) {
    selectedId = id;
    dockExpanded = true;
    notifyListeners();
  }

  /// Expand/collapse toggle — the only way the dock goes away. Blank-canvas
  /// drags pan the board and never dismiss it.
  void toggleDock() {
    dockExpanded = !dockExpanded;
    notifyListeners();
  }

  void moveNode(String id, Offset delta) {
    final HeroNode? n = byId(id);
    if (n == null) return;
    n.pos += delta;
    notifyListeners();
  }

  void panBy(Offset delta) {
    pan += delta;
    notifyListeners();
  }

  void toggleTree() {
    treeVisible = !treeVisible;
    notifyListeners();
  }

  void pickFile(String name, {String? path}) {
    activeFile = name;
    treeVisible = false;
    editorMode = true; // opening a file opens the editor
    if (path != null) {
      unawaited(
        engine.openPath(path).then((bool ok) {
          if (!ok) postAgentNote('打不开 $name —— 不是可读的 UTF-8 文本。');
        }),
      );
    }
    notifyListeners();
  }

  void setEditorMode(bool v) {
    editorMode = v;
    notifyListeners();
  }

  // ── settings ───────────────────────────────────────────────
  bool settingsVisible = false;

  void toggleSettings() {
    settingsVisible = !settingsVisible;
    notifyListeners();
  }

  // ── workspace selection (runtime) ───────────────────────────
  FlowHeroWorkspaceStore? _workspaceStore;
  FlowHeroWorkspacePicker? _workspacePicker;
  final FlowHeroWorkspaceFileIndexFactory _workspaceFileIndexFactory;
  String _workspaceRoot = '';

  /// The chosen workspace root; empty means none is configured, which keeps the
  /// demo / package-root fallback behaviour.
  String get workspaceRoot => _workspaceRoot;

  /// The path the drawer and quick-open walk: the chosen root, or the
  /// package-root fallback the pre-selection build already used.
  String get workspaceRootDisplayPath => _workspaceRoot.isNotEmpty
      ? _workspaceRoot
      : flowHeroWorkspaceRoot(AgentBridge.workspaceDir);

  /// True only when the choice survives a restart.
  bool get workspacePersistent => _workspaceStore?.persistent ?? false;

  /// The initial adoption of a persisted selection. Exposed so tests can await
  /// it instead of guessing at timing.
  @visibleForTesting
  Future<void> workspaceBootSettled = Future<void>.value();

  /// Adopts a persisted selection after the (possibly deferred) store boot.
  ///
  /// The first attach already ran with the build-time root, so a stored root
  /// that differs is applied through the same [switchWorkspace] path the UI
  /// uses — without writing it back, since it is already stored. The initial
  /// execution/toolchain boot is awaited first so its route cannot land after
  /// the new root's and silently point at the old workspace.
  Future<void> _bootWorkspaceSelection() async {
    final FlowHeroWorkspaceStore? store = _workspaceStore;
    if (store == null) return;
    String? stored;
    try {
      stored = await store.load();
    } on Object {
      stored = null;
    }
    if (_disposed) return;
    final String path = (stored ?? '').trim();
    if (path.isEmpty || path == _workspaceRoot) return;
    final Future<void>? startup = _toolchainStartInFlight;
    if (startup != null) {
      try {
        await startup;
      } on Object {
        // A failed startup boot reports itself; the switch still proceeds.
      }
    }
    if (_disposed) return;
    await switchWorkspace(path, persist: false);
  }

  /// Opens the platform directory chooser and adopts the chosen root. A cancel
  /// (or a host with no chooser) leaves the current workspace untouched.
  Future<bool> pickWorkspace() async {
    final FlowHeroWorkspacePicker? picker = _workspacePicker;
    if (picker == null) return false;
    String? chosen;
    try {
      chosen = await picker(_workspaceRoot);
    } on Object {
      chosen = null;
    }
    final String path = (chosen ?? '').trim();
    if (path.isEmpty) return false;
    return switchWorkspace(path);
  }

  /// Switches the active workspace at runtime.
  ///
  /// Persists the choice (unless [persist] is false, used when adopting an
  /// already-stored root), re-roots the file index, drops buffers opened from
  /// the previous root, rebuilds the agent link on a fresh session — the Agent
  /// binds a session to its canonical roots, so the old one must not be reused
  /// — re-probes the execution and language routes, and re-attaches the
  /// engine's document store for the new root.
  Future<bool> switchWorkspace(String path, {bool persist = true}) async {
    final String root = path.trim();
    if (root.isEmpty || _disposed) return false;
    if (root == _workspaceRoot) {
      if (persist) await _persistWorkspace(root);
      return true;
    }
    if (persist) await _persistWorkspace(root);
    _workspaceRoot = root;
    workspaceFileIndex = _workspaceFileIndexFactory(root);
    if (engine.resetWorkspaceBuffers()) activeFile = engine.activeFile.name;
    bridge.setWorkspaceRoot(root);
    notifyListeners();
    await bridge.reconnect();
    await _rebootExecution();
    await _rebootLanguageService();
    if (!_disposed) notifyListeners();
    return true;
  }

  Future<void> _persistWorkspace(String root) async {
    try {
      await _workspaceStore?.save(root);
    } on Object {
      // A failed write leaves the choice session-scoped; the applied root is
      // still shown, so there is nothing honest to claim here.
    }
  }

  // ── agent wiring ─────────────────────────────────────────────
  void _agentText(String text) {
    _adoptLiveTranscript();
    postAgentNote(text);
  }

  void _agentReceipt(String text) {
    _adoptLiveTranscript();
    postAgentNote(text, receipt: true);
  }

  void _adoptLiveTranscript() {
    if (_liveTranscript) return;
    _liveTranscript = true;
    messages.clear();
  }

  /// SEND path: live bridge when attached, demo transcript otherwise.
  void sendChat(String text) {
    sendUserMessage(text);
    if (bridge.mode == AgentLinkMode.live) {
      unawaited(bridge.send(text));
    }
  }

  /// Widgets never call notifyListeners directly — they go through these.
  void postAgentNote(String text, {bool receipt = false, bool demo = false}) {
    messages.add(ChatMsg('AGENT', text, receipt: receipt, demo: demo));
    notifyListeners();
  }

  void sendUserMessage(String text) {
    messages.add(ChatMsg('你', text));
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final Timer t in _demoTimers) {
      t.cancel();
    }
    _demoTimers.clear();
    engine.dispose();
    final FlowHeroLanguageSession? language = _languageRuntime;
    if (language != null) unawaited(language.dispose());
    final FlowHeroExecutionSource? execution = _execution;
    if (execution != null) unawaited(execution.dispose());
    bridge.dispose();
    super.dispose();
  }
}

FlowHeroWorkspaceFileIndex _defaultWorkspaceFileIndexFactory(String root) =>
    const _EmptyFlowHeroWorkspaceFileIndex();

class _EmptyFlowHeroWorkspaceFileIndex implements FlowHeroWorkspaceFileIndex {
  const _EmptyFlowHeroWorkspaceFileIndex();

  @override
  Future<List<String>> listFiles() async => const <String>[];
}
