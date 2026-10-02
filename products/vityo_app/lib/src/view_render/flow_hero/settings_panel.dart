/// The settings panel: a centered modal card over a dimmed scrim. Every row
/// is wired — the theme switch flips the palette live, the link row reads the
/// real agent bridge state, and the scrim or the ✕ closes it.
library;

import 'package:flutter/material.dart';

import 'agent_bridge.dart';
import 'controller.dart';
import 'palette.dart';

class SettingsPanel extends StatelessWidget {
  const SettingsPanel({super.key, required this.controller});

  final FlowHeroController controller;

  @override
  Widget build(BuildContext context) {
    final FlowHeroController c = controller;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: c.toggleSettings,
          child: ColoredBox(color: Colors.black.withValues(alpha: 0.55)),
        ),
        Center(
          child: Container(
            width: 420,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: P.panel,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: P.seamLo),
              boxShadow: const <BoxShadow>[
                BoxShadow(color: Colors.black87, blurRadius: 34, offset: Offset(0, 10)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Container(
                  height: 38,
                  padding: const EdgeInsets.only(left: 14, right: 6),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: P.seamLo)),
                  ),
                  child: Row(
                    children: <Widget>[
                      Text('设置', style: P.silkStyle(hi: true)),
                      const Spacer(),
                      InkWell(
                        onTap: c.toggleSettings,
                        borderRadius: BorderRadius.circular(3),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(Icons.close, size: 15, color: P.silkDim),
                        ),
                      ),
                    ],
                  ),
                ),
                _Section(
                  title: '外观',
                  child: Row(
                    children: <Widget>[
                      _ThemeTab(label: '夜间', on: P.dark, onTap: () => _setTheme(c, true)),
                      const SizedBox(width: 6),
                      _ThemeTab(label: '白天', on: !P.dark, onTap: () => _setTheme(c, false)),
                    ],
                  ),
                ),
                _Section(
                  title: 'AGENT 连接',
                  child: _LinkRow(bridge: c.bridge),
                ),
                const _Section(
                  title: '关于',
                  divider: false,
                  child: _AboutRow(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _setTheme(FlowHeroController c, bool dark) {
    if (P.dark == dark) return;
    P.dark = dark;
    c.toggleTheme();
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.divider = true});

  final String title;
  final Widget child;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        border: divider ? Border(bottom: BorderSide(color: P.seamLo)) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: P.silkStyle(dim: true)),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _ThemeTab extends StatelessWidget {
  const _ThemeTab({required this.label, required this.on, required this.onTap});

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: on ? P.well : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: on ? P.ring : P.seamLo),
        ),
        child: Text(
          label,
          style: P.silkStyle().copyWith(color: on ? P.orangeBright : P.silk),
        ),
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.bridge});

  final AgentBridge bridge;

  @override
  Widget build(BuildContext context) {
    final (Color dot, String label) = switch (bridge.mode) {
      AgentLinkMode.live => (const Color(0xFF30D158), '已连接'),
      AgentLinkMode.connecting => (P.orange, '连接中…'),
      AgentLinkMode.failed => (P.red, '连接失败'),
      AgentLinkMode.demo => (P.ledOff, '演示模式（未连接）'),
    };
    return Row(
      children: <Widget>[
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
        ),
        const SizedBox(width: 8),
        Text(label, style: P.silkStyle()),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            bridge.statusLine,
            style: P.monoStyle(color: P.silkDim, size: 10.5),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow();

  @override
  Widget build(BuildContext context) {
    return Text('VITYO — Flow Hero 工作台', style: P.monoStyle(color: P.silkDim, size: 10.5));
  }
}
