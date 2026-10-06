import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'agent_client_models.dart';
import 'agent_launch_paths_contract.dart';

Future<AgentLaunchDescriptor> resolvePackagedCodingAgentLaunch({
  required String workingDirectory,
}) async {
  final supportDirectory = await getApplicationSupportDirectory();
  return AgentLaunchPaths.fromInstalledApplication(
    applicationExecutable: Platform.resolvedExecutable,
    applicationSupportDirectory: supportDirectory.path,
    operatingSystem: Platform.operatingSystem,
    pathSeparator: Platform.pathSeparator,
    workingDirectory: workingDirectory,
  );
}

/// The `provider.json` path the packaged coding agent is launched with.
///
/// The workbench's model configuration writes to exactly this path, so it never
/// diverges from the launch contract.
Future<String> resolvePackagedCodingAgentProviderConfigPath() async {
  final supportDirectory = await getApplicationSupportDirectory();
  return AgentLaunchPaths.providerConfigPath(
    applicationSupportDirectory: supportDirectory.path,
    pathSeparator: Platform.pathSeparator,
  );
}
