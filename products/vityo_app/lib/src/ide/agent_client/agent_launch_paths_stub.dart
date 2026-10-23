import 'agent_client_models.dart';

Future<AgentLaunchDescriptor> resolvePackagedCodingAgentLaunch({
  required String workingDirectory,
}) => Future<AgentLaunchDescriptor>.error(
  UnsupportedError('The packaged Vityo Coding Agent requires a desktop app.'),
);

Future<String> resolvePackagedCodingAgentProviderConfigPath() =>
    Future<String>.error(
      UnsupportedError(
        'The packaged Vityo Coding Agent requires a desktop app.',
      ),
    );
