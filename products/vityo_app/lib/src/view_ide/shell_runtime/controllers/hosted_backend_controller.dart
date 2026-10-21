import 'package:flutter/foundation.dart';

import '../../../ide/workspace/hosted_backend_retry_executor.dart';
import '../../../ide/workspace/hosted_workspace_lifecycle.dart';
import '../../../ide/workspace/workspace_controller.dart';
import '../../backend_toolchain/hosted_control_plane.dart';
import '../../backend_toolchain/hosted_payload_codec.dart';
import '../../platform/platform_target.dart';
import '../../runtime/runtime_output_channels.dart';

/// Owns the live hosted-backend recovery path exposed by the IDE shell.
///
/// Network payloads remain internal to this controller. The public state only
/// contains connector checks, stable recovery messages, and action outcomes.
class HostedBackendController extends ChangeNotifier {
  HostedBackendController({
    required this.workspaceController,
    required this.platformTarget,
    required this.runtimeOutputBuffer,
    required this.documentStoreAvailable,
    this.hostedClient,
    this.lifecycle = const HostedWorkspaceLifecycle(),
  }) : _workspaceId =
           workspaceController.activeProject.hostedWorkspace?.workspaceId {
    _connectorReport = _buildConnectorReport();
    workspaceController.addListener(_handleWorkspaceChanged);
  }

  final WorkspaceController workspaceController;
  final PlatformTarget platformTarget;
  final RuntimeOutputLiveBuffer runtimeOutputBuffer;
  final bool documentStoreAvailable;
  final HostedControlPlaneClient? hostedClient;
  final HostedWorkspaceLifecycle lifecycle;

  late HostedBackendConnectorParityReport _connectorReport;
  HostedBackendRetryActionExecutionResult? _lastResult;
  String? _lastSettingsRoute;
  String? _workspaceId;
  String? _failureMessage = 'Hosted backend connection has not been checked.';
  var _backendReachable = false;
  var _actionRunning = false;

  HostedBackendConnectorParityReport get connectorReport => _connectorReport;

  HostedBackendRetryActionExecutionResult? get lastResult => _lastResult;

  String? get lastSettingsRoute => _lastSettingsRoute;

  bool get actionRunning => _actionRunning;

  bool get hasHostedWorkspace =>
      workspaceController.activeProject.hostedWorkspace != null;

  Future<HostedBackendRetryActionExecutionResult> verifyConnection() {
    final action = _connectorReport.actionFor(
      HostedBackendRetryActionKind.refreshWorkspace,
    );
    if (action == null) {
      return Future.value(
        _blockedResult(
          actionId: 'refresh-workspace',
          kind: HostedBackendRetryActionKind.refreshWorkspace,
          message: 'No hosted workspace is available to refresh.',
        ),
      );
    }
    return execute(action);
  }

  Future<HostedBackendRetryActionExecutionResult> execute(
    HostedBackendRetryAction action,
  ) async {
    final workspace = workspaceController.activeProject.hostedWorkspace;
    final endpointPlan =
        action.endpointPlan ??
        HostedBackendRetryEndpointPlan.forAction(
          actionId: action.id,
          kind: action.kind,
          workspaceId: workspace?.workspaceId ?? _connectorReport.workspaceId,
        );
    if (_actionRunning) {
      return _blockedResult(
        actionId: action.id,
        kind: action.kind,
        endpointPlan: endpointPlan,
        message: 'Another hosted backend action is already running.',
      );
    }
    if (workspace == null) {
      return _recordResult(
        action: action,
        workspaceId: _connectorReport.workspaceId,
        result: _blockedResult(
          actionId: action.id,
          kind: action.kind,
          endpointPlan: endpointPlan,
          message: 'No hosted workspace is available for this action.',
        ),
      );
    }
    if (!action.enabled) {
      return _recordResult(
        action: action,
        workspaceId: workspace.workspaceId,
        result: _blockedResult(
          actionId: action.id,
          kind: action.kind,
          endpointPlan: endpointPlan,
          message: action.message ?? 'This hosted backend action is disabled.',
        ),
      );
    }

    _actionRunning = true;
    notifyListeners();
    try {
      HostedBackendRetryActionExecutionResult result;
      if (action.kind == HostedBackendRetryActionKind.openSettings) {
        _lastSettingsRoute = endpointPlan.settingsRoute;
        result = HostedBackendRetryActionExecutionResult(
          actionId: action.id,
          kind: action.kind,
          status: HostedBackendRetryActionExecutionStatus.completed,
          message: 'Hosted backend settings opened.',
          endpointPlan: endpointPlan,
        );
      } else if (hostedClient == null) {
        _backendReachable = false;
        _failureMessage = 'Hosted control plane is not configured.';
        result = _blockedResult(
          actionId: action.id,
          kind: action.kind,
          endpointPlan: endpointPlan,
          message: 'Configure the hosted control plane before retrying.',
        );
      } else {
        result = await HostedBackendRetryActionExecutor(
          transport: HostedControlPlaneRetryTransport(
            hostedClient: hostedClient!,
            platformTarget: platformTarget,
          ),
        ).execute(action: action, workspace: workspace);
        if (result.successful && _refreshesProjectGraph(action.kind)) {
          result = _applyProjectGraphResponse(result, workspace.workspaceId);
        } else if (_refreshesProjectGraph(action.kind)) {
          _backendReachable = false;
          _failureMessage = 'Hosted backend did not complete the request.';
        }
      }
      return _recordResult(
        action: action,
        workspaceId: workspace.workspaceId,
        result: result,
      );
    } finally {
      _actionRunning = false;
      _connectorReport = _buildConnectorReport();
      notifyListeners();
    }
  }

