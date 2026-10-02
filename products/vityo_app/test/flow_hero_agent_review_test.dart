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
      String? selectedPermissionOption;
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
              permissions: <AgentPermissionRequest>[
                AgentPermissionRequest(
                  id: 'permission-1',
                  agentId: 'fixture-agent',
                  sessionId: 'session-1',
                  toolCallId: 'tool-1',
                  toolCallTitle: 'Read source',
                  options: const <AgentPermissionOption>[
                    AgentPermissionOption(
                      optionId: 'allow-first',
                      name: 'Allow first operation',
                      kind: AgentPermissionOptionKind.allowOnce,
                    ),
                    AgentPermissionOption(
                      optionId: 'allow-second',
                      name: 'Allow related operation',
                      kind: AgentPermissionOptionKind.allowOnce,
                    ),
                    AgentPermissionOption(
                      optionId: 'allow-always',
                      name: 'Always allow',
                      kind: AgentPermissionOptionKind.allowAlways,
                    ),
                    AgentPermissionOption(
                      optionId: 'reject-once',
                      name: 'Reject once',
                      kind: AgentPermissionOptionKind.rejectOnce,
                    ),
                    AgentPermissionOption(
                      optionId: 'reject-always',
                      name: 'Always reject',
                      kind: AgentPermissionOptionKind.rejectAlways,
                    ),
                  ],
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
              onResolvePermission: (_, optionId) {
                selectedPermissionOption = optionId;
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
        find.byKey(
          const ValueKey('permission-option-permission-1-allow-first'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('permission-option-permission-1-allow-second'),
        ),
        findsOneWidget,
      );
      expect(find.text('Always allow'), findsOneWidget);
      expect(find.text('Reject once'), findsOneWidget);
      expect(find.text('Always reject'), findsOneWidget);
      await tester.tap(
        find.byKey(
          const ValueKey('permission-option-permission-1-allow-second'),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('apply-proposal-review-1')));

      expect(selectedPermissionOption, 'allow-second');
      expect(resolvedReviewId, 'review-1');
      expect(proposalApplied, isTrue);
    },
  );

  testWidgets('permission cards show only once-only supplied choices', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FlowHeroAgentReviewPanel(
            permissions: <AgentPermissionRequest>[
              AgentPermissionRequest(
                id: 'once-only',
                agentId: 'fixture-agent',
                sessionId: 'session-1',
                toolCallId: 'tool-1',
                options: const <AgentPermissionOption>[
                  AgentPermissionOption(
                    optionId: 'allow-id',
                    name: 'Allow this time',
                    kind: AgentPermissionOptionKind.allowOnce,
                  ),
                  AgentPermissionOption(
                    optionId: 'reject-id',
                    name: 'Reject this time',
                    kind: AgentPermissionOptionKind.rejectOnce,
                  ),
                ],
              ),
            ],
            proposals: const <FlowHeroWorkspaceChangeReview>[],
            onResolvePermission: (_, _) {},
            onResolveProposal: (_, _) {},
          ),
        ),
      ),
    );

    expect(find.text('Allow this time'), findsOneWidget);
    expect(find.text('Reject this time'), findsOneWidget);
    expect(find.text('Always allow'), findsNothing);
    expect(find.text('Always reject'), findsNothing);
  });
}
