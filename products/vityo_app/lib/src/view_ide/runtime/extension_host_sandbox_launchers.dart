import '../environment/system_compatibility/process/process_manager.dart';
import '../platform/platform_target.dart';
import 'extension_host_sandbox_launchers_stub.dart'
    if (dart.library.io) 'extension_host_sandbox_launchers_io.dart'
    if (dart.library.js_interop) 'extension_host_sandbox_launchers_web.dart'
    as platform_launchers;
import 'extension_host_supervisor_execution.dart';

/// Creates the concrete extension-host launchers available on this runtime.
///
/// Compiled-in extensions use the registered in-process host set. Native
/// builds additionally register the managed local-process launcher, while web
/// builds register a browser Worker launcher.
ExtensionHostSandboxLauncherRegistry
createPlatformExtensionHostSandboxLauncherRegistry({
  required PlatformTarget platformTarget,
  required ProcessManager processManager,
  Iterable<String> compiledInExtensionIds = const <String>[],
}) {
  return platform_launchers.createPlatformExtensionHostSandboxLauncherRegistry(
    platformTarget: platformTarget,
    processManager: processManager,
    compiledInExtensionIds: compiledInExtensionIds,
  );
}
