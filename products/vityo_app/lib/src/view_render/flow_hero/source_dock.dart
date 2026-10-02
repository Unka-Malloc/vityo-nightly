/// The floating source dock. Appears on node selection; its corner button is
/// expand/collapse (pop up / tuck down) — there is no close button, and
/// blank-canvas drags never dismiss it.
library;

import 'package:flutter/material.dart';

import 'controller.dart';
import 'palette.dart';
import 'lexer_buf.dart';

class SourceDock extends StatelessWidget {
  const SourceDock({super.key, required this.controller});

  final FlowHeroController controller;

  @override
  Widget build(BuildContext context) {
    final FlowHeroController c = controller;
    if (c.selectedId == null) return const SizedBox.shrink();
    final String sig = kNodeSnippetLines[c.selectedId] ?? '// no source';
    return Positioned(
      right: 18,
      bottom: 18,
      width: 420,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: P.recess.withValues(alpha: 0.97),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: P.seamLo),
          boxShadow: const <BoxShadow>[BoxShadow(color: Colors.black87, blurRadius: 34, offset: Offset(0, 10))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: P.panel,
                border: Border(bottom: BorderSide(color: P.seamLo)),
              ),
              child: Row(
                children: <Widget>[
                  Text(c.selectedId!, style: P.silkStyle(hi: true)),
                  const SizedBox(width: 10),
                  Text('user_sync.sty', style: P.silkStyle(dim: true)),
                  const Spacer(),
                  // expand/collapse toggle — pops up, tucks down. No close ✕.
                  InkWell(
                    onTap: c.toggleDock,
                    borderRadius: BorderRadius.circular(3),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        c.dockExpanded ? Icons.expand_more : Icons.expand_less,
                        size: 18,
                        color: P.silkHi,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 220),
              sizeCurve: Curves.easeOut,
              crossFadeState: c.dockExpanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
              firstChild: SizedBox(
                height: 180,
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: <Widget>[
                    SourceLine(lineNo: 1, line: sig, hot: true),
                    const SourceLine(lineNo: 2, line: '  …'),
                    const SourceLine(lineNo: 3, line: '}'),
                  ],
                ),
              ),
              secondChild: const SizedBox(width: 420, height: 0),
            ),
          ],
        ),
      ),
    );
  }
}
