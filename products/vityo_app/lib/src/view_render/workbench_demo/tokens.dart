/// Design tokens transcribed from `.impeccable/mocks/vityo-step-row.html`
/// (`:root`) and the DESIGN.md palette. One pen, one light source, one lamp grade.
library;

import 'package:flutter/material.dart';

/// ---------------------------------------------------------------- colours ---
class C {
  const C._();

  static const room = Color(0xFF0B0B0B);
  static const panel = Color(0xFF1A1A1A);
  static const panelHi = Color(0xFF212121);
  static const recess = Color(0xFF121212);
  static const well = Color(0xFF0E0E0E);
  static const seamHi = Color(0xFF2D2D2D);
  static const seamLo = Color(0xFF000000);

  static const red = Color(0xFFFF3B30);
  static const redBright = Color(0xFFFF5A4D);
  static const redDeep = Color(0xFFE02820);
  static const orange = Color(0xFFFF9A00);
  static const orangeBright = Color(0xFFFFAB33);
  static const orangeDeep = Color(0xFFE68A00);
  static const yellow = Color(0xFFFFE100);
  static const yellowBright = Color(0xFFFFE94D);
  static const yellowDeep = Color(0xFFE6CA00);
  static const paper = Color(0xFFF2F2F2);
  static const paperLow = Color(0xFFDCDCDC);

  static const silk = Color(0xFF8D8D8D);
  static const silkHi = Color(0xFFC9C9C9);
  static const silkDim = Color(0xFF6F6F6F);
  static const chipLabel = Color(0xFF9A9A9A);
  static const gutterGrey = Color(0xFF828282);
  static const bone = Color(0xFFE9E7E1);

  static const ledOff = Color(0xFF2A2A2A);
  static const terminalRing = Color(0xFF3A3A3A);
  static const plugBody = Color(0xFF242424);
  static const plugRing = Color(0xFF4C4C4C);
  static const keyCap = Color(0xFF2B2B2B);
  static const keyCapLow = Color(0xFF1E1E1E);
  static const modFaceHi = Color(0xFF1F1F1F);
  static const modFaceLo = Color(0xFF171717);
  static const stepOffHi = Color(0xFF262626);
  static const stepOffLo = Color(0xFF1B1B1B);
  static const stepOffNum = Color(0xFF7A7A7A);
  static const gutterRule = Color(0xFF232323);
  static const factRule = Color(0xFF1E1E1E);

  static const selection = Color(0x52FF3B30); // rgba(255,59,48,.32)
  static const focusRim = Color(0x47FF9A00); // rgba(255,154,0,.28)
  static const chipStroke = Color(0xFF262626);
  static const chipCvStroke = Color(0xFF333333);
  static const chipWarnFill = Color(0xFF151310);
  static const chipWarnStroke = Color(0xFF3A2A10);
  static const scrollThumb = Color(0xFF2E2E2E);
}

/// -------------------------------------------------------------- typography ---
const String kMono = 'IBM Plex Mono';
const String kCond = 'IBM Plex Sans Condensed';

/// The silkscreen face. The proof sets IBM Plex Sans here; measured against the
/// proof's own pixels (status strip labels, loop head, panel names) Plus Jakarta
/// Sans reproduces those advance widths within 2%, where the Condensed cut comes
/// in 10–18% narrow — so the labels keep the machine's own line lengths and the
/// condensed cut is kept for the display legends it was drawn for.
const String kSans = 'Plus Jakarta Sans';
const List<String> kMonoFallback = <String>['Azeret Mono'];
const List<String> kSansFallback = <String>['IBM Plex Sans Condensed'];
const List<String> kCondFallback = <String>['Plus Jakarta Sans'];

/// One letter-spacing unit: CSS `em` tracking on an 11px silkscreen label.
double em(double size, double tracking) => size * tracking;

class T {
  const T._();

