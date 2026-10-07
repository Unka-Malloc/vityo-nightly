/// Run strip: the real execution state compressed into the canvas corner.
///
/// There is no simulated progress here. The strip shows the honest phase of
/// the session the controller is driving — idle, pending, running, succeeded,
/// failed — or, when the execution route is not live, a dedicated missing
/// state: no RUN title and no RUN/CLR controls, because none of them do
/// anything in that state. The missing state names the real cause (the tool
/// the route could not resolve, the workspace/manifest it could not find) and
/// offers the one real next step, opening the toolchain install dialog. While
/// the route is still being probed the strip says so instead of presenting the
/// unwired state as a resolved failure. The RUN control launches
/// `pafio --json run`; while the child is live it becomes STOP.
///
/// Responsive: the status readout flexes with the canvas width and truncates
/// instead of overflowing the pill.
library;

import 'package:flutter/material.dart';

import 'controller.dart';
import '../../view_ide/flow_hero/flow_hero.dart';
import 'palette.dart';

class RunStrip extends StatelessWidget {
  const RunStrip({super.key, required this.controller, this.dense = false});

  final FlowHeroController controller;

  /// Docked-in-a-toolbar variant: tighter vertical padding so the strip fits
  /// the 34pt editor toolbar grade.
  final bool dense;

  Color _phaseColor(FlowHeroExecutionPhase phase) => switch (phase) {
    FlowHeroExecutionPhase.idle =>
      controller.executionLive ? P.orange : P.ledOff,
    FlowHeroExecutionPhase.pending => P.yellowBright,
    FlowHeroExecutionPhase.running => P.orange,
    FlowHeroExecutionPhase.succeeded => const Color(0xFF30D158),
    FlowHeroExecutionPhase.failed => P.red,
  };

  @override
  Widget build(BuildContext context) {
    final FlowHeroController c = controller;
    return AnimatedBuilder(
      animation: c,
      builder: (BuildContext context, _) {
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            if (!c.executionLive) {
              return c.executionProbing
                  ? _probing(constraints)
                  : _missing(constraints, c);
            }
            return _live(constraints, c);
          },
        );
      },
    );
  }

  /// The real route is live (or busy with a real invocation): the RUN title,
  /// the honest phase readout and the RUN/STOP/CLR transport.
  Widget _live(BoxConstraints constraints, FlowHeroController c) {
    final bool showStatus = constraints.maxWidth >= 380;
    final bool canRun = c.canExecute;
    final bool running = c.executionPhase == FlowHeroExecutionPhase.running;
    final bool hasOutcome =
        c.executionPhase != FlowHeroExecutionPhase.idle ||
        c.lastExecutionOutcome != null;
    final Color statusColor = _phaseColor(c.executionPhase);
    return Container(
      key: const ValueKey('run-strip'),
      // Dense: pinned to 25pt so the editor toolbar wraps it with exactly equal
      // margins (34 − 1pt seam − 25) / 2 = 4.
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
          if (showStatus) ...<Widget>[
            const SizedBox(width: 10),
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: statusColor,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      c.executionStatusLabel,
                      key: const ValueKey('run-strip-status'),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: P.monoStyle(color: P.paper, size: 11),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(width: 8),
          _StripBtn(
            key: const ValueKey('run-strip-run'),
            label: running ? 'STOP' : 'RUN',
            color: running ? P.yellowBright : P.redBright,
            enabled: running || canRun,
            tooltip: running
                ? '中断本次执行'
                : (canRun ? null : c.executionUnavailableReason),
            onTap: running
                ? c.cancelExecution
                : () => c.runExecution(FlowHeroExecutionKind.run),
            dense: dense,
          ),
          const SizedBox(width: 6),
          _StripBtn(
            key: const ValueKey('run-strip-clear'),
            label: 'CLR',
            enabled: hasOutcome,
            onTap: c.clearExecution,
            dense: dense,
          ),
        ],
      ),
    );
  }

  /// The route is still being probed; nothing is known yet, so there is no
  /// reason and no action — only the honest probe readout.
  Widget _probing(BoxConstraints constraints) {
    final bool showLabel = constraints.maxWidth >= 220;
    return Container(
      key: const ValueKey('run-strip-probing'),
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
          Icon(Icons.hourglass_empty, size: 13, color: P.silkDim),
          if (showLabel) ...<Widget>[
            const SizedBox(width: 7),
            Text(
              '正在探测执行环境…',
              key: const ValueKey('run-strip-probing-label'),
              style: P.silkStyle(dim: true),
            ),
          ],
        ],
      ),
    );
  }

  /// The route resolved but cannot run: a diagnostic strip that names the real
  /// cause and offers the single real next step. No RUN title, no transport —
  /// none of it would do anything here.
  Widget _missing(BoxConstraints constraints, FlowHeroController c) {
    final _MissingExecution p = _MissingExecution.from(c);
    final bool showDetail = constraints.maxWidth >= 360;
    final Color accent = P.orangeBright;
    return Container(
      key: const ValueKey('run-strip-missing'),
      height: dense ? 25 : null,
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: dense ? 0 : 6),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          accent.withValues(alpha: 0.08),
          P.well,
        ).withValues(alpha: 0.94),
        border: Border.all(color: accent.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(p.icon, size: 13, color: accent),
          const SizedBox(width: 7),
          Text(
            p.headline,
            key: const ValueKey('run-strip-missing-headline'),
            style: P.silkStyle().copyWith(color: accent, fontSize: 10),
          ),
          if (showDetail && p.detail.isNotEmpty) ...<Widget>[
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                p.detail,
                key: const ValueKey('run-strip-missing-reason'),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: P.monoStyle(color: P.paperLow, size: 10.5),
              ),
            ),
          ],
          const SizedBox(width: 10),
          // An unavailable route is the one state where pointing at a local
          // binary is a real next step, so the install dialog hangs off here.
          _StripBtn(
            key: const ValueKey('run-strip-install'),
            label: p.actionLabel,
            color: P.orangeBright,
            enabled: true,
            tooltip: p.actionTooltip,
            onTap: c.openToolchainInstall,
            dense: dense,
          ),
        ],
      ),
    );
  }
}

