import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_agent_protocol/vityo_agent_protocol.dart';
import 'package:vityo_app/src/ide/agent_client/agent_client_models.dart';
import 'package:vityo_app/src/ide/local_service/vityod_client.dart';
import 'package:vityo_app/src/view_render/flow_hero/agent_bridge.dart';
import 'package:vityo_app/src/view_render/flow_hero/controller.dart';
import 'package:vityo_app/src/view_render/flow_hero/engine/machine.dart';
import 'package:vityo_app/src/view_ide/flow_hero/execution_service.dart';
import 'package:vityo_app/src/view_ide/flow_hero/local_services.dart';
import 'package:vityo_app/src/view_ide/flow_hero/toolchain_install_runtime.dart';
import 'package:vityo_app/src/view_ide/flow_hero/toolchain_store.dart';
import 'package:vityo_daemon_protocol/vityo_daemon_protocol.dart';

/// A daemon that answers the vityod requests Flow Hero's boot layer makes, in
/// memory: protocol negotiation, the file-system scope/stat calls the platform
/// managers issue, the `pafio.request` task supervision the process manager
/// drives, and enough of the Agent Client protocol to take an attach to live.
///
/// [existingPaths] holds workspace-relative paths (as the file-system manager
/// reports them) that the scripted daemon says exist and are executable.
final class _ScriptedDaemonTransport implements VityodTransport {
  _ScriptedDaemonTransport({this.existingPaths = const <String>{}});

  final Set<String> existingPaths;

  static const String _versionStdout = 'pafio 1.0.0\n';

  final StreamController<Uint8List> _control =
      StreamController<Uint8List>.broadcast(sync: true);
  final StreamController<VityodBinaryFrame> _binary =
      StreamController<VityodBinaryFrame>.broadcast(sync: true);
  final List<String> methods = <String>[];
  final List<String> spawnedExecutables = <String>[];
  final Map<Object?, String> _taskStdout = <Object?, String>{};
  final Map<String, String> _scopeRoots = <String, String>{};
  int disposeCalls = 0;
  int sessionsCreated = 0;
  bool connected = false;

  @override
  Stream<Uint8List> get incomingControl => _control.stream;

  @override
  Stream<VityodBinaryFrame> get incomingBinary => _binary.stream;

  @override
  Future<String> connect() async {
    connected = true;
    return 'flow-hero-local-services-daemon';
  }

