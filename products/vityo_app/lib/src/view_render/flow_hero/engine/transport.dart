/// The transport: the sixteen-step band riding at the bottom of the machine,
/// and the 220px milled bay at its right hand where TEMPO, CLEAR and RUN live.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'machine.dart';
import '../tokens.dart';

/// The quarter ramps — the only place in the system where the full phase ramp
/// appears at once.
const List<List<Color>> kQuarterCaps = <List<Color>>[
  <Color>[C.redBright, C.redDeep],
  <Color>[C.orangeBright, C.orangeDeep],
  <Color>[C.yellowBright, C.yellowDeep],
  <Color>[Colors.white, C.paperLow],
];

class LoopBar extends StatelessWidget {
  const LoopBar({super.key, required this.controller});
  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    final WorkbenchController c = controller;
    return SeamTop(
      color: C.panel,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      const Text('LOOP — SIXTEEN STEPS', style: T.silkHi),
                      Text('${c.armedCount}/16 Armed', style: T.silk),
                    ],
                  ),
                  const SizedBox(height: 8),
                  StepTrack(controller: c),
                  const SizedBox(height: 8),
                  const Phases(),
                ],
              ),
            ),
            const SizedBox(width: 16),
            TransportBay(controller: c),
          ],
        ),
      ),
    );
  }
}

class StepTrack extends StatelessWidget {
  const StepTrack({super.key, required this.controller});
  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    final WorkbenchController c = controller;
    return Row(
      children: <Widget>[
        for (int i = 0; i < 16; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: StepKey(
              index: i,
              armed: c.armed[i],
              chase: c.chaseStep == i && !c.faultStepLit,
              fault: c.faultStepLit && i == kFaultStep,
              onTap: () => c.toggleStep(i),
            ),
          ),
        ],
      ],
    );
  }
}

class StepKey extends StatelessWidget {
  const StepKey({
    super.key,
    required this.index,
    required this.armed,
    required this.chase,
    required this.fault,
    required this.onTap,
  });

