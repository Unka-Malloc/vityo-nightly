/// The hero canvas: a Flutter transcription of the stage in
/// `.impeccable/mocks/vityo-flow-hero.html`. A dotted grid, sagging cables
/// (hot ones flow, 7/9 dashes on a 1.1s cycle like the mock's
/// `stroke-dashoffset` animation), and node cards — head with status lamp and
/// uppercase name, body with the call and its signature, side ports.
///
/// Both modes are served through `P`: charcoal board at night, a warm
/// drafting-paper sheet by day.
///
/// Gestures: drag a card to move it, drag the background to pan, tap a card
/// to select it (the controller opens the source dock).
library;

import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import 'controller.dart';
import 'palette.dart';

/// Card geometry, fixed like the mock: 188×86, ports centred on the midline.
const double kCardW = 188;
const double kCardH = 86;
const double kPortD = 13;
const double kPortY = kCardH / 2;

class HeroBoard extends StatefulWidget {
  const HeroBoard({super.key, required this.controller});

  final FlowHeroController controller;

  @override
  State<HeroBoard> createState() => _HeroBoardState();
}

class _HeroBoardState extends State<HeroBoard>
    with SingleTickerProviderStateMixin {
  /// Drives the hot cables' dash phase — the mock's `flow 1.1s linear
  /// infinite` keyframe.
  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _flow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FlowHeroController c = widget.controller;
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[c, _flow]),
      builder: (BuildContext context, Widget? _) {
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (DragUpdateDetails d) => c.panBy(d.delta),
              child: CustomPaint(
                painter: _StagePainter(
                  nodes: c.nodes,
                  edges: c.edges,
                  pan: c.pan,
                  phase: _flow.value,
                ),
              ),
            ),
            for (final HeroNode n in c.nodes)
              Positioned(
                left: n.pos.dx + c.pan.dx,
                top: n.pos.dy + c.pan.dy,
                width: kCardW,
                height: kCardH,
                child: _NodeCard(
                  key: ValueKey<String>(n.id),
                  node: n,
                  selected: c.selectedId == n.id,
                  entering: c.flashingId == n.id,
                  onTap: () => c.select(n.id),
                  onDrag: (Offset delta) => c.moveNode(n.id, delta),
                ),
              ),
            // Honest empty state: no real workspace buffer, nothing to project.
            if (c.nodes.isEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: _EmptyCanvas(reason: c.projectionEmptyReason),
                ),
              ),
            // The projection's source, named the same way the settings panel
            // names the language route.
            if (c.projectionBadgeLabel.isNotEmpty)
              Positioned(
                left: 14,
                top: 14,
                child: IgnorePointer(child: _SourceBadge(controller: c)),
              ),
          ],
        );
      },
    );
  }
}

/// ------------------------------------------------------------------ stage ---
/// Grid, cables. Painted under the cards, panned with them.
class _StagePainter extends CustomPainter {
  _StagePainter({
    required this.nodes,
    required this.edges,
    required this.pan,
    required this.phase,
  });

  final List<HeroNode> nodes;
  final List<HeroEdge> edges;
  final Offset pan;

  /// 0..1, loops every 1.1s.
  final double phase;

  static const double _grid = 26;

  HeroNode? _byId(String id) {
    for (final HeroNode n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final Rect area = Offset.zero & size;
    canvas.drawRect(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[P.canvasTop, P.canvasBottom],
        ).createShader(area),
    );

    final Paint dot = Paint()..color = P.gridDot;
    final double ox = pan.dx % _grid;
    final double oy = pan.dy % _grid;
    for (double x = ox; x < size.width; x += _grid) {
      for (double y = oy; y < size.height; y += _grid) {
        canvas.drawCircle(Offset(x, y), 1, dot);
      }
    }

    for (final HeroEdge e in edges) {
      final HeroNode? a = _byId(e.a);
      final HeroNode? b = _byId(e.b);
      if (a == null || b == null) continue;
      // Out-port centre of A → in-port centre of B, both on the card midline.
      final Offset p1 = a.pos + pan + const Offset(kCardW, kPortY);
      final Offset p2 = b.pos + pan + const Offset(0, kPortY);
      final double sag = math.max(40, (p2.dx - p1.dx) * .32);
      final Path cable = Path()
        ..moveTo(p1.dx, p1.dy)
        ..cubicTo(
          p1.dx + sag,
          p1.dy + sag * .4,
          p2.dx - sag,
          p2.dy - sag * .4,
          p2.dx,
          p2.dy,
        );
      if (e.hot) {
        canvas.drawPath(
          cable,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5
            ..color = P.hotWire.withValues(alpha: P.dark ? 0.55 : 0.4)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
        canvas.drawPath(
          _dashed(cable, 7, 9, phase),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5
            ..strokeCap = StrokeCap.round
            ..color = P.hotWire,
        );
      } else {
        canvas.drawPath(
          cable,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5
            ..color = P.cableCold,
        );
      }
    }
  }

  /// Dashes [src] with [dash]/[gap]; [phase] 0..1 walks the pattern one full
  /// period forward, so dashes stream from the out-port to the in-port.
  static Path _dashed(Path src, double dash, double gap, double phase) {
    final Path out = Path();
    final double period = dash + gap;
    final double shift = (phase * period) % period;
    for (final PathMetric m in src.computeMetrics()) {
      double cursor = shift - period;
      while (cursor < m.length) {
        final double from = cursor < 0 ? 0 : cursor;
        final double to = math.min(cursor + dash, m.length);
        if (to > from) out.addPath(m.extractPath(from, to), Offset.zero);
        cursor += period;
      }
    }
    return out;
  }

  @override
  bool shouldRepaint(_StagePainter old) => true; // animated; cheap at this scale
}

/// ------------------------------------------------------------------- card ---
class _NodeCard extends StatefulWidget {
  const _NodeCard({
    super.key,
    required this.node,
    required this.selected,
    required this.entering,
    required this.onTap,
    required this.onDrag,
  });

