import 'package:flutter/material.dart';

import '../../../theme/vityo_theme.dart';

@immutable
final class WorkbenchDestination {
  const WorkbenchDestination({required this.label, required this.icon});

  final String label;
  final IconData icon;
}

class WorkbenchActivityRail extends StatelessWidget {
  const WorkbenchActivityRail({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    super.key,
  });

  final List<WorkbenchDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const double itemExtent = 52;

  @override
  Widget build(BuildContext context) {
    final tokens = VityoWorkbenchTokens.of(context);
    final motion = VityoMotion.of(context);
    return Container(
      key: const ValueKey('workbench-activity-rail'),
      width: 52,
      decoration: BoxDecoration(
        color: tokens.canvas,
        border: Border(right: BorderSide(color: tokens.divider)),
      ),
      child: Stack(
        children: [
          if (selectedIndex >= 0 && selectedIndex < destinations.length)
            AnimatedPositioned(
              duration: motion.fast,
              curve: motion.emphasized,
              top: selectedIndex * itemExtent + 6,
              left: 6,
              right: 6,
              height: itemExtent - 12,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.hover,
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
              ),
            ),
          if (selectedIndex >= 0 && selectedIndex < destinations.length)
            AnimatedPositioned(
              duration: motion.fast,
              curve: motion.emphasized,
              top: selectedIndex * itemExtent + (itemExtent - 18) / 2,
              left: 0,
              width: 3,
              height: 18,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.accent,
                    borderRadius: const BorderRadius.horizontal(
                      right: Radius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          Column(
            children: [
              for (var index = 0; index < destinations.length; index++)
                _ActivityRailItem(
                  destination: destinations[index],
                  selected: index == selectedIndex,
                  onTap: () => onSelected(index),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActivityRailItem extends StatefulWidget {
  const _ActivityRailItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final WorkbenchDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ActivityRailItem> createState() => _ActivityRailItemState();
}

class _ActivityRailItemState extends State<_ActivityRailItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = VityoWorkbenchTokens.of(context);
    final motion = VityoMotion.of(context);
    final color = widget.selected
        ? tokens.ink
        : _hovered
        ? tokens.ink.withValues(alpha: 0.82)
        : tokens.muted;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.destination.label,
      child: Tooltip(
        message: widget.destination.label,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: InkWell(
            onTap: widget.onTap,
            child: SizedBox(
              height: WorkbenchActivityRail.itemExtent,
              width: double.infinity,
              child: Center(
                child: AnimatedDefaultTextStyle(
                  duration: motion.micro,
                  curve: motion.standard,
                  style: TextStyle(color: color),
                  child: IconTheme(
                    data: IconThemeData(color: color, size: 20),
                    child: Icon(widget.destination.icon),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
