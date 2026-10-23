import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/app/app_bootstrap.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';
import 'package:vityo_app/src/view_ide/module_host/module_host.dart';
import 'package:vityo_app/src/view_ide/platform/platform.dart';
import 'package:vityo_app/src/view_ide/runtime/runtime.dart';

void main() {
  for (final fixture in <({PlatformTarget target, ProcessFacts facts})>[
    (
      target: PlatformTarget.linux,
      facts: ProcessFacts.linuxDebianArm(targetId: 'linux-fixture'),
    ),
    (
      target: PlatformTarget.windows,
      facts: ProcessFacts.windowsX64(targetId: 'windows-fixture'),
    ),
  ]) {
    test('${fixture.target.wireValue} registers and launches managed extension '
        'hosts', () async {
      final processManager = _RecordingProcessManager(fixture.facts);
      final launchers = createPlatformExtensionHostSandboxLauncherRegistry(
        platformTarget: fixture.target,
        processManager: processManager,
      );
      final registry = ExtensionManifestRegistry(<ExtensionManifest>[
        const ExtensionManifest(
          extensionId: 'fixture.language',
          displayName: 'Fixture Language',
          version: '1.0.0',
          publisher: 'vityo',
          entrypoint: 'fixture-host',
          activationEvents: <String>['onStartup'],
          trustedByDefault: true,
          metadata: <String, Object?>{
            'isolationMode': 'local-process',
            'hostArguments': <String>['--stdio'],
            'hostEnvironment': <String, String>{'VITYO_HOST': '1'},
            'hostWorkingDirectory': '/workspace',
          },
        ),
      ]);
      DateTime clock() => DateTime.utc(2026, 8, 31, 8);
      final activation = ExtensionActivator(
        clock: clock,
      ).activate(registry: registry, event: 'onStartup');
      final snapshot = ExtensionHostSupervisor(
        clock: clock,
      ).applyActivation(registry: registry, session: activation);

      final receipt =
          await ExtensionHostStartupExecutor(
            clock: clock,
            bridge: ExtensionHostSupervisorExecutionBridge(
              sandboxLaunchers: launchers,
            ),
          ).execute(
            snapshot: snapshot,
            manifestRegistry: registry,
            buffer: RuntimeOutputLiveBuffer(),
          );

      expect(
        launchers.launchers.map((launcher) => launcher.launcherId),
        containsAll(<String>[
          'compiled-in-host-registry',
          'managed-local-process',
        ]),
      );
      expect(receipt.ready, isTrue);
      expect(receipt.supervisorSnapshot.runningExtensionIds, <String>[
        'fixture.language',
      ]);
      expect(receipt.launchResults.single.processHandleId, isNotEmpty);
      expect(receipt.launchResults.single.pid, greaterThan(0));
      expect(processManager.lastRequest?.arguments, <String>['--stdio']);
      expect(processManager.lastRequest?.workingDirectory, '/workspace');
      expect(processManager.lastRequest?.environment['VITYO_HOST'], '1');
      expect(
        receipt.telemetryEvents
            .map((event) => event.status)
            .toList(growable: false),
        <ExtensionHostSupervisorStatus>[
          ExtensionHostSupervisorStatus.starting,
          ExtensionHostSupervisorStatus.running,
        ],
      );
    });
  }

  test(
    'compiled-in module hosts activate from the registered host set',
    () async {
      final processManager = _RecordingProcessManager(
        ProcessFacts.linuxDebianArm(),
      );
      final launchers = createPlatformExtensionHostSandboxLauncherRegistry(
        platformTarget: PlatformTarget.linux,
        processManager: processManager,
        compiledInExtensionIds: const <String>['editor.core'],
      );
      final registry = ExtensionManifestRegistry(<ExtensionManifest>[
        const ExtensionManifest(
          extensionId: 'editor.core',
          displayName: 'Editor Core',
          version: '1.0.0',
          publisher: 'vityo',
          entrypoint: 'lib/editor.dart',
          activationEvents: <String>['onStartup'],
          trustedByDefault: true,
          metadata: <String, Object?>{'source': 'module-registry'},
        ),
      ]);
      final activation = const ExtensionActivator().activate(
        registry: registry,
        event: 'onStartup',
      );
      final snapshot = const ExtensionHostSupervisor().applyActivation(
        registry: registry,
        session: activation,
      );

      final receipt =
          await ExtensionHostStartupExecutor(
            bridge: ExtensionHostSupervisorExecutionBridge(
              sandboxLaunchers: launchers,
            ),
          ).execute(
            snapshot: snapshot,
            manifestRegistry: registry,
            buffer: RuntimeOutputLiveBuffer(),
          );

      expect(receipt.ready, isTrue);
      expect(
        receipt.launchResults.single.launcher?.launcherId,
        'compiled-in-host-registry',
      );
      expect(receipt.launchResults.single.processHandleId, isEmpty);
      expect(processManager.lastRequest, isNull);

      final unregisteredReceipt =
          await ExtensionHostStartupExecutor(
            bridge: ExtensionHostSupervisorExecutionBridge(
              sandboxLaunchers:
                  createPlatformExtensionHostSandboxLauncherRegistry(
                    platformTarget: PlatformTarget.linux,
                    processManager: processManager,
                  ),
            ),
          ).execute(
            snapshot: snapshot,
            manifestRegistry: registry,
            buffer: RuntimeOutputLiveBuffer(),
          );
      expect(unregisteredReceipt.ready, isFalse);
      expect(
        unregisteredReceipt.supervisorSnapshot.failedExtensionIds,
        <String>['editor.core'],
      );
      expect(unregisteredReceipt.launchResults.single.launched, isFalse);
    },
  );

  test('app bootstrap trusts bundled optional modules for activation', () {
    final registry = ModuleRegistry(
      platformTarget: PlatformTarget.macos,
      definitions: const <ModuleDefinition>[
        ModuleDefinition(
          manifest: ModuleManifest(
            moduleId: 'agent.surface',
            displayName: 'Agent Surface',
            version: '1.0.0',
            kind: ModuleKind.optional,
            slot: ModuleSlot.agentSurface,
            description: 'Bundled optional surface.',
            enabledByDefault: true,
            entrypoint: 'lib/agent_surface.dart',
            distributionPolicyRef: 'bundled',
            capabilityFlags: <String, bool>{'agentPanel': true},
            extensionActivationEvents: <String>['onStartup'],
            extensionMetadata: <String, Object?>{'isolationMode': 'in-process'},
          ),
          matrix: ModuleCapabilityMatrix(
            moduleId: 'agent.surface',
            platforms: <PlatformTarget, ModuleCapabilityRule>{
              PlatformTarget.macos: ModuleCapabilityRule(
                supported: true,
                visible: true,
                installable: true,
                mountedByDefault: true,
                iosSafe: true,
                distributionChannel: 'bundled',
                note: 'fixture',
              ),
            },
          ),
        ),
      ],
    );

    final startup = AppBootstrap.createExtensionStartupPlan(
      moduleRegistry: registry,
      clock: () => DateTime.utc(2026, 8, 31),
    );

    expect(startup.activationSession.activatedExtensionIds, <String>[
      'agent.surface',
    ]);
    expect(startup.supervisorSnapshot.startingExtensionIds, <String>[
      'agent.surface',
    ]);
    expect(
      startup.manifestRegistry.lookup('agent.surface')?.trustedByDefault,
      isTrue,
    );
  });
}

