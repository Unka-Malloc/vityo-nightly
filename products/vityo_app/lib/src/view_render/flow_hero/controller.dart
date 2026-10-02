/// Flow Hero controller: graph state, dock/tree/view/theme toggles, the run
/// ticker and the scripted agent-write simulation. Pure Flutter, no services.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'agent_bridge.dart';
import 'engine/machine.dart';

enum NodeStatus { idle, running, done }

class HeroNode {
  HeroNode({
    required this.id,
    required this.name,
    required this.sig,
    required this.pos,
    this.status = NodeStatus.idle,
  });

  final String id;
  final String name;
  final String sig;
  Offset pos;
  NodeStatus status;
}

class HeroEdge {
  const HeroEdge(this.a, this.b, {this.hot = true});
  final String a;
  final String b;
  final bool hot;
}

class ChatMsg {
  const ChatMsg(this.who, this.text, {this.receipt = false});
  final String who;
  final String text;
  final bool receipt;
}

class FlowHeroController extends ChangeNotifier {
  FlowHeroController() {
    engine.addListener(notifyListeners);
    bridge.addListener(notifyListeners);
    unawaited(
      bridge.attach(
        engine: engine,
        onText: _agentText,
        onReceipt: _agentReceipt,
      ),
    );
    _seed();
  }

  /// The real workbench engine: buffers, FLOW board geometry, run state.
  final WorkbenchController engine = WorkbenchController();

  /// The real agent link (vityod gateway → registry → session). Demo mode
  /// until attach() proves otherwise.
  final AgentBridge bridge = AgentBridge();
  bool _liveTranscript = false;

  // ── graph ────────────────────────────────────────────────────
  final List<HeroNode> nodes = <HeroNode>[
    HeroNode(
      id: 'fetch',
      name: 'fetch_users',
      sig: 'api: Endpoint → List[User]',
      pos: const Offset(70, 110),
      status: NodeStatus.done,
    ),
    HeroNode(
      id: 'valid',
      name: 'validate',
      sig: 's: Schema → Rule',
      pos: const Offset(340, 70),
      status: NodeStatus.done,
    ),
    HeroNode(
      id: 'dedup',
      name: 'dedupe',
      sig: 'key: Str → Rule',
      pos: const Offset(340, 230),
      status: NodeStatus.running,
    ),
    HeroNode(
      id: 'emit',
      name: 'emit',
      sig: 'to: warehouse',
      pos: const Offset(620, 150),
      status: NodeStatus.running,
    ),
    HeroNode(
      id: 'state',
      name: 'sync',
      sig: 'state · idle → running',
      pos: const Offset(620, 310),
    ),
  ];
  final List<HeroEdge> edges = <HeroEdge>[
    const HeroEdge('fetch', 'valid'),
    const HeroEdge('valid', 'dedup'),
    const HeroEdge('dedup', 'emit'),
    const HeroEdge('state', 'emit', hot: false),
  ];

  HeroNode? byId(String id) {
    for (final HeroNode n in nodes) {
      if (n.id == id) return n;
    }
    return null;
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

  // ── run strip ────────────────────────────────────────────────
  bool running = false;
  int playhead = -1;
  final Set<int> litSteps = <int>{};
  Timer? _runTimer;

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

  void toggleTheme() {
    // palette import avoided here; flow_hero.dart flips P.dark then calls this.
    notifyListeners();
  }

  void toggleRun() {
    if (running) {
      _runTimer?.cancel();
      running = false;
    } else {
      running = true;
      _runTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
        playhead = (playhead + 1) % 16;
        litSteps.add(playhead);
        notifyListeners();
      });
    }
    notifyListeners();
  }

  void clearRun() {
    playhead = -1;
    litSteps.clear();
    notifyListeners();
  }

  // ── agent simulation ─────────────────────────────────────────
  void _seed() {
    messages.addAll(const <ChatMsg>[
      ChatMsg('你', '给 user_sync 加 enrich 阶段。'),
      ChatMsg('AGENT', '收到，写入中 —— 看画布。'),
    ]);
    Timer(const Duration(milliseconds: 2600), () {
      nodes.add(
        HeroNode(
          id: 'enrich',
          name: 'enrich',
          sig: 'u: User → User+Profile',
          pos: const Offset(470, 330),
          status: NodeStatus.running,
        ),
      );
      edges.add(const HeroEdge('dedup', 'enrich'));
      edges.add(const HeroEdge('enrich', 'emit'));
      flashingId = 'enrich'; // 写代码时代码框不弹，节点闪一下
      messages.add(
        const ChatMsg('AGENT', '已写入 fn enrich，接入 dedupe → emit 之间。'),
      );
      notifyListeners();
    });
    Timer(const Duration(milliseconds: 4200), () {
      messages.add(
        const ChatMsg('AGENT', '回执 · +9 行 user_sync.sty · 测试通过', receipt: true),
      );
      notifyListeners();
    });
  }

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
  void postAgentNote(String text, {bool receipt = false}) {
    messages.add(ChatMsg('AGENT', text, receipt: receipt));
    notifyListeners();
  }

  void sendUserMessage(String text) {
    messages.add(ChatMsg('你', text));
    notifyListeners();
  }

  @override
  void dispose() {
    _runTimer?.cancel();
    engine.dispose();
    bridge.dispose();
    super.dispose();
  }
}
