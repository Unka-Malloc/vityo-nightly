import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/environment/configuration/platform_secure_credential_storage.dart';
import 'package:vityo_app/src/view_ide/flow_hero/model_config.dart';

import 'support/test_file_system_manager.dart';

/// Records every keychain operation without touching the real keychain.
class _FakeSecretBackend implements SecureCredentialKeyValueBackend {
  final Map<String, String> values = <String, String>{};
  int deletes = 0;

  @override
  Future<bool> containsKey({required String key}) async =>
      values.containsKey(key);

  @override
  Future<void> delete({required String key}) async {
    deletes++;
    values.remove(key);
  }

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }
}

FlowHeroModelConfig _valid({
  String endpoint = 'https://api.example.com/v1',
  String model = 'model-name',
  int contextTokens = 128000,
  int maxConcurrency = 2,
  FlowHeroModelAuthMode authMode = FlowHeroModelAuthMode.bearerToken,
  FlowHeroModelProvider provider = FlowHeroModelProvider.custom,
}) => FlowHeroModelConfig(
  endpointBase: endpoint,
  model: model,
  contextTokens: contextTokens,
  maxConcurrency: maxConcurrency,
  authMode: authMode,
  provider: provider,
);

void main() {
  group('validation mirrors the Rust provider config rules', () {
    test('a well-formed configuration has no field errors', () {
      expect(_valid().validate(), isEmpty);
    });

    test('the adapter is fixed to the only value the runtime accepts', () {
      expect(kFlowHeroProviderAdapter, 'openai_compatible_chat');
      expect(
        _valid().toProviderConfigJson()['adapter'],
        'openai_compatible_chat',
      );
    });

    test('the endpoint must be an absolute https URL', () {
      expect(
        _valid(endpoint: 'http://api.example.com').validate()['endpointBase'],
        '服务端点必须是 https:// 地址',
      );
      expect(
        _valid(endpoint: 'api.example.com').validate()['endpointBase'],
        '服务端点必须是 https:// 地址',
      );
      expect(_valid(endpoint: '').validate()['endpointBase'], '服务端点不能为空');
      expect(_valid(endpoint: '   ').validate()['endpointBase'], '服务端点不能为空');
      expect(_valid(endpoint: 'https://').validate(), isNotEmpty);
      expect(
        _valid(endpoint: 'https:///v1').validate()['endpointBase'],
        '服务端点缺少主机名',
      );
    });

    test(
      'user-info, query, and fragment are rejected like the Rust URL check',
      () {
        expect(
          _valid(
            endpoint: 'https://user@api.example.com',
          ).validate()['endpointBase'],
          '服务端点不能包含用户名或密码',
        );
        expect(
          _valid(
            endpoint: 'https://user:secret@api.example.com',
          ).validate()['endpointBase'],
          '服务端点不能包含用户名或密码',
        );
        expect(
          _valid(
            endpoint: 'https://api.example.com/v1?key=1',
          ).validate()['endpointBase'],
          '服务端点不能包含查询参数',
        );
        expect(
          _valid(
            endpoint: 'https://api.example.com/v1#frag',
          ).validate()['endpointBase'],
          '服务端点不能包含片段',
        );
      },
    );

    test('the model name must not be blank', () {
      expect(_valid(model: '').validate()['model'], '模型名不能为空');
      expect(_valid(model: '   ').validate()['model'], '模型名不能为空');
      expect(_valid(model: ' deepseek-flash ').validate(), isEmpty);
    });

    test('the context and concurrency bounds are enforced', () {
      expect(_valid(contextTokens: 0).validate()['contextTokens'], isNotNull);
      expect(_valid(contextTokens: -1).validate()['contextTokens'], isNotNull);
      expect(_valid(maxConcurrency: 0).validate()['maxConcurrency'], isNotNull);
      expect(_valid(contextTokens: 1).validate(), isEmpty);
    });

    test('output and session bounds are no longer part of the rules', () {
      // Both bounds left the shape, so there is no rule left for them to
      // report — and no stored value left to conflict with the context one.
      final Map<String, String> errors = _valid().validate();
      expect(errors.containsKey('outputTokens'), isFalse);
      expect(errors.containsKey('maxTotalTokens'), isFalse);
      expect(_valid(contextTokens: 64000).validate(), isEmpty);
    });

    test('a bearer route needs a resolvable key; auth none never does', () {
      expect(
        _valid().validateForSave(hasStoredApiKey: false)['apiKey'],
        '需要填写 API 密钥',
      );
      expect(_valid().validateForSave(hasStoredApiKey: true), isEmpty);
      expect(
        _valid(
          authMode: FlowHeroModelAuthMode.none,
        ).validateForSave(hasStoredApiKey: false),
        isEmpty,
      );
      expect(_valid().validate(), isEmpty, reason: 'the key is not structural');
    });
  });

  group('provider selection', () {
    test(
      'DeepSeek carries the endpoint, models, and context the panel fills',
      () {
        expect(kFlowHeroDeepSeekEndpointBase, 'https://api.deepseek.com/v1');
        expect(kFlowHeroDeepSeekContextTokens, 1000000);
        expect(FlowHeroModelProvider.deepSeek.modelCandidates, <String>[
          'deepseek-flash',
          'deepseek-v4-pro',
        ]);
        expect(FlowHeroModelProvider.deepSeek.defaultModel, 'deepseek-flash');
        expect(
          FlowHeroModelProvider.deepSeek.offersModel('deepseek-flash'),
          isTrue,
        );
        expect(
          FlowHeroModelProvider.deepSeek.offersModel('deepseek-v4-pro'),
          isTrue,
        );
        expect(
          FlowHeroModelProvider.deepSeek.offersModel('deepseek-chat'),
          isFalse,
          reason: 'the retired V3 id is outside the list',
        );
        expect(
          FlowHeroModelProvider.deepSeek.offersModel('deepseek-reasoner'),
          isFalse,
        );
        expect(FlowHeroModelProvider.custom.modelCandidates, isEmpty);
        expect(FlowHeroModelProvider.custom.defaultModel, isEmpty);
        expect(FlowHeroModelProvider.custom.offersModel('anything'), isTrue);
        expect(FlowHeroModelProvider.deepSeek.label, 'DeepSeek');
        expect(FlowHeroModelProvider.custom.label, '自定义');
      },
    );

    test(
      'a stored model outside a provider list falls back to its default',
      () {
        final FlowHeroModelConfig deepSeek =
            FlowHeroModelConfig.fromJson(<String, dynamic>{
              'endpointBase': 'https://api.deepseek.com/v1',
              'model': 'deepseek-reasoner',
              'contextTokens': 1000000,
              'supportsTools': true,
              'maxConcurrency': 2,
              'authMode': 'bearer_token',
              'provider': 'deepseek',
            })!;
        expect(deepSeek.provider, FlowHeroModelProvider.deepSeek);
        expect(deepSeek.model, 'deepseek-flash');

        // A custom route keeps its freely typed name.
        final FlowHeroModelConfig custom =
            FlowHeroModelConfig.fromJson(<String, dynamic>{
              'endpointBase': 'https://api.example.com/v1',
              'model': 'my-own-model',
              'contextTokens': 128000,
              'supportsTools': true,
              'maxConcurrency': 2,
              'authMode': 'bearer_token',
            })!;
        expect(custom.provider, FlowHeroModelProvider.custom);
        expect(custom.model, 'my-own-model');
      },
    );

    test('the wire value round-trips and defaults to custom', () {
      for (final FlowHeroModelProvider provider
          in FlowHeroModelProvider.values) {
        expect(
          FlowHeroModelProvider.fromWireValue(provider.wireValue),
          provider,
        );
      }
      expect(
        FlowHeroModelProvider.fromWireValue(null),
        FlowHeroModelProvider.custom,
      );
      expect(
        FlowHeroModelProvider.fromWireValue('future-vendor'),
        FlowHeroModelProvider.custom,
      );
    });

    test('the choice survives copyWith and the non-secret document', () {
      expect(
        _valid().copyWith(provider: FlowHeroModelProvider.deepSeek).provider,
        FlowHeroModelProvider.deepSeek,
      );
      expect(
        _valid(provider: FlowHeroModelProvider.deepSeek).toJson()['provider'],
        'deepseek',
      );
      expect(_valid().toJson()['provider'], 'custom');
    });
  });

  group('provider.json materialization', () {
    test('a bearer route writes exactly the schema the runtime reads', () {
      final Map<String, Object?> json = _valid().toProviderConfigJson();
      expect(json.keys.toSet(), <String>{
        'adapter',
        'endpointBase',
        'model',
        'capabilities',
        'limits',
        'auth',
      });
      final Map<String, Object?> capabilities =
          json['capabilities']! as Map<String, Object?>;
      expect(capabilities.keys.toSet(), <String>{
        'contextTokens',
        'supportsTools',
        'maxConcurrency',
      });
      expect(
        capabilities['contextTokens'],
        128000,
        reason: 'the context window is the one bound the panel configures',
      );
      final Map<String, Object?> limits =
          json['limits']! as Map<String, Object?>;
      expect(
        limits,
        isEmpty,
        reason:
            'every limits field has a serde default; a missing total '
            'means the runtime applies no session cap',
      );
      final Map<String, Object?> auth = json['auth']! as Map<String, Object?>;
      expect(auth.keys.toSet(), <String>{'mode', 'secretRef'});
      expect(auth['mode'], 'bearer_token');
      final Map<String, Object?> secretRef =
          auth['secretRef']! as Map<String, Object?>;
      expect(secretRef, <String, Object?>{
        'service': kFlowHeroAgentProviderService,
        'account': kFlowHeroAgentProviderAccount,
      });
    });

    test('auth none omits the secret reference entirely', () {
      final Map<String, Object?> json = _valid(
        authMode: FlowHeroModelAuthMode.none,
      ).toProviderConfigJson();
      expect(json['auth'], <String, Object?>{'mode': 'none'});
      expect(jsonEncode(json), isNot(contains('secretRef')));
    });

    test('the two unbounded limits are omitted, not defaulted', () {
      final Map<String, Object?> json = _valid().toProviderConfigJson();
      final Map<String, Object?> capabilities =
          json['capabilities']! as Map<String, Object?>;
      expect(capabilities.containsKey('outputTokens'), isFalse);
      final Map<String, Object?> limits =
          json['limits']! as Map<String, Object?>;
      expect(limits.containsKey('maxTotalTokens'), isFalse);
      final String body = jsonEncode(json);
      expect(body, isNot(contains('outputTokens')));
      expect(body, isNot(contains('maxTotalTokens')));
    });

    test('the provider choice stays out of the launch contract', () {
      final Map<String, Object?> json = _valid(
        provider: FlowHeroModelProvider.deepSeek,
      ).toProviderConfigJson();
      expect(json.keys.toSet(), <String>{
        'adapter',
        'endpointBase',
        'model',
        'capabilities',
        'limits',
        'auth',
      });
      expect(
        jsonEncode(json),
        isNot(contains('deepseek')),
        reason: 'the selector only feeds the panel defaults',
      );
    });

    test(
      'the writer writes that document to the launch-contract path',
      () async {
        final Directory root = Directory.systemTemp.createTempSync(
          'flow_hero_provider_',
        );
        addTearDown(() {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });
        final TestFileSystemManager fileSystem =
            TestFileSystemManager.linuxDebianArm();
        final String path = fileSystem.joinPath(<String>[
          root.path,
          'vityo-coding-agent',
          'provider.json',
        ]);
        final writer = FlowHeroFileProviderConfigWriter(
          fileSystem: fileSystem,
          path: path,
        );

        expect(await writer.exists(), isFalse);
        await writer.write(_valid());
        expect(await writer.exists(), isTrue);
        final String body = await fileSystem.readText(path);
        final Map<String, Object?> decoded =
            jsonDecode(body) as Map<String, Object?>;
        expect(decoded, _valid().toProviderConfigJson());
        expect(decoded.length, 6, reason: 'no unknown fields are written');
        expect(body, isNot(contains('outputTokens')));
        expect(body, isNot(contains('maxTotalTokens')));
      },
    );

    test('the writer refuses a configuration that failed validation', () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'flow_hero_provider_',
      );
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final TestFileSystemManager fileSystem =
          TestFileSystemManager.linuxDebianArm();
      final writer = FlowHeroFileProviderConfigWriter(
        fileSystem: fileSystem,
        path: fileSystem.joinPath(<String>[root.path, 'provider.json']),
      );
      await expectLater(
        writer.write(_valid(endpoint: 'http://insecure.example.com')),
        throwsArgumentError,
      );
      expect(await writer.exists(), isFalse);
    });
  });

  group('non-secret store', () {
    test('the file store round-trips every field', () async {
      final Directory home = Directory.systemTemp.createTempSync(
        'flow_hero_model_',
      );
      addTearDown(() {
        if (home.existsSync()) home.deleteSync(recursive: true);
      });
      final TestFileSystemManager fileSystem =
          TestFileSystemManager.linuxDebianArm();
      final String path = fileSystem.joinPath(<String>[
        home.path,
        ...kFlowHeroModelConfigStorePathSegments,
      ]);
      final store = FlowHeroFileModelConfigStore(
        fileSystem: fileSystem,
        path: path,
      );

      expect(store.persistent, isTrue);
      expect(await store.load(), isNull);

      const FlowHeroModelConfig config = FlowHeroModelConfig(
        endpointBase: 'https://api.example.com/v1',
        model: 'deepseek-v4-pro',
        contextTokens: 64000,
        supportsTools: false,
        maxConcurrency: 3,
        authMode: FlowHeroModelAuthMode.none,
        provider: FlowHeroModelProvider.deepSeek,
      );
      await store.save(config);
      final FlowHeroModelConfig? loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.endpointBase, config.endpointBase);
      expect(loaded.model, config.model);
      expect(loaded.contextTokens, config.contextTokens);
      expect(loaded.supportsTools, isFalse);
      expect(loaded.maxConcurrency, 3);
      expect(loaded.authMode, FlowHeroModelAuthMode.none);
      expect(loaded.provider, FlowHeroModelProvider.deepSeek);
      final String stored = await fileSystem.readText(path);
      expect(
        stored,
        isNot(contains('apiKey')),
        reason: 'the non-secret store never carries a credential',
      );
      expect(
        stored,
        isNot(contains('outputTokens')),
        reason: 'the removed bounds are not written back either',
      );
      expect(
        stored,
        isNot(contains('maxTotalTokens')),
        reason: 'the removed bounds are not written back either',
      );
    });

    test(
      'a configuration written before the selector existed still opens',
      () async {
        // The shape this version wrote: no `provider`, both bounds present.
        const String legacy =
            '{"schemaVersion": 1, "config": {"endpointBase":'
            ' "https://api.example.com/v1", "model": "model-name",'
            ' "contextTokens": 64000, "outputTokens": 4096,'
            ' "maxTotalTokens": 100000, "supportsTools": true,'
            ' "maxConcurrency": 2, "authMode": "bearer_token"}}';
        final TestFileSystemManager fileSystem =
            TestFileSystemManager.linuxDebianArm();
        final Directory home = Directory.systemTemp.createTempSync(
          'flow_hero_model_',
        );
        addTearDown(() {
          if (home.existsSync()) home.deleteSync(recursive: true);
        });
        final String path = fileSystem.joinPath(<String>[
          home.path,
          ...kFlowHeroModelConfigStorePathSegments,
        ]);
        await fileSystem.writeText(path, legacy);

        final FlowHeroModelConfig? loaded = await FlowHeroFileModelConfigStore(
          fileSystem: fileSystem,
          path: path,
        ).load();
        expect(loaded, isNotNull, reason: 'the old shape is not rejected');
        expect(loaded!.contextTokens, 64000);
        expect(loaded.provider, FlowHeroModelProvider.custom);
        expect(
          loaded.toProviderConfigJson().toString(),
          isNot(contains('4096')),
          reason: 'the stored output bound is dropped, not carried forward',
        );
      },
    );

    test('an unknown provider reads as custom instead of failing', () async {
      const String future =
          '{"schemaVersion": 1, "config": {"endpointBase":'
          ' "https://api.example.com/v1", "model": "model-name",'
          ' "contextTokens": 128000, "supportsTools": true,'
          ' "maxConcurrency": 2, "authMode": "bearer_token",'
          ' "provider": "future-vendor"}}';
      final TestFileSystemManager fileSystem =
          TestFileSystemManager.linuxDebianArm();
      final Directory home = Directory.systemTemp.createTempSync(
        'flow_hero_model_',
      );
      addTearDown(() {
        if (home.existsSync()) home.deleteSync(recursive: true);
      });
      final String path = fileSystem.joinPath(<String>[
        home.path,
        ...kFlowHeroModelConfigStorePathSegments,
      ]);
      await fileSystem.writeText(path, future);

      final FlowHeroModelConfig? loaded = await FlowHeroFileModelConfigStore(
        fileSystem: fileSystem,
        path: path,
      ).load();
      expect(loaded, isNotNull);
      expect(loaded!.provider, FlowHeroModelProvider.custom);
      expect(
        FlowHeroModelProvider.fromWireValue(null),
        FlowHeroModelProvider.custom,
      );
    });

    test('a corrupted or foreign file reads as unconfigured', () async {
      final Directory home = Directory.systemTemp.createTempSync(
        'flow_hero_model_',
      );
      addTearDown(() {
        if (home.existsSync()) home.deleteSync(recursive: true);
      });
      final TestFileSystemManager fileSystem =
          TestFileSystemManager.linuxDebianArm();
      final String path = fileSystem.joinPath(<String>[
        home.path,
        ...kFlowHeroModelConfigStorePathSegments,
      ]);
      final store = FlowHeroFileModelConfigStore(
        fileSystem: fileSystem,
        path: path,
      );

      for (final String body in <String>[
        'not json at all',
        '{"schemaVersion": 99, "config": {}}',
        '{"schemaVersion": 1}',
        '{"schemaVersion": 1, "config": {"endpointBase": 1}}',
        '{"schemaVersion": 1, "config": {"endpointBase": "https://a",'
            ' "model": "m", "contextTokens": 1, "outputTokens": 1,'
            ' "maxTotalTokens": 1, "supportsTools": true,'
            ' "maxConcurrency": 1, "authMode": "unsupported"}}',
      ]) {
        await fileSystem.writeText(path, body);
        expect(await store.load(), isNull, reason: body);
      }
    });

    test('the memory store is honest about being session-scoped', () async {
      final store = FlowHeroMemoryModelConfigStore();
      expect(store.persistent, isFalse);
      expect(await store.load(), isNull);
      await store.save(_valid());
      expect((await store.load())!.model, 'model-name');
    });

    test('boot never throws and returns a store', () async {
      expect(await FlowHeroModelConfigStoreBoot.boot(), isNotNull);
    });
  });

  group('secret store is write-only and never leaks into config', () {
    test(
      'save, probe, and delete use the fixed service/account pair',
      () async {
        final backend = _FakeSecretBackend();
        final store = FlowHeroKeychainAgentSecretStore(backend: backend);

        expect(await store.hasKey(), isFalse);
        await store.saveKey('  sk-secret-value  ');
        expect(await store.hasKey(), isTrue);
        expect(
          backend.values,
          <String, String>{kFlowHeroAgentProviderAccount: 'sk-secret-value'},
          reason:
              'the token is trimmed and stored under the account the '
              'runtime resolves',
        );
        expect(kFlowHeroAgentProviderService, 'land.vityo.flow-hero.agent');

        await store.deleteKey();
        expect(await store.hasKey(), isFalse);
        expect(backend.values, isEmpty);
      },
    );

    test('an empty key is refused instead of stored', () async {
      final store = FlowHeroKeychainAgentSecretStore(
        backend: _FakeSecretBackend(),
      );
      await expectLater(store.saveKey('   '), throwsArgumentError);
    });

    test(
      'a deleted key never resurfaces through the config documents',
      () async {
        final Directory root = Directory.systemTemp.createTempSync(
          'flow_hero_secret_',
        );
        addTearDown(() {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });
        final TestFileSystemManager fileSystem =
            TestFileSystemManager.linuxDebianArm();
        final flowHeroDir = fileSystem.joinPath(<String>[root.path, '.vityo']);
        final String storePath = fileSystem.joinPath(<String>[
          root.path,
          ...kFlowHeroModelConfigStorePathSegments,
        ]);
        final String providerPath = fileSystem.joinPath(<String>[
          flowHeroDir,
          'provider.json',
        ]);
        final backend = _FakeSecretBackend();
        final secrets = FlowHeroKeychainAgentSecretStore(backend: backend);
        final config = _valid();

        await secrets.saveKey('sk-never-persisted');
        await FlowHeroFileModelConfigStore(
          fileSystem: fileSystem,
          path: storePath,
        ).save(config);
        await FlowHeroFileProviderConfigWriter(
          fileSystem: fileSystem,
          path: providerPath,
        ).write(config);

        for (final String path in <String>[storePath, providerPath]) {
          expect(
            await fileSystem.readText(path),
            isNot(contains('sk-never-persisted')),
            reason: 'the credential belongs to the keychain alone',
          );
        }
      },
    );
  });

  group('save result', () {
    test('states outcomes without overstating them', () {
      final saved = FlowHeroModelConfigSaveResult.saved();
      expect(saved.saved, isTrue);
      expect(saved.fieldErrors, isEmpty);
      expect(saved.failureMessage, isEmpty);

      final invalid = FlowHeroModelConfigSaveResult.invalid(<String, String>{
        'model': '模型名不能为空',
      });
      expect(invalid.saved, isFalse);
      expect(invalid.fieldErrors['model'], '模型名不能为空');

      final failed = FlowHeroModelConfigSaveResult.failed('保存失败');
      expect(failed.saved, isFalse);
      expect(failed.failureMessage, '保存失败');
    });
  });
}