  static const TextStyle silk = TextStyle(
    fontFamily: kSans,
    fontFamilyFallback: kSansFallback,
    fontSize: 11,
    height: 14 / 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.32,
    color: C.silk,
  );
  static const TextStyle silkHi = TextStyle(
    fontFamily: kSans,
    fontFamilyFallback: kSansFallback,
    fontSize: 11,
    height: 14 / 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.32,
    color: C.silkHi,
  );
  static const TextStyle silkDim = TextStyle(
    fontFamily: kSans,
    fontFamilyFallback: kSansFallback,
    fontSize: 11,
    height: 14 / 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.32,
    color: C.silkDim,
  );

  /// Mono 11px, the machine's voice. `ls` is the CSS tracking in px.
  static const TextStyle mono = TextStyle(
    fontFamily: kMono,
    fontFamilyFallback: kMonoFallback,
    fontSize: 11,
    height: 14 / 11,
    fontWeight: FontWeight.w400,
    color: C.bone,
  );
  static const TextStyle monoMed = TextStyle(
    fontFamily: kMono,
    fontFamilyFallback: kMonoFallback,
    fontSize: 11,
    height: 14 / 11,
    fontWeight: FontWeight.w500,
    color: C.bone,
  );
  static const TextStyle monoBold = TextStyle(
    fontFamily: kMono,
    fontFamilyFallback: kMonoFallback,
    fontSize: 11,
    height: 14 / 11,
    fontWeight: FontWeight.w600,
    color: C.bone,
  );

  /// 11px mono data at 0.05em — cable labels, receipts, agent steps, facts.
  static const TextStyle monoData = TextStyle(
    fontFamily: kMono,
    fontFamilyFallback: kMonoFallback,
    fontSize: 11,
    height: 14 / 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.55,
    color: C.bone,
  );
  static const TextStyle chipLabel = TextStyle(
    fontFamily: kMono,
    fontFamilyFallback: kMonoFallback,
    fontSize: 11,
    height: 14 / 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.44,
    color: C.chipLabel,
  );
  static const TextStyle fTitle = TextStyle(
    fontFamily: kSans,
    fontFamilyFallback: kSansFallback,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.54,
    color: C.silk,
  );
  static const TextStyle fDim = TextStyle(
    fontFamily: kMono,
    fontFamilyFallback: kMonoFallback,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 1.1,
    color: C.silkDim,
  );
  static const TextStyle fLabel = TextStyle(
    fontFamily: kMono,
    fontFamilyFallback: kMonoFallback,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.55,
    color: C.silkDim,
  );
  static const TextStyle modName = TextStyle(
    fontFamily: kSans,
    fontFamilyFallback: kSansFallback,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.44,
    color: C.silkHi,
  );
  static const TextStyle modKind = TextStyle(
    fontFamily: kMono,
    fontFamilyFallback: kMonoFallback,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.88,
    color: C.silkDim,
  );

  /// The editor: 13px Mono on the integer 24px line grid.
  static const TextStyle code = TextStyle(
    fontFamily: kMono,
    fontFamilyFallback: kMonoFallback,
    fontSize: 13,
    height: 24 / 13,
    fontWeight: FontWeight.w400,
    color: C.bone,
  );
  static const TextStyle gutter = TextStyle(
    fontFamily: kMono,
    fontFamilyFallback: kMonoFallback,
    fontSize: 11,
    height: 24 / 11,
    fontWeight: FontWeight.w400,
    color: C.gutterGrey,
  );
  static const TextStyle diagStrip = TextStyle(
    fontFamily: kMono,
    fontFamilyFallback: kMonoFallback,
    fontSize: 11,
    height: 14 / 11,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.44,
    color: C.red,
  );

