import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/environment/configuration/configuration.dart';
import 'package:vityo_app/src/view_ide/platform/platform_target.dart';

import 'support/test_secure_credential_backend.dart';

void main() {
  const key = CredentialDataStoreKey(
    namespace: 'registry',
    name: 'nightly',
    scope: CredentialScope.toolchain,
    targetId: 'workspace',
  );

  test(
    'secure adapter round-trips records without exposing secret snapshots',
    () async {
      final backend = TestSecureCredentialKeyValueBackend();
      final first = _adapter(backend);
      await first.write(
        CredentialSecretRecord(
          key: key,
          kind: CredentialKind.token,
          secretValue: 'secure-value-for-test',
          displayName: 'Nightly token',
        ),
      );

      final storageKey = first.storageKeyFor(key);
      final second = _adapter(backend);
      final loaded = await second.read(key);
      final snapshot = await PlatformSecureCredentialDataStore(
        adapter: second,
      ).snapshot();

      expect(storageKey, isNot(contains(key.stableId)));
      expect(storageKey, matches(RegExp(r'^[A-Za-z0-9_\-]+$')));
      expect(loaded?.secretValue, 'secure-value-for-test');
      expect(snapshot.credentials.single.redactedValue, 'se****st');
      expect(
        snapshot.toJson().toString(),
        isNot(contains('secure-value-for-test')),
      );
      expect(await second.delete(key), isTrue);
      expect(await second.delete(key), isFalse);
    },
  );

  test('secure adapter ignores malformed and foreign-version values', () async {
    final backend = TestSecureCredentialKeyValueBackend();
    final adapter = _adapter(backend);
    backend.values[adapter.storageKeyFor(key)] = '{not-json';
    backend.values['vityo_credentials_v1_foreign'] =
        '{"schemaVersion":2,"record":{}}';
    backend.values[PlatformSecureJsonCredentialStorageAdapter.indexStorageKey] =
        jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'keys': <String>[
            adapter.storageKeyFor(key),
            'vityo_credentials_v1_foreign',
          ],
        });
    backend.values['unrelated'] = 'leave-me-alone';

    expect(await adapter.read(key), isNull);
    expect(await adapter.list(), isEmpty);
    expect(backend.values['unrelated'], 'leave-me-alone');
  });

  test('secure adapter serializes concurrent index mutations', () async {
    final backend = TestSecureCredentialKeyValueBackend();
    final adapter = _adapter(backend);
    final keys = List<CredentialDataStoreKey>.generate(
      24,
      (index) => CredentialDataStoreKey(
        namespace: 'concurrent',
        name: 'credential-$index',
        scope: CredentialScope.workspace,
      ),
    );

    await Future.wait(
      keys.map(
        (key) => adapter.write(
          CredentialSecretRecord(
            key: key,
            kind: CredentialKind.genericSecret,
            secretValue: 'value-${key.name}',
          ),
        ),
      ),
    );
    final listed = await adapter.list(scope: CredentialScope.workspace);

    expect(listed, hasLength(keys.length));
    expect(
      listed.map((record) => record.key.stableId),
      orderedEquals(
        keys.map((key) => key.stableId).toList(growable: false)..sort(),
      ),
    );
  });

  test(
    'desktop and mobile targets select a verified production backend',
    () async {
      for (final target in <PlatformTarget>[
        PlatformTarget.macos,
        PlatformTarget.ios,
        PlatformTarget.android,
        PlatformTarget.windows,
        PlatformTarget.linux,
      ]) {
        final backend = TestSecureCredentialKeyValueBackend();
        final bootstrap = await createPlatformCredentialDataStoreBootstrap(
          platformTarget: target,
          backend: backend,
        );

        expect(bootstrap.usingProductionBackend, isTrue, reason: target.name);
        expect(bootstrap.backendHealth.productionReady, isTrue);
        expect(bootstrap.activeHealth.safeForLongLivedSecrets, isTrue);
        expect(bootstrap.registry.registrations, hasLength(1));
        expect(backend.values, isEmpty, reason: 'health probe must clean up');
      }
    },
  );

  test(
    'web and unavailable native storage use policy-enforced session memory',
    () async {
      final web = await createPlatformCredentialDataStoreBootstrap(
        platformTarget: PlatformTarget.web,
        backend: TestSecureCredentialKeyValueBackend(),
      );
      final unavailable = await createPlatformCredentialDataStoreBootstrap(
        platformTarget: PlatformTarget.macos,
        backend: TestSecureCredentialKeyValueBackend(failOperations: true),
      );
      final longLived = CredentialSecretRecord(
        key: key,
        kind: CredentialKind.token,
        secretValue: 'long-lived-test-value',
      );

      expect(web.usingProductionBackend, isFalse);
      expect(
        web.selection.status,
        PlatformSecureCredentialStorageSelectionStatus.missingProductionBackend,
      );
      expect(unavailable.usingProductionBackend, isFalse);
      expect(
        unavailable.selection.status,
        PlatformSecureCredentialStorageSelectionStatus.missingBackend,
      );
      await expectLater(web.dataStore.write(longLived), throwsStateError);
      await expectLater(
        unavailable.dataStore.write(longLived),
        throwsStateError,
      );

      final shortLived = CredentialSecretRecord(
        key: key,
        kind: CredentialKind.token,
        secretValue: 'short-lived-test-value',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      );
      await unavailable.dataStore.write(shortLived);
      expect(
        (await unavailable.dataStore.read(key))?.secretValue,
        'short-lived-test-value',
      );
    },
  );

  test('backend and protection kinds expose stable wire values', () {
    expect(
      PlatformSecureCredentialBackendKind.values.map((kind) => kind.wireValue),
      containsAll(<String>[
        'macos-keychain',
        'ios-keychain',
        'android-encrypted-storage',
        'windows-credential-manager',
        'linux-libsecret',
        'web-crypto',
      ]),
    );
    expect(
      CredentialStorageProtection.values.map((value) => value.wireValue),
      isNot(contains('foundation-data-store')),
    );
  });
}

PlatformSecureJsonCredentialStorageAdapter _adapter(
  SecureCredentialKeyValueBackend backend,
) {
  return PlatformSecureJsonCredentialStorageAdapter(
    adapterId: 'test-keychain',
    backendId: 'test-keychain',
    backend: backend,
    productionSupported: true,
    platformLabel: 'Test Keychain',
  );
}
