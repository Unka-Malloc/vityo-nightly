import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_agent_protocol/vityo_agent_protocol.dart';
import 'package:vityo_app/src/ide/agent_client/agent_client_models.dart';
import 'package:vityo_app/src/ide/local_service/vityod_client.dart';
import 'package:vityo_app/src/view_render/flow_hero/agent_bridge.dart';
import 'package:vityo_app/src/view_render/flow_hero/engine/machine.dart';
import 'package:vityo_daemon_protocol/vityo_daemon_protocol.dart';

/// A daemon that answers the Agent Client protocol in memory: enough of
/// `handshake`, `event.resume`, `agent.connection.*`, and `agent.session.*` to
/// take an attach all the way to `live` without a real service or executable.
final class _ScriptedDaemonTransport implements VityodTransport {
  _ScriptedDaemonTransport({
    required this.workspaceRoot,
    this.releaseSessionNew,
    this.includeReadOperation = false,
  });

  final String workspaceRoot;
  final Completer<void>? releaseSessionNew;
  final bool includeReadOperation;

  final StreamController<Uint8List> _control =
      StreamController<Uint8List>.broadcast(sync: true);
  final StreamController<VityodBinaryFrame> _binary =
      StreamController<VityodBinaryFrame>.broadcast(sync: true);
  final List<String> methods = <String>[];
  final List<String> openedWorkspaceRoots = <String>[];
  final List<String> readWorkspacePaths = <String>[];
  final List<String> sessionRoots = <String>[];
  final Completer<void> sessionNewEntered = Completer<void>();
  final Completer<VityodControlEnvelope> clientOperationResponse =
      Completer<VityodControlEnvelope>();
  int sessionsCreated = 0;
  int scopeCloseCount = 0;
  int disposeCount = 0;
  bool connected = false;
  var _readOperationSent = false;

  @override
  Stream<Uint8List> get incomingControl => _control.stream;

  @override
  Stream<VityodBinaryFrame> get incomingBinary => _binary.stream;

  @override
  Future<String> connect() async {
    connected = true;
    return 'flow-hero-scripted-daemon';
  }

