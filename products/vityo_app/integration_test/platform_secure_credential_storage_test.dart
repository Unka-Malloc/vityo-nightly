import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vityo_app/src/view_ide/environment/configuration/configuration.dart';
import 'package:vityo_app/src/view_ide/platform/platform_target.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS Keychain performs an isolated credential round-trip', (
    tester,
  ) async {
    final bootstrap = await createPlatformCredentialDataStoreBootstrap(
      platformTarget: PlatformTarget.macos,
    );
    expect(bootstrap.usingProductionBackend, isTrue);
    expect(bootstrap.backendHealth.productionReady, isTrue);

    final nonce = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final key = CredentialDataStoreKey(
      namespace: 'native-verification',
      name: 'keychain-round-trip-$nonce',
      scope: CredentialScope.user,
    );
    final record = CredentialSecretRecord(
      key: key,
      kind: CredentialKind.genericSecret,
      secretValue: 'isolated-native-verification-$nonce',
    );

    try {
      await bootstrap.dataStore.write(record);
      final loaded = await bootstrap.dataStore.read(key);
      expect(loaded?.secretValue, record.secretValue);
      expect(
        (await bootstrap.dataStore.snapshot()).toJson().toString(),
        isNot(contains(record.secretValue)),
      );
    } finally {
      await bootstrap.dataStore.delete(key);
    }
    expect(await bootstrap.dataStore.read(key), isNull);
  });
}
