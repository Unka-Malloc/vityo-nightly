import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_agent_protocol/vityo_agent_protocol.dart';
import 'package:vityo_app/src/ide/agent_client/agent_client_models.dart';
import 'package:vityo_app/src/view_render/flow_hero/agent_operations.dart';
import 'package:vityo_app/src/view_render/flow_hero/chat_rail.dart';

void main() {
  testWidgets('empty review panel leaves the chat baseline unchanged', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FlowHeroAgentReviewPanel(
            permissions: const <AgentPermissionRequest>[],
            proposals: const <FlowHeroWorkspaceChangeReview>[],
            onResolvePermission: (_, _) {},
            onResolveProposal: (_, _) {},
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('agent-permission-permission-1')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('workspace-proposal-review-1')),
      findsNothing,
    );
  });

  testWidgets(
    'review cards render the offered permission and real patch diff',
    (tester) async {
      AgentPermissionDecision? permissionDecision;
      String? resolvedReviewId;
      bool? proposalApplied;
      final proposal = VityoWorkspaceChangeProposal(
        id: 'proposal-1',
        baseWorkspaceRevision: 7,
        resources: <VityoResourceChange>[
          VityoResourceChange(
            resourceId: 'src/main.styio',
            baseDocumentRevision: 3,
            edits: <VityoTextChange>[
              VityoTextChange(start: 0, end: 6, replacement: 'module'),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FlowHeroAgentReviewPanel(
              permissions: const <AgentPermissionRequest>[
                AgentPermissionRequest(
                  id: 'permission-1',
                  agentId: 'fixture-agent',
                  sessionId: 'session-1',
                  toolCallId: 'tool-1',
                  toolCallTitle: 'Read source',
                  options: <String>{'allow_once'},
                ),
              ],
              proposals: <FlowHeroWorkspaceChangeReview>[
                FlowHeroWorkspaceChangeReview(
                  reviewId: 'review-1',
                  sessionId: 'session-1',
                  proposal: proposal,
                  resources: <FlowHeroWorkspaceResourceReview>[
                    FlowHeroWorkspaceResourceReview(
                      resourceId: 'src/main.styio',
                      baseDocumentRevision: 3,
                      edits: const <FlowHeroWorkspaceEditReview>[
                        FlowHeroWorkspaceEditReview(
                          start: 0,
                          end: 6,
                          beforeText: 'import',
                          replacement: 'module',
                        ),
                      ],
                    ),
                  ],
                ),
              ],
              onResolvePermission: (_, decision) {
                permissionDecision = decision;
              },
              onResolveProposal: (reviewId, apply) {
                resolvedReviewId = reviewId;
                proposalApplied = apply;
              },
            ),
          ),
        ),
      );

      expect(find.textContaining('import'), findsOneWidget);
      expect(find.textContaining('module'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reject-permission-permission-1')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('allow-permission-permission-1')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('allow-permission-permission-1')),
      );
      await tester.tap(find.byKey(const ValueKey('apply-proposal-review-1')));

      expect(permissionDecision, AgentPermissionDecision.allowOnce);
      expect(resolvedReviewId, 'review-1');
      expect(proposalApplied, isTrue);
    },
  );
}
