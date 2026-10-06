import 'agent_client_models.dart';

const String firstPartyCodingAgentId = 'vityo-coding-agent';

/// Builds the first-party descriptor from the installed app and support roots.
/// This pure layout contract is shared by desktop composition and tests.
abstract final class AgentLaunchPaths {
  static AgentLaunchDescriptor fromInstalledApplication({
    required String applicationExecutable,
    required String applicationSupportDirectory,
    required String operatingSystem,
    required String pathSeparator,
    required String workingDirectory,
  }) {
    if (!_isAbsolute(applicationExecutable, operatingSystem) ||
        !_isAbsolute(applicationSupportDirectory, operatingSystem)) {
      throw ArgumentError(
        'Installed executable and application support paths must be absolute.',
      );
    }
    if (workingDirectory.isEmpty) {
      throw ArgumentError.value(
        workingDirectory,
        'workingDirectory',
        'must not be empty',
      );
    }

    final executable = _packagedExecutable(
      applicationExecutable: applicationExecutable,
      operatingSystem: operatingSystem,
      separator: pathSeparator,
    );

    return AgentLaunchDescriptor(
      id: firstPartyCodingAgentId,
      executable: executable,
      arguments: <String>[
        '--stdio-agent',
        '--provider-config',
        providerConfigPath(
          applicationSupportDirectory: applicationSupportDirectory,
          pathSeparator: pathSeparator,
        ),
        '--session-dir',
        sessionDirectoryPath(
          applicationSupportDirectory: applicationSupportDirectory,
          pathSeparator: pathSeparator,
        ),
      ],
      workingDirectory: workingDirectory,
    );
  }

  /// The support directory the packaged agent owns:
  /// `<applicationSupportDirectory>/vityo-coding-agent`.
  static String agentSupportDirectory({
    required String applicationSupportDirectory,
    required String pathSeparator,
  }) => _append(applicationSupportDirectory, <String>[
    'vityo-coding-agent',
  ], pathSeparator);

  /// The provider configuration file the agent is launched with. This is the
  /// single source of truth for the path — the launch descriptor and the
  /// workbench's model configuration writer both read it from here, so the two
  /// can never drift apart.
  static String providerConfigPath({
    required String applicationSupportDirectory,
    required String pathSeparator,
  }) => _append(
    agentSupportDirectory(
      applicationSupportDirectory: applicationSupportDirectory,
      pathSeparator: pathSeparator,
    ),
    <String>['provider.json'],
    pathSeparator,
  );

  /// The durable session journal directory the agent is launched with.
  static String sessionDirectoryPath({
    required String applicationSupportDirectory,
    required String pathSeparator,
  }) => _append(
    agentSupportDirectory(
      applicationSupportDirectory: applicationSupportDirectory,
      pathSeparator: pathSeparator,
    ),
    <String>['sessions'],
    pathSeparator,
  );

  static String _packagedExecutable({
    required String applicationExecutable,
    required String operatingSystem,
    required String separator,
  }) {
    final executableDirectory = _parent(applicationExecutable);
    return switch (operatingSystem) {
      'macos' => _append(_parent(executableDirectory), <String>[
        'Helpers',
        'vityo-coding-agent',
      ], separator),
      'linux' => _append(executableDirectory, <String>[
        'components',
        'vityo-coding-agent',
      ], separator),
      'windows' => _append(executableDirectory, <String>[
        'components',
        'vityo-coding-agent.exe',
      ], separator),
      _ => throw UnsupportedError(
        'The packaged Vityo Coding Agent is unavailable on this platform.',
      ),
    };
  }

  static String _parent(String path) {
    final separatorIndex = path.lastIndexOf(RegExp(r'[/\\]'));
    if (separatorIndex < 0) {
      throw ArgumentError.value(path, 'path', 'must have a parent directory');
    }
    if (separatorIndex == 0) return path.substring(0, 1);
    return path.substring(0, separatorIndex);
  }

  static String _append(String base, List<String> segments, String separator) {
    var result = base;
    for (final segment in segments) {
      if (!result.endsWith('/') && !result.endsWith('\\')) {
        result = '$result$separator';
      }
      result = '$result$segment';
    }
    return result;
  }

  static bool _isAbsolute(String path, String operatingSystem) {
    if (operatingSystem == 'windows') {
      return RegExp(r'^[A-Za-z]:[/\\]').hasMatch(path) ||
          path.startsWith('\\\\');
    }
    return path.startsWith('/');
  }
}
