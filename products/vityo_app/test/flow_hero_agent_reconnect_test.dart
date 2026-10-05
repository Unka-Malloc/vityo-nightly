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
  _ScriptedDaemonTransport();

  final StreamController<Uint8List> _control =
      StreamController<Uint8List>.broadcast(sync: true);
  final StreamController<VityodBinaryFrame> _binary =
      StreamController<VityodBinaryFrame>.broadcast(sync: true);
  final List<String> methods = <String>[];
  int sessionsCreated = 0;
  bool connected = false;
  bool disposed = false;

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
    disposed = true;
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
      final bridge = AgentBridge(
        workspaceDirectory: '/fixture/workspace',
        launchResolver: ({required String workingDirectory}) async =>
            _descriptor(workingDirectory: workingDirectory),
        clientFactory: () async {
          final transport = _ScriptedDaemonTransport();
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
      expect(transports.first.disposed, isTrue);
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
