import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/agent_client/agent_launch_paths_contract.dart';

void main() {
  test(
    'Linux descriptor resolves the packaged Rust binary and support paths',
    () {
      final descriptor = AgentLaunchPaths.fromInstalledApplication(
        applicationExecutable: '/fixture/install/Vityo/vityo',
        applicationSupportDirectory: '/fixture/runtime/support/Vityo',
        operatingSystem: 'linux',
        pathSeparator: '/',
        workingDirectory: '/fixture/workspace/project',
      );

      expect(descriptor.id, firstPartyCodingAgentId);
      expect(
        descriptor.executable,
        '/fixture/install/Vityo/components/vityo-coding-agent',
      );
      expect(descriptor.workingDirectory, '/fixture/workspace/project');
      expect(descriptor.arguments, <String>[
        '--stdio-agent',
        '--provider-config',
        '/fixture/runtime/support/Vityo/vityo-coding-agent/provider.json',
        '--session-dir',
        '/fixture/runtime/support/Vityo/vityo-coding-agent/sessions',
      ]);
    },
  );

  test('macOS descriptor resolves from the app bundle executable', () {
    final descriptor = AgentLaunchPaths.fromInstalledApplication(
      applicationExecutable: '/fixture/install/Vityo.app/Contents/MacOS/Vityo',
      applicationSupportDirectory: '/fixture/runtime/support/Vityo',
      operatingSystem: 'macos',
      pathSeparator: '/',
      workingDirectory: '/fixture/workspace/project',
    );

    expect(
      descriptor.executable,
      '/fixture/install/Vityo.app/Contents/Helpers/vityo-coding-agent',
    );
    expect(
      descriptor.arguments[2],
      '/fixture/runtime/support/Vityo/vityo-coding-agent/provider.json',
    );
    expect(
      descriptor.arguments[4],
      '/fixture/runtime/support/Vityo/vityo-coding-agent/sessions',
    );
  });

  test(
    'Windows descriptor resolves the packaged executable and support paths',
    () {
      final descriptor = AgentLaunchPaths.fromInstalledApplication(
        applicationExecutable: r'C:\fixture\install\Vityo\Vityo.exe',
        applicationSupportDirectory: r'C:\fixture\runtime\support\Vityo',
        operatingSystem: 'windows',
        pathSeparator: r'\',
        workingDirectory: r'C:\fixture\workspace\project',
      );

      expect(
        descriptor.executable,
        r'C:\fixture\install\Vityo\components\vityo-coding-agent.exe',
      );
      expect(descriptor.arguments, <String>[
        '--stdio-agent',
        '--provider-config',
        r'C:\fixture\runtime\support\Vityo\vityo-coding-agent\provider.json',
        '--session-dir',
        r'C:\fixture\runtime\support\Vityo\vityo-coding-agent\sessions',
      ]);
    },
  );

  test('the shared support paths are the ones the descriptor uses', () {
    const String support = '/fixture/runtime/support/Vityo';
    final descriptor = AgentLaunchPaths.fromInstalledApplication(
      applicationExecutable: '/fixture/install/Vityo/vityo',
      applicationSupportDirectory: support,
      operatingSystem: 'linux',
      pathSeparator: '/',
      workingDirectory: '/fixture/workspace/project',
    );

    // The model configuration writer reads the same helper, so the file it
    // writes is always the file the launch hands the executable.
    final String providerConfig = AgentLaunchPaths.providerConfigPath(
      applicationSupportDirectory: support,
      pathSeparator: '/',
    );
    expect(providerConfig, '$support/vityo-coding-agent/provider.json');
    expect(descriptor.arguments[2], providerConfig);
    expect(
      descriptor.arguments[4],
      AgentLaunchPaths.sessionDirectoryPath(
        applicationSupportDirectory: support,
        pathSeparator: '/',
      ),
    );
    expect(
      AgentLaunchPaths.agentSupportDirectory(
        applicationSupportDirectory: support,
        pathSeparator: '/',
      ),
      '$support/vityo-coding-agent',
    );
  });

  test('relative app and support paths are rejected', () {
    expect(
      () => AgentLaunchPaths.fromInstalledApplication(
        applicationExecutable: 'Vityo',
        applicationSupportDirectory: '/support',
        operatingSystem: 'linux',
        pathSeparator: '/',
        workingDirectory: '/workspace',
      ),
      throwsArgumentError,
    );
    expect(
      () => AgentLaunchPaths.fromInstalledApplication(
        applicationExecutable: '/fixture/install/Vityo/vityo',
        applicationSupportDirectory: 'support',
        operatingSystem: 'linux',
        pathSeparator: '/',
        workingDirectory: '/fixture/workspace',
      ),
      throwsArgumentError,
    );
  });
}
