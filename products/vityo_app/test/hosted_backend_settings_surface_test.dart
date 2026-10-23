import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/workspace/workspace.dart';
import 'package:vityo_app/src/view_ide/interaction/interaction.dart';
import 'package:vityo_app/src/view_ide/platform/platform_target.dart';
import 'package:vityo_app/src/view_render/platform/platform.dart';
import 'package:vityo_app/src/view_render/settings/settings_surface.dart';

void main() {
  testWidgets('settings surface exposes hosted backend recovery actions', (
    tester,
  ) async {
    const report = HostedBackendConnectorParityReport(
      workspaceId: 'hosted-demo',
      status: HostedBackendConnectorStatus.retryableFailure,
      message: 'Hosted backend connection needs attention.',
      checks: <HostedBackendConnectorCheck>[
        HostedBackendConnectorCheck(
          id: 'control-plane',
          label: 'Hosted control plane',
          available: true,
          required: true,
        ),
        HostedBackendConnectorCheck(
          id: 'backend-reachability',
          label: 'Hosted backend reachability',
          available: false,
          required: true,
        ),
      ],
      actions: <HostedBackendRetryAction>[
        HostedBackendRetryAction(
          id: 'retry-connect',
          label: 'Retry connection',
          kind: HostedBackendRetryActionKind.retryConnect,
        ),
        HostedBackendRetryAction(
          id: 'open-settings',
          label: 'Open hosted settings',
          kind: HostedBackendRetryActionKind.openSettings,
        ),
      ],
    );
    final actions = <HostedBackendRetryActionKind>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsSurface(
            viewportProfile: resolveViewportProfile(
              platformTarget: PlatformTarget.macos,
              width: 1200,
              height: 800,
            ),
            toolchainStatus: const ToolchainStatusSurface(
              source: 'fixture',
              severity: ToolchainStatusSeverity.ready,
              title: 'Toolchain ready',
              message: 'Ready.',
              recoveryActions: <ToolchainRecoveryAction>[],
            ),
            hostedBackendConnector: report,
            hostedBackendActionResult:
                const HostedBackendRetryActionExecutionResult(
                  actionId: 'retry-connect',
                  kind: HostedBackendRetryActionKind.retryConnect,
                  status: HostedBackendRetryActionExecutionStatus.failed,
                  message: 'Review hosted settings and retry.',
                ),
            onHostedBackendAction: (action) async {
              actions.add(action.kind);
            },
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('settings-hosted-backend-card')),
      findsOneWidget,
    );
    expect(find.text('Hosted Backend'), findsOneWidget);
    expect(find.text('retryable-failure'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-hosted-last-result')),
      findsOneWidget,
    );

    final retry = find.byKey(
      const ValueKey('settings-hosted-action-retry-connect'),
    );
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pump();

    expect(actions, <HostedBackendRetryActionKind>[
      HostedBackendRetryActionKind.retryConnect,
    ]);
  });
}
