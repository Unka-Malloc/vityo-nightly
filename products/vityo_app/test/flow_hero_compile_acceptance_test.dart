import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/local_service/service_launcher_io.dart';
import 'package:vityo_app/src/ide/local_service/vityod_client.dart';
import 'package:vityo_app/src/view_ide/flow_hero/compile_acceptance.dart';
import 'package:vityo_app/src/view_ide/flow_hero/local_services.dart';
import 'package:vityo_app/src/view_ide/flow_hero/model_config.dart';
import 'package:vityo_app/src/view_ide/flow_hero/runtime.dart';
import 'package:vityo_app/src/view_ide/flow_hero/toolchain_store.dart';
import 'package:vityo_app/src/view_render/flow_hero/agent_bridge.dart';
import 'package:vityo_app/src/view_render/flow_hero/controller.dart';
import 'package:vityo_app/src/view_render/flow_hero/engine/machine.dart';
import 'package:vityo_daemon_protocol/vityo_daemon_protocol.dart';

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test(
    'each acceptance launch uses fresh roots and copies only its fixture',
    () async {
      final parent = await Directory.systemTemp.createTemp('acceptance-test-');
      addTearDown(() => parent.delete(recursive: true));
      final fixture = await Directory('${parent.path}/fixture').create();
      final source = File('${fixture.path}/hello.styio');
      await source.writeAsString('print("fixture")');
      final first = await FlowHeroCompileAcceptance.create(
        temporaryParent: parent,
        workspaceFixture: fixture.path,
      );
      final second = await FlowHeroCompileAcceptance.create(
        temporaryParent: parent,
      );
      addTearDown(first.runtime.dispose);
      addTearDown(second.runtime.dispose);

      expect(first.service.root.path, isNot(second.service.root.path));
      expect(first.service.endpoint, isNot(second.service.endpoint));
      expect(first.workspaceRoot, startsWith(first.service.root.path));
      expect(first.service.stateDirectory, startsWith(first.service.root.path));
      expect(first.runtime.agentEnabled, isFalse);
      expect(first.runtime.localServices.clientCreations, 0);
      expect(
        first.runtime.modelConfigStore,
        isA<FlowHeroMemoryModelConfigStore>(),
      );
      expect(
        first.runtime.agentSecretStore,
        isA<FlowHeroDisabledAgentSecretStore>(),
      );
      expect(await first.runtime.providerConfigWriter.exists(), isFalse);
      final copied = File('${first.workspaceRoot}/hello.styio');
      expect(await copied.readAsString(), 'print("fixture")');
      await copied.writeAsString('changed only in disposable workspace');
      expect(await source.readAsString(), 'print("fixture")');
      expect(await Directory(second.workspaceRoot).list().isEmpty, isTrue);
    },
  );

  test(
    'linked fixtures fail closed before any daemon boot',
    () async {
      final parent = await Directory.systemTemp.createTemp('acceptance-link-');
      addTearDown(() => parent.delete(recursive: true));
      final fixture = await Directory('${parent.path}/fixture').create();
      await File('${parent.path}/outside.styio').writeAsString('outside');
      await Link(
        '${fixture.path}/linked.styio',
      ).create('${parent.path}/outside.styio');
      await expectLater(
        FlowHeroCompileAcceptance.create(
          temporaryParent: parent,
          workspaceFixture: fixture.path,
        ),
        throwsArgumentError,
      );
    },
    skip: Platform.isWindows
        ? 'Windows link permission is host-dependent.'
        : false,
  );

  test(
    'isolated environment excludes provider secrets and host cache overrides',
    () {
      final environment =
          compileAcceptanceEnvironment('/private-run', <String, String>{
            'HOME': '/normal-home',
            'PAFIO_HOME': '/normal-pafio',
            'XDG_CONFIG_HOME': '/normal-config',
            'TMPDIR': '/normal-temp',
            'OPENAI_API_KEY': 'synthetic-secret',
            'DEEPSEEK_API_KEY': 'synthetic-secret',
            'CUSTOM_CACHE_HOME': '/normal-cache',
            'PATH': '/tools',
            'VITYO_STYIO_BIN': '/tools/styio',
          });
      expect(environment['HOME'], '/private-run/home');
      expect(environment['PAFIO_HOME'], '/private-run/home/.pafio');
      expect(environment['XDG_CONFIG_HOME'], '/private-run/home/.config');
      expect(environment['TMPDIR'], '/private-run/tmp');
      expect(environment['PATH'], '/tools');
      expect(environment['VITYO_STYIO_BIN'], '/tools/styio');
      expect(environment.containsKey('OPENAI_API_KEY'), isFalse);
      expect(environment.containsKey('DEEPSEEK_API_KEY'), isFalse);
      expect(environment.containsKey('CUSTOM_CACHE_HOME'), isFalse);
      expect(
        compileAcceptanceEndpoint(r'C:\Temp\vca-first', windows: true),
        r'\\.\pipe\vityo-compile-vca-first',
      );
      expect(
        compileAcceptanceEndpoint('/tmp/vca-second', windows: false),
        '/tmp/vca-second/d.sock',
      );
    },
  );

  test(
    'missing owned daemon never borrows even an already-listening endpoint',
    () async {
      final parent = await Directory.systemTemp.createTemp(
        'acceptance-connect-',
      );
      final service = await VityodCompileAcceptanceService.create(
        temporaryParent: parent,
        executable: File('${parent.path}/missing-vityod'),
      );
      addTearDown(() => parent.delete(recursive: true));
      addTearDown(service.dispose);
      var connections = 0;
      final server = await ServerSocket.bind(
        InternetAddress(service.endpoint, type: InternetAddressType.unix),
        0,
      );
      final subscription = server.listen((socket) {
        connections++;
        socket.destroy();
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close();
      });
      await expectLater(service.client(), throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(
        connections,
        0,
        reason: 'The owned process must start before any connect.',
      );
    },
    skip: Platform.isWindows ? 'UNIX socket fixture.' : false,
  );

  test(
    'production store adapters read and write only the isolated store paths',
    () async {
      final root = await Directory.systemTemp.createTemp('acceptance-stores-');
      addTearDown(() => root.delete(recursive: true));
      final transport = _StoreTransport();
      final client = VityodClient(
        transport: transport,
        clientInstanceId: 'stores-test',
      );
      await client.connect();
      final runtime = ProductionFlowHeroRuntime.compileAcceptance(
        localServices: FlowHeroLocalServices(clientFactory: () async => client),
        homePath: '${root.path}/fixture-home',
        environment: compileAcceptanceEnvironment(
          root.path,
          const <String, String>{},
        ),
      );
      addTearDown(runtime.dispose);

      expect(await runtime.themeStore.loadDark(), isNull);
      expect(await runtime.workspaceStore.load(), isNull);
      expect(await runtime.toolchainStore.load(), isNull);
      await runtime.themeStore.saveDark(false);
      await runtime.workspaceStore.save('${root.path}/workspace');
      await runtime.toolchainStore.savePath(
        FlowHeroToolchainKind.styio,
        '/tools/styio',
      );
      expect(await runtime.themeStore.loadDark(), isFalse);
      expect(await runtime.workspaceStore.load(), '${root.path}/workspace');
      expect((await runtime.toolchainStore.load())?.styioPath, '/tools/styio');
      expect(transport.paths, isNotEmpty);
      expect(
        transport.paths.every(
          (path) => path.startsWith('${root.path}/fixture-home/.vityo/flow-hero/'),
        ),
        isTrue,
      );
      expect(transport.files.keys.toSet(), <String>{
        '${root.path}/fixture-home/.vityo/flow-hero/theme.json',
        '${root.path}/fixture-home/.vityo/flow-hero/workspace.json',
        '${root.path}/fixture-home/.vityo/flow-hero/toolchain.json',
      });
      expect(
        transport.methods.any((method) => method.startsWith('agent.')),
        isFalse,
      );
    },
  );

  test(
    'disabled Agent never probes provider, resolves launch, acquires client or reconnects',
    () async {
      var touches = 0;
      final bridge = AgentBridge(
        enabled: false,
        workspaceDirectory: '/disposable/workspace',
        clientFactory: () async {
          touches++;
          throw StateError('client');
        },
        launchResolver: ({required workingDirectory}) async {
          touches++;
          throw StateError('launch');
        },
      );
      final engine = WorkbenchController();
      addTearDown(bridge.dispose);
      addTearDown(engine.dispose);
      bridge.modelConfigured = () async {
        touches++;
        return true;
      };
      await bridge.attach(engine: engine, onText: (_) {}, onReceipt: (_) {});
      await bridge.reconnect();
      bridge.setWorkspaceRoot('/disposable/other');
      await bridge.reconnect();
      expect(touches, 0);
      expect(bridge.mode, AgentLinkMode.demo);
      expect(bridge.statusLine, contains('Agent 已禁用'));
    },
  );

  test(
    'controller disable happens before Agent state restore or mutations',
    () async {
      final poison = _PoisonAgentState();
      final controller = FlowHeroController(
        initialWorkspaceRoot: '/disposable/workspace',
        agentEnabled: false,
        modelConfigStore: poison,
        providerConfigWriter: poison,
        agentSecretStore: poison,
      );
      addTearDown(controller.dispose);
      await controller.workspaceBootSettled;
      await controller.bridge.reconnect();
      final result = await controller.saveModelConfig(
        const FlowHeroModelConfig(),
        apiKey: 'synthetic-test-key',
      );
      expect(result.saved, isFalse);
      expect(poison.touches, 0);
    },
  );

  test('disabled credential adapter cannot save or delete a key', () async {
    const store = FlowHeroDisabledAgentSecretStore();
    expect(await store.hasKey(), isFalse);
    await expectLater(store.saveKey('synthetic-test-key'), throwsStateError);
    await expectLater(store.deleteKey(), throwsStateError);
  });
}