  @override
  Future<void> sendControl(Uint8List payload) async {
    if (!connected) throw StateError('disconnected');
    final VityodControlEnvelope request = VityodControlCodec.decode(payload);
    methods.add(request.method);
    if (request.requestId == null) return;
    if (request.method == 'agent.session.new') {
      sessionRoots.add(request.params['workspacePath'] as String);
      if (!sessionNewEntered.isCompleted) sessionNewEntered.complete();
      await releaseSessionNew?.future;
    }
    if (request.method == 'workspace.open') {
      openedWorkspaceRoots.add(request.params['rootPath'] as String);
    }
    if (request.method == 'workspace.read') {
      readWorkspacePaths.add(request.params['relativePath'] as String);
    }
    if (request.method == 'fs.scope.close') scopeCloseCount++;
    if (request.method == 'agent.acp.client_operation.respond' &&
        !clientOperationResponse.isCompleted) {
      clientOperationResponse.complete(request);
    }
    final Map<String, Object?> result = switch (request.method) {
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
      'fs.scope.close' => <String, Object?>{
        'scopeId': request.params['scopeId'],
        'closed': true,
      },
      'workspace.open' => const <String, Object?>{'workspaceRevision': 0},
      'workspace.read' => <String, Object?>{
        'relativePath': request.params['relativePath'],
        'contents': 'contents:$workspaceRoot',
        'documentRevision': 1,
        'workspaceRevision': 0,
      },
      'agent.session.new' => <String, Object?>{
        'sessionId': 'session-${++sessionsCreated}',
        'remoteSessionId': 'remote-$sessionsCreated',
        'generation': 1,
      },
      'agent.session.poll' => <String, Object?>{
        'events': <Object?>[],
        'permissions': <Object?>[],
        'clientOperations': includeReadOperation && !_readOperationSent
            ? <Object?>[
                <String, Object?>{
                  'operationId': 'read-$sessionsCreated',
                  'sessionId': 'session-$sessionsCreated',
                  'method': 'fs/read_text_file',
                  'params': <String, Object?>{
                    'sessionId': 'remote-$sessionsCreated',
                    'path': '$workspaceRoot/src/main.styio',
                  },
                },
              ]
            : const <Object?>[],
        'promptResult': <String, Object?>{'stopReason': 'end_turn'},
      },
      _ => const <String, Object?>{},
    };
    if (request.method == 'agent.session.poll' && includeReadOperation) {
      _readOperationSent = true;
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
  Future<void> close() async {
    connected = false;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    await close();
    await _control.close();
    await _binary.close();
  }
}

AgentLaunchDescriptor _descriptor({required String workingDirectory}) =>
    AgentLaunchDescriptor(
      id: AgentBridge.agentId,
      executable: '/fixture/Vityo.app/Contents/Helpers/vityo-coding-agent',
      arguments: const <String>['--stdio-agent'],
      workingDirectory: workingDirectory,
    );

void main() {
  test(
    'an unconfigured model route keeps the bridge in demo and never launches',
    () async {
      final WorkbenchController engine = WorkbenchController();
      addTearDown(engine.dispose);
      var launched = false;
      final bridge = AgentBridge(
        workspaceDirectory: '/fixture/workspace',
        launchResolver: ({required String workingDirectory}) async {
          launched = true;
          return _descriptor(workingDirectory: workingDirectory);
        },
      )..modelConfigured = () async => false;
      addTearDown(bridge.dispose);

      await bridge.attach(
        engine: engine,
        onText: (String _) {},
        onReceipt: (String _) {},
      );

      expect(bridge.mode, AgentLinkMode.demo);
      expect(bridge.statusLine, '未配置模型 · 演示会话');
      expect(launched, isFalse, reason: 'no runtime that would exit 78');
      expect(bridge.activeListenerCount, 0);
    },
  );

  test('a configured route with no local service stays honest', () async {
    final WorkbenchController engine = WorkbenchController();
    addTearDown(engine.dispose);
    final bridge = AgentBridge(
      workspaceDirectory: '/fixture/workspace',
      launchResolver: ({required String workingDirectory}) async =>
          _descriptor(workingDirectory: workingDirectory),
      clientFactory: () async => null,
    )..modelConfigured = () async => true;
    addTearDown(bridge.dispose);

    await bridge.attach(
      engine: engine,
      onText: (String _) {},
      onReceipt: (String _) {},
    );

    expect(bridge.mode, AgentLinkMode.demo);
    expect(bridge.statusLine, '本地服务不可用 · 演示会话');
  });

  test(
    'a live attach is rebuilt by reconnect without doubling listeners',
    () async {
      final WorkbenchController engine = WorkbenchController();
      addTearDown(engine.dispose);
      final List<_ScriptedDaemonTransport> transports =
          <_ScriptedDaemonTransport>[];
      var resolvedWorkspaceRoot = '/fixture/workspace';
      final bridge = AgentBridge(
        workspaceDirectory: resolvedWorkspaceRoot,
        launchResolver: ({required String workingDirectory}) async {
          resolvedWorkspaceRoot = workingDirectory;
          return _descriptor(workingDirectory: workingDirectory);
        },
        clientFactory: () async {
          final transport = _ScriptedDaemonTransport(
            workspaceRoot: resolvedWorkspaceRoot,
          );
          transports.add(transport);
          final client = VityodClient(
            transport: transport,
            clientInstanceId: 'flow-hero-test-${transports.length}',
          );
          await client.connect();
          return client;
        },
      )..modelConfigured = () async => true;
      addTearDown(bridge.dispose);

      await bridge.attach(
        engine: engine,
        onText: (String _) {},
        onReceipt: (String _) {},
      );

      expect(bridge.mode, AgentLinkMode.live);
      expect(bridge.statusLine, AgentBridge.agentId);
      final int listeners = bridge.activeListenerCount;
      expect(listeners, greaterThan(0));
      expect(transports.length, 1);
      expect(transports.first.sessionsCreated, 1);

      await bridge.reconnect();

      expect(bridge.mode, AgentLinkMode.live);
      expect(bridge.statusLine, AgentBridge.agentId);
      expect(transports.length, 2, reason: 'a fresh connection was built');
      expect(transports.first.methods, contains('agent.connection.close'));
      expect(transports.first.scopeCloseCount, 1);
      expect(transports.first.disposeCount, 1);
      expect(transports.last.sessionsCreated, 1);
      expect(
        bridge.activeListenerCount,
        listeners,
        reason: 'the previous subscriptions were cancelled, not stacked',
      );
      expect(bridge.attachStarted, isTrue);
    },
  );

  test('reconnect before any attach does not block a later attach', () async {
    final WorkbenchController engine = WorkbenchController();
    addTearDown(engine.dispose);
    var probes = 0;
    final bridge = AgentBridge(workspaceDirectory: '/fixture/workspace')
      ..modelConfigured = () async {
        probes++;
        return false;
      };
    addTearDown(bridge.dispose);

    await bridge.reconnect();
    expect(bridge.attachStarted, isFalse);

    await bridge.attach(
      engine: engine,
      onText: (String _) {},
      onReceipt: (String _) {},
    );
    expect(probes, 1);
    expect(bridge.mode, AgentLinkMode.demo);
    expect(bridge.statusLine, '未配置模型 · 演示会话');
  });

  test(
    'overlapping reconnects retire the stale session and use the latest store for dispatch',
    () async {
      const middleRoot = '/fixture/middle';
      const finalRoot = '/fixture/final';
      final engine = WorkbenchController();
      addTearDown(engine.dispose);
      final releaseMiddleSession = Completer<void>();
      final middleTransportReady = Completer<_ScriptedDaemonTransport>();
      final transports = <_ScriptedDaemonTransport>[];
      var resolvedWorkspaceRoot = '/fixture/initial';
      final bridge =
          AgentBridge(
              launchResolver: ({required String workingDirectory}) async {
                resolvedWorkspaceRoot = workingDirectory;
                return _descriptor(workingDirectory: workingDirectory);
              },
              clientFactory: () async {
                final root = resolvedWorkspaceRoot;
                final transport = _ScriptedDaemonTransport(
                  workspaceRoot: root,
                  releaseSessionNew: root == middleRoot
                      ? releaseMiddleSession
                      : null,
                  includeReadOperation: true,
                );
                transports.add(transport);
                if (root == middleRoot) {
                  middleTransportReady.complete(transport);
                }
                final client = VityodClient(
                  transport: transport,
                  clientInstanceId: 'flow-hero-race-${transports.length}',
                );
                await client.connect();
                return client;
              },
            )
            ..setWorkspaceRoot('/fixture/initial')
            ..modelConfigured = () async => true;
      addTearDown(bridge.dispose);

      await bridge.attach(
        engine: engine,
        onText: (String _) {},
        onReceipt: (String _) {},
      );
      final listeners = bridge.activeListenerCount;
      bridge.setWorkspaceRoot(middleRoot);
      final middleReconnect = bridge.reconnect();
      final middleTransport = await middleTransportReady.future;
      await middleTransport.sessionNewEntered.future;

      bridge.setWorkspaceRoot(finalRoot);
      final finalReconnect = bridge.reconnect();
      releaseMiddleSession.complete();
      await Future.wait<void>(<Future<void>>[middleReconnect, finalReconnect]);

      expect(bridge.mode, AgentLinkMode.live);
      expect(bridge.workspaceRoot, finalRoot);
      expect(transports, hasLength(3));
      final initialTransport = transports[0];
      final finalTransport = transports[2];
      expect(middleTransport.openedWorkspaceRoots, <String>[middleRoot]);
      expect(
        middleTransport.sessionRoots.single,
        Uri.directory(middleRoot).toFilePath(),
      );
      expect(middleTransport.scopeCloseCount, 1);
      expect(middleTransport.disposeCount, 1);
      expect(initialTransport.scopeCloseCount, 1);
      expect(initialTransport.disposeCount, 1);
      expect(finalTransport.openedWorkspaceRoots, <String>[finalRoot]);
      expect(
        finalTransport.sessionRoots.single,
        Uri.directory(finalRoot).toFilePath(),
      );
      expect(bridge.activeListenerCount, listeners);

      final mainPath = '$finalRoot/src/main.styio';
      expect(await engine.openPath(mainPath), isTrue);
      expect(engine.openedBuffer(mainPath)!.text, 'contents:$finalRoot');
      expect(finalTransport.readWorkspacePaths, contains('src/main.styio'));

      await bridge.send('read from the active workspace');
      final operationResponse =
          await finalTransport.clientOperationResponse.future;
      final response = operationResponse.params['response'] as Map;
      expect(response['content'], 'contents:$finalRoot');
      expect(bridge.activeListenerCount, listeners);
    },
  );

  test(
    'dispose during session creation retires late resources without notifying',
    () async {
      final engine = WorkbenchController();
      addTearDown(engine.dispose);
      final releaseSessionNew = Completer<void>();
      final transportReady = Completer<_ScriptedDaemonTransport>();
      final bridge = AgentBridge(
        workspaceDirectory: '/fixture/dispose',
        launchResolver: ({required String workingDirectory}) async =>
            _descriptor(workingDirectory: workingDirectory),
        clientFactory: () async {
          final transport = _ScriptedDaemonTransport(
            workspaceRoot: '/fixture/dispose',
            releaseSessionNew: releaseSessionNew,
          );
          transportReady.complete(transport);
          final client = VityodClient(
            transport: transport,
            clientInstanceId: 'flow-hero-dispose',
          );
          await client.connect();
          return client;
        },
      )..modelConfigured = () async => true;
      var notifications = 0;
      bridge.addListener(() => notifications++);

      final attaching = bridge.attach(
        engine: engine,
        onText: (String _) {},
        onReceipt: (String _) {},
      );
      final transport = await transportReady.future;
      await transport.sessionNewEntered.future;
      final notificationsAtDispose = notifications;
      bridge.dispose();
      releaseSessionNew.complete();
      await attaching;

      expect(notifications, notificationsAtDispose);
      expect(bridge.mode, isNot(AgentLinkMode.live));
      expect(transport.scopeCloseCount, 1);
      expect(transport.disposeCount, 1);
      expect(transport.methods, contains('agent.connection.close'));
      expect(bridge.activeListenerCount, 0);
    },
  );

  test('dispose during launch resolution does not create a client', () async {
    final engine = WorkbenchController();
    addTearDown(engine.dispose);
    final resolverEntered = Completer<void>();
    final releaseResolver = Completer<void>();
    var clientsCreated = 0;
    final bridge = AgentBridge(
      workspaceDirectory: '/fixture/pending-launch',
      launchResolver: ({required String workingDirectory}) async {
        resolverEntered.complete();
        await releaseResolver.future;
        return _descriptor(workingDirectory: workingDirectory);
      },
      clientFactory: () async {
        clientsCreated++;
        return null;
      },
    )..modelConfigured = () async => true;

    final attaching = bridge.attach(
      engine: engine,
      onText: (String _) {},
      onReceipt: (String _) {},
    );
    await resolverEntered.future;
    bridge.dispose();
    releaseResolver.complete();
    await attaching;

    expect(clientsCreated, 0);
    expect(bridge.mode, isNot(AgentLinkMode.live));
  });

  test('a missing workspace still wins over the model precheck', () async {
    final WorkbenchController engine = WorkbenchController();
    addTearDown(engine.dispose);
    var probes = 0;
    final bridge = AgentBridge(workspaceDirectory: '  ')
      ..modelConfigured = () async {
        probes++;
        return false;
      };
    addTearDown(bridge.dispose);

    await bridge.attach(
      engine: engine,
      onText: (String _) {},
      onReceipt: (String _) {},
    );

    expect(bridge.statusLine, '未配置 Agent 工作区 · 演示会话');
    expect(probes, 0);
  });
}
