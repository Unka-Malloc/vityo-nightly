/// The editor stage: the real SourceEditor from the workbench engine (gutter,
/// diagnostics strip, live highlighting, real buffers) framed by the Flow
/// Hero chrome.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'controller.dart';
import 'engine/editor.dart';
import 'engine/machine.dart';
import 'palette.dart';
import 'run_strip.dart';

class EditorStage extends StatelessWidget {
  const EditorStage({super.key, required this.controller});

  final FlowHeroController controller;

  @override
  Widget build(BuildContext context) {
    final FlowHeroController c = controller;
    return Container(
      color: P.bed,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // The file's name already rides the main title strip above, and the
          // rail already owns canvas/workspace switching — this bar keeps
          // only what is editor-local: save, and the run transport docked at
          // the right end.
          Container(
            key: const ValueKey('editor-toolbar'),
            height: 34,
            // Right inset 4 matches the run strip's vertical margins:
            // (34 − 1pt seam − 25pt strip) / 2 = 4.
            padding: const EdgeInsets.only(left: 8, right: 4),
            decoration: BoxDecoration(
              color: P.panel,
              border: Border(bottom: BorderSide(color: P.seamLo)),
            ),
            child: Row(
              children: <Widget>[
                AnimatedBuilder(
                  animation: c.engine,
                  builder: (BuildContext context, Widget? _) {
                    final BufferFile f = c.engine.activeFile;
                    final bool canSave = f.savable && f.dirty;
                    return _IconBtn(
                      icon: Icons.save_outlined,
                      tooltip: f.savable ? '保存 ⌘S' : '保存（此缓冲不在磁盘上）',
                      hot: canSave,
                      onTap: () => unawaited(c.engine.saveActive()),
                    );
                  },
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: RunStrip(controller: c, dense: true),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: SourceEditor(controller: c.engine)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: P.seamHi))),
            child: AnimatedBuilder(
              animation: c.engine,
              builder: (BuildContext context, Widget? _) {
                final BufferFile f = c.engine.activeFile;
                return Row(
                  children: <Widget>[
                    Text('${f.lang} · UTF-8', style: P.silkStyle(dim: true)),
                    const SizedBox(width: 14),
                    Text(
                      'Ln ${c.engine.cursorLine}, Col ${c.engine.cursorColumn}',
                      style: P.silkStyle(dim: true),
                    ),
                    const Spacer(),
                    Text(
                      '${f.lineCount} 行 · ${f.byteSize} B',
                      style: P.silkStyle(dim: true),
                    ),
                    if (f.savable) ...<Widget>[
                      const SizedBox(width: 14),
                      if (f.dirty)
                        Text('● 未保存', style: P.silkStyle().copyWith(color: P.orange))
                      else
                        Text('已保存', style: P.silkStyle(dim: true)),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A 26pt square glyph button for the editor toolbar — the rail's RailBtn
/// grade, shrunk to strip height.
class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.hot = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// Needs attention (e.g. unsaved changes).
  final bool hot;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: tooltip,
        preferBelow: false,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(3),
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
            ),
            child: Icon(
              icon,
              size: 15,
              color: hot ? P.orange : P.silkDim,
            ),
          ),
        ),
      ),
    );
  }
}
