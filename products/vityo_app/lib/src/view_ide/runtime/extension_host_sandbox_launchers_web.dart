import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../environment/system_compatibility/process/process_manager.dart';
import '../module_host/module_host.dart';
import '../platform/platform_target.dart';
import 'extension_host_sandbox_launcher_shared.dart';
import 'extension_host_supervisor_execution.dart';

final Map<String, web.Worker> _workers = <String, web.Worker>{};

ExtensionHostSandboxLauncherRegistry
createPlatformExtensionHostSandboxLauncherRegistry({
  required PlatformTarget platformTarget,
  required ProcessManager processManager,
  Iterable<String> compiledInExtensionIds = const <String>[],
}) {
  final inProcess = createInProcessExtensionHostLauncher(
    platformTarget,
    registeredExtensionIds: compiledInExtensionIds,
  );

  late final ExtensionHostSandboxLauncherRegistration webWorker;
  webWorker = ExtensionHostSandboxLauncherRegistration(
    launcherId: 'browser-worker',
    label: 'Browser Worker',
    action: ExtensionHostSupervisorAction.spawnWebWorker,
    available: platformTarget == PlatformTarget.web,
    metadata: const <String, Object?>{'sandboxKind': 'browser-worker'},
    launcher: (request) async {
      final workerUri = request.plan.definition.command.trim();
      if (workerUri.isEmpty) {
        return ExtensionHostSandboxLaunchResult.blocked(
          request: request,
          message: 'Browser Worker launch requires a worker entrypoint URI.',
        );
      }
      try {
        final previous = _workers.remove(request.extensionId);
        previous?.terminate();
        _workers[request.extensionId] = web.Worker(workerUri.toJS);
        return ExtensionHostSandboxLaunchResult.launched(
          request: request,
          launcher: webWorker,
          message: 'Browser Worker extension host started.',
          processHandleId: 'worker:${request.extensionId}',
          activationTelemetryId: extensionHostActivationTelemetryId(
            request,
            'web-worker',
          ),
        );
      } on Object catch (error) {
        return ExtensionHostSandboxLaunchResult.blocked(
          request: request,
          message: 'Browser Worker extension host failed to start: $error',
        );
      }
    },
  );

  return ExtensionHostSandboxLauncherRegistry(
    launchers: <ExtensionHostSandboxLauncherRegistration>[inProcess, webWorker],
  );
}
