import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/workspace/workspace.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/hosted_control_plane.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/project_graph_contract.dart';
import 'package:vityo_app/src/view_ide/platform/platform_target.dart';
import 'package:vityo_app/src/view_ide/runtime/runtime_output_channels.dart';
import 'package:vityo_app/src/view_ide/shell_runtime/controllers/hosted_backend_controller.dart';

void main() {
  test('verifies hosted backend and applies refreshed project graph', () async {
    final workspaceController = WorkspaceController(
      projectSnapshot: _hostedProject(title: 'Before refresh'),
    );
    final outputBuffer = RuntimeOutputLiveBuffer();
    final client = _HostedClient(response: _hostedEnvelope());
    final controller = HostedBackendController(
      workspaceController: workspaceController,
      platformTarget: PlatformTarget.linux,
      runtimeOutputBuffer: outputBuffer,
      documentStoreAvailable: true,
      hostedClient: client,
    );
    addTearDown(() async {
      controller.dispose();
      workspaceController.dispose();
      await outputBuffer.dispose();
    });

    expect(
      controller.connectorReport.status,
      HostedBackendConnectorStatus.retryableFailure,
    );

    final result = await controller.verifyConnection();

    expect(result.status, HostedBackendRetryActionExecutionStatus.completed);
    expect(result.message, 'Hosted workspace refreshed.');
    expect(client.projectGraphWorkspaceIds, <String>['hosted-demo']);
    expect(workspaceController.activeProject.title, 'After refresh');
    expect(
      controller.connectorReport.status,
      HostedBackendConnectorStatus.ready,
    );
    expect(outputBuffer.snapshot.events, hasLength(1));
    expect(
      outputBuffer.snapshot.events.single.metadata['hostedRetryStatus'],
      'completed',
    );

    final settingsAction = controller.connectorReport.actionFor(
      HostedBackendRetryActionKind.openSettings,
    )!;
    final settingsResult = await controller.execute(settingsAction);

    expect(settingsResult.successful, isTrue);
    expect(
      controller.lastSettingsRoute,
      'settings://hosted-backend?workspaceId=hosted-demo',
    );
    expect(outputBuffer.snapshot.events, hasLength(2));
  });

  test(
    'keeps transport failures out of user-visible state and output',
    () async {
      final workspaceController = WorkspaceController(
        projectSnapshot: _hostedProject(title: 'Failure fixture'),
      );
      final outputBuffer = RuntimeOutputLiveBuffer();
      final controller = HostedBackendController(
        workspaceController: workspaceController,
        platformTarget: PlatformTarget.windows,
        runtimeOutputBuffer: outputBuffer,
        documentStoreAvailable: true,
        hostedClient: _HostedClient(failure: StateError('private-detail')),
      );
      addTearDown(() async {
        controller.dispose();
        workspaceController.dispose();
        await outputBuffer.dispose();
      });
      final action = controller.connectorReport.actionFor(
        HostedBackendRetryActionKind.retryConnect,
      )!;

      final result = await controller.execute(action);

      expect(result.status, HostedBackendRetryActionExecutionStatus.failed);
      expect(result.message, isNot(contains('private-detail')));
      expect(
        controller.connectorReport.message,
        isNot(contains('private-detail')),
      );
      expect(
        outputBuffer.snapshot.events.single.message,
        isNot(contains('private-detail')),
      );
      expect(result.toJson(), isNot(containsPair('response', anything)));
    },
  );
}

class _HostedClient implements HostedControlPlaneClient {
  _HostedClient({this.response, this.failure});

  final Map<String, dynamic>? response;
  final Object? failure;
  final List<String> projectGraphWorkspaceIds = <String>[];

  @override
  HostedControlPlaneConfig get config => const HostedControlPlaneConfig(
    baseUrl: 'https://hosted.example.test',
    workspaceRoot: '/workspace/demo',
    workspaceId: 'hosted-demo',
  );

  @override
  Future<Map<String, dynamic>> projectGraph({
    required String workspaceId,
  }) async {
    projectGraphWorkspaceIds.add(workspaceId);
    if (failure case final failure?) {
      throw failure;
    }
    return response!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _hostedEnvelope() {
  return <String, dynamic>{
    'returncode': 0,
    'message': 'Internal response detail is not presented by the IDE.',
    'payload': <String, dynamic>{
      'schema_version': 1,
      'id': 'hosted-demo',
      'title': 'After refresh',
      'workspace_root': '/workspace/demo',
      'workspace_members': <String>[],
      'manifest_path': '/workspace/demo/pafio.toml',
      'packages': <Object>[],
      'dependencies': <Object>[],
      'targets': <Object>[],
      'editor_files': <String>['/workspace/demo/src/main.styio'],
      'lock_state': 'fresh',
      'vendor_state': 'present',
    },
    'workspace': <String, dynamic>{
      'workspaceId': 'hosted-demo',
      'schemaVersion': '1',
      'ownerRef': 'fixture',
      'status': 'active',
      'entryUrl': 'https://hosted.example.test/workspaces/hosted-demo',
      'createdAt': '2026-05-01T00:00:00Z',
      'lastActiveAt': '2026-05-02T00:00:00Z',
      'retentionDays': 7,
      'exportState': 'not-requested',
    },
  };
}

ProjectGraphSnapshot _hostedProject({required String title}) {
  return ProjectGraphSnapshot(
    id: 'hosted-demo',
    title: title,
    kind: ProjectKind.hosted,
    workspaceRoot: '/workspace/demo',
    workspaceMembers: const <String>[],
    manifestPath: '/workspace/demo/pafio.toml',
    packages: const <ProjectPackageSnapshot>[],
    dependencies: const <ProjectDependencySnapshot>[],
    targets: const <ProjectTargetDescriptor>[],
    editorFiles: const <String>['/workspace/demo/src/main.styio'],
    toolchain: const ToolchainStatusSnapshot(
      source: ToolchainResolutionSource.unavailable,
      detail: 'Hosted controller fixture.',
    ),
    lockState: ProjectLockState.unknown,
    vendorState: ProjectVendorState.unknown,
    hostedWorkspace: HostedWorkspaceRecordSnapshot(
      workspaceId: 'hosted-demo',
      schemaVersion: '1',
      ownerRef: 'fixture',
      status: HostedWorkspaceStatus.active,
      entryUrl: 'https://hosted.example.test/workspaces/hosted-demo',
      createdAt: DateTime.utc(2026, 5),
      lastActiveAt: DateTime.utc(2026, 5, 2),
      retentionDays: 7,
      exportState: HostedWorkspaceExportState.notRequested,
    ),
    notes: const <String>[],
  );
}
