import 'package:vityo_app/src/view_ide/environment/configuration/configuration.dart';

final class TestSecureCredentialKeyValueBackend
    implements SecureCredentialKeyValueBackend {
  TestSecureCredentialKeyValueBackend({this.failOperations = false});

  final bool failOperations;
  final Map<String, String> values = <String, String>{};

  void _checkAvailable() {
    if (failOperations) {
      throw StateError('secure credential backend unavailable');
    }
  }

  @override
  Future<void> write({required String key, required String value}) async {
    _checkAvailable();
    values[key] = value;
  }

  @override
  Future<String?> read({required String key}) async {
    _checkAvailable();
    return values[key];
  }

  @override
  Future<bool> containsKey({required String key}) async {
    _checkAvailable();
    return values.containsKey(key);
  }

  @override
  Future<void> delete({required String key}) async {
    _checkAvailable();
    values.remove(key);
  }
}
