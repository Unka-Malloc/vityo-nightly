import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_render/flow_hero/flow_hero.dart';
import 'package:vityo_app/src/view_ide/flow_hero/model_config.dart';

class _FakeModelConfigStore implements FlowHeroModelConfigStore {
  _FakeModelConfigStore({this.config});

  FlowHeroModelConfig? config;
  int saves = 0;

  @override
  bool get persistent => true;

  @override
  Future<FlowHeroModelConfig?> load() async => config;

  @override
  Future<void> save(FlowHeroModelConfig value) async {
    config = value;
    saves++;
  }
}

class _FakeProviderConfigWriter implements FlowHeroProviderConfigWriter {
  FlowHeroModelConfig? written;
  bool present = false;
  int writes = 0;

  @override
  Future<bool> exists() async => present;

  @override
  Future<void> write(FlowHeroModelConfig value) async {
    written = value;
    present = true;
    writes++;
  }
}

class _FakeSecretStore implements FlowHeroAgentSecretStore {
  _FakeSecretStore({this.stored});

  String? stored;
  int saves = 0;
  int deletes = 0;

  @override
  Future<bool> hasKey() async => stored != null;

  @override
  Future<void> saveKey(String key) async {
    stored = key;
    saves++;
  }

  @override
  Future<void> deleteKey() async {
    stored = null;
    deletes++;
  }
}

const FlowHeroModelConfig _storedConfig = FlowHeroModelConfig(
  endpointBase: 'https://api.example.com/v1',
  model: 'model-name',
);

/// A DeepSeek route as an older build stored it: a retired V3 model ID.
const FlowHeroModelConfig _legacyDeepSeekConfig = FlowHeroModelConfig(
  endpointBase: 'https://api.deepseek.com/v1',
  model: 'deepseek-chat',
  contextTokens: 1000000,
  provider: FlowHeroModelProvider.deepSeek,
);

String _textOf(WidgetTester tester, String key) => tester
    .widget<TextField>(find.byKey(ValueKey<String>(key)))
    .controller!
    .text;

Finder _modelOption(String model) =>
    find.byKey(ValueKey<String>('flow-hero-model-name-option-$model'));

/// The label the model dropdown currently shows, found under its own key.
String _selectedModel(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('flow-hero-model-name')),
        matching: find.byType(Text),
      ),
    )
    .data!;

