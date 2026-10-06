import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/module_host/module_host.dart';

void main() {
  group('extension manifest validation', () {
    test('valid manifest uses the production contract', () {
      const manifest = ExtensionManifest(
        extensionId: 'styio.example-tool',
        displayName: 'Example Tool',
        version: '1.0.0',
        publisher: 'vityo',
        entrypoint: 'example-tool',
        activationEvents: <String>['onStartup'],
        contributions: <ExtensionContributionPoint>[
          ExtensionContributionPoint(
            kind: ExtensionContributionKind.command,
            id: 'example.hello',
            target: 'command.palette',
            title: 'Hello',
          ),
        ],
      );

      expect(manifest.valid, isTrue);
      expect(manifest.activatesOn('onStartup'), isTrue);
      expect(
        manifest.contributionsFor(ExtensionContributionKind.command),
        hasLength(1),
      );
    });

    test('required identity fields and contribution targets are enforced', () {
      const missingIdentity = ExtensionManifest(
        extensionId: '',
        displayName: 'Invalid',
        version: '',
        publisher: '',
        entrypoint: '',
      );
      const missingContributionTarget = ExtensionManifest(
        extensionId: 'styio.invalid-contribution',
        displayName: 'Invalid Contribution',
        version: '1.0.0',
        publisher: 'vityo',
        entrypoint: 'invalid',
        contributions: <ExtensionContributionPoint>[
          ExtensionContributionPoint(
            kind: ExtensionContributionKind.view,
            id: 'missing-target',
            target: '',
          ),
        ],
      );

      expect(missingIdentity.valid, isFalse);
      expect(missingContributionTarget.valid, isFalse);
      expect(
        () => ExtensionManifestRegistry(<ExtensionManifest>[missingIdentity]),
        throwsStateError,
      );
    });
  });

  group('extension manifest forward compatibility', () {
    test('unknown manifest and contribution fields survive a round trip', () {
      final manifest = ExtensionManifest.fromJson(<String, Object?>{
        'schemaVersion': 2,
        'extensionId': 'styio.future-tool',
        'displayName': 'Future Tool',
        'version': '2.0.0',
        'publisher': 'vityo',
        'entrypoint': 'future-tool',
        'activationEvents': <String>['onLanguage:styio'],
        'contributions': <Map<String, Object?>>[
          <String, Object?>{
            'schemaVersion': 2,
            'kind': 'language',
            'id': 'styio.future-language',
            'target': 'language.registry',
            'futureContributionField': <String, Object?>{'enabled': true},
          },
        ],
        'futureManifestField': <String, Object?>{'channel': 'preview'},
      });

      final restored = ExtensionManifest.fromJson(manifest.toJson());

      expect(restored.valid, isTrue);
      expect(restored.schemaVersion, 2);
      expect(restored.extensions['futureManifestField'], <String, Object?>{
        'channel': 'preview',
      });
      expect(
        restored.contributions.single.extensions['futureContributionField'],
        <String, Object?>{'enabled': true},
      );
    });
  });

  group('extension contribution kinds', () {
    test('every production contribution kind round-trips by wire value', () {
      for (final kind in ExtensionContributionKind.values) {
        final contribution =
            ExtensionContributionPoint.fromJson(<String, Object?>{
              'kind': kind.wireValue,
              'id': 'fixture.${kind.wireValue}',
              'target': '${kind.wireValue}.registry',
            });

        expect(contribution.valid, isTrue);
        expect(contribution.kind, kind);
        expect(contribution.toJson()['kind'], kind.wireValue);
      }
    });
  });

  group('extension host isolation values', () {
    test('production isolation modes map to explicit execution plans', () {
      const expectedModes = <String, ExtensionHostIsolationMode>{
        'in-process': ExtensionHostIsolationMode.inProcess,
        'local-process': ExtensionHostIsolationMode.localProcess,
        'web-worker': ExtensionHostIsolationMode.webWorker,
        'remote-service': ExtensionHostIsolationMode.remoteService,
        'blocked': ExtensionHostIsolationMode.blocked,
      };

      for (final entry in expectedModes.entries) {
        final plan = const ExtensionHostIsolationPolicy().planFor(
          _manifest(isolationMode: entry.key),
        );
        expect(plan.mode, entry.value, reason: entry.key);
        expect(
          plan.executable,
          entry.value != ExtensionHostIsolationMode.blocked,
          reason: entry.key,
        );
      }
    });

    test('unknown isolation modes are blocked instead of downgraded', () {
      final plan = const ExtensionHostIsolationPolicy().planFor(
        _manifest(isolationMode: 'unrestricted'),
      );

      expect(plan.mode, ExtensionHostIsolationMode.blocked);
      expect(plan.executable, isFalse);
    });
  });

  group('extension activation events', () {
    test('event matching remains exact and supports wildcard activation', () {
      const exact = ExtensionManifest(
        extensionId: 'styio.language',
        displayName: 'Styio Language',
        version: '1.0.0',
        publisher: 'vityo',
        entrypoint: 'styio-language',
        activationEvents: <String>['onLanguage:styio'],
        trustedByDefault: true,
      );
      const wildcard = ExtensionManifest(
        extensionId: 'styio.always',
        displayName: 'Always Active',
        version: '1.0.0',
        publisher: 'vityo',
        entrypoint: 'always-active',
        activationEvents: <String>['*'],
        trustedByDefault: true,
      );
      final registry = ExtensionManifestRegistry(<ExtensionManifest>[
        exact,
        wildcard,
      ]);

      final session = const ExtensionActivator().activate(
        registry: registry,
        event: 'onLanguage:styio',
      );

      expect(session.activatedExtensionIds, <String>[
        'styio.always',
        'styio.language',
      ]);
    });
  });

  test('extension registry rejects duplicate extension IDs', () {
    final registry = ExtensionManifestRegistry(<ExtensionManifest>[
      _manifest(isolationMode: 'local-process'),
    ]);

    expect(
      () => registry.register(_manifest(isolationMode: 'web-worker')),
      throwsStateError,
    );
  });
}

ExtensionManifest _manifest({required String isolationMode}) {
  return ExtensionManifest(
    extensionId: 'styio.isolation-fixture',
    displayName: 'Isolation Fixture',
    version: '1.0.0',
    publisher: 'vityo',
    entrypoint: 'fixture-host',
    trustedByDefault: true,
    metadata: <String, Object?>{'isolationMode': isolationMode},
  );
}
