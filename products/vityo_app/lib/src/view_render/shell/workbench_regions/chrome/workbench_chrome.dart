import 'package:flutter/material.dart';

import '../../../theme/vityo_theme.dart';

class WorkbenchTitleBar extends StatelessWidget {
  const WorkbenchTitleBar({
    required this.title,
    required this.commandHint,
    required this.connectionLabel,
    required this.onOpenCommands,
    this.actions = const <Widget>[],
    this.status = WorkbenchStatus.ready,
    super.key,
  });

  final String title;
  final String commandHint;
  final String connectionLabel;
  final VoidCallback onOpenCommands;
  final List<Widget> actions;
  final WorkbenchStatus status;

  @override
  Widget build(BuildContext context) {
    final tokens = VityoWorkbenchTokens.of(context);
    return Semantics(
      container: true,
      label: 'Workbench title and command strip',
      child: Container(
        key: const ValueKey('workbench-title-bar'),
        height: 52,
        decoration: BoxDecoration(
          color: tokens.region,
          border: Border(bottom: BorderSide(color: tokens.divider)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 640;
            final visibleActionCount = constraints.maxWidth >= 1400
                ? actions.length
                : constraints.maxWidth >= 1050
                ? actions.length.clamp(0, 3)
                : constraints.maxWidth >= 840
                ? actions.length.clamp(0, 1)
                : 0;
            final visibleActions = actions.take(visibleActionCount);
            final showConnectionLabel = constraints.maxWidth >= 1280;
            final statusColor = switch (status) {
              WorkbenchStatus.ready => tokens.success,
              WorkbenchStatus.reconnecting => tokens.warning,
              WorkbenchStatus.blocked => tokens.blocked,
              WorkbenchStatus.error => tokens.error,
            };
            return Row(
              children: [
                const SizedBox(width: 84),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 21,
                      height: 21,
                      decoration: BoxDecoration(
                        color: tokens.accent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'V',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: tokens.onAccent,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 9),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: compact ? 42 : 240),
                      child: Text(
                        compact ? 'Vityo' : title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.labelLarge?.copyWith(letterSpacing: -0.1),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Align(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Semantics(
                        button: true,
                        label: 'Open command palette',
                        child: InkWell(
                          key: const ValueKey('workbench-command-launcher'),
                          onTap: onOpenCommands,
                          borderRadius: BorderRadius.circular(8),
                          hoverColor: tokens.hover,
                          child: Container(
                            height: 30,
                            padding: const EdgeInsets.symmetric(horizontal: 13),
                            decoration: BoxDecoration(
                              color: tokens.canvas,
                              border: Border.all(color: tokens.divider),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.search,
                                  size: 14,
                                  color: tokens.muted,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    commandHint,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ),
                                if (!compact) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: tokens.hover,
                                      borderRadius: BorderRadius.circular(5),
                                      border: Border.all(color: tokens.divider),
                                    ),
                                    child: Text(
                                      '⌘K',
                                      style: VityoTheme.mono(
                                        color: tokens.muted,
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w500,
                                        height: 1.2,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ...visibleActions,
                if (visibleActionCount > 0) const SizedBox(width: 8),
                Tooltip(
                  message: connectionLabel,
                  child: Icon(Icons.circle, size: 8, color: statusColor),
                ),
                if (showConnectionLabel) ...[
                  const SizedBox(width: 7),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      connectionLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
                const SizedBox(width: 14),
              ],
            );
          },
        ),
      ),
    );
  }
}

class WorkbenchStatusBar extends StatelessWidget {
  const WorkbenchStatusBar({
    required this.leading,
    required this.trailing,
    this.status = WorkbenchStatus.ready,
    super.key,
  });

  final String leading;
  final String trailing;
  final WorkbenchStatus status;

  @override
  Widget build(BuildContext context) {
    final tokens = VityoWorkbenchTokens.of(context);
    final statusColor = switch (status) {
      WorkbenchStatus.ready => tokens.success,
      WorkbenchStatus.reconnecting => tokens.warning,
      WorkbenchStatus.blocked => tokens.blocked,
      WorkbenchStatus.error => tokens.error,
    };
    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Workbench status ${status.name}: $leading, $trailing',
      child: Container(
        key: const ValueKey('workbench-status-bar'),
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: tokens.region,
          border: Border(top: BorderSide(color: tokens.divider)),
        ),
        child: Row(
          children: [
            Icon(Icons.circle, size: 6, color: statusColor),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: Text(
                leading,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: VityoTheme.mono(
                  color: tokens.muted,
                  fontSize: 10,
                  height: 1.2,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: Text(
                trailing,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: VityoTheme.mono(
                  color: tokens.muted,
                  fontSize: 10,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum WorkbenchStatus { ready, reconnecting, blocked, error }
