/// Vityo — Flow Hero, the canvas-first workbench direction.
/// Desktop port of the chosen direction proof at
/// `.impeccable/mocks/vityo-flow-hero.html`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../view_ide/flow_hero/flow_hero.dart';
import 'agent_bridge.dart';
import 'tokens.dart';
import 'chat_rail.dart';
import 'controller.dart';
import 'editor_stage.dart';
import 'flow_stage.dart';
import 'palette.dart';
import 'quick_open.dart';
import 'rail.dart';
import 'run_strip.dart';
import 'settings_panel.dart';
import 'source_dock.dart';
import 'toolchain_install.dart';
import 'workspace_drawer.dart';

class FlowHeroApp extends StatefulWidget {
  const FlowHeroApp({
    super.key,
    this.runtime,
    this.executionSource,
    this.themeStore,
    this.workspaceFileIndex,
    this.workspaceStore,
    this.workspacePicker,
    this.modelConfigStore,
    this.providerConfigWriter,
    this.agentSecretStore,
    this.toolchainStore,
    this.initialToolchainSelection = const FlowHeroToolchainSelection(),
    this.executionBoot,
    this.languageBoot,
  });

  /// Real execution route supplied by the host or its feature runtime.
  final FlowHeroExecutionSource? executionSource;

  /// Feature operations supplied by the app composition root.
  final FlowHeroFeatureRuntime? runtime;

  /// Persistence for the light/dark choice. Null keeps the choice session-only.
  final FlowHeroThemeStore? themeStore;

  /// Real workspace file index for quick-open. Null uses the host resolver.
  final FlowHeroWorkspaceFileIndex? workspaceFileIndex;

  /// Persistence for the runtime workspace selection. Null boots the real one
  /// (resolved lazily, degrading to an in-process store).
  final FlowHeroWorkspaceStore? workspaceStore;

  /// Opens the platform directory chooser.
  final FlowHeroWorkspacePicker? workspacePicker;

  /// Persistence for the non-secret model configuration.
  final FlowHeroModelConfigStore? modelConfigStore;

  /// Writer for the launch-contract `provider.json`.
  final FlowHeroProviderConfigWriter? providerConfigWriter;

  /// Write-only keychain access for the provider bearer token.
  final FlowHeroAgentSecretStore? agentSecretStore;

  /// Persistence for the user-selected pafio/styio binaries.
  final FlowHeroToolchainStore? toolchainStore;

  /// The initial selection before the controller restores persisted choices.
  final FlowHeroToolchainSelection initialToolchainSelection;

  /// Overrides execution boot when the host supplies no execution source.
  final FlowHeroExecutionBoot? executionBoot;

  /// Overrides language boot supplied by the feature runtime.
  final FlowHeroLanguageBoot? languageBoot;

  @override
  State<FlowHeroApp> createState() => _FlowHeroAppState();
}

class _FlowHeroAppState extends State<FlowHeroApp> {
  late final FlowHeroFeatureRuntime? runtime;

  late final FlowHeroController controller;

  /// The store the light/dark choice is restored from and written back to.
  late final FlowHeroThemeStore? _themeStore;

  @override
  void initState() {
    super.initState();
    runtime = widget.runtime;
    _themeStore = widget.themeStore ?? runtime?.themeStore;
    controller = FlowHeroController(
      localServices: runtime?.localServices,
      executionSource: widget.executionSource,
      themeStore: _themeStore,
      workspaceFileIndex: widget.workspaceFileIndex,
      workspaceFileIndexFactory: runtime?.createWorkspaceFileIndex,
      workspaceStore: widget.workspaceStore ?? runtime?.workspaceStore,
      workspacePicker: widget.workspacePicker,
      initialWorkspaceRoot: AgentBridge.workspaceDir.trim(),
      initialToolchainSelection: widget.initialToolchainSelection,
      modelConfigStore: widget.modelConfigStore ?? runtime?.modelConfigStore,
      providerConfigWriter:
          widget.providerConfigWriter ?? runtime?.providerConfigWriter,
      agentSecretStore: widget.agentSecretStore ?? runtime?.agentSecretStore,
      toolchainStore: widget.toolchainStore ?? runtime?.toolchainStore,
      toolchainProbe: runtime?.probeToolchain,
      // The controller owns the execution boot so it can re-probe after the
      // user changes workspace or saves a binary. An injected source keeps
      // its host-owned route.
      executionBoot: widget.executionSource != null
          ? widget.executionBoot
          : (widget.executionBoot ?? runtime?.bootExecution),
      languageBoot: widget.languageBoot ?? runtime?.bootLanguage,
    );
    unawaited(_restoreTheme());
  }

  Future<void> _restoreTheme() async {
    final bool? dark = await _themeStore?.loadDark();
    if (!mounted || dark == null) return;
    controller.applyRestoredDark(dark);
  }