  HostedBackendRetryActionExecutionResult _applyProjectGraphResponse(
    HostedBackendRetryActionExecutionResult result,
    String expectedWorkspaceId,
  ) {
    try {
      final response = result.response;
      if (response == null) {
        throw const FormatException('Missing hosted project graph response.');
      }
      final snapshot = hostedProjectGraphSnapshotFromEnvelope(response);
      final refreshedWorkspace = snapshot.hostedWorkspace;
      if (refreshedWorkspace == null ||
          refreshedWorkspace.workspaceId != expectedWorkspaceId) {
        throw const FormatException('Hosted workspace identity mismatch.');
      }
      _backendReachable = true;
      _failureMessage = null;
      workspaceController.replaceProject(snapshot);
      return result;
    } on Object {
      _backendReachable = false;
      _failureMessage = 'Hosted backend returned an unusable workspace state.';
      return HostedBackendRetryActionExecutionResult(
        actionId: result.actionId,
        kind: result.kind,
        status: HostedBackendRetryActionExecutionStatus.failed,
        message:
            'Hosted backend returned an unusable workspace state. Review hosted settings and retry.',
        endpointPlan: result.endpointPlan,
      );
    }
  }

  HostedBackendRetryActionExecutionResult _recordResult({
    required HostedBackendRetryAction action,
    required String workspaceId,
    required HostedBackendRetryActionExecutionResult result,
  }) {
    _lastResult = result;
    runtimeOutputBuffer.addEvent(
      HostedBackendRetryRuntimeOutputBinding(
        workspaceId: workspaceId,
        action: action,
        result: result,
      ).runtimeOutputEvent(),
    );
    _connectorReport = _buildConnectorReport();
    notifyListeners();
    return result;
  }

  HostedBackendConnectorParityReport _buildConnectorReport() {
    return lifecycle.connectorParityReportFor(
      workspaceController.activeProject,
      controlPlaneAvailable: hostedClient != null,
      documentStoreAvailable: documentStoreAvailable,
      backendReachable: _backendReachable,
      failureMessage: _failureMessage,
    );
  }

  void _handleWorkspaceChanged() {
    final nextWorkspaceId =
        workspaceController.activeProject.hostedWorkspace?.workspaceId;
    if (nextWorkspaceId != _workspaceId) {
      _workspaceId = nextWorkspaceId;
      _backendReachable = false;
      _failureMessage = nextWorkspaceId == null
          ? null
          : 'Hosted backend connection has not been checked.';
      _lastResult = null;
      _lastSettingsRoute = null;
    }
    _connectorReport = _buildConnectorReport();
    notifyListeners();
  }

  bool _refreshesProjectGraph(HostedBackendRetryActionKind kind) {
    return kind == HostedBackendRetryActionKind.retryConnect ||
        kind == HostedBackendRetryActionKind.refreshWorkspace;
  }

  HostedBackendRetryActionExecutionResult _blockedResult({
    required String actionId,
    required HostedBackendRetryActionKind kind,
    required String message,
    HostedBackendRetryEndpointPlan? endpointPlan,
  }) {
    return HostedBackendRetryActionExecutionResult(
      actionId: actionId,
      kind: kind,
      status: HostedBackendRetryActionExecutionStatus.blocked,
      message: message,
      endpointPlan: endpointPlan,
    );
  }

  @override
  void dispose() {
    workspaceController.removeListener(_handleWorkspaceChanged);
    super.dispose();
  }
}
