import 'dart:async';

import '../environment/system_compatibility/process/process_manager.dart';
import '../module_host/module_host.dart';
import '../platform/platform_target.dart';
import 'extension_host_sandbox_launcher_shared.dart';
import 'extension_host_supervisor_execution.dart';

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

  late final ExtensionHostSandboxLauncherRegistration localProcess;
  localProcess = ExtensionHostSandboxLauncherRegistration(
    launcherId: 'managed-local-process',
    label: 'Managed local process',
    action: ExtensionHostSupervisorAction.spawnLocalProcess,
    available:
        platformTarget != PlatformTarget.web &&
        processManager.compatibility.supportsSpawn,
    metadata: <String, Object?>{
      'sandboxKind': 'managed-local-process',
      'platformTarget': platformTarget.wireValue,
      'processManagerTarget': processManager.compatibility.targetId,
    },
    launcher: (request) {
      return _launchManagedProcess(
        request: request,
        launcher: localProcess,
        processManager: processManager,
      );
    },
  );

  return ExtensionHostSandboxLauncherRegistry(
    launchers: <ExtensionHostSandboxLauncherRegistration>[
      inProcess,
      localProcess,
    ],
  );
}

Future<ExtensionHostSandboxLaunchResult> _launchManagedProcess({
  required ExtensionHostSandboxLaunchRequest request,
  required ExtensionHostSandboxLauncherRegistration launcher,
  required ProcessManager processManager,
}) async {
  final start = Completer<_ProcessStartOutcome>();
  final definition = request.plan.definition;
  final completion = processManager.run(
    ProcessCommandRequest(
      executablePath: definition.command,
      arguments: definition.arguments,
      workingDirectory: definition.workingDirectory,
      environment: definition.environment,
      onStarted: (handle) {
        if (!start.isCompleted) {
          start.complete(_ProcessStartOutcome.started(handle));
        }
      },
    ),
  );
  unawaited(
    completion.then(
      (result) {
        if (!start.isCompleted) {
          start.complete(_ProcessStartOutcome.completed(result));
        }
      },
      onError: (Object error, StackTrace _) {
        if (!start.isCompleted) {
          start.complete(_ProcessStartOutcome.failed(error));
        }
      },
    ),
  );

  final outcome = await start.future;
  final handle = outcome.handle;
  if (handle != null) {
    return ExtensionHostSandboxLaunchResult.launched(
      request: request,
      launcher: launcher,
      message: 'Managed extension-host process started.',
      processHandleId: handle.processHandleId,
      pid: handle.pid,
      activationTelemetryId: extensionHostActivationTelemetryId(
        request,
        'native-process',
      ),
      metadata: <String, Object?>{'processHandleSource': handle.sourceManager},
    );
  }
  final result = outcome.result;
  final processMessage = result?.message?.trim() ?? '';
  final processError = result?.stderr.trim() ?? '';
  return ExtensionHostSandboxLaunchResult.blocked(
    request: request,
    message: processMessage.isNotEmpty
        ? processMessage
        : processError.isNotEmpty
        ? processError
        : outcome.error?.toString() ??
              'Managed extension-host process failed before startup.',
    metadata: <String, Object?>{
      if (result != null) 'processStatus': result.status.name,
    },
  );
}

final class _ProcessStartOutcome {
  const _ProcessStartOutcome({this.handle, this.result, this.error});

  factory _ProcessStartOutcome.started(ProcessCommandHandle handle) {
    return _ProcessStartOutcome(handle: handle);
  }

  factory _ProcessStartOutcome.completed(ProcessCommandResult result) {
    return _ProcessStartOutcome(result: result);
  }

  factory _ProcessStartOutcome.failed(Object error) {
    return _ProcessStartOutcome(error: error);
  }

  final ProcessCommandHandle? handle;
  final ProcessCommandResult? result;
  final Object? error;
}
