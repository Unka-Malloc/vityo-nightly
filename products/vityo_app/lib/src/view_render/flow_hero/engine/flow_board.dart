/// The FLOW board: a `CustomPainter` fed by the generated graph model. Cables
/// first, modules over them, jacks and plugs on top, chips last — the proof's
/// own draw order, so a longer program lengthens the board instead of
/// colliding inside it.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Chip, Cubic;
import 'package:flutter/scheduler.dart';

import '../flow_model.dart';
import 'machine.dart';
import '../tokens.dart';

/// A real measurer for the graph's furniture (port note (o): measure, don't
/// count characters).
class FlutterGlyphs implements Glyphs {
  const FlutterGlyphs();

  @override
  double width(String text, GraphFont font) {
    if (text.isEmpty) return 0;
    switch (font) {
      case GraphFont.modName:
        return measure(text, T.modName).width;
      case GraphFont.modKind:
        return measure(text, T.modKind).width;
      case GraphFont.chip:
      case GraphFont.chipWarn:
        return measure(text, T.chipLabel).width;
    }
  }
}

/// A lamps: two drop-shadows and a lens — the one glow recipe, at any size.
void paintLamp(Canvas canvas, Offset c, double r, Color color, {bool lit = false, bool amber = false}) {
  final Color tint = amber ? C.orange : color;
  if (!lit) {
    canvas.drawCircle(c, r, Paint()..color = C.ledOff);
    return;
  }
  canvas.drawCircle(
    c,
    r,
    Paint()
      ..color = tint.withValues(alpha: 0.9)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.6),
  );
  canvas.drawCircle(
    c,
    r,
    Paint()
      ..color = tint.withValues(alpha: 0.4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.2),
  );
  canvas.drawCircle(c, r, Paint()..color = tint);
}

void _baselineText(Canvas canvas, String text, TextStyle style, Offset at, TextAnchor anchor) {
  final TextPainter tp = measure(text, style);
  double dx = at.dx;
  if (anchor == TextAnchor.middle) dx -= tp.width / 2;
  if (anchor == TextAnchor.end) dx -= tp.width;
  final double baseline = tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
  tp.paint(canvas, Offset(dx, at.dy - baseline));
}

Path _dashed(Path src, double dash, double gap) {
  final Path out = Path();
  for (final ui.PathMetric m in src.computeMetrics()) {
    double d = 0;
    while (d < m.length) {
      final double end = math.min(d + dash, m.length);
      out.addPath(m.extractPath(d, end), Offset.zero);
      d = end + gap;
    }
  }
  return out;
}

Path _curvePath(Cubic c) => Path()
  ..moveTo(c.p0.x, c.p0.y)
  ..cubicTo(c.c1.x, c.c1.y, c.c2.x, c.c2.y, c.p3.x, c.p3.y);

class FlowBoard extends StatefulWidget {
  const FlowBoard({super.key, required this.controller});

  final WorkbenchController controller;

  @override
  State<FlowBoard> createState() => _FlowBoardState();
}

class _FlowBoardState extends State<FlowBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  Duration _last = Duration.zero;
  bool _scrollableH = false;
  bool _scrollableV = false;
  late final ScrollController _h = ScrollController();
  late final ScrollController _v = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncTicker);
    _syncTicker();
  }

  @override
  void didUpdateWidget(FlowBoard old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_syncTicker);
      widget.controller.addListener(_syncTicker);
    }
  }

  void _syncTicker() {
    final WorkbenchController c = widget.controller;
    if ((c.flowOn || c.pulses.isNotEmpty) && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!c.flowOn && c.pulses.isEmpty && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    final double dt = math.min(
      (elapsed - _last).inMicroseconds / 1000.0,
      50,
    );
    _last = elapsed;
    if (dt <= 0) return;
    widget.controller.tickPulses(dt, visible: true);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncTicker);
    _ticker.dispose();
    _h.dispose();
    _v.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final GraphBoard board = widget.controller.graph;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // the board holds a max(760, rightmost + 48) × max(480, lowest + 72)
        // floor: below it the well pans, above it the board fills the well and
        // its 11px labels grow with it.
        final double boxW = math.max(c.maxWidth, board.maxX);
        final double boxH = math.max(c.maxHeight, board.maxY);
        _scrollableH = boxW > c.maxWidth + 0.5;
        _scrollableV = boxH > c.maxHeight + 0.5;
        Widget canvasBox = SizedBox(
          width: boxW,
          height: boxH,
          child: RepaintBoundary(
            child: CustomPaint(
              size: Size(boxW, boxH),
              painter: _BoardPainter(
                controller: widget.controller,
                board: board,
                scale: math.min(boxW / board.maxX, boxH / board.maxY),
              ),
            ),
          ),
        );
        canvasBox = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          controller: _h,
          physics: _scrollableH
              ? const ClampingScrollPhysics()
              : const NeverScrollableScrollPhysics(),
          child: SingleChildScrollView(
            controller: _v,
            physics: _scrollableV
                ? const ClampingScrollPhysics()
                : const NeverScrollableScrollPhysics(),
            child: canvasBox,
          ),
        );
        return ClipRect(child: canvasBox);
      },
    );
  }
}