  static const TextStyle maker = TextStyle(
    fontFamily: kCond,
    fontFamilyFallback: kCondFallback,
    fontSize: 14,
    height: 1,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.12,
    color: C.silkHi,
  );
  static const TextStyle keyRun = TextStyle(
    fontFamily: kCond,
    fontFamilyFallback: kCondFallback,
    fontSize: 14,
    height: 1,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.4,
    color: Colors.white,
  );
  static const TextStyle keyClear = TextStyle(
    fontFamily: kCond,
    fontFamilyFallback: kCondFallback,
    fontSize: 11,
    height: 1,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.1,
    color: C.silkHi,
  );
  static const TextStyle keyAdj = TextStyle(
    fontFamily: kCond,
    fontFamilyFallback: kCondFallback,
    fontSize: 15,
    height: 1,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    color: C.silkHi,
  );
  static const TextStyle auth = TextStyle(
    fontFamily: kCond,
    fontFamilyFallback: kCondFallback,
    fontSize: 14,
    height: 1,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.12,
    color: Colors.white,
  );
  static const TextStyle tab = TextStyle(
    fontFamily: kMono,
    fontFamilyFallback: kMonoFallback,
    fontSize: 11,
    height: 1,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.66,
    color: C.silk,
  );
  static const TextStyle fine = TextStyle(
    fontFamily: kSans,
    fontFamilyFallback: kSansFallback,
    fontSize: 11,
    height: 1.55,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.32,
    color: C.silkDim,
  );
}

/// ------------------------------------------------------- filter arithmetic ---
/// CSS `filter: brightness(x) saturate(y)` applied in that order, so a key cap
/// or a step cap can be lit exactly the way the proof lights it.
Color filterColor(Color c, {double brightness = 1, double saturate = 1}) {
  var r = (c.r * 255.0) * brightness;
  var g = (c.g * 255.0) * brightness;
  var b = (c.b * 255.0) * brightness;
  if (saturate != 1) {
    final lr = 0.213, lg = 0.715, lb = 0.072;
    final nr = (lr + (1 - lr) * saturate) * r +
        (lg - lg * saturate) * g +
        (lb - lb * saturate) * b;
    final ng = (lr - lr * saturate) * r +
        (lg + (1 - lg) * saturate) * g +
        (lb - lb * saturate) * b;
    final nb = (lr - lr * saturate) * r +
        (lg - lg * saturate) * g +
        (lb + (1 - lb) * saturate) * b;
    r = nr;
    g = ng;
    b = nb;
  }
  int ch(double v) => v.round().clamp(0, 255);
  return Color.fromARGB(
    255,
    ch(r),
    ch(g),
    ch(b),
  );
}

/// --------------------------------------------------------------- hardware ---
/// A lamp. The only emissive element besides the tube and the signal pulses.
class Led extends StatelessWidget {
  const Led({
    super.key,
    this.size = 6,
    this.on = false,
    this.color = C.red,
    this.dim = false,
    this.blink = false,
  });

  final double size;
  final bool on;

  /// `dim-on`: an armed step at rest — visibly on, not lit.
  final bool dim;
  final Color color;
  final bool blink;

  @override
  Widget build(BuildContext context) {
    if (!on && !dim) {
      return Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: C.ledOff,
          shape: BoxShape.circle,
        ),
      );
    }
    final lit = on ? color : color.withValues(alpha: 0.62);
    final blur = on ? (size <= 5 ? 3.0 : 6.0) : 4.0;
    final spread = on ? (size <= 5 ? 8.0 : 16.0) : 0.0;
    final core = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: lit,
        shape: BoxShape.circle,
        boxShadow: <BoxShadow>[
          BoxShadow(color: color.withValues(alpha: on ? 0.9 : 0.4), blurRadius: blur),
          if (spread > 0)
            BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: spread),
        ],
      ),
    );
    if (!blink) return core;
    return _Blink(child: core);
  }
}

/// A hard 500ms on/off — `steps(1,end)`, never a fade. Blinking means
/// "press something", so only the gate lamp and the diagnostic gutter lamp blink.
class _Blink extends StatefulWidget {
  const _Blink({required this.child});
  final Widget child;

  @override
  State<_Blink> createState() => _BlinkState();
}

class _BlinkState extends State<_Blink> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (BuildContext context, Widget? child) =>
          Opacity(opacity: _c.value < 0.5 ? 1 : 0.18, child: child),
      child: widget.child,
    );
  }
}

