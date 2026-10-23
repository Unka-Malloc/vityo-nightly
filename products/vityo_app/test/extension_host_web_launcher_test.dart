import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';
import 'package:vityo_app/src/view_ide/module_host/module_host.dart';
import 'package:vityo_app/src/view_ide/platform/platform.dart';
import 'package:vityo_app/src/view_ide/runtime/runtime.dart';

void main() {
  test('web registers and launches browser Worker extension hosts', () async {
    final processManager = UnsupportedProcessManager(
      facts: ProcessFacts.linuxDebianArm(targetId: 'web-unused'),
    );
    final launchers = createPlatformExtensionHostSandboxLauncherRegistry(
      platformTarget: PlatformTarget.web,
      processManager: processManager,
    );
    final registry = ExtensionManifestRegistry(<ExtensionManifest>[
      const ExtensionManifest(
        extensionId: 'fixture.web-worker',
        displayName: 'Fixture Web Worker',
        version: '1.0.0',
        publisher: 'vityo',
        entrypoint: 'data:text/javascript,self.onmessage=()=>{}',
        activationEvents: <String>['onStartup'],
        trustedByDefault: true,
        metadata: <String, Object?>{'isolationMode': 'web-worker'},
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

    expect(
      launchers.launchers.map((launcher) => launcher.launcherId),
      containsAll(<String>['compiled-in-host-registry', 'browser-worker']),
    );
    expect(receipt.ready, isTrue);
    expect(receipt.supervisorSnapshot.runningExtensionIds, <String>[
      'fixture.web-worker',
    ]);
    expect(receipt.launchResults.single.processHandleId, startsWith('worker:'));
    expect(receipt.launchResults.single.launcher?.launcherId, 'browser-worker');
  }, skip: !kIsWeb);
}
