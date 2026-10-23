import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';

void main() {
  test(
    'platform manager bundle exposes the complete system manager contract',
    () async {
      final bundle = await createDetectedPlatformManagerBundle(
        targetId: 'platform-manager-contract-test',
      );
      final snapshot = bundle.snapshot();
      final health = bundle.healthSnapshot();
      final probeHealth = bundle.probeHealthSnapshot();
      final blockedProbeHealth = bundle.probeHealthSnapshot(
        probes: <PlatformManagerHealthProbe>[
          PlatformManagerHealthProbe(
            managerKey: 'shell',
            ready: (_) => false,
            message: (_, _) => 'Shell probe failed.',
            recoveryActions: const <PlatformManagerRecoveryAction>[
              PlatformManagerRecoveryAction(
                id: 'platform.shell.select',
                label: 'Select shell',
                managerKey: 'shell',
                message: 'Choose another shell profile.',
              ),
            ],
          ),
        ],
      );
      final liveProbeHealth = await bundle.probeLiveOperationHealthSnapshot(
        registry: PlatformManagerLiveOperationProbeRegistry(
          registrations: <PlatformManagerLiveOperationProbeRegistration>[
            PlatformManagerLiveOperationProbeRegistration(
              managerKey: 'fileSystem',
              operationId: 'platform.fileSystem.smoke',
              probe: (bundle) async {
                return PlatformManagerLiveOperationProbeResult.ready(
                  managerKey: 'fileSystem',
                  operationId: 'platform.fileSystem.smoke',
                  message:
                      'File system smoke passed for ${bundle.context.targetId}.',
                );
              },
            ),
            PlatformManagerLiveOperationProbeRegistration(
              managerKey: 'shell',
              operationId: 'platform.shell.smoke',
              recoveryActions: const <PlatformManagerRecoveryAction>[
                PlatformManagerRecoveryAction(
                  id: 'platform.shell.open-settings',
                  label: 'Open shell settings',
                  managerKey: 'shell',
                  message: 'Select a shell profile.',
                ),
              ],
              probe: (_) async {
                return const PlatformManagerLiveOperationProbeResult.blocked(
                  managerKey: 'shell',
                  operationId: 'platform.shell.smoke',
                  message: 'Shell smoke requires a concrete shell callback.',
                  recoveryActions: <PlatformManagerRecoveryAction>[
                    PlatformManagerRecoveryAction(
                      id: 'platform.shell.open-settings',
                      label: 'Open shell settings',
                      managerKey: 'shell',
                      message: 'Select a shell profile.',
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      );

      expect(snapshot.targetId, 'platform-manager-contract-test');
      expect(snapshot.managerKeys, <String>[
        'fileSystem',
        'shell',
        'process',
        'resource',
        'network',
        'clipboard',
        'notification',
        'localService',
        'pty',
      ]);
      expect(bundle.fileSystem.compatibility, isNotNull);
      expect(bundle.shell.compatibility, isNotNull);
      expect(bundle.process.compatibility, isNotNull);
      expect(bundle.resource.compatibility, isNotNull);
      expect(bundle.network.compatibility, isNotNull);
      expect(bundle.clipboard.compatibility, isNotNull);
      expect(bundle.notification.compatibility, isNotNull);
      expect(bundle.localService.compatibility, isNotNull);
      expect(bundle.pty.compatibility, isNotNull);
      expect(health.targetId, 'platform-manager-contract-test');
      expect(
        health.components.map((component) => component.managerKey),
        <String>[
          'fileSystem',
          'shell',
          'process',
          'resource',
          'network',
          'clipboard',
          'notification',
          'localService',
          'pty',
        ],
      );
      expect(health.toJson()['componentCount'], 9);
      expect(health.todo, isEmpty);
      expect(
        health.toJson()['probeKindCounts'],
        containsPair('factReadiness', 9),
      );
      expect(probeHealth.ready, isTrue);
      expect(probeHealth.toJson()['probeSource'], 'platform-manager-probes');
      expect(
        probeHealth.toJson()['probeKindCounts'],
        containsPair('managerLiveOperation', 9),
      );
      expect(
        probeHealth.components.first.toJson()['operationId'],
        'platform.fileSystem.live-operation',
      );
      expect(probeHealth.recoveryActions, isEmpty);
      expect(blockedProbeHealth.ready, isFalse);
      expect(blockedProbeHealth.blockedCount, 1);
      expect(
        blockedProbeHealth.recoveryActions.single.id,
        'platform.shell.select',
      );
      final routes = const PlatformManagerRecoveryActionRouter().routesFor(
        blockedProbeHealth,
      );
      expect(routes.single.settingsSectionId, 'shell');
      expect(routes.single.toJson()['settingsSectionId'], 'shell');
      expect(liveProbeHealth.ready, isFalse);
      expect(liveProbeHealth.probeSource, 'platform-live-operation-registry');
      expect(
        liveProbeHealth.components.map((component) => component.managerKey),
        <String>['fileSystem', 'shell'],
      );
      expect(
        liveProbeHealth.recoveryActions.single.id,
        'platform.shell.open-settings',
      );
      expect(liveProbeHealth.toJson().containsKey('todo'), isFalse);
    },
  );

  test('default live probe registry covers every platform manager', () async {
    final bundle = await createDetectedPlatformManagerBundle(
      targetId: 'platform-default-live-probes',
    );
    final registry = PlatformManagerLiveOperationProbeRegistry.defaults();

    final health = await bundle.probeLiveOperationHealthSnapshot(
      registry: registry,
    );

    expect(registry.coversAllManagers, isTrue);
    expect(registry.toJson()['registrationCount'], 9);
    expect(registry.toJson()['coversAllManagers'], isTrue);
    expect(health.components, hasLength(9));
    expect(
      health.components.map((component) => component.managerKey).toSet(),
      <String>{
        'fileSystem',
        'shell',
        'process',
        'resource',
        'network',
        'clipboard',
        'notification',
        'localService',
        'pty',
      },
    );
    expect(health.probeSource, 'platform-live-operation-registry');
    expect(health.todo, isEmpty);
    expect(
      health.components
          .where((component) => !component.ready)
          .every((component) => component.recoveryActions.isNotEmpty),
      isTrue,
    );
  });

  test(
    'platform settings surface routes blocked managers to their section',
    () {
      const health = PlatformManagerHealthSnapshot(
        targetId: 'platform-settings',
        ready: false,
        components: <PlatformManagerComponentHealth>[
          PlatformManagerComponentHealth(
            managerKey: 'fileSystem',
            ready: true,
            message: 'File system is ready.',
            operationId: 'platform.fileSystem.live-operation',
          ),
          PlatformManagerComponentHealth(
            managerKey: 'shell',
            ready: false,
            message: 'Shell is blocked.',
            operationId: 'platform.shell.live-operation',
            recoveryActions: <PlatformManagerRecoveryAction>[
              PlatformManagerRecoveryAction(
                id: 'platform.shell.open-settings',
                label: 'Review Shell settings',
                managerKey: 'shell',
                message: 'Select a shell.',
                metadata: <String, Object?>{'settingsSectionId': 'shell'},
              ),
            ],
          ),
        ],
        probeSource: 'platform-live-operation-registry',
      );

      final surface = PlatformManagerSettingsSurface.fromHealthSnapshot(
        health,
        activeSectionId: 'shell',
      );

      expect(surface.readyCount, 1);
      expect(surface.blockedCount, 1);
      expect(surface.activeSection?.id, 'shell');
      expect(surface.activeSection?.title, 'Shell');
      expect(
        surface.activeSection?.recoveryRoutes.single.route,
        'settings://platform/shell?action=platform.shell.open-settings',
      );
      expect(surface.toJson()['activeSectionId'], 'shell');
    },
  );
}