/// A key cap: top-lit gradient, a 3px black pad beneath, 2px of travel on press.
class CapKey extends StatefulWidget {
  const CapKey({
    super.key,
    required this.child,
    this.onTap,
    this.width,
    this.height,
    this.radius = 5,
    this.gradient,
    this.pressed = false,
    this.latched = false,
    this.disabled = false,
    this.glow = 0,
    this.tooltip,
    this.padding = EdgeInsets.zero,
    this.alignment = Alignment.center,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double? width;
  final double? height;
  final double radius;
  final Gradient? gradient;

  /// Held down by the machine (a run in progress, the fitted instrument):
  /// 2px of travel and a collapsed pad, but the cap keeps its colour.
  final bool pressed;

  /// Latched down for good — the interlock after AUTHORIZE: dark charcoal and
  /// an inset shadow, no animation, a key that has physically stayed down.
  final bool latched;
  final bool disabled;

  /// 0 = at rest, 1 = fully lit (the RUN invitation, the authorize pulse).
  final double glow;
  final String? tooltip;
  final EdgeInsets padding;
  final Alignment alignment;

  @override
  State<CapKey> createState() => _CapKeyState();
}

class _CapKeyState extends State<CapKey> {
  bool _hover = false;
  bool _down = false;

  static const Gradient _darkCap = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[C.keyCap, C.keyCapLow],
  );

  @override
  Widget build(BuildContext context) {
    final bool pressed = _down || widget.pressed || widget.latched;
    Gradient base = widget.gradient ?? _darkCap;
    if (widget.latched) {
      base = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[Color(0xFF1C1C1C), Color(0xFF141414)],
      );
    }
    Gradient g = base;
    if (widget.glow > 0) {
      g = _mapGradient(base, brightness: 1 + 0.22 * widget.glow);
    }
    if (_hover && !widget.disabled && !widget.latched && !widget.pressed) {
      g = _mapGradient(g, brightness: 1.07);
    }
    Widget cap = Container(
      width: widget.width,
      height: widget.height,
      padding: widget.padding,
      alignment: widget.alignment,
      decoration: BoxDecoration(
        gradient: g,
        borderRadius: BorderRadius.circular(widget.radius),
        boxShadow: pressed
            ? const <BoxShadow>[
                BoxShadow(color: Color(0x8C000000), offset: Offset(0, 1)),
                BoxShadow(
                  color: Color(0x73000000),
                  blurRadius: 5,
                  spreadRadius: -2,
                  offset: Offset(0, 2),
                ),
              ]
            : const <BoxShadow>[
                BoxShadow(color: Color(0x8C000000), offset: Offset(0, 3)),
                BoxShadow(
                  color: Color(0x38FFFFFF),
                  offset: Offset(0, 1),
                  spreadRadius: -1,
                ),
              ],
      ),
      child: widget.child,
    );
    if (widget.disabled) {
      cap = Opacity(opacity: 0.38, child: cap);
    } else if (widget.onTap != null) {
      cap = MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: widget.onTap,
          child: cap,
        ),
      );
    }
    cap = AnimatedContainer(
      duration: const Duration(milliseconds: 40),
      transform: Matrix4.translationValues(0, pressed ? 2 : 0, 0),
      child: cap,
    );
    if (widget.tooltip != null) {
      cap = Tooltip(message: widget.tooltip!, child: cap);
    }
    return cap;
  }

  static Gradient _mapGradient(Gradient g, {double brightness = 1, double saturate = 1}) {
    if (g is LinearGradient) {
      return LinearGradient(
        begin: g.begin,
        end: g.end,
        colors: g.colors
            .map((Color c) => filterColor(c, brightness: brightness, saturate: saturate))
            .toList(),
      );
    }
    return g;
  }
}

/// The sign painter's helper: one pen, a 24-unit box, 1.8px stroke, currentColor.
class HandIcon extends StatelessWidget {
  const HandIcon({
    super.key,
    required this.painter,
    required this.size,
    required this.color,
  });

  final void Function(Path p) painter;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _IconPainter(painter, color),
          isComplex: false,
        ),
      );
}

class _IconPainter extends CustomPainter {
  _IconPainter(this.build, this.color);

  final void Function(Path p) build;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24.0);
    final Path p = Path();
    build(p);
    canvas.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_IconPainter old) => old.color != color || old.build != build;
}

