import 'dart:async';
import 'dart:typed_data';

import 'package:vityo_agent_protocol/vityo_agent_protocol.dart';
import 'package:test/test.dart';
import 'package:vityo_app/src/ide/agent_client/agent_client.dart';
import 'package:vityo_app/src/ide/local_service/vityod_client.dart';
import 'package:vityo_daemon_protocol/vityo_daemon_protocol.dart';

void main() {
  test('an Agent prompt can outlive bounded control request budgets', () async {
    final transport = _PromptTransport(
      completeAfter: const Duration(milliseconds: 120),
    );
    final client = await _connectClient(transport);
    final registry = _registry(
      client,
      policy: const AgentClientPolicy(
        controlRequestTimeout: Duration(milliseconds: 40),
      ),
    );
    addTearDown(() async {
      await registry.close();
      await client.dispose();
    });
    final session = await registry.newSession(
      agentId: 'agent',
      cwd: Uri.file('/workspace'),
    );

    final result = await session.prompt('run a long task');

    expect(result.stopReason, 'end_turn');
    expect(registry.policy.requestTimeout, isNull);
  });

  test('an explicitly configured prompt deadline remains enforced', () async {
    final transport = _PromptTransport(
      completeAfter: const Duration(milliseconds: 200),
    );
    final client = await _connectClient(transport);
    final registry = _registry(
      client,
      policy: const AgentClientPolicy(
        requestTimeout: Duration(milliseconds: 50),
      ),
    );
    addTearDown(() async {
      await registry.close();
      await client.dispose();
    });
    final session = await registry.newSession(
      agentId: 'agent',
      cwd: Uri.file('/workspace'),
    );

    await expectLater(
      session.prompt('bounded request'),
      throwsA(
        isA<AgentClientFailure>().having(
          (e) => e.code,
          'code',
          'request_timeout',
        ),
      ),
    );
  });

  test(
    'an unbounded prompt still completes through explicit cancellation',
    () async {
      final transport = _PromptTransport(completeOnCancel: true);
      final client = await _connectClient(transport);
      final registry = _registry(client);
      addTearDown(() async {
        await registry.close();
        await client.dispose();
      });
      final session = await registry.newSession(
        agentId: 'agent',
        cwd: Uri.file('/workspace'),
      );

      final prompt = session.prompt('wait for cancellation');
      await transport.promptSubmitted.future;
      expect(await session.cancel(), isTrue);
      expect((await prompt).stopReason, 'cancelled');
    },
  );
}

Future<VityodClient> _connectClient(_PromptTransport transport) async {
  final client = VityodClient(
    transport: transport,
    clientInstanceId: 'agent-prompt-test',
  );
  await client.connect();
  return client;
}

AgentClientRegistry _registry(
  VityodClient client, {
  AgentClientPolicy policy = const AgentClientPolicy(),
}) => AgentClientRegistry(
  descriptors: <String, AgentLaunchDescriptor>{
    'agent': AgentLaunchDescriptor(
      id: 'agent',
      executable: '/fixture/agent',
      arguments: const <String>[],
      workingDirectory: '/workspace',
    ),
  },
  client: client,
  policy: policy,
);

final class _PromptTransport implements VityodTransport {
  _PromptTransport({this.completeAfter, this.completeOnCancel = false});

  final Duration? completeAfter;
  final bool completeOnCancel;
  final StreamController<Uint8List> _control =
      StreamController<Uint8List>.broadcast(sync: true);
  final StreamController<VityodBinaryFrame> _binary =
      StreamController<VityodBinaryFrame>.broadcast(sync: true);
  final Completer<void> promptSubmitted = Completer<void>();
  final Stopwatch _promptElapsed = Stopwatch();
  var _connected = false;
  var _cancelled = false;

  @override
  Stream<Uint8List> get incomingControl => _control.stream;

  @override
  Stream<VityodBinaryFrame> get incomingBinary => _binary.stream;

  @override
  Future<String> connect() async {
    _connected = true;
    return 'agent-prompt-test-daemon';
  }

  @override
  Future<void> sendControl(Uint8List payload) async {
    if (!_connected) throw StateError('disconnected');
    final request = VityodControlCodec.decode(payload);
    if (request.method == 'event.resume') return;
    final requestId = request.requestId;
    if (requestId == null) return;

    if (request.method == 'agent.session.prompt') {
      _promptElapsed.start();
      if (!promptSubmitted.isCompleted) promptSubmitted.complete();
    } else if (request.method == 'agent.acp.session.cancel') {
      _cancelled = true;
    }

    final params = switch (request.method) {
      'handshake.negotiate' => <String, Object?>{
        'selectedProtocolVersion': vityodProtocolVersion,
        'capabilities': vityodCoreCapabilities,
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
      },
      'agent.session.new' => const <String, Object?>{
        'sessionId': 'session-1',
        'remoteSessionId': 'remote-session-1',
        'generation': 1,
      },
      'agent.session.prompt' => const <String, Object?>{},
      'agent.session.poll' => _pollResult(),
      'agent.acp.session.cancel' => const <String, Object?>{'cancelled': true},
      _ => const <String, Object?>{},
    };
    _control.add(
      VityodControlCodec.encode(
        VityodControlEnvelope(
          method: '${request.method}.result',
          requestId: requestId,
          clientInstanceId: request.clientInstanceId,
          idempotencyKey: request.idempotencyKey,
          deadlineUnixMillis: request.deadlineUnixMillis,
          params: params,
          capabilities: request.method == 'handshake.negotiate'
              ? vityodCoreCapabilities
              : const <String>[],
        ),
      ),
    );
  }

  Map<String, Object?> _pollResult() {
    final finished =
        _cancelled && completeOnCancel ||
        completeAfter != null && _promptElapsed.elapsed >= completeAfter!;
    return <String, Object?>{
      'events': const <Object?>[],
      'permissions': const <Object?>[],
      'clientOperations': const <Object?>[],
      if (finished)
        'promptResult': <String, Object?>{
          'stopReason': _cancelled ? 'cancelled' : 'end_turn',
        },
    };
  }

  @override
  Future<void> sendBinary(VityodBinaryFrame frame) async {}

  @override
  Future<void> close() async {
    _connected = false;
  }

  @override
  Future<void> dispose() async {
    await close();
    await _control.close();
    await _binary.close();
  }
}