final class _RecordingProcessManager implements ProcessManager {
  _RecordingProcessManager(this.facts)
    : compatibility = ProcessAdapter(facts).adapt();

  @override
  final ProcessFacts facts;

  @override
  final ProcessCompatibility compatibility;

  ProcessCommandRequest? lastRequest;

  @override
  Future<ProcessCommandResult> run(ProcessCommandRequest request) async {
    lastRequest = request;
    request.onStarted?.call(
      const ProcessCommandHandle(
        processHandleId: 'fixture-extension-host',
        sourceManager: 'fixture-process-manager',
        pid: 4242,
      ),
    );
    return ProcessCommandResult(
      status: ProcessCommandStatus.succeeded,
      executablePath: request.executablePath,
      arguments: request.arguments,
      exitCode: 0,
      stdout: '',
      stderr: '',
      duration: const Duration(milliseconds: 1),
      metadata: const <String, Object?>{
        'processHandleId': 'fixture-extension-host',
        'pid': 4242,
      },
    );
  }

  @override
  ProcessOperationFailure? failureFor(
    ProcessCommandResult result, {
    String operation = 'process.spawn',
    String? recoveryHint,
  }) {
    return const ProcessFailureClassifier(
      sourceManager: 'fixture-process-manager',
    ).classify(result, operation: operation, recoveryHint: recoveryHint);
  }
}
