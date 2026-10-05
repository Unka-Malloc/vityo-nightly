/// Right agent column: its own 38pt title strip carrying the link status —
/// header and conversation are one unit — then the message log, then the
/// input box. The width is the parent's call; the split handle on the
/// column's left edge drags it.
library;

import 'package:flutter/material.dart';

import 'agent_bridge.dart';
import 'controller.dart';
import 'palette.dart';
import '../../ide/agent_client/agent_client_models.dart';
import 'agent_operations.dart';

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
                final permissions = c.bridge.pendingPermissions;
                final proposals = c.bridge.pendingWorkspaceReviews;
                return SelectionArea(
                  child: ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    children: <Widget>[
                      if (permissions.isNotEmpty || proposals.isNotEmpty)
                        FlowHeroAgentReviewPanel(
                          permissions: permissions,
                          proposals: proposals,
                          onResolvePermission:
                              (
                                AgentPermissionRequest request,
                                String optionId,
                              ) {
                                c.bridge.decidePermission(request.id, optionId);
                              },
                          onResolveProposal: (String reviewId, bool apply) {
                            c.bridge.decideWorkspaceProposal(
                              reviewId,
                              apply: apply,
                            );
                          },
                        ),
                      for (final message in c.messages) _MsgView(msg: message),
                    ],
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: P.seamHi)),
            ),
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
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
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
                        borderSide: BorderSide(
                          color: P.red.withValues(alpha: 0.6),
                        ),
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
                    child: Text(
                      'SEND',
                      style: P.silkStyle().copyWith(color: P.paperLow),
                    ),
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

class FlowHeroAgentReviewPanel extends StatelessWidget {
  const FlowHeroAgentReviewPanel({
    super.key,
    required this.permissions,
    required this.proposals,
    required this.onResolvePermission,
    required this.onResolveProposal,
  });

  final List<AgentPermissionRequest> permissions;
  final List<FlowHeroWorkspaceChangeReview> proposals;
  final void Function(AgentPermissionRequest request, String optionId)
  onResolvePermission;
  final void Function(String reviewId, bool apply) onResolveProposal;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final permission in permissions)
          _PermissionReviewCard(
            request: permission,
            onResolve: (String optionId) =>
                onResolvePermission(permission, optionId),
          ),
        for (final proposal in proposals)
          _WorkspaceProposalReviewCard(
            proposal: proposal,
            onResolve: (bool apply) =>
                onResolveProposal(proposal.reviewId, apply),
          ),
      ],
    );
  }
}

class _PermissionReviewCard extends StatelessWidget {
  const _PermissionReviewCard({required this.request, required this.onResolve});

  final AgentPermissionRequest request;
  final ValueChanged<String> onResolve;

  @override
  Widget build(BuildContext context) {
    final title =
        request.toolCallTitle ?? request.toolCallKind ?? 'Agent operation';
    return _ReviewCardFrame(
      key: ValueKey<String>('agent-permission-${request.id}'),
      title: 'PERMISSION · $title',
      subtitle: 'Agent permission · ${request.sessionId}',
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 6,
        children: <Widget>[
          for (final option in request.options)
            TextButton(
              key: ValueKey<String>(
                'permission-option-${request.id}-${option.optionId}',
              ),
              onPressed: () => onResolve(option.optionId),
              child: Text(option.name),
            ),
          if (request.options.isEmpty)
            Text(
              'No decision option was offered',
              style: P.silkStyle(dim: true),
            ),
        ],
      ),
    );
  }
}

class _WorkspaceProposalReviewCard extends StatelessWidget {
  const _WorkspaceProposalReviewCard({
    required this.proposal,
    required this.onResolve,
  });

  final FlowHeroWorkspaceChangeReview proposal;
  final ValueChanged<bool> onResolve;

  @override
  Widget build(BuildContext context) {
    return _ReviewCardFrame(
      key: ValueKey<String>('workspace-proposal-${proposal.reviewId}'),
      title: 'WORKSPACE PATCH · ${proposal.proposal.id}',
      subtitle:
          'rev ${proposal.proposal.baseWorkspaceRevision} · '
          '${proposal.resources.length} file(s) · ${proposal.editCount} edit(s)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final resource in proposal.resources) ...<Widget>[
            Text(
              '${resource.resourceId} · base ${resource.baseDocumentRevision}',
              style: P.silkStyle(hi: true),
            ),
            for (final edit in resource.edits) ...<Widget>[
              _DiffLine(
                prefix: '−',
                text: edit.beforeText.isEmpty ? '<insert>' : edit.beforeText,
                color: P.red,
              ),
              _DiffLine(
                prefix: '+',
                text: edit.replacement.isEmpty ? '<delete>' : edit.replacement,
                color: const Color(0xFF30D158),
              ),
            ],
            const SizedBox(height: 8),
          ],
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 6,
            children: <Widget>[
              TextButton(
                key: ValueKey<String>('reject-proposal-${proposal.reviewId}'),
                onPressed: () => onResolve(false),
                child: const Text('REJECT'),
              ),
              TextButton(
                key: ValueKey<String>('apply-proposal-${proposal.reviewId}'),
                onPressed: () => onResolve(true),
                child: const Text('APPLY'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DiffLine extends StatelessWidget {
  const _DiffLine({
    required this.prefix,
    required this.text,
    required this.color,
  });

  final String prefix;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 3),
    child: Text('$prefix $text', style: P.monoStyle(color: color, size: 10)),
  );
}

class _ReviewCardFrame extends StatelessWidget {
  const _ReviewCardFrame({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: P.well,
      border: Border.all(color: P.orange.withValues(alpha: 0.55)),
      borderRadius: BorderRadius.circular(3),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: P.silkStyle(hi: true)),
        const SizedBox(height: 3),
        Text(subtitle, style: P.silkStyle(dim: true)),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );
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
                boxShadow: glow
                    ? <BoxShadow>[BoxShadow(color: dot, blurRadius: 5)]
                    : null,
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
          border: Border(
            left: BorderSide(color: P.orange, width: 2),
            top: BorderSide(color: P.seamLo),
            bottom: BorderSide(color: P.seamLo),
            right: BorderSide(color: P.seamLo),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (msg.demo) ...<Widget>[
              Text(
                '演示内容',
                style: P.silkStyle().copyWith(color: P.orange, fontSize: 9),
              ),
              const SizedBox(height: 3),
            ],
            Text(msg.text, style: P.monoStyle(color: P.silk, size: 11)),
          ],
        ),
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
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(msg.who, style: P.silkStyle(dim: true)),
                if (msg.demo) ...<Widget>[
                  const SizedBox(width: 6),
                  Text(
                    '演示',
                    style: P.silkStyle().copyWith(color: P.orange, fontSize: 9),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: isUser ? P.well : P.panelHi,
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: isUser ? P.ring : P.seamLo),
              ),
              child: Text(
                msg.text,
                style: P.monoStyle(color: P.paperLow, size: 11.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