  final HeroNode node;
  final bool selected;

  /// Plays the mock's `nodeIn`: fade + scale .92→1 + rise 8px, once.
  final bool entering;
  final VoidCallback onTap;
  final ValueChanged<Offset> onDrag;

  @override
  State<_NodeCard> createState() => _NodeCardState();
}

class _NodeCardState extends State<_NodeCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    Widget card = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onPanUpdate: (DragUpdateDetails d) => widget.onDrag(d.delta),
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Container(
              decoration: BoxDecoration(
                color: P.panel.withValues(alpha: P.dark ? 0.94 : 0.97),
                borderRadius: BorderRadius.circular(5),
                // Mock: seam-lo all round + a seam-hi top lip, drawn as a 1px
                // shadow strip (BoxDecoration can't mix border sides with a
                // radius). `.sel` swaps the whole shadow set for the red ring.
                border: Border.all(color: P.seamLo),
                boxShadow: widget.selected
                    ? <BoxShadow>[
                        BoxShadow(color: P.red, spreadRadius: 1),
                        BoxShadow(
                          color: P.red.withValues(alpha: P.dark ? 0.3 : 0.22),
                          blurRadius: P.dark ? 24 : 20,
                        ),
                      ]
                    : <BoxShadow>[
                        BoxShadow(
                          color: P.cardShadow.withValues(
                            alpha: P.dark ? 0.55 : 0.3,
                          ),
                          blurRadius: P.dark ? 22 : 18,
                          offset: Offset(0, P.dark ? 6 : 5),
                        ),
                        BoxShadow(color: P.seamHi, offset: const Offset(0, -1)),
                        if (_hover) BoxShadow(color: P.ring, spreadRadius: 1),
                      ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _head(),
                  Expanded(child: _body()),
                ],
              ),
            ),
            const Positioned(
              left: -kPortD / 2,
              top: kPortY - kPortD / 2,
              child: _Port(),
            ),
            const Positioned(
              right: -kPortD / 2,
              top: kPortY - kPortD / 2,
              child: _Port(),
            ),
          ],
        ),
      ),
    );
    if (widget.entering) {
      card = TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
        builder: (BuildContext context, double v, Widget? child) => Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - v)),
            child: Transform.scale(scale: .92 + .08 * v, child: child),
          ),
        ),
        child: card,
      );
    }
    return card;
  }

  Widget _head() {
    final NodeStatus s = widget.node.status;
    final Color lamp = s == NodeStatus.running
        ? P.orangeBright
        : P.yellowBright;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: P.panelHi,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
        border: Border(bottom: BorderSide(color: P.seamLo)),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: s == NodeStatus.idle ? P.ledOff : lamp,
              boxShadow: s == NodeStatus.idle
                  ? null
                  : <BoxShadow>[BoxShadow(color: lamp, blurRadius: 6)],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.node.name.toUpperCase(),
              style: P.silkStyle(hi: true),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // A confirmed node's identity came from a real service symbol, not
          // just the local parse — worth one honest mark.
          if (widget.node.serviceConfirmed) ...<Widget>[
            const SizedBox(width: 6),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF30D158)),
              ),
            ),
          ],
          // Demo content says so on the card itself, never passed off as real.
          if (widget.node.demo) ...<Widget>[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                border: Border.all(color: P.orange),
                borderRadius: BorderRadius.circular(2),
              ),
              child: Text(
                '演示',
                style: P.silkStyle().copyWith(color: P.orange, fontSize: 9),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _body() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${widget.node.name}()',
            style: P.monoStyle(color: P.paper, size: 12),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            widget.node.sig,
            style: P.monoStyle(color: P.silk, size: 10.5),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// A jack on the card's waist: well fill, 2px ring, purely decorative — hits
/// fall through to the card beneath, like the mock.
class _Port extends StatelessWidget {
  const _Port();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: kPortD,
      height: kPortD,
      decoration: BoxDecoration(
        color: P.well,
        shape: BoxShape.circle,
        border: Border.all(color: P.ring, width: 2),
      ),
    );
  }
}

/// The canvas's honest empty state — shown whenever there is no real workspace
/// buffer to project. Never a placeholder graph.
class _EmptyCanvas extends StatelessWidget {
  const _EmptyCanvas({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final String text = reason.isEmpty ? '打开工作区文件以生成真实图' : reason;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.hub_outlined, size: 26, color: P.silkDim),
          const SizedBox(height: 10),
          Text(
            text,
            key: const ValueKey('flow-hero-empty-state'),
            textAlign: TextAlign.center,
            style: P.silkStyle(dim: true),
          ),
        ],
      ),
    );
  }
}

/// Names where the canvas projection came from — `语义服务投影` when a live
/// `styio_lspd` route informed it, `本地解析投影` when the local engine parse
/// backs it. Mirrors the settings panel's language row.
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.controller});

  final FlowHeroController controller;

  @override
  Widget build(BuildContext context) {
    final bool semantic =
        controller.projectionSource == FlowHeroProjectionSource.semanticService;
    final Color tint = semantic ? const Color(0xFF30D158) : P.orange;
    return Container(
      key: const ValueKey('flow-hero-source-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: P.room.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: tint.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: tint),
          ),
          const SizedBox(width: 6),
          Text(
            controller.projectionBadgeLabel,
            style: P.silkStyle().copyWith(color: tint, fontSize: 10),
          ),
        ],
      ),
    );
  }
}
