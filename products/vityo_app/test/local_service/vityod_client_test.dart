import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/local_service/vityod_client.dart';
import 'package:vityo_daemon_protocol/vityo_daemon_protocol.dart';

void main() {
  for (final endOfStream in [false, true]) {
    test(
      'transport ${endOfStream ? 'EOF' : 'error'} settles pending work without replay',
      () async {
        final transport = _FaultingTransport();
        final client = VityodClient(
          transport: transport,
          clientInstanceId: 'failure-settlement',
        );
        try {
          await client.connect();
          final pending = client.request(
            method: 'workspace.read',
            idempotencyKey: 'one-operation',
          );
          final failed = expectLater(pending, throwsStateError);
          if (endOfStream) {
            await transport.control.close();
          } else {
            transport.control.addError(StateError('peer failed'));
          }
          await failed;
          expect(client.state.phase, VityodConnectionPhase.disconnected);
          expect(
            transport.delegate.sent
                .map(VityodControlCodec.decode)
                .where((r) => r.method == 'workspace.read'),
            hasLength(1),
          );
          if (!endOfStream) {
            await client.connect();
            expect(client.state.canDispatch, isTrue);
            expect(
              transport.delegate.sent
                  .map(VityodControlCodec.decode)
                  .where((r) => r.method == 'workspace.read'),
              hasLength(1),
            );
          }
        } finally {
          await client.dispose();
        }
      },
    );
  }

  test(
    'real socket EOF settles the pending handshake',
    () async {
      final directory = await Directory.systemTemp.createTemp('vityo-eof-');
      final endpoint = '${directory.path}/service.sock';
      final server = await ServerSocket.bind(
        InternetAddress(endpoint, type: InternetAddressType.unix),
        0,
      );
      final client = VityodClient(
        transport: SocketVityodTransport(endpointPath: endpoint),
        clientInstanceId: 'socket-eof',
      );
      Socket? peer;
      try {
        final connected = server.first;
        final failed = expectLater(client.connect(), throwsStateError);
        peer = await connected;
        await peer.first;
        peer.destroy();
        await failed;
        expect(client.state.phase, VityodConnectionPhase.disconnected);
      } finally {
        peer?.destroy();
        await client.dispose();
        await server.close();
        await directory.delete(recursive: true);
      }
    },
    skip: !(Platform.isLinux || Platform.isMacOS)
        ? 'Unix socket path; Windows named-pipe execution needs its platform owner.'
        : false,
  );

  testWidgets(
    'healthy daemon request has no implicit deadline and retains its response',
    (tester) async {
      final transport = MemoryVityodTransport();
      final client = VityodClient(
        transport: transport,
        clientInstanceId: 'held-request',
      );
      try {
        await client.connect();
        var completed = false;
        final pending = client
            .request(method: 'workspace.read', idempotencyKey: 'held')
            .then((value) {
              completed = true;
              return value;
            });
        await tester.pump(const Duration(minutes: 3));
        expect(completed, isFalse);
        final request = VityodControlCodec.decode(transport.sent.last);
        expect(request.deadlineUnixMillis, 0);
        transport.receiveControl(
          VityodControlCodec.encode(
            VityodControlEnvelope(
              method: 'workspace.read.result',
              requestId: request.requestId,
              clientInstanceId: 'daemon',
              idempotencyKey: request.idempotencyKey,
              deadlineUnixMillis: 0,
              params: const {'contents': 'completed'},
            ),
          ),
        );
        await tester.pump();
        expect((await pending).params['contents'], 'completed');
      } finally {
        // Stream cleanup must complete outside WidgetTester's fake clock.
        await tester.runAsync(client.dispose);
      }
    },
  );

  test(
    'connect sends revisioned resume request and accepts ordered snapshot',
    () async {
      final transport = MemoryVityodTransport(instanceId: 'daemon-1');
      final client = VityodClient(
        transport: transport,
        clientInstanceId: 'client-1',
        clock: () => DateTime.utc(2030),
      );

      await client.connect();

      expect(client.state.phase, VityodConnectionPhase.connected);
      expect(transport.sent, hasLength(2));
      final handshake = VityodControlCodec.decode(transport.sent.first);
      expect(handshake.method, 'handshake.negotiate');
      expect(
        handshake.params['requiredCapabilities'],
        containsAll(<String>['event.resume', 'workspace.snapshot']),
      );
      final resume = VityodControlCodec.decode(transport.sent.last);
      expect(resume.method, 'event.resume');
      expect(resume.params['afterCursor'], 0);

      client.acceptSnapshot(
        const VityodServiceSnapshot(
          eventCursor: 8,
          workspaceRevision: 3,
          capabilities: <String>{'workspace.snapshot'},
        ),
      );
      expect(client.state.lastEventCursor, 8);
      expect(client.snapshot?.workspaceRevision, 3);
      await client.dispose();
    },
  );

  test('connect fails closed when negotiation is rejected', () async {
    final transport = MemoryVityodTransport(automaticallyNegotiate: false);
    final client = VityodClient(
      transport: transport,
      clientInstanceId: 'client-rejected',
    );

    final connect = client.connect();
    await Future<void>.delayed(Duration.zero);
    final request = VityodControlCodec.decode(transport.sent.single);
    transport.receiveControl(
      VityodControlCodec.encode(
        VityodControlEnvelope(
          method: 'handshake.negotiate.error',
          requestId: request.requestId,
          clientInstanceId: 'daemon',
          idempotencyKey: request.idempotencyKey,
          deadlineUnixMillis: request.deadlineUnixMillis,
          params: const <String, Object?>{
            'errorCode': 'required_capability_unsupported',
            'retryable': false,
          },
        ),
      ),
    );

    await expectLater(
      connect,
      throwsA(
        isA<VityodProtocolException>().having(
          (error) => error.code,
          'code',
          'required_capability_unsupported',
        ),
      ),
    );
    expect(client.state.phase, VityodConnectionPhase.disconnected);
    await client.dispose();
    await transport.dispose();
  });

  test('resume validates a contiguous ordered event digest', () async {
    final transport = MemoryVityodTransport(instanceId: 'daemon-events');
    final client = VityodClient(
      transport: transport,
      clientInstanceId: 'client-events',
    );
    await client.connect();
    final resume = VityodControlCodec.decode(transport.sent.last);
    transport.receiveControl(
      VityodControlCodec.encode(
        VityodControlEnvelope(
          method: 'event.resume.result',
          requestId: resume.requestId,
          clientInstanceId: 'daemon-events',
          idempotencyKey: resume.idempotencyKey,
          deadlineUnixMillis: resume.deadlineUnixMillis,
          params: <String, Object?>{
            'eventCursor': 1,
            'eventDigest': 'bf3851d909f822ed',
            'events': <Object?>[
              <String, Object?>{
                'cursor': 1,
                'kind': 'workspace.transaction.committed',
                'workspaceRevision': 2,
                'payloadBase64': base64Encode(utf8.encode('workspace-commit')),
              },
            ],
            'workspaceRevision': 2,
            'capabilities': const <String>[
              'event.resume',
              'workspace.snapshot',
            ],
            'activeTerminalIds': const <String>[],
            'activeTaskIds': const <String>[],
            'activeAgentSessionIds': const <String>[],
          },
        ),
      ),
    );

    expect(client.state.phase, VityodConnectionPhase.connected);
    expect(client.snapshot?.eventCursor, 1);
    expect(client.snapshot?.events.single.workspaceRevision, 2);
    expect(client.snapshot?.eventDigest, 'bf3851d909f822ed');
    await client.dispose();
    await transport.dispose();
  });

  test('pruned resume requests and accepts one full snapshot', () async {
    final transport = MemoryVityodTransport(instanceId: 'daemon-gap');
    final client = VityodClient(
      transport: transport,
      clientInstanceId: 'client-gap',
    );
    await client.connect();
    final resume = VityodControlCodec.decode(transport.sent.last);
    transport.receiveControl(
      VityodControlCodec.encode(
        VityodControlEnvelope(
          method: 'event.resume.error',
          requestId: resume.requestId,
          clientInstanceId: 'daemon-gap',
          idempotencyKey: resume.idempotencyKey,
          deadlineUnixMillis: resume.deadlineUnixMillis,
          params: const <String, Object?>{
            'errorCode': 'event_cursor_pruned',
            'retryable': true,
            'context': <String, Object?>{'resyncMode': 'full_snapshot'},
          },
        ),
      ),
    );

    expect(client.state.phase, VityodConnectionPhase.resyncRequired);
    expect(client.state.reasonCode, 'event_cursor_pruned');
    await Future<void>.delayed(Duration.zero);
    final snapshotRequest = VityodControlCodec.decode(transport.sent.last);
    expect(snapshotRequest.method, 'snapshot.get');
    transport.receiveControl(
      VityodControlCodec.encode(
        VityodControlEnvelope(
          method: 'snapshot.get.result',
          requestId: snapshotRequest.requestId,
          clientInstanceId: 'daemon-gap',
          idempotencyKey: snapshotRequest.idempotencyKey,
          deadlineUnixMillis: snapshotRequest.deadlineUnixMillis,
          params: const <String, Object?>{
            'eventCursor': 7,
            'eventDigest': 'cbf29ce484222325',
            'events': <Object?>[],
            'workspaceRevision': 3,
            'capabilities': <String>['event.resume', 'workspace.snapshot'],
            'activeTerminalIds': <String>[],
            'activeTaskIds': <String>[],
            'activeAgentSessionIds': <String>[],
            'dirtyBuffers': <Object?>[
              <String, Object?>{
                'documentId': 'main',
                'revision': 2,
                'contents': 'dirty',
              },
            ],
          },
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(client.state.phase, VityodConnectionPhase.connected);
    expect(client.snapshot?.eventCursor, 7);
    expect(client.snapshot?.dirtyBuffers.single.contents, 'dirty');
    await client.dispose();
    await transport.dispose();
  });

  test('buffer outbox is bounded, contiguous, and acknowledgement-driven', () {
    final outbox = BufferDeltaOutbox(maximumPendingDeltas: 2);
    outbox.add(
      const BufferDelta(
        documentId: 'doc',
        baseRevision: 1,
        targetRevision: 2,
        startOffset: 0,
        deletedLength: 0,
        insertedText: 'a',
      ),
    );
    outbox.add(
      const BufferDelta(
        documentId: 'doc',
        baseRevision: 2,
        targetRevision: 3,
        startOffset: 1,
        deletedLength: 0,
        insertedText: 'b',
      ),
    );
    expect(
      () => outbox.add(
        const BufferDelta(
          documentId: 'doc',
          baseRevision: 3,
          targetRevision: 4,
          startOffset: 2,
          deletedLength: 0,
          insertedText: 'c',
        ),
      ),
      throwsStateError,
    );
    outbox.acknowledge(documentId: 'doc', revision: 2);
    expect(outbox.pending.map((delta) => delta.targetRevision), <int>[3]);
  });

  test('stale service snapshot is rejected', () async {
    final client = VityodClient(
      transport: MemoryVityodTransport(),
      clientInstanceId: 'client',
    );
    await client.connect();
    client.acceptSnapshot(
      const VityodServiceSnapshot(
        eventCursor: 4,
        workspaceRevision: 1,
        capabilities: <String>{},
      ),
    );
    expect(
      () => client.acceptSnapshot(
        const VityodServiceSnapshot(
          eventCursor: 3,
          workspaceRevision: 1,
          capabilities: <String>{},
        ),
      ),
      throwsStateError,
    );
    await client.dispose();
  });

  test(
    'request correlates one daemon response and clears it on completion',
    () async {
      final transport = MemoryVityodTransport();
      final client = VityodClient(
        transport: transport,
        clientInstanceId: 'client-request',
      );
      await client.connect();
      final responseFuture = client.request(
        method: 'health.get',
        idempotencyKey: 'health-1',
      );
      final request = VityodControlCodec.decode(transport.sent.last);
      transport.receiveControl(
        VityodControlCodec.encode(
          VityodControlEnvelope(
            method: 'health.get.result',
            requestId: request.requestId,
            clientInstanceId: 'vityod',
            idempotencyKey: request.idempotencyKey,
            deadlineUnixMillis: request.deadlineUnixMillis,
            params: const <String, Object?>{'status': 'ready'},
          ),
        ),
      );

      final response = await responseFuture;
      expect(response.method, 'health.get.result');
      expect(response.params['status'], 'ready');
      await client.dispose();
      await transport.dispose();
    },
  );
}

class _FaultingTransport implements VityodTransport {
  _FaultingTransport() {
    subscription = delegate.incomingControl.listen(control.add);
  }
  final delegate = MemoryVityodTransport();
  final control = StreamController<Uint8List>.broadcast(sync: true);
  late final StreamSubscription<Uint8List> subscription;
  @override
  Stream<Uint8List> get incomingControl => control.stream;
  @override
  Stream<VityodBinaryFrame> get incomingBinary => delegate.incomingBinary;
  @override
  Future<String> connect() => delegate.connect();
  @override
  Future<void> sendControl(Uint8List payload) => delegate.sendControl(payload);
  @override
  Future<void> sendBinary(VityodBinaryFrame frame) =>
      delegate.sendBinary(frame);
  @override
  Future<void> close() => delegate.close();
  @override
  Future<void> dispose() async {
    await subscription.cancel();
    await delegate.dispose();
    await control.close();
  }
}