class _PoisonAgentState
    implements
        FlowHeroModelConfigStore,
        FlowHeroProviderConfigWriter,
        FlowHeroAgentSecretStore {
  int touches = 0;
  Never _touch() {
    touches++;
    throw StateError('Agent state must not be touched');
  }

  @override
  bool get persistent => true;
  @override
  Future<FlowHeroModelConfig?> load() async => _touch();
  @override
  Future<void> save(FlowHeroModelConfig config) async => _touch();
  @override
  Future<bool> exists() async => _touch();
  @override
  Future<void> write(FlowHeroModelConfig config) async => _touch();
  @override
  Future<bool> hasKey() async => _touch();
  @override
  Future<void> saveKey(String key) async => _touch();
  @override
  Future<void> deleteKey() async => _touch();
}

/// Fake only the daemon boundary, keeping real store boot, path selection,
/// serialization, protocol framing and file-system manager behavior in test.
class _StoreTransport implements VityodTransport {
  final _control = StreamController<Uint8List>.broadcast(sync: true);
  final _binary = StreamController<VityodBinaryFrame>.broadcast(sync: true);
  final scopes = <String, String>{};
  final files = <String, String>{};
  final paths = <String>[];
  final methods = <String>[];
  @override
  Stream<Uint8List> get incomingControl => _control.stream;
  @override
  Stream<VityodBinaryFrame> get incomingBinary => _binary.stream;
  @override
  Future<String> connect() async => 'acceptance-test';
  @override
  Future<void> sendControl(Uint8List payload) async {
    final request = VityodControlCodec.decode(payload);
    methods.add(request.method);
    if (request.requestId == null) return;
    var result = <String, Object?>{};
    if (request.method == 'handshake.negotiate') {
      result = <String, Object?>{
        'selectedProtocolVersion': vityodProtocolVersion,
        'capabilities': vityodCoreCapabilities,
      };
    } else if (request.method == 'event.resume') {
      result = <String, Object?>{
        'eventCursor': 0,
        'workspaceRevision': 0,
        'capabilities': vityodCoreCapabilities,
        'events': <Object?>[],
        'activeTerminalIds': <String>[],
        'activeTaskIds': <String>[],
        'activeAgentSessionIds': <String>[],
        'dirtyBuffers': <Object?>[],
        'eventDigest': 'cbf29ce484222325',
      };
    } else if (request.method == 'fs.scope.open') {
      scopes[request.params['scopeId'] as String] =
          request.params['rootPath'] as String;
    } else if (request.method.startsWith('fs.')) {
      final relative = request.params['relativePath'] as String;
      final path = '${scopes[request.params['scopeId']]}/$relative';
      paths.add(path);
      if (request.method == 'fs.stat') {
        result = <String, Object?>{
          'entry': <String, Object?>{
            'relativePath': relative,
            'kind': files.containsKey(path) ? 'file' : 'notFound',
          },
        };
      } else if (request.method == 'fs.read') {
        result = <String, Object?>{
          'contentsBase64': base64Encode(utf8.encode(files[path]!)),
        };
      } else if (request.method == 'fs.write') {
        files[path] = utf8.decode(
          base64Decode(request.params['contentsBase64'] as String),
        );
      }
    }
    _control.add(
      VityodControlCodec.encode(
        VityodControlEnvelope(
          method: '${request.method}.result',
          requestId: request.requestId,
          clientInstanceId: request.clientInstanceId,
          idempotencyKey: request.idempotencyKey,
          deadlineUnixMillis: request.deadlineUnixMillis,
          params: result,
        ),
      ),
    );
  }

  @override
  Future<void> sendBinary(VityodBinaryFrame frame) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> dispose() async {
    await _control.close();
    await _binary.close();
  }
}
