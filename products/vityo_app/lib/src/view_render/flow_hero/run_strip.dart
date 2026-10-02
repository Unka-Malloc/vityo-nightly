/// Run strip: the sixteen execution ticks compressed into the canvas corner.
/// Four stage quarters (PARSE/CHECK/LOWER/EMIT), live playhead, throughput.
///
/// Responsive: the tick row flexes with the canvas width, and the throughput
/// counter steps aside when the strip gets tight, so a narrow canvas never
/// overflows the pill.
library;

import 'package:flutter/material.dart';

import 'controller.dart';
import 'palette.dart';

class RunStrip extends StatelessWidget {
  const RunStrip({super.key, required this.controller, this.dense = false});

  final FlowHeroController controller;

  /// Docked-in-a-toolbar variant: tighter vertical padding so the strip fits
  /// the 34pt editor toolbar grade.
  final bool dense;

  /// The tick row's natural width: 16 ticks × 14pt + the 2pt margins.
  static const double _ticksWidth = 288;

  Color _stageColor(int i) {
    switch (i ~/ 4) {
      case 0:
        return P.red;
      case 1:
        return P.orange;
      case 2:
        return P.yellow;
      default:
        return P.paper;
    }
  }

  @override
  Widget build(BuildContext context) {
    final FlowHeroController c = controller;
    return AnimatedBuilder(
      animation: c,
      builder: (BuildContext context, _) {
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool showRate = constraints.maxWidth >= 560;
            return Container(
              // Dense: pinned to 25pt so the editor toolbar wraps it with
              // exactly equal margins (34 − 1pt seam − 25) / 2 = 4.
              height: dense ? 25 : null,
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: dense ? 0 : 6),
              decoration: BoxDecoration(
                color: P.well.withValues(alpha: 0.9),
                border: Border.all(color: P.ring),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text('RUN', style: P.silkStyle()),
                  const SizedBox(width: 10),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: _ticksWidth),
                      child: Row(
                        children: <Widget>[
                          for (int i = 0; i < 16; i++)
                            Expanded(
                              child: Container(
                                height: 5,
                                margin: const EdgeInsets.symmetric(horizontal: 2),
                                decoration: BoxDecoration(
                                  color: c.litSteps.contains(i) ? _stageColor(i) : P.ledOff,
                                  borderRadius: BorderRadius.circular(2),
                                  border: c.playhead == i ? Border.all(color: P.paperLow, width: 1) : null,
                                  boxShadow: c.litSteps.contains(i)
                                      ? <BoxShadow>[BoxShadow(color: _stageColor(i).withValues(alpha: 0.7), blurRadius: 5)]
                                      : null,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (showRate) ...<Widget>[
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 76,
                      child: Text(
                        c.running ? '42 EVT/S' : '0 EVT/S',
                        textAlign: TextAlign.right,
                        style: P.monoStyle(color: P.paper, size: 12),
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  _StripBtn(label: c.running ? 'STOP' : 'RUN', color: P.redBright, onTap: c.toggleRun, dense: dense),
                  const SizedBox(width: 6),
                  _StripBtn(label: 'CLR', onTap: c.clearRun, dense: dense),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _StripBtn extends StatelessWidget {
  const _StripBtn({required this.label, required this.onTap, this.color, this.dense = false});

  final String label;
  final VoidCallback onTap;
  final Color? color;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: dense ? 3 : 5),
        decoration: BoxDecoration(
          color: P.panelHi,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: P.seamLo),
        ),
        child: Text(label, style: P.silkStyle().copyWith(color: color ?? P.paperLow, fontSize: 10)),
      ),
    );
  }
}
