/// Left icon rail: workspace drawer, flow/editor switch, tests, day/night,
/// settings. The workspace file tree itself lives in workspace_drawer.dart.
library;

import 'package:flutter/material.dart';

import 'controller.dart';
import '../../view_ide/flow_hero/flow_hero.dart';
import 'palette.dart';

class HeroRail extends StatelessWidget {
  const HeroRail({super.key, required this.controller});

  final FlowHeroController controller;

  /// The rail's fixed width — the page positions the drawer sash from it.
  static const double width = 56;

  @override
  Widget build(BuildContext context) {
    final FlowHeroController c = controller;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: P.panel,
        border: Border(right: BorderSide(color: P.seamLo)),
      ),
      child: Column(
        children: <Widget>[
          // The title strip spans the whole window above this rail — the
          // traffic-light bay lives there, so the rail starts with its tools.
          const SizedBox(height: 10),
          RailBtn(
            icon: Icons.folder_outlined,
            tooltip: '工作区',
            active: c.treeVisible,
            onTap: c.toggleTree,
          ),
          RailBtn(
            icon: Icons.account_tree_outlined,
            tooltip: 'FLOW 流程图',
            active: !c.editorMode,
            onTap: () => c.setEditorMode(false),
          ),
          RailBtn(
            icon: Icons.code,
            tooltip: '编辑器（传统 IDE）',
            active: c.editorMode,
            onTap: () => c.setEditorMode(true),
          ),
          RailBtn(
            icon: Icons.check_circle_outline,
            tooltip: c.executionBusy
                ? '测试执行中…'
                : (c.canExecute ? '测试 · pafio test' : '测试'),
            enabled: c.canExecute,
            disabledReason: c.executionUnavailableReason,
            onTap: () => c.runExecution(FlowHeroExecutionKind.test),
          ),
          const Spacer(),
          RailBtn(
            icon: P.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            tooltip: P.dark ? '切到白天' : '切到黑夜',
            onTap: () => c.setDark(!P.dark),
          ),
          RailBtn(
            icon: Icons.settings_outlined,
            tooltip: '设置',
            active: c.settingsVisible,
            onTap: c.toggleSettings,
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class RailBtn extends StatelessWidget {
  const RailBtn({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.enabled = true,
    this.disabledReason,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  /// False disables the control and makes [disabledReason] the visible hover
  /// text — the same honesty pattern the settings rows use.
  final bool enabled;
  final String? disabledReason;

  @override
  Widget build(BuildContext context) {
    final String message = enabled ? tooltip : (disabledReason ?? tooltip);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Tooltip(
        message: message,
        preferBelow: false,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(4),
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: active ? P.well : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                  border: active ? Border.all(color: P.ring) : null,
                ),
                child: Icon(
                  icon,
                  size: 17,
                  color: !enabled
                      ? P.silkDim.withValues(alpha: 0.5)
                      : (active ? P.orangeBright : P.silkDim),
                ),
              ),
              if (active)
                Positioned(
                  left: -9,
                  top: 10,
                  bottom: 10,
                  child: Container(width: 2, color: P.red),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