  final int index;
  final bool armed;
  final bool chase;
  final bool fault;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final List<Color> ramp = kQuarterCaps[(index ~/ 4).clamp(0, 3)];
    final List<Color> colors = armed
        ? ramp
        : const <Color>[C.stepOffHi, C.stepOffLo];
    double brightness = 1;
    double saturate = 1;
    if (chase) {
      brightness = 1.22;
      saturate = 1.1;
    }
    if (fault) {
      brightness = 1.28;
      saturate = 1.15;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Led(on: fault || chase, dim: armed && !chase && !fault, size: 6),
        const SizedBox(height: 6),
        _StepCap(
          ramp: colors,
          brightness: brightness,
          saturate: saturate,
          armed: armed,
          onTap: onTap,
          label: 'step ${index + 1} ${kStepNames[index]}',
        ),
        const SizedBox(height: 6),
        Text(
          '${index + 1}',
          style: T.monoMed.copyWith(
            color: fault
                ? C.red
                : (armed ? C.silk : C.stepOffNum),
            fontWeight: fault ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _StepCap extends StatefulWidget {
  const _StepCap({
    required this.ramp,
    required this.brightness,
    required this.saturate,
    required this.armed,
    required this.onTap,
    required this.label,
  });

  final List<Color> ramp;
  final double brightness;
  final double saturate;
  final bool armed;
  final VoidCallback onTap;
  final String label;

  @override
  State<_StepCap> createState() => _StepCapState();
}

class _StepCapState extends State<_StepCap> {
  bool _down = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final double b = widget.brightness * (_hover ? 1.07 : 1);
    final List<Color> colors = widget.ramp
        .map((Color c) => filterColor(c, brightness: b, saturate: widget.saturate))
        .toList();
    return Semantics(
      button: true,
      label: widget.label,
      selected: widget.armed,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 40),
            transform: Matrix4.translationValues(0, _down ? 2 : 0, 0),
            height: 38,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(5),
              boxShadow: widget.armed
                  ? (_down
                      ? const <BoxShadow>[
                          BoxShadow(color: Color(0x8C000000), offset: Offset(0, 1)),
                        ]
                      : const <BoxShadow>[
                          BoxShadow(color: Color(0x8C000000), offset: Offset(0, 3)),
                          BoxShadow(
                            color: Color(0x40FFFFFF),
                            offset: Offset(0, 1),
                            spreadRadius: -1,
                          ),
                        ])
                  : const <BoxShadow>[
                      BoxShadow(
                        color: Color(0xB3000000),
                        blurRadius: 4,
                        offset: Offset(0, 2),
                      ),
                      BoxShadow(
                        color: Color(0x0AFFFFFF),
                        offset: Offset(0, 1),
                        spreadRadius: -1,
                      ),
                    ],
            ),
            child: CustomPaint(
              painter: _StepCapPainter(
                colors: colors,
                rim: widget.armed,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepCapPainter extends CustomPainter {
  _StepCapPainter({required this.colors, required this.rim});
  final List<Color> colors;
  final bool rim;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect r = Offset.zero & size;
    final RRect rr = RRect.fromRectAndRadius(r, const Radius.circular(5));
    canvas.drawRRect(
      rr,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
        ).createShader(r),
    );
    // the slot window cut near the top of the cap
    final Rect slot = Rect.fromLTWH(size.width * 0.18, 7, size.width * 0.64, 5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(slot, const Radius.circular(2)),
      Paint()..color = const Color(0x61000000),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(slot, const Radius.circular(2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x99000000),
    );
  }

  @override
  bool shouldRepaint(_StepCapPainter old) =>
      old.rim != rim || !_sameColors(old.colors, colors);

  static bool _sameColors(List<Color> a, List<Color> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The bracket: a 1px rule in Terminal Ring spanning one quarter of the track
/// with a centered 11px phase name beneath it.
class Phases extends StatelessWidget {
  const Phases({super.key});

  @override
  Widget build(BuildContext context) => Row(
        children: <Widget>[
          for (int i = 0; i < 4; i++)
            Expanded(
              child: Column(
                children: <Widget>[
                  Container(margin: const EdgeInsets.symmetric(horizontal: 2), height: 1, color: C.terminalRing),
                  const SizedBox(height: 3),
                  Text(kPhaseNames[i], style: T.silk),
                ],
              ),
            ),
        ],
      );
}

/// ------------------------------------------------------------- the bay ---
class TransportBay extends StatelessWidget {
  const TransportBay({super.key, required this.controller});
  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    final WorkbenchController c = controller;
    return Well(
      width: 220,
      radius: 6,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Row(
            children: <Widget>[
              HandIcon(painter: Pen.metronome, size: 12, color: C.silk),
              SizedBox(width: 7),
              Text('TEMPO · BPM', style: T.silk),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              AdjKey(label: '–', onTap: () => c.setBpm(c.bpm - 1), tooltip: 'Tempo down'),
              Well(
                radius: 4,
                padding: const EdgeInsets.fromLTRB(9, 5, 9, 3),
                child: SevenSegmentReadout(text: c.bpm.toStringAsFixed(1)),
              ),
              AdjKey(label: '+', onTap: () => c.setBpm(c.bpm + 1), tooltip: 'Tempo up'),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: CapKey(
                  height: 36,
                  onTap: c.clearLoop,
                  tooltip: 'Clear the loop',
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      HandIcon(painter: Pen.stop, size: 12, color: C.silkHi),
                      SizedBox(width: 7),
                      Text('CLEAR', style: T.keyClear),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: RunKey(controller: c)),
            ],
          ),
        ],
      ),
    );
  }
}

class AdjKey extends StatelessWidget {
  const AdjKey({super.key, required this.label, required this.onTap, this.tooltip});
  final String label;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => CapKey(
        width: 30,
        height: 30,
        radius: 4,
        tooltip: tooltip,
        onTap: onTap,
        child: Text(label, style: T.keyAdj),
      );
}

/// RUN, and the same cap saying something else when the machine is held.
class RunKey extends StatefulWidget {
  const RunKey({super.key, required this.controller});
  final WorkbenchController controller;

  @override
  State<RunKey> createState() => _RunKeyState();
}

class _RunKeyState extends State<RunKey> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    _breath.dispose();
    super.dispose();
  }

  /// The machine invites its first run once; the first press spends it for good.
  void _sync() {
    if (widget.controller.runInvite && !_breath.isAnimating) {
      _breath.repeat(reverse: true);
    } else if (!widget.controller.runInvite && _breath.isAnimating) {
      _breath.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final WorkbenchController c = widget.controller;
    final bool replay = c.faulted;
    return AnimatedBuilder(
      animation: _breath,
      builder: (BuildContext context, Widget? _) => CapKey(
        height: 36,
        pressed: c.runHeld,
        glow: c.runInvite ? _breath.value : 0,
        tooltip: replay
            ? 'Replay the run-up to the fault — slow the tempo to watch'
            : 'Run the loop',
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[C.redBright, C.redDeep],
        ),
        onTap: () => unawaited(c.run()),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            HandIcon(
              painter: replay ? Pen.rotateCcw : Pen.play,
              size: 13,
              color: Colors.white,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                replay ? 'REPLAY' : 'RUN',
                style: T.keyRun,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The transport's key row splits its width evenly at 36px.
const double kRunKeyHeight = 36;
