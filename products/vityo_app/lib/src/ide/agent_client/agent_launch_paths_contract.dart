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
    final support = _append(applicationSupportDirectory, <String>[
      'vityo-coding-agent',
    ], pathSeparator);

    return AgentLaunchDescriptor(
      id: firstPartyCodingAgentId,
      executable: executable,
      arguments: <String>[
        '--stdio-agent',
        '--provider-config',
        _append(support, <String>['provider.json'], pathSeparator),
        '--session-dir',
        _append(support, <String>['sessions'], pathSeparator),
      ],
      workingDirectory: workingDirectory,
    );
  }

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