/// The icon pen itself. Every drawing is a 24-unit box, stroke 1.8, round joins.
class Pen {
  const Pen._();

  static void folder(Path p) {
    p.moveTo(3, 7);
    p.arcToPoint(const Offset(5, 5), radius: const Radius.circular(2));
    p.lineTo(9, 5);
    p.lineTo(11, 7);
    p.lineTo(19, 7);
    p.arcToPoint(const Offset(21, 9), radius: const Radius.circular(2));
    p.lineTo(21, 18);
    p.arcToPoint(const Offset(19, 20), radius: const Radius.circular(2));
    p.lineTo(5, 20);
    p.arcToPoint(const Offset(3, 18), radius: const Radius.circular(2));
    p.close();
  }

  static void spark(Path p) {
    p.moveTo(12, 3);
    p.lineTo(13.9, 8.1);
    p.lineTo(19, 10);
    p.lineTo(13.9, 11.9);
    p.lineTo(12, 17);
    p.lineTo(10.1, 11.9);
    p.lineTo(5, 10);
    p.lineTo(10.1, 8.1);
    p.close();
  }

  static void pulse(Path p) {
    p.moveTo(3, 12);
    p.lineTo(7, 12);
    p.lineTo(9.5, 6);
    p.lineTo(13.5, 18);
    p.lineTo(16, 12);
    p.lineTo(21, 12);
  }

  /// FLOW: two jacks and a sagging lead.
  static void patchCable(Path p) {
    p.addOval(Rect.fromCircle(center: const Offset(5, 10), radius: 2.2));
    p.addOval(Rect.fromCircle(center: const Offset(19, 10), radius: 2.2));
    p.moveTo(7.2, 10);
    p.cubicTo(9.6, 14.5, 16.8, 14.5, 19.2, 10);
  }

  static void brackets(Path p) {
    p.moveTo(9.5, 7.5);
    p.lineTo(5, 12);
    p.lineTo(9.5, 16.5);
    p.moveTo(14.5, 7.5);
    p.lineTo(19, 12);
    p.lineTo(14.5, 16.5);
  }

  static void metronome(Path p) {
    p.moveTo(9.5, 20);
    p.lineTo(11.1, 7);
    p.lineTo(12.9, 7);
    p.lineTo(14.5, 20);
    p.moveTo(5.5, 20);
    p.lineTo(18.5, 20);
    p.moveTo(12, 14.5);
    p.lineTo(16.5, 9);
  }

  static void play(Path p) {
    p.moveTo(8.5, 6);
    p.lineTo(19, 12);
    p.lineTo(8.5, 18);
    p.close();
  }

  static void stop(Path p) {
    p.addRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(7, 7, 10, 10),
        const Radius.circular(2),
      ),
    );
  }

  static void rotateCcw(Path p) {
    p.moveTo(3, 12);
    p.arcToPoint(
      const Offset(12, 3),
      radius: const Radius.circular(9),
      largeArc: true,
      clockwise: false,
    );
    p.arcToPoint(
      const Offset(5.26, 5.74),
      radius: const Radius.circular(9.75),
      clockwise: false,
    );
    p.lineTo(3, 8);
    p.moveTo(3, 3);
    p.lineTo(3, 8);
    p.lineTo(8, 8);
  }

  static void lockClosed(Path p) => _lock(p, open: false);
  static void lockOpen(Path p) => _lock(p, open: true);

  static void _lock(Path p, {required bool open}) {
    p.addRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(6, 10.5, 12, 9),
        const Radius.circular(2),
      ),
    );
    p.moveTo(9, 10.5);
    p.lineTo(9, 8);
    if (open) {
      p.arcToPoint(const Offset(14.9, 6.8), radius: const Radius.circular(3), clockwise: true);
    } else {
      p.arcToPoint(const Offset(15, 8), radius: const Radius.circular(3), clockwise: true);
      p.lineTo(15, 10.5);
    }
    p.addOval(Rect.fromCircle(center: const Offset(12, 15), radius: 1.3));
  }

  /// .styio: a patch link.
  static void patchLink(Path p) {
    p.addOval(Rect.fromCircle(center: const Offset(6, 12), radius: 2));
    p.addOval(Rect.fromCircle(center: const Offset(18, 12), radius: 2));
    p.moveTo(8, 12);
    p.lineTo(16, 12);
  }

  /// .toml: a slider.
  static void slider(Path p) {
    p.moveTo(4, 8);
    p.lineTo(20, 8);
    p.moveTo(4, 16);
    p.lineTo(20, 16);
    p.addOval(Rect.fromCircle(center: const Offset(9, 8), radius: 2.2));
    p.addOval(Rect.fromCircle(center: const Offset(15, 16), radius: 2.2));
  }

  static void warning(Path p) {
    p.moveTo(6, 0.6);
    p.lineTo(11.4, 10.4);
    p.lineTo(0.6, 10.4);
    p.close();
    p.moveTo(6, 4.5);
    p.lineTo(6, 7.1);
    p.moveTo(6, 8.9);
    p.lineTo(6, 9.1);
  }
}

