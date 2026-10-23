part of '../shell_runtime_model.dart';

/// Public hosted-backend state and recovery actions for render-layer clients.
mixin ShellRuntimeHostedBackendFacade on ShellRuntimeFacadeHost {
  HostedBackendConnectorParityReport get hostedBackendConnectorReport =>
      _hostedBackendController.connectorReport;

  HostedBackendRetryActionExecutionResult? get lastHostedBackendActionResult =>
      _hostedBackendController.lastResult;

  String? get lastHostedBackendSettingsRoute =>
      _hostedBackendController.lastSettingsRoute;

  bool get hostedBackendActionRunning => _hostedBackendController.actionRunning;

  Future<HostedBackendRetryActionExecutionResult> executeHostedBackendAction(
    HostedBackendRetryAction action,
  ) => _hostedBackendController.execute(action);

  Future<HostedBackendRetryActionExecutionResult>
  verifyHostedBackendConnection() =>
      _hostedBackendController.verifyConnection();
}
