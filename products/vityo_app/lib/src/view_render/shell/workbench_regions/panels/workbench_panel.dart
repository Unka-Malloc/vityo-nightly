import 'package:flutter/material.dart';

import '../../../theme/vityo_theme.dart';

class WorkbenchRegionSurface extends StatelessWidget {
  const WorkbenchRegionSurface({
    required this.label,
    required this.child,
    this.headerActions = const <Widget>[],
    this.showHeader = true,
    super.key,
  });

  final String label;
  final Widget child;
  final List<Widget> headerActions;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final tokens = VityoWorkbenchTokens.of(context);
    return Semantics(
      container: true,
      label: '$label region',
      child: ColoredBox(
        color: tokens.region,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHeader)
              Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: tokens.divider)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: tokens.muted.withValues(alpha: 0.85),
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    ...headerActions,
                  ],
                ),
              ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class WorkbenchBottomPanelFrame extends StatelessWidget {
  const WorkbenchBottomPanelFrame({
    required this.label,
    required this.child,
    required this.expanded,
    super.key,
  });

  final String label;
  final Widget child;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final motion = VityoMotion.of(context);
    return AnimatedSize(
      duration: motion.fast,
      curve: motion.emphasized,
      alignment: Alignment.topCenter,
      child: expanded
          ? SizedBox(
              key: const ValueKey('workbench-bottom-panel'),
              height: 220,
              child: WorkbenchRegionSurface(label: label, child: child),
            )
          : const SizedBox.shrink(),
    );
  }
}

/// The standard raised container: one hairline border over the elevated
/// surface, no stacked bezels.
class WorkbenchCard extends StatelessWidget {
  const WorkbenchCard({
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.tint,
    this.radius = 12,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? tint;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final tokens = VityoWorkbenchTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: tint ?? tokens.elevated,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: tokens.divider),
      ),
      padding: padding,
      child: child,
    );
  }
}

class WorkbenchMetaPill extends StatelessWidget {
  const WorkbenchMetaPill({
    required this.label,
    this.color,
    this.filled = false,
    super.key,
  });

  final String label;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final tokens = VityoWorkbenchTokens.of(context);
    final tone = color ?? tokens.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: filled ? tone.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: filled ? tone.withValues(alpha: 0.32) : tokens.divider,
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: filled ? tone : tokens.muted,
          fontWeight: filled ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    );
  }
}