  @override
  void dispose() {
    controller.dispose();
    final FlowHeroFeatureRuntime? runtime = this.runtime;
    if (runtime != null) unawaited(runtime.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, _) {
        return MaterialApp(
          title: 'VITYO — Flow Hero',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            brightness: P.dark ? Brightness.dark : Brightness.light,
            scaffoldBackgroundColor: P.room,
            canvasColor: P.room,
            fontFamily: kMono,
            colorScheme:
                (P.dark ? const ColorScheme.dark() : const ColorScheme.light())
                    .copyWith(
                      surface: P.panel,
                      primary: P.red,
                      secondary: P.orange,
                    ),
            splashFactory: NoSplash.splashFactory,
            highlightColor: Colors.transparent,
            hoverColor: Colors.transparent,
          ),
          home: FlowHeroPage(controller: controller),
        );
      },
    );
  }
}

class FlowHeroPage extends StatelessWidget {
  const FlowHeroPage({super.key, required this.controller});

  final FlowHeroController controller;

  @override
  Widget build(BuildContext context) {
    final FlowHeroController c = controller;
    // Left-right split. Each column is a thin 38pt title strip over its
    // content, and the seam between them is a single 1pt line — the split in
    // the title strips is the same line as the split below. The drag handle
    // is an invisible 7pt sash overlaid on that line (VS Code style), so the
    // visible geometry never carries the hit area's width.
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            c.toggleQuickOpen,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            c.toggleQuickOpen,
        const SingleActivator(LogicalKeyboardKey.escape): c.closeQuickOpen,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      children: <Widget>[
                        _MainTitleBar(controller: c),
                        Expanded(
                          child: Row(
                            children: <Widget>[
                              HeroRail(controller: c),
                              WorkspaceDrawer(controller: c),
                              Expanded(
                                // StackFit.expand is load-bearing: Scaffold hands
                                // the body loose constraints, so an all-Positioned
                                // Stack with the default loose fit collapses to
                                // zero height and clips every child away.
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: <Widget>[
                                    Positioned.fill(
                                      child: c.editorMode
                                          ? EditorStage(controller: c)
                                          : FlowStage(controller: c),
                                    ),
                                    // Run strip floats on the canvas corner (V2
                                    // layout) — flow mode only; in editor mode it
                                    // docks into the editor's toolbar instead of
                                    // covering it (editor_stage.dart).
                                    // left+right together bound the strip to the
                                    // canvas width (a right-only Positioned is
                                    // unconstrained), so it shrinks responsively
                                    // on narrow windows.
                                    if (!c.editorMode)
                                      Positioned(
                                        top: 12,
                                        right: 12,
                                        left: 12,
                                        child: Align(
                                          alignment: Alignment.topRight,
                                          child: RunStrip(controller: c),
                                        ),
                                      ),
                                    // The dock is a canvas component — it belongs
                                    // to the flow board, never the editor.
                                    if (!c.editorMode)
                                      SourceDock(controller: c),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    key: const ValueKey('chat-split-line'),
                    width: 1,
                    height: double.infinity,
                    color: P.seamLo,
                  ),
                  SizedBox(
                    width: c.chatWidth,
                    child: ChatRail(controller: c),
                  ),
                ],
              ),
              Positioned(
                top: 0,
                bottom: 0,
                right: c.chatWidth - 3,
                width: 7,
                child: _SplitHandle(
                  key: const ValueKey('chat-split-handle'),
                  onDrag: c.resizeChatBy,
                ),
              ),
              // The workspace drawer's own sash, centred on its right edge. It
              // only exists while the drawer is open and only spans the drawer's
              // height — the title strip above belongs to the window drag zone.
              if (c.treeVisible)
                Positioned(
                  top: _MainTitleBar.height,
                  bottom: 0,
                  left: HeroRail.width + c.treeWidth - 3,
                  width: 7,
                  child: _SplitHandle(
                    key: const ValueKey('tree-split-handle'),
                    onDrag: c.resizeTreeBy,
                    onActive: c.setTreeDragging,
                  ),
                ),
              // Settings rides above everything, sashes included.
              if (c.settingsVisible) SettingsPanel(controller: c),
              // The install dialog opens from the strip or the settings row and
              // rides above the settings card it was launched from.
              if (c.toolchainInstallVisible)
                ToolchainInstallDialog(controller: c),
              // Quick-open rides above settings: ⌘K is the fastest surface and
              // must never be buried.
              if (c.quickOpenVisible) FlowHeroQuickOpen(controller: c),
            ],
          ),
        ),
      ),
    );
  }
}

/// An invisible drag sash over a vertical seam: 7pt of hit area centred on
/// the seam's 1pt line. Painting only happens while hovering or dragging — a
/// hot 3pt line centred on the seam, covering the idle one.
///
/// The window's native drag zone owns the top 38pt (TitleBarDragViewController
/// turns drags there into window moves before Flutter sees them), so gestures
/// effectively start below the strip; the sash is drawn full height anyway to
/// keep the hot line continuous while dragging.
class _SplitHandle extends StatefulWidget {
  const _SplitHandle({super.key, required this.onDrag, this.onActive});