/// ------------------------------------------------------------- the pen kit ---
/// Small composed icons so a call site reads like the control it draws.
class FlowIcon extends StatelessWidget {
  const FlowIcon(this.size, this.color, this.painter, {super.key});
  final double size;
  final Color color;
  final void Function(Path p) painter;

  @override
  Widget build(BuildContext context) =>
      HandIcon(painter: painter, size: size, color: color);
}

/// ----------------------------------------------------------- seven segments ---
/// Segment geometry lifted from the proof, in its own 22 x 40 unit box.
class SegmentFont {
  const SegmentFont._();

  static const List<String> order = <String>['a', 'b', 'c', 'd', 'e', 'f', 'g'];

  static void path(String seg, Path p) {
    switch (seg) {
      case 'a':
        p.moveTo(5, 2);
        p.lineTo(17, 2);
        p.lineTo(19, 4);
        p.lineTo(17, 6);
        p.lineTo(5, 6);
        p.lineTo(3, 4);
        p.close();
      case 'b':
        p.moveTo(18, 7);
        p.lineTo(20, 5);
        p.lineTo(22, 7);
        p.lineTo(22, 18);
        p.lineTo(20, 20);
        p.lineTo(18, 18);
        p.close();
      case 'c':
        p.moveTo(18, 22);
        p.lineTo(20, 20);
        p.lineTo(22, 22);
        p.lineTo(22, 33);
        p.lineTo(20, 35);
        p.lineTo(18, 33);
        p.close();
      case 'd':
        p.moveTo(5, 34);
        p.lineTo(17, 34);
        p.lineTo(19, 36);
        p.lineTo(17, 38);
        p.lineTo(5, 38);
        p.lineTo(3, 36);
        p.close();
      case 'e':
        p.moveTo(0, 22);
        p.lineTo(2, 20);
        p.lineTo(4, 22);
        p.lineTo(4, 33);
        p.lineTo(2, 35);
        p.lineTo(0, 33);
        p.close();
      case 'f':
        p.moveTo(0, 7);
        p.lineTo(2, 5);
        p.lineTo(4, 7);
        p.lineTo(4, 18);
        p.lineTo(2, 20);
        p.lineTo(0, 18);
        p.close();
      case 'g':
        p.moveTo(5, 18);
        p.lineTo(17, 18);
        p.lineTo(19, 20);
        p.lineTo(17, 22);
        p.lineTo(5, 22);
        p.lineTo(3, 20);
        p.close();
    }
  }

  static const Map<String, List<String>> digits = <String, List<String>>{
    '0': <String>['a', 'b', 'c', 'd', 'e', 'f'],
    '1': <String>['b', 'c'],
    '2': <String>['a', 'b', 'g', 'e', 'd'],
    '3': <String>['a', 'b', 'g', 'c', 'd'],
    '4': <String>['f', 'g', 'b', 'c'],
    '5': <String>['a', 'f', 'g', 'c', 'd'],
    '6': <String>['a', 'f', 'g', 'e', 'c', 'd'],
    '7': <String>['a', 'b', 'c'],
    '8': <String>['a', 'b', 'c', 'd', 'e', 'f', 'g'],
    '9': <String>['a', 'b', 'c', 'd', 'f', 'g'],
    '-': <String>['g'],
    ' ': <String>[],
  };
}

