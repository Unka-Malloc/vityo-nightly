import '../environment/system_compatibility/process/process_manager.dart';
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
  return ExtensionHostSandboxLauncherRegistry(
    launchers: <ExtensionHostSandboxLauncherRegistration>[inProcess],
  );
}
