/// Right agent column: its own 38pt title strip carrying the link status —
/// header and conversation are one unit — then the message log, then the
/// input box. The width is the parent's call; the split handle on the
/// column's left edge drags it.
library;

import 'package:flutter/material.dart';

import 'agent_bridge.dart';
import 'controller.dart';
import 'palette.dart';

class ChatRail extends StatefulWidget {
  const ChatRail({super.key, required this.controller});

  final FlowHeroController controller;

  @override
  State<ChatRail> createState() => _ChatRailState();
}

class _ChatRailState extends State<ChatRail> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  FlowHeroController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_scrollLate);
  }

  void _scrollLate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    c.removeListener(_scrollLate);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final String text = _input.text.trim();
    if (text.isEmpty) return;
    c.sendChat(text);
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: P.panel,
      child: Column(
        children: <Widget>[
          _AgentHeader(controller: c),
          Expanded(
            child: AnimatedBuilder(
              animation: c,
              builder: (BuildContext context, _) {
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: c.messages.length,
                  itemBuilder: (BuildContext context, int i) => _MsgView(msg: c.messages[i]),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: P.seamHi))),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _input,
                    style: P.monoStyle(size: 11.5),
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: '给 AGENT 下指令…',
                      hintStyle: P.silkStyle(dim: true),
                      filled: true,
                      fillColor: P.well,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(2),
                        borderSide: BorderSide(color: P.ring),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(2),
                        borderSide: BorderSide(color: P.ring),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(2),
                        borderSide: BorderSide(color: P.red.withValues(alpha: 0.6)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: _send,
                  borderRadius: BorderRadius.circular(3),
                  child: Container(
                    height: 36,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: P.panelHi,
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: P.seamLo),
                    ),
                    child: Text('SEND', style: P.silkStyle().copyWith(color: P.paperLow)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The agent column's title strip, 38pt — the same grade as the main strip,
/// so the two read as one bar split at the drag handle. The lamp alone
/// carries the link state at the right edge (hover it for the detail line).
class _AgentHeader extends StatelessWidget {
  const _AgentHeader({required this.controller});

  final FlowHeroController controller;

  static const double height = 38;

  @override
  Widget build(BuildContext context) {
    final (Color dot, bool glow) = switch (controller.bridge.mode) {
      AgentLinkMode.live => (const Color(0xFF30D158), true),
      AgentLinkMode.connecting => (P.orange, true),
      AgentLinkMode.failed => (P.red, false),
      AgentLinkMode.demo => (P.ledOff, false),
    };
    return Container(
      key: const ValueKey('agent-title-strip'),
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: P.seamLo)),
      ),
      child: Row(
        children: <Widget>[
          Text('AGENT', style: P.silkStyle(hi: true)),
          const Spacer(),
          Tooltip(
            message: controller.bridge.statusLine,
            child: Container(
              key: const ValueKey('agent-status-lamp'),
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dot,
                boxShadow: glow ? <BoxShadow>[BoxShadow(color: dot, blurRadius: 5)] : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MsgView extends StatelessWidget {
  const _MsgView({required this.msg});

  final ChatMsg msg;

  @override
  Widget build(BuildContext context) {
    if (msg.receipt) {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: P.well,
          border: Border(left: BorderSide(color: P.orange, width: 2), top: BorderSide(color: P.seamLo), bottom: BorderSide(color: P.seamLo), right: BorderSide(color: P.seamLo)),
        ),
        child: Text(msg.text, style: P.monoStyle(color: P.silk, size: 11)),
      );
    }
    final bool isUser = msg.who == '你';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        constraints: const BoxConstraints(maxWidth: 250),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(msg.who, style: P.silkStyle(dim: true)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: isUser ? P.well : P.panelHi,
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: isUser ? P.ring : P.seamLo),
              ),
              child: Text(msg.text, style: P.monoStyle(color: P.paperLow, size: 11.5)),
            ),
          ],
        ),
      ),
    );
  }
}