/// The missing state's copy, derived from the route's own diagnosis instead of
/// assuming the cause was pafio.
class _MissingExecution {
  const _MissingExecution({
    required this.headline,
    required this.detail,
    required this.icon,
    required this.actionLabel,
    required this.actionTooltip,
  });

  final String headline;
  final String detail;
  final IconData icon;
  final String actionLabel;
  final String actionTooltip;

  static _MissingExecution from(FlowHeroController c) {
    final Set<FlowHeroToolchainKind> missing = c.missingToolchains;
    if (missing.isNotEmpty) {
      final String tools = missing
          .map((FlowHeroToolchainKind kind) => kind.displayName)
          .join(' / ');
      return _MissingExecution(
        headline: _toolchainHeadline(missing),
        detail: _toolchainDetail(c, missing),
        icon: Icons.build_outlined,
        actionLabel: '安装',
        actionTooltip: '设置本地 $tools 二进制',
      );
    }
    final FlowHeroExecutionUnavailableCause? cause =
        c.executionUnavailableCause;
    final String reason = c.executionUnavailableReason;
    return _MissingExecution(
      headline: _causeHeadline(cause, reason),
      detail: reason,
      icon: _causeIcon(cause),
      actionLabel: '修复',
      actionTooltip: '打开工具链诊断 · 重新探测执行环境',
    );
  }

  static String _toolchainHeadline(Set<FlowHeroToolchainKind> missing) {
    if (missing.length > 1) return '执行工具链未就绪';
    return switch (missing.single) {
      FlowHeroToolchainKind.pafio => 'Pafio 未就绪',
      FlowHeroToolchainKind.styio => 'Styio 未就绪',
    };
  }

  /// Which tools are missing and, when the boot recorded them, the slots it
  /// looked in — concise and real, never a guess at a path.
  static String _toolchainDetail(
    FlowHeroController c,
    Set<FlowHeroToolchainKind> missing,
  ) {
    final bool multiple = missing.length > 1;
    final List<String> names = <String>[];
    final List<String> searched = <String>[];
    for (final FlowHeroToolchainKind kind in FlowHeroToolchainKind.values) {
      if (!missing.contains(kind)) continue;
      names.add(kind.displayName);
      final List<String> sources =
          (c.toolchainChecks[kind] ?? const <FlowHeroToolchainCheck>[])
              .map((FlowHeroToolchainCheck check) => check.source.trim())
              .where((String source) => source.isNotEmpty)
              .toList(growable: false);
      if (sources.isEmpty) continue;
      searched.add(
        multiple
            ? '${kind.displayName}：${sources.join('、')}'
            : sources.join('、'),
      );
    }
    return <String>[
      '未发现 ${names.join('、')}',
      if (searched.isNotEmpty) '已查找 ${searched.join(' · ')}',
    ].join(' · ');
  }

  static String _causeHeadline(
    FlowHeroExecutionUnavailableCause? cause,
    String reason,
  ) => switch (cause) {
    FlowHeroExecutionUnavailableCause.workspace => '未配置工作区',
    FlowHeroExecutionUnavailableCause.manifest => '工作区缺少 pafio.toml',
    FlowHeroExecutionUnavailableCause.toolchain => '执行工具链未就绪',
    FlowHeroExecutionUnavailableCause.probeFailed => '执行服务不可用',
    FlowHeroExecutionUnavailableCause.compatibility => '工具链不兼容',
    // A route that classifies nothing (a scripted embedding) still gets an
    // honest headline: the first clause of its own real reason.
    null => _firstSegment(reason),
  };

  static IconData _causeIcon(
    FlowHeroExecutionUnavailableCause? cause,
  ) => switch (cause) {
    FlowHeroExecutionUnavailableCause.workspace => Icons.folder_off_outlined,
    FlowHeroExecutionUnavailableCause.manifest => Icons.description_outlined,
    FlowHeroExecutionUnavailableCause.toolchain => Icons.build_outlined,
    FlowHeroExecutionUnavailableCause.compatibility =>
      Icons.warning_amber_outlined,
    FlowHeroExecutionUnavailableCause.probeFailed =>
      Icons.assignment_late_outlined,
    null => Icons.warning_amber_rounded,
  };

  static String _firstSegment(String reason) {
    final String trimmed = reason.trim();
    if (trimmed.isEmpty) return '执行服务未就绪';
    final int cut = trimmed.indexOf(' · ');
    return cut < 0 ? trimmed : trimmed.substring(0, cut);
  }
}

class _StripBtn extends StatelessWidget {
  const _StripBtn({
    super.key,
    required this.label,
    required this.onTap,
    required this.enabled,
    this.color,
    this.tooltip,
    this.dense = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final Color? color;
  final String? tooltip;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final Color textColor = enabled
        ? (color ?? P.paperLow)
        : P.silkDim.withValues(alpha: 0.6);
    final Widget button = InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: dense ? 3 : 5),
        decoration: BoxDecoration(
          color: P.panelHi,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: P.seamLo),
        ),
        child: Text(
          label,
          style: P.silkStyle().copyWith(color: textColor, fontSize: 10),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, preferBelow: false, child: button);
  }
}