/// The tube: a red seven-segment readout with a 2px glow on lit segments.
class SevenSegmentReadout extends StatelessWidget {
  const SevenSegmentReadout({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 15.0 * text.replaceAll('.', '').length + 6.0 * '.'.allMatches(text).length,
        height: 27,
        child: CustomPaint(painter: _SegPainter(text)),
      );
}

class _SegPainter extends CustomPainter {
  _SegPainter(this.text);
  final String text;

  @override
  void paint(Canvas canvas, Size size) {
    double x = 0;
    const double s = 0.65; /* the glyph grid is 23×40; the tube cell is 15×27 */
    final Paint glow = Paint()
      ..color = C.red
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    final Paint off = Paint()..color = C.red.withValues(alpha: 0.06);
    for (final String ch in text.split('')) {
      if (ch == '.') {
        canvas.save();
        canvas.translate(x, 0);
        canvas.scale(s);
        final Path p = Path()
          ..addRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTWH(1, 33, 5, 5),
              const Radius.circular(1),
            ),
          );
        canvas.drawPath(p, glow);
        canvas.drawPath(p, Paint()..color = C.red);
        canvas.restore();
        x += 6;
        continue;
      }
      canvas.save();
      canvas.translate(x, 0);
      canvas.scale(s);
      final List<String> lit = SegmentFont.digits[ch] ?? const <String>[];
      for (final String seg in SegmentFont.order) {
        final Path p = Path();
        SegmentFont.path(seg, p);
        if (lit.contains(seg)) {
          canvas.drawPath(p, glow);
          canvas.drawPath(p, Paint()..color = C.red);
        } else {
          canvas.drawPath(p, off);
        }
      }
      canvas.restore();
      x += 15;
    }
  }

  @override
  bool shouldRepaint(_SegPainter old) => old.text != text;
}

/// -------------------------------------------------------------- text tools ---
TextPainter measure(String text, TextStyle style, {double? maxWidth}) {
  final TextPainter tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout(minWidth: 0, maxWidth: maxWidth ?? double.infinity);
  return tp;
}

void paintText(
  Canvas canvas,
  String text,
  TextStyle style,
  Offset at, {
  TextAnchor anchor = TextAnchor.start,
}) {
  final TextPainter tp = measure(text, style);
  double dx = at.dx;
  if (anchor == TextAnchor.middle) dx -= tp.width / 2;
  if (anchor == TextAnchor.end) dx -= tp.width;
  tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
}

enum TextAnchor { start, middle, end }

/// The seam pair: a black cut plus a one-pixel light lip. Never a stroke.
class SeamTop extends StatelessWidget {
  const SeamTop({super.key, required this.child, this.color});

  final Widget child;
  final Color? color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          border: const Border(top: BorderSide(color: C.seamLo)),
          boxShadow: const <BoxShadow>[
            BoxShadow(color: C.seamHi, offset: Offset(0, 1), spreadRadius: -1),
          ],
        ),
        child: child,
      );
}

class SeamBottom extends StatelessWidget {
  const SeamBottom({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: C.seamLo)),
          boxShadow: <BoxShadow>[
            BoxShadow(color: C.seamHi, offset: Offset(0, 1), spreadRadius: -1),
          ],
        ),
        child: child,
      );
}

/// The milled well: a recessed control surface cut into the panel face.
class Well extends StatelessWidget {
  const Well({
    super.key,
    required this.child,
    this.radius = 5,
    this.padding = EdgeInsets.zero,
    this.width,
    this.height,
    this.clip = true,
  });

  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final double? width;
  final double? height;
  final bool clip;

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        padding: padding,
        clipBehavior: clip ? Clip.antiAlias : Clip.none,
        decoration: BoxDecoration(
          color: C.well,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: C.seamLo),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0xBF000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
            BoxShadow(color: C.seamHi, offset: Offset(0, 1), spreadRadius: -1),
          ],
        ),
        child: child,
      );
}
