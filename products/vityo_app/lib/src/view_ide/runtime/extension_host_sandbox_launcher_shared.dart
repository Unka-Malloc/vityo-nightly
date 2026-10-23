import '../module_host/module_host.dart';
import '../platform/platform_target.dart';
import 'extension_host_supervisor_execution.dart';

ExtensionHostSandboxLauncherRegistration createInProcessExtensionHostLauncher(
  PlatformTarget platformTarget, {
  required Iterable<String> registeredExtensionIds,
}) {
  final registered = Set<String>.unmodifiable(
    registeredExtensionIds.map((id) => id.trim()).where((id) => id.isNotEmpty),
  );
  late final ExtensionHostSandboxLauncherRegistration registration;
  registration = ExtensionHostSandboxLauncherRegistration(
    launcherId: 'compiled-in-host-registry',
    label: 'Compiled-in host registry',
    action: ExtensionHostSupervisorAction.runInProcess,
    metadata: <String, Object?>{
      'sandboxKind': 'compiled-in-host-registry',
      'platformTarget': platformTarget.wireValue,
      'registeredExtensionCount': registered.length,
    },
    launcher: (request) async {
      if (!registered.contains(request.extensionId)) {
        return ExtensionHostSandboxLaunchResult.blocked(
          request: request,
          message:
              'In-process extension host is not present in the compiled-in '
              'module registry.',
        );
      }
      return ExtensionHostSandboxLaunchResult.launched(
        request: request,
        launcher: registration,
        message:
            'Compiled-in extension host activated from the module registry.',
        activationTelemetryId: extensionHostActivationTelemetryId(
          request,
          'in-process',
        ),
      );
    },
  );
  return registration;
}

String extensionHostActivationTelemetryId(
  ExtensionHostSandboxLaunchRequest request,
  String launcherKind,
) {
  return '$launcherKind:${request.extensionId}:'
      '${request.timestamp.microsecondsSinceEpoch}';
}