  /// Drag-by-delta, signed in screen space (positive = rightward).
  final ValueChanged<double> onDrag;

  /// Hover/drag activity — the workspace drawer uses it to bypass its reveal
  /// animation while the pointer owns its width.
  final ValueChanged<bool>? onActive;

  @override
  State<_SplitHandle> createState() => _SplitHandleState();
}

class _SplitHandleState extends State<_SplitHandle> {
  bool _hover = false;
  bool _dragging = false;

  void _setDragging(bool value) {
    if (value == _dragging) return;
    setState(() => _dragging = value);
    widget.onActive?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => _setDragging(true),
        onHorizontalDragUpdate: (DragUpdateDetails details) {
          widget.onDrag(details.delta.dx);
        },
        onHorizontalDragEnd: (_) => _setDragging(false),
        onHorizontalDragCancel: () => _setDragging(false),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Positioned(
              left: 2,
              top: 0,
              bottom: 0,
              width: 3,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                color: (_hover || _dragging) ? P.hotWire : Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The main column's 38pt title strip: pipeline name and the link lamp at the
/// left (the traffic lights sit in its 84pt left bay — Runner reserves the
/// top 38pt as the window drag zone) and the quick-open box at the right. The
/// agent column carries its own strip (chat_rail.dart); the seam between the
/// two is the drag handle.
class _MainTitleBar extends StatelessWidget {
  const _MainTitleBar({required this.controller});

  final FlowHeroController controller;

  static const double height = 38;

  @override
  Widget build(BuildContext context) {
    final FlowHeroController c = controller;
    final String pipeline = c.activeFile.split('.').first.toUpperCase();
    return Container(
      key: const ValueKey('main-title-strip'),
      height: height,
      // Right inset 6.5 matches the box's vertical margins: the strip's
      // bottom hairline eats 1pt of the 38pt height, so the 24pt box sits
      // with (38-1-24)/2 = 6.5 above and below.
      padding: const EdgeInsets.only(left: 84, right: 6.5),
      decoration: BoxDecoration(
        color: P.panel,
        border: Border(bottom: BorderSide(color: P.seamLo)),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // Progressive disclosure: the search box steps aside on a narrow
          // main column (the agent column can be dragged wide) instead of
          // overflowing the strip. ⌘K keeps working regardless.
          final bool showSearch = constraints.maxWidth >= 460;
          return Row(
            children: <Widget>[
              Text(pipeline, style: P.silkStyle(hi: true)),
              const SizedBox(width: 12),
              _LiveBadge(controller: c),
              const Spacer(),
              if (showSearch) _SearchBox(onTap: c.toggleQuickOpen),
            ],
          );
        },
      ),
    );
  }
}

/// Square-cornered like everything else on the machine — a capsule would
/// clash with the milled-panel language. Tapping it (or ⌘K) opens the real
/// quick-open overlay.
class _SearchBox extends StatelessWidget {
  const _SearchBox({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Container(
        key: const ValueKey('main-title-search-box'),
        height: 24,
        width: 210,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: P.well,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: P.ring),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.search, size: 13, color: P.silkDim),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '搜索命令 / 文件…',
                style: P.silkStyle(dim: true),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text('⌘K', style: P.silkStyle(dim: true)),
          ],
        ),
      ),
    );
  }
}

/// The main strip's link lamp, mirroring the agent column's (`chat_rail.dart`):
/// green LIVE only while the agent bridge is a real session, amber while it is
/// still connecting, red on failure, and an honest grey DEMO otherwise.
class _LiveBadge extends StatefulWidget {
  const _LiveBadge({required this.controller});

  final FlowHeroController controller;

  @override
  State<_LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<_LiveBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath;

  @override
  void initState() {
    super.initState();
    // Created eagerly: the lamp may not blink in every mode, but dispose must
    // never trip the lazy initializer while the element is unmounting.
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (
      Color dot,
      String label,
      bool glow,
    ) = switch (widget.controller.bridge.mode) {
      AgentLinkMode.live => (const Color(0xFF30D158), 'LIVE', true),
      AgentLinkMode.connecting => (P.orange, '连接中…', true),
      AgentLinkMode.failed => (P.red, '连接失败', false),
      AgentLinkMode.demo => (P.ledOff, 'DEMO', false),
    };
    final Widget lamp = glow
        ? FadeTransition(
            opacity: Tween<double>(begin: 0.45, end: 1).animate(_breath),
            child: _dot(dot, glow: true),
          )
        : _dot(dot, glow: false);
    return Container(
      key: const ValueKey('main-title-status-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: dot.withValues(alpha: 0.7)),
        borderRadius: BorderRadius.circular(2),
        color: P.room.withValues(alpha: 0.6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          lamp,
          const SizedBox(width: 6),
          Text(label, style: P.silkStyle().copyWith(color: dot, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _dot(Color color, {required bool glow}) => Container(
    width: 6,
    height: 6,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color,
      boxShadow: glow
          ? <BoxShadow>[BoxShadow(color: color, blurRadius: 5)]
          : null,
    ),
  );
}