class _BoardPainter extends CustomPainter {
  _BoardPainter({required this.controller, required this.board, required this.scale})
      : super(repaint: controller);

  final WorkbenchController controller;
  final GraphBoard board;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    final double dx = (size.width - board.maxX * scale) / 2;
    final double dy = (size.height - board.maxY * scale) / 2;
    canvas.translate(dx, dy);
    canvas.scale(scale);

    _grid(canvas);
    _cables(canvas);
    _controlVoltages(canvas);
    _modules(canvas);
    _jacksAndPlugs(canvas);
    _chips(canvas);
    _pulses(canvas);
    _plate(canvas);
    canvas.restore();
  }

  void _grid(Canvas canvas) {
    final Paint dot = Paint()..color = const Color(0x0AFFFFFF);
    for (double x = 0; x < board.maxX; x += 24) {
      for (double y = 0; y < board.maxY; y += 24) {
        canvas.drawCircle(Offset(x + 1.2, y + 1.2), 1.2, dot);
      }
    }
  }

  void _cables(Canvas canvas) {
    final Paint shadow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round
      ..color = const Color(0x73000000);
    final Paint silk = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..color = C.silk;
    final Path shadowPath = Path();
    final Path cablePath = Path();
    for (final BoardCable c in board.cables) {
      if (c.cv) continue;
      final Path p = _curvePath(c.curve);
      shadowPath.addPath(p, const Offset(0, 2));
      cablePath.addPath(p, Offset.zero);
    }
    canvas.drawPath(shadowPath, shadow);
    canvas.drawPath(cablePath, silk);
    // an input route that never seats frays before the jack
    final Paint stray = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..color = C.silk;
    for (final Pt p in board.strays) {
      canvas.drawLine(Offset(p.x, p.y), Offset(p.x - 5, p.y + 8), stray);
      canvas.drawLine(Offset(p.x, p.y), Offset(p.x, p.y + 9), stray);
      canvas.drawLine(Offset(p.x, p.y), Offset(p.x + 5, p.y + 7), stray);
    }
  }

  void _controlVoltages(Canvas canvas) {
    final Paint cv = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..color = C.silkDim;
    final Path dashed = Path();
    for (final BoardCable c in board.cables) {
      if (!c.cv) continue;
      dashed.addPath(_dashed(_curvePath(c.curve), 6, 5), Offset.zero);
    }
    canvas.drawPath(dashed, cv);
    // tap dots are CV furniture: under the modules and chips, same as the
    // proof's gCV group — a tap landing on a cable's chip hides beneath it
    final Paint tap = Paint()..color = C.silk;
    for (final BoardTap t in board.taps) {
      canvas.drawCircle(Offset(t.point.x, t.point.y), 3, tap);
    }
  }

  void _modules(Canvas canvas) {
    for (final GraphModule n in board.modules) {
      final Rect r = Rect.fromLTWH(n.x, n.y, n.w, n.h);
      final RRect rr = RRect.fromRectAndRadius(r, const Radius.circular(5));
      canvas.drawRRect(
        rr,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[C.modFaceHi, C.modFaceLo],
          ).createShader(r),
      );
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = C.seamHi,
      );
      canvas.drawLine(
        Offset(n.x + 1, n.y + 1),
        Offset(n.x + n.w - 1, n.y + 1),
        Paint()
          ..strokeWidth = 1
          ..color = const Color(0x12FFFFFF),
      );
      _baselineText(
        canvas,
        n.name.toUpperCase(),
        T.modName,
        Offset(n.x + 14, n.y + 22),
        TextAnchor.start,
      );
      if (n.isState) {
        for (final Lamp l in n.lamps) {
          final bool lit = controller.stateLampLit(l);
          paintLamp(
            canvas,
            Offset(l.at.x, l.at.y),
            3,
            C.red,
            lit: lit,
            amber: lit && controller.stateLampAmber(l),
          );
          _baselineText(
            canvas,
            l.name.toUpperCase(),
            T.modKind,
            Offset(n.x + 32, l.at.y + 4),
            TextAnchor.start,
          );
        }
      } else {
        _baselineText(
          canvas,
          n.kindText,
          T.modKind,
          Offset(n.x + 14, n.y + 37),
          TextAnchor.start,
        );
        paintLamp(
          canvas,
          Offset(n.sled.x, n.sled.y),
          3,
          C.red,
          lit: controller.moduleLampLit(n),
        );
      }
    }
  }

  void _jacksAndPlugs(Canvas canvas) {
    final Paint ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = C.terminalRing;
    final Paint hole = Paint()..color = C.well;
    final Paint core = Paint()..color = C.seamLo;
    for (final Pt j in board.jacks) {
      canvas.drawCircle(Offset(j.x, j.y), 5, hole);
      canvas.drawCircle(Offset(j.x, j.y), 5, ring);
      canvas.drawCircle(Offset(j.x, j.y), 1.6, core);
    }
    final Paint body = Paint()..color = C.plugBody;
    final Paint edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = C.terminalRing;
    final Paint band = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = C.plugRing;
    for (final ({Pt at, double angle}) p in board.plugs) {
      canvas.save();
      canvas.translate(p.at.x, p.at.y);
      canvas.rotate(p.angle * math.pi / 180);
      final RRect pr = RRect.fromRectAndRadius(
        const Rect.fromLTWH(-6.5, -4, 13, 8),
        const Radius.circular(3),
      );
      canvas.drawRRect(pr, body);
      canvas.drawRRect(pr, edge);
      canvas.drawLine(const Offset(3.5, -4), const Offset(3.5, 4), band);
      canvas.restore();
    }
  }

  void _chips(Canvas canvas) {
    for (final Chip chip in board.chips) {
      final Rect r = Rect.fromLTWH(
        chip.center.x - chip.width / 2,
        chip.center.y - 8,
        chip.width,
        16,
      );
      final RRect rr = RRect.fromRectAndRadius(r, const Radius.circular(3));
      if (chip.warn) {
        canvas.drawRRect(rr, Paint()..color = C.chipWarnFill);
        canvas.drawRRect(
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = C.chipWarnStroke,
        );
        _baselineText(
          canvas,
          chip.label,
          T.chipLabel.copyWith(color: C.orange),
          Offset(chip.center.x, chip.center.y + 4),
          TextAnchor.middle,
        );
      } else if (chip.cv) {
        canvas.drawRRect(rr, Paint()..color = const Color(0xFF141414));
        canvas.drawPath(
          _dashed(Path()..addRRect(rr), 3, 3),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = C.chipCvStroke,
        );
        _baselineText(
          canvas,
          chip.label,
          T.chipLabel,
          Offset(chip.center.x, chip.center.y + 4),
          TextAnchor.middle,
        );
      } else {
        canvas.drawRRect(rr, Paint()..color = C.recess);
        canvas.drawRRect(
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = C.chipStroke,
        );
        _baselineText(
          canvas,
          chip.label,
          T.chipLabel,
          Offset(chip.center.x, chip.center.y + 4),
          TextAnchor.middle,
        );
      }
    }
    // the amber sled that marks a route nothing consumes — a standing fact,
    // steady, never a blink
    for (final BoardRoute r in board.routes) {
      if (r.sled != null) {
        paintLamp(canvas, Offset(r.sled!.x, r.sled!.y), 2.6, C.orange, lit: true, amber: true);
      }
    }
  }

  void _pulses(Canvas canvas) {
    final List<BoardCable> path = board.pulsePath;
    if (path.isEmpty) return;
    for (final Pulse p in controller.pulses) {
      if (p.seg >= path.length) continue;
      final Cubic c = path[p.seg].curve;
      final Pt pt = c.pointAtLength(p.d);
      paintLamp(canvas, Offset(pt.x, pt.y), 4, C.red, lit: true);
    }
    if (controller.flowHold && board.frozenPulse != null) {
      paintLamp(
        canvas,
        Offset(board.frozenPulse!.x, board.frozenPulse!.y),
        4,
        C.red,
        lit: true,
      );
    }
  }

  void _plate(Canvas canvas) {
    _baselineText(canvas, board.title, T.fTitle, const Offset(24, 32), TextAnchor.start);
    _baselineText(
      canvas,
      board.caption,
      T.fDim,
      Offset(board.maxX - 24, 32),
      TextAnchor.end,
    );
  }

  @override
  bool shouldRepaint(_BoardPainter old) =>
      old.board != board || old.scale != scale || old.controller != controller;
}
