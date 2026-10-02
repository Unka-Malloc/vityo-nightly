/// Vityo — Flow Hero, the canvas-first workbench direction.
/// Desktop port of the chosen direction proof at
/// `.impeccable/mocks/vityo-flow-hero.html`.
///
/// Run it on its own:
/// `flutter run -d macos -t lib/src/view_render/flow_hero/flow_hero.dart`
///
/// Self-contained: boots no services, talks to no daemon, imports only
/// Flutter, the shared workbench tokens, and its own files.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';
import 'chat_rail.dart';
import 'controller.dart';
import 'editor_stage.dart';
import 'flow_stage.dart';
import 'palette.dart';
import 'rail.dart';
import 'run_strip.dart';
import 'settings_panel.dart';
import 'source_dock.dart';
import 'workspace_drawer.dart';

void main() => runApp(const FlowHeroApp());

class FlowHeroApp extends StatefulWidget {
  const FlowHeroApp({super.key});

  @override
  State<FlowHeroApp> createState() => _FlowHeroAppState();
}

class _FlowHeroAppState extends State<FlowHeroApp> {
  final FlowHeroController controller = FlowHeroController();

  @override
  void dispose() {
    controller.dispose();
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
            colorScheme: (P.dark ? const ColorScheme.dark() : const ColorScheme.light()).copyWith(
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
    return Scaffold(
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
                                  child: c.editorMode ? EditorStage(controller: c) : FlowStage(controller: c),
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
                                if (!c.editorMode) SourceDock(controller: c),
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
        ],
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

/// The main column's 38pt title strip: pipeline name and LIVE badge at the
/// left (the traffic lights sit in its 84pt left bay — Runner reserves the
/// top 38pt as the window drag zone), hint text, and the square search box at
/// the right. The agent column carries its own strip (chat_rail.dart); the
/// seam between the two is the drag handle.
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
              const _LiveBadge(),
              const Spacer(),
              if (showSearch) const _SearchBox(),
            ],
          );
        },
      ),
    );
  }
}

/// Square-cornered like everything else on the machine — a capsule would
/// clash with the milled-panel language.
class _SearchBox extends StatelessWidget {
  const _SearchBox();

  @override
  Widget build(BuildContext context) {
    return Container(
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
            child: Text('搜索命令 / 文件…', style: P.silkStyle(dim: true), overflow: TextOverflow.ellipsis),
          ),
          Text('⌘K', style: P.silkStyle(dim: true)),
        ],
      ),
    );
  }
}

class _LiveBadge extends StatefulWidget {
  const _LiveBadge();

  @override
  State<_LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<_LiveBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: P.red.withValues(alpha: 0.7)),
        borderRadius: BorderRadius.circular(2),
        color: P.room.withValues(alpha: 0.6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FadeTransition(
            opacity: Tween<double>(begin: 0.45, end: 1).animate(_breath),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(shape: BoxShape.circle, color: P.red, boxShadow: <BoxShadow>[BoxShadow(color: P.red, blurRadius: 5)]),
            ),
          ),
          const SizedBox(width: 6),
          Text('LIVE 投影', style: P.silkStyle().copyWith(color: P.redBright, fontSize: 10)),
        ],
      ),
    );
  }
}