Future<void> _openSettings(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(1280, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  await tester.tap(find.byIcon(Icons.settings_outlined));
  await tester.pump();
}

Future<void> _tapSave(WidgetTester tester) async {
  await tester.ensureVisible(
    find.byKey(const ValueKey<String>('flow-hero-model-save')),
  );
  await tester.tap(find.byKey(const ValueKey<String>('flow-hero-model-save')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Opens the provider dropdown and commits one option, the way a user does.
Future<void> _selectProvider(WidgetTester tester, String id) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('flow-hero-model-provider')),
  );
  await tester.pump();
  await tester.tap(
    find.byKey(ValueKey<String>('flow-hero-model-provider-option-$id')),
  );
  await tester.pump();
}

/// Opens the DeepSeek model dropdown and commits one option.
Future<void> _selectModel(WidgetTester tester, String model) async {
  await tester.tap(find.byKey(const ValueKey<String>('flow-hero-model-name')));
  await tester.pump();
  await tester.tap(_modelOption(model));
  await tester.pump();
}

void main() {
  testWidgets('the model section renders the stored route and saves it', (
    WidgetTester tester,
  ) async {
    final store = _FakeModelConfigStore(config: _storedConfig);
    final writer = _FakeProviderConfigWriter();
    final secret = _FakeSecretStore();
    addTearDown(() {
      // The demo timers must not outlive the test.
    });

    await _openSettings(
      tester,
      FlowHeroApp(
        modelConfigStore: store,
        providerConfigWriter: writer,
        agentSecretStore: secret,
      ),
    );

    expect(find.text('模型配置'), findsOneWidget);
    expect(
      _textOf(tester, 'flow-hero-model-endpoint'),
      _storedConfig.endpointBase,
    );
    expect(_textOf(tester, 'flow-hero-model-name'), _storedConfig.model);
    expect(
      find.widgetWithText(TextField, '未设置'),
      findsOneWidget,
      reason: 'the key is unset; its value is never shown',
    );

    // An invalid endpoint is refused inline and nothing is written.
    await tester.enterText(
      find.byKey(const ValueKey<String>('flow-hero-model-endpoint')),
      'http://insecure.example.com',
    );
    await _tapSave(tester);
    expect(find.text('服务端点必须是 https:// 地址'), findsOneWidget);
    expect(writer.writes, 0);
    expect(store.saves, 0);

    // A valid route saves the config, the launch contract, and the key.
    await tester.enterText(
      find.byKey(const ValueKey<String>('flow-hero-model-endpoint')),
      'https://api.example.com/v1',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('flow-hero-model-api-key')),
      'sk-live-token',
    );
    await _tapSave(tester);

    expect(find.text('服务端点必须是 https:// 地址'), findsNothing);
    expect(store.saves, 1);
    expect(store.config!.model, 'model-name');
    expect(writer.writes, 1);
    expect(writer.written!.endpointBase, 'https://api.example.com/v1');
    expect(writer.written!.authMode, FlowHeroModelAuthMode.bearerToken);
    expect(secret.stored, 'sk-live-token');
    expect(find.text('已保存 · 未连接'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, '已保存 · 留空保持不变'),
      findsOneWidget,
      reason: 'the saved key is announced without being revealed',
    );

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a bearer route without any key cannot be saved', (
    WidgetTester tester,
  ) async {
    final store = _FakeModelConfigStore(config: _storedConfig);
    final writer = _FakeProviderConfigWriter();
    final secret = _FakeSecretStore();

    await _openSettings(
      tester,
      FlowHeroApp(
        modelConfigStore: store,
        providerConfigWriter: writer,
        agentSecretStore: secret,
      ),
    );
    await _tapSave(tester);

    expect(find.text('需要填写 API 密钥'), findsOneWidget);
    expect(writer.writes, 0);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('the advanced section keeps only the context window', (
    WidgetTester tester,
  ) async {
    final store = _FakeModelConfigStore(config: _storedConfig);
    final writer = _FakeProviderConfigWriter();
    final secret = _FakeSecretStore(stored: 'sk-existing');

    await _openSettings(
      tester,
      FlowHeroApp(
        modelConfigStore: store,
        providerConfigWriter: writer,
        agentSecretStore: secret,
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('flow-hero-model-context-tokens')),
      findsNothing,
      reason: 'the one remaining bound sits behind the advanced toggle',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('flow-hero-model-advanced-toggle')),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('flow-hero-model-context-tokens')),
      findsOneWidget,
    );
    expect(_textOf(tester, 'flow-hero-model-context-tokens'), '128000');
    expect(
      find.byKey(const ValueKey<String>('flow-hero-model-output-tokens')),
      findsNothing,
      reason: 'the output bound is gone, not just hidden',
    );
    expect(
      find.byKey(const ValueKey<String>('flow-hero-model-max-total-tokens')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('flow-hero-model-output-limit')),
      findsOneWidget,
    );
    expect(find.text('输出上限 · 无限（沿用服务商默认）'), findsOneWidget);
    expect(find.text('会话 token · 无上限'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('flow-hero-model-context-tokens')),
      '0',
    );
    await _tapSave(tester);
    expect(find.text('上下文窗口必须是大于 0 的整数'), findsOneWidget);
    expect(writer.writes, 0);

    await tester.enterText(
      find.byKey(const ValueKey<String>('flow-hero-model-context-tokens')),
      '64000',
    );
    await _tapSave(tester);
    expect(writer.writes, 1);
    expect(writer.written!.contextTokens, 64000);
    expect(
      writer.written!.toProviderConfigJson().toString(),
      isNot(contains('outputTokens')),
    );

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('choosing DeepSeek fills the route and offers its models', (
    WidgetTester tester,
  ) async {
    final store = _FakeModelConfigStore(config: _storedConfig);
    final writer = _FakeProviderConfigWriter();
    final secret = _FakeSecretStore(stored: 'sk-existing');

    await _openSettings(
      tester,
      FlowHeroApp(
        modelConfigStore: store,
        providerConfigWriter: writer,
        agentSecretStore: secret,
      ),
    );

    // 自定义 types its own model: free text, no option list behind it.
    expect(_textOf(tester, 'flow-hero-model-name'), 'model-name');
    expect(_modelOption('deepseek-flash'), findsNothing);

    await _selectProvider(tester, 'deepseek');

    expect(
      _textOf(tester, 'flow-hero-model-endpoint'),
      'https://api.deepseek.com/v1',
    );
    expect(_selectedModel(tester), 'deepseek-flash');
    await tester.tap(
      find.byKey(const ValueKey<String>('flow-hero-model-advanced-toggle')),
    );
    await tester.pump();
    expect(_textOf(tester, 'flow-hero-model-context-tokens'), '1000000');

    // The picker commits a different official id.
    await _selectModel(tester, 'deepseek-v4-pro');
    expect(_selectedModel(tester), 'deepseek-v4-pro');

    await _tapSave(tester);
    expect(writer.writes, 1);
    expect(store.config!.provider, FlowHeroModelProvider.deepSeek);
    expect(writer.written!.endpointBase, 'https://api.deepseek.com/v1');
    expect(writer.written!.model, 'deepseek-v4-pro');
    expect(writer.written!.contextTokens, 1000000);
    expect(writer.written!.authMode, FlowHeroModelAuthMode.bearerToken);

    // Back to 自定义: free text returns and keeps the last selection.
    await _selectProvider(tester, 'custom');
    expect(_modelOption('deepseek-flash'), findsNothing);
    expect(_textOf(tester, 'flow-hero-model-name'), 'deepseek-v4-pro');

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('the DeepSeek model dropdown lists exactly the official ids', (
    WidgetTester tester,
  ) async {
    final store = _FakeModelConfigStore(config: _legacyDeepSeekConfig);
    final writer = _FakeProviderConfigWriter();
    final secret = _FakeSecretStore(stored: 'sk-existing');

    await _openSettings(
      tester,
      FlowHeroApp(
        modelConfigStore: store,
        providerConfigWriter: writer,
        agentSecretStore: secret,
      ),
    );

    expect(
      _modelOption('deepseek-flash'),
      findsNothing,
      reason: 'the list is closed until tapped',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('flow-hero-model-name')),
    );
    await tester.pump();
    expect(_modelOption('deepseek-flash'), findsOneWidget);
    expect(_modelOption('deepseek-v4-pro'), findsOneWidget);
    expect(
      _modelOption('deepseek-chat'),
      findsNothing,
      reason: 'the retired V3 id is not offered any more',
    );
    expect(_modelOption('deepseek-reasoner'), findsNothing);

    // A tap outside dismisses without changing the selection.
    await tester.tapAt(const Offset(4, 4));
    await tester.pump();
    expect(_modelOption('deepseek-v4-pro'), findsNothing);
    expect(_selectedModel(tester), 'deepseek-flash');

    // Picking the other id commits it.
    await _selectModel(tester, 'deepseek-v4-pro');
    expect(_selectedModel(tester), 'deepseek-v4-pro');

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a stored DeepSeek route with a retired model falls back', (
    WidgetTester tester,
  ) async {
    final store = _FakeModelConfigStore(config: _legacyDeepSeekConfig);
    final writer = _FakeProviderConfigWriter();
    final secret = _FakeSecretStore(stored: 'sk-existing');

    await _openSettings(
      tester,
      FlowHeroApp(
        modelConfigStore: store,
        providerConfigWriter: writer,
        agentSecretStore: secret,
      ),
    );

    expect(
      _selectedModel(tester),
      'deepseek-flash',
      reason: 'a model outside the list is replaced by the provider default',
    );

    await _tapSave(tester);
    expect(store.config!.model, 'deepseek-flash');
    expect(writer.written!.model, 'deepseek-flash');

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'choosing DeepSeek replaces a name typed under another provider',
    (WidgetTester tester) async {
      final store = _FakeModelConfigStore();
      final writer = _FakeProviderConfigWriter();
      final secret = _FakeSecretStore();

      await _openSettings(
        tester,
        FlowHeroApp(
          modelConfigStore: store,
          providerConfigWriter: writer,
          agentSecretStore: secret,
        ),
      );

      expect(_textOf(tester, 'flow-hero-model-name'), isEmpty);
      await _selectProvider(tester, 'deepseek');
      expect(_selectedModel(tester), 'deepseek-flash');

      // A custom route keeps whatever it had and accepts a free-typed name.
      await _selectProvider(tester, 'custom');
      await tester.enterText(
        find.byKey(const ValueKey<String>('flow-hero-model-name')),
        'my-own-model',
      );
      expect(_textOf(tester, 'flow-hero-model-name'), 'my-own-model');

      // DeepSeek only serves its two ids, so the foreign name is replaced.
      await _selectProvider(tester, 'deepseek');
      expect(_selectedModel(tester), 'deepseek-flash');

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('switching to 无需密钥 clears the stored key', (
    WidgetTester tester,
  ) async {
    final store = _FakeModelConfigStore(config: _storedConfig);
    final writer = _FakeProviderConfigWriter();
    final secret = _FakeSecretStore(stored: 'sk-existing');

    await _openSettings(
      tester,
      FlowHeroApp(
        modelConfigStore: store,
        providerConfigWriter: writer,
        agentSecretStore: secret,
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('flow-hero-model-api-key')),
      findsOneWidget,
    );
    await tester.tap(find.text('无需密钥'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('flow-hero-model-api-key')),
      findsNothing,
    );

    await _tapSave(tester);
    expect(secret.deletes, 1);
    expect(secret.stored, isNull);
    expect(writer.written!.authMode, FlowHeroModelAuthMode.none);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('the provider dropdown lists its options and closes', (
    WidgetTester tester,
  ) async {
    final store = _FakeModelConfigStore(config: _storedConfig);
    final writer = _FakeProviderConfigWriter();
    final secret = _FakeSecretStore(stored: 'sk-existing');

    await _openSettings(
      tester,
      FlowHeroApp(
        modelConfigStore: store,
        providerConfigWriter: writer,
        agentSecretStore: secret,
      ),
    );

    final Finder custom = find.byKey(
      const ValueKey<String>('flow-hero-model-provider-option-custom'),
    );
    final Finder deepseek = find.byKey(
      const ValueKey<String>('flow-hero-model-provider-option-deepseek'),
    );

    expect(custom, findsNothing, reason: 'the list is closed until tapped');

    // Open: every option appears, current one included.
    await tester.tap(
      find.byKey(const ValueKey<String>('flow-hero-model-provider')),
    );
    await tester.pump();
    expect(custom, findsOneWidget);
    expect(deepseek, findsOneWidget);

    // A tap outside dismisses without changing the selection.
    await tester.tapAt(const Offset(4, 4));
    await tester.pump();
    expect(deepseek, findsNothing);
    expect(
      _textOf(tester, 'flow-hero-model-endpoint'),
      _storedConfig.endpointBase,
    );

    // Picking one commits it and closes the list.
    await tester.tap(
      find.byKey(const ValueKey<String>('flow-hero-model-provider')),
    );
    await tester.pump();
    await tester.tap(deepseek);
    await tester.pump();
    expect(deepseek, findsNothing);
    expect(
      _textOf(tester, 'flow-hero-model-endpoint'),
      'https://api.deepseek.com/v1',
    );

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
