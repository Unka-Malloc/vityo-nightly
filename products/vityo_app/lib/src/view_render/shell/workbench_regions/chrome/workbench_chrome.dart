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
        height: 40,
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
                const SizedBox(width: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: tokens.focus,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'V',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: compact ? 42 : 240),
                      child: Text(
                        compact ? 'Vityo' : title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Align(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Semantics(
                        button: true,
                        label: 'Open command palette',
                        child: InkWell(
                          key: const ValueKey('workbench-command-launcher'),
                          onTap: onOpenCommands,
                          child: Container(
                            height: 28,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: tokens.canvas,
                              border: Border.all(color: tokens.divider),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.search,
                                  size: 15,
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
                                  Text(
                                    '⌘K',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(color: tokens.muted),
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
                  child: Icon(Icons.circle, size: 9, color: statusColor),
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
                const SizedBox(width: 12),
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
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: tokens.region,
          border: Border(top: BorderSide(color: tokens.divider)),
        ),
        child: Row(
          children: [
            Icon(Icons.circle, size: 7, color: statusColor),
            const SizedBox(width: 7),
            Expanded(
              flex: 3,
              child: Text(
                leading,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: tokens.ink),
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
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: tokens.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum WorkbenchStatus { ready, reconnecting, blocked, error }