  @override
  Future<void> sendControl(Uint8List payload) async {
    if (!connected) throw StateError('disconnected');
    final VityodControlEnvelope request = VityodControlCodec.decode(payload);
    methods.add(request.method);
    if (request.requestId == null) return;
    final Map<String, Object?> result = _resultFor(request);
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

  Map<String, Object?> _resultFor(VityodControlEnvelope request) {
    return switch (request.method) {
      'handshake.negotiate' => <String, Object?>{
        'selectedProtocolVersion': vityodProtocolVersion,
        'capabilities': vityodCoreCapabilities,
      },
      'event.resume' => <String, Object?>{
        'eventCursor': 0,
        'workspaceRevision': 0,
        'capabilities': vityodCoreCapabilities,
        'events': const <Object?>[],
        'activeTerminalIds': const <String>[],
        'activeTaskIds': const <String>[],
        'activeAgentSessionIds': const <String>[],
        'dirtyBuffers': const <Object?>[],
        'eventDigest': 'cbf29ce484222325',
      },
      'fs.scope.open' => _openScope(request),
      'fs.stat' => <String, Object?>{
        'entry': <String, Object?>{
          'relativePath': request.params['relativePath'],
          'kind': _exists(request) ? 'file' : 'notFound',
        },
      },
      'fs.isExecutable' => <String, Object?>{'executable': _exists(request)},
      'pafio.request' || 'styio.request' => _taskResult(request),
      'agent.connection.open' => <String, Object?>{
        'agentId': request.params['agentId'],
        'protocolVersion': acpProtocolVersion,
        'generation': 1,
        'capabilities': const <Object?>[],
      },
      'agent.connection.close' => const <String, Object?>{
        'terminated': true,
        'forced': false,
        'exitCode': 0,
      },
      'agent.session.new' => <String, Object?>{
        'sessionId': 'session-${++sessionsCreated}',
        'remoteSessionId': 'remote-$sessionsCreated',
        'generation': 1,
      },
      'agent.session.poll' => const <String, Object?>{
        'events': <Object?>[],
        'permissions': <Object?>[],
        'clientOperations': <Object?>[],
        'promptResult': <String, Object?>{'stopReason': 'end_turn'},
      },
      _ => const <String, Object?>{},
    };
  }

  Map<String, Object?> _openScope(VityodControlEnvelope request) {
    final Object? scopeId = request.params['scopeId'];
    final Object? rootPath = request.params['rootPath'];
    if (scopeId is String && rootPath is String) {
      _scopeRoots[scopeId] = rootPath;
    }
    return const <String, Object?>{};
  }

  bool _exists(VityodControlEnvelope request) {
    final Object? relativePath = request.params['relativePath'];
    if (relativePath is! String) return false;
    if (relativePath == '.') {
      // A stat of the scope root itself; nothing in these tests asserts on it.
      return false;
    }
    // Fixture keys are portable; the real manager uses the host's separator.
    return existingPaths.contains(relativePath.replaceAll(r'\', '/'));
  }

  Map<String, Object?> _taskResult(VityodControlEnvelope request) {
    final Object? action = request.params['action'];
    if (action == 'start') {
      final Object? executable = request.params['executable'];
      if (executable is String) spawnedExecutables.add(executable);
      final arguments = request.params['arguments'];
      _taskStdout[request.params['taskId']] =
          arguments is List && arguments.contains('doctor')
          ? jsonEncode({
              'command': 'doctor',
              'ok': true,
              'checks': [
                {
                  'name': 'styio',
                  'status': 'ok',
                  'detail': {
                    'supported_compile_plan_versions': [1],
                  },
                },
              ],
            })
          : _versionStdout;
      return const <String, Object?>{'pid': 4242};
    }
    if (action == 'output') {
      return <String, Object?>{
        'running': false,
        'exitCode': 0,
        'stdout': _taskStdout[request.params['taskId']] ?? _versionStdout,
        'stderr': '',
        'durationMillis': 7,
      };
    }
    return const <String, Object?>{};
  }

  @override
  Future<void> sendBinary(VityodBinaryFrame frame) async {}

  @override
  Future<void> close() async {
    connected = false;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await close();
    await _control.close();
    await _binary.close();
  }
}

VityodClient _newClient(_ScriptedDaemonTransport transport, String id) =>
    VityodClient(transport: transport, clientInstanceId: id);

Future<VityodClient> _connectedClient(
  _ScriptedDaemonTransport transport,
  String id,
) async {
  final client = _newClient(transport, id);
  await client.connect();
  return client;
}

void main() {
  group('FlowHeroLocalServices', () {
    test('establishes one client for concurrent consumers', () async {
      final transport = _ScriptedDaemonTransport();
      var builds = 0;
      final services = FlowHeroLocalServices(
        clientFactory: () async {
          builds++;
          return _connectedClient(transport, 'shared');
        },
      );
      addTearDown(services.dispose);

      final clients = await Future.wait(<Future<VityodClient?>>[
        services.client(),
        services.client(),
        services.client(),
      ]);

      expect(builds, 1, reason: 'the platform client is launched once');
      expect(services.clientCreations, 1);
      expect(clients[0], isNotNull);
      expect(identical(clients[0], clients[1]), isTrue);
      expect(identical(clients[1], clients[2]), isTrue);
    });

    test('an unavailable client is null and remembered', () async {
      var builds = 0;
      final services = FlowHeroLocalServices(
        clientFactory: () async {
          builds++;
          return null;
        },
      );
      addTearDown(services.dispose);

      expect(await services.client(), isNull);
      expect(await services.client(), isNull);
      expect(builds, 1, reason: 'a failed launch is not retried per probe');
      expect(services.clientAvailable, isFalse);
    });

    test(
      'a throwing factory degrades to null instead of propagating',
      () async {
        final services = FlowHeroLocalServices(
          clientFactory: () async => throw StateError('no packaged vityod'),
        );
        addTearDown(services.dispose);
        expect(await services.client(), isNull);
      },
    );

    test('dispose releases the shared client exactly once', () async {
      final transport = _ScriptedDaemonTransport();
      final services = FlowHeroLocalServices(
        clientFactory: () => _connectedClient(transport, 'dispose-once'),
      );

      await services.client();
      await services.dispose();
      await services.dispose();

      expect(transport.disposeCalls, 1);
      expect(services.disposed, isTrue);
      expect(await services.client(), isNull);
    });

    test(
      'dispose during establishment still releases the client once',
      () async {
        final transport = _ScriptedDaemonTransport();
        final gate = Completer<VityodClient?>();
        final services = FlowHeroLocalServices(
          clientFactory: () => gate.future,
        );

        final pending = services.client();
        final disposing = services.dispose();
        gate.complete(await _connectedClient(transport, 'late'));
        await disposing;

        expect(
          await pending,
          isNull,
          reason: 'the holder was already torn down',
        );
        expect(transport.disposeCalls, 1);
      },
    );
  });

  group('agent bridge borrows the shared client', () {
    test(
      'attach goes live and neither reconnect nor dispose closes it',
      () async {
        final transport = _ScriptedDaemonTransport();
        final client = await _connectedClient(transport, 'shared-agent');
        final engine = WorkbenchController();
        addTearDown(engine.dispose);

        final bridge = AgentBridge(
          workspaceDirectory: '/fixture/workspace',
          launchResolver: ({required String workingDirectory}) async =>
              AgentLaunchDescriptor(
                id: AgentBridge.agentId,
                executable:
                    '/fixture/Vityo.app/Contents/Helpers/vityo-coding-agent',
                arguments: const <String>['--stdio-agent'],
                workingDirectory: workingDirectory,
              ),
          clientProvider: () async => client,
        )..modelConfigured = () async => true;

        await bridge.attach(
          engine: engine,
          onText: (String _) {},
          onReceipt: (String _) {},
        );
        expect(bridge.mode, AgentLinkMode.live);
        expect(transport.disposeCalls, 0);

        await bridge.reconnect();
        expect(bridge.mode, AgentLinkMode.live);
        expect(
          transport.disposeCalls,
          0,
          reason: 'a shared client survives the bridge\'s teardown',
        );

        bridge.dispose();
        await Future<void>.delayed(Duration.zero);
        expect(
          transport.disposeCalls,
          0,
          reason: 'the holder owns disposal, not the bridge',
        );

        await client.dispose();
      },
    );
  });

  group('execution boot through the shared client', () {
    late Directory workspace;
    late String pafioPath;
    late String styioPath;

    setUp(() {
      workspace = Directory.systemTemp.createTempSync('flow_hero_shared_');
      pafioPath = '${workspace.path}/bin/pafio';
      styioPath = '${workspace.path}/bin/styio';
    });

    tearDown(() {
      if (workspace.existsSync()) workspace.deleteSync(recursive: true);
    });

    _ScriptedDaemonTransport scripted() => _ScriptedDaemonTransport(
      existingPaths: const <String>{'pafio.toml', 'bin/pafio', 'bin/styio'},
    );

    test('a live client discovers the fake pafio and boots live', () async {
      final transport = scripted();
      final client = await _connectedClient(transport, 'boot-live');
      addTearDown(client.dispose);

      final runtime = await FlowHeroExecutionRuntime.boot(
        workspaceRoot: workspace.path,
        vityodClient: client,
        environment: <String, String>{
          'VITYO_PAFIO_BIN': pafioPath,
          'VITYO_STYIO_BIN': styioPath,
        },
        pafioSystemCandidatePaths: const <String>[],
      );
      addTearDown(runtime.dispose);

      expect(runtime.live, isTrue);
      expect(
        runtime.pafioBinaryPath,
        pafioPath,
        reason: 'a real process probe',
      );
      expect(runtime.styioBinaryPath, styioPath);
      expect(runtime.missingToolchains, isEmpty);
      expect(transport.spawnedExecutables, contains(pafioPath));
    });

    test('without a client the same boot stays honestly unavailable', () async {
      final runtime = await FlowHeroExecutionRuntime.boot(
        workspaceRoot: workspace.path,
        environment: const <String, String>{},
        pafioSystemCandidatePaths: const <String>[],
      );
      addTearDown(runtime.dispose);

      expect(runtime.live, isFalse);
      expect(runtime.unavailableReason, contains('未发现 pafio'));
      expect(runtime.missingToolchains, contains(FlowHeroToolchainKind.pafio));
    });

    test(
      'retryExecutionBoot re-boots through the same single client',
      () async {
        final transport = scripted();
        final services = FlowHeroLocalServices(
          clientFactory: () => _connectedClient(
            transport,
            'shared-boot-${workspace.path.hashCode}',
          ),
        );
        addTearDown(services.dispose);

        var boots = 0;
        final controller = FlowHeroController(
          localServices: services,
          initialWorkspaceRoot: workspace.path,
          executionBoot:
              (String root, FlowHeroToolchainSelection selection) async {
                boots++;
                return FlowHeroExecutionRuntime.boot(
                  workspaceRoot: root,
                  vityodClient: await services.client(),
                  environment: <String, String>{
                    'VITYO_PAFIO_BIN': pafioPath,
                    'VITYO_STYIO_BIN': styioPath,
                  },
                  pafioSystemCandidatePaths: const <String>[],
                );
              },
        );
        addTearDown(controller.dispose);

        await controller.workspaceBootSettled;
        expect(controller.executionLive, isTrue);
        final int booted = boots;

        await controller.retryExecutionBoot();

        expect(
          boots,
          greaterThan(booted),
          reason: 'the retry really re-booted',
        );
        expect(controller.executionLive, isTrue);
        expect(
          services.clientCreations,
          1,
          reason: 'every boot shares one vityod connection',
        );
      },
    );

    test('the install probe spawns --version only with a client', () async {
      final transport = scripted();
      final client = await _connectedClient(transport, 'probe-live');
      addTearDown(client.dispose);

      final verified = await probeFlowHeroToolchainBinary(
        kind: FlowHeroToolchainKind.pafio,
        path: pafioPath,
        vityodClient: client,
      );
      expect(verified.ok, isTrue);
      expect(verified.versionOutput, contains('pafio 1.0.0'));

      final unverified = await probeFlowHeroToolchainBinary(
        kind: FlowHeroToolchainKind.pafio,
        path: pafioPath,
      );
      expect(
        unverified.ok,
        isFalse,
        reason: 'the unsupported process manager cannot spawn --version',
      );
    });
  });
}
