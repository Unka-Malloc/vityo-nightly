import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_daemon_protocol/vityo_daemon_protocol.dart';
import 'package:vityo_app/src/ide/local_service/vityod_client.dart';

void main() {
  for (final kind in [
    'blocked-send',
    'blocked-response',
    'late-send-error',
    'close-during-send',
    'late-resume-error',
    'late-snapshot',
    'reconnect-late-resume',
  ]) {
    test(kind, () async {
      final t = ControlledTransport();
      final c = VityodClient(transport: t, clientInstanceId: 'test');
      await c.connect();
      final release = Completer<void>();
      Uint8List? sent;
      final unhandled = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(
        () async {
          t.sender = (p) async {
            sent = p;
            if (kind != 'blocked-response') await release.future;
            if (kind == 'late-send-error') throw StateError('late');
          };
          final future = c.request(
            method: 'event.resume',
            idempotencyKey: 'one',
            deadline: const Duration(milliseconds: 40),
          );
          final expected = expectLater(
            future,
            throwsA(
              kind == 'close-during-send'
                  ? isA<StateError>()
                  : isA<TimeoutException>(),
            ),
          );
          if (kind == 'close-during-send') {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            await c.close();
          }
          await expected.timeout(const Duration(seconds: 1));
          if (kind == 'reconnect-late-resume') {
            await c.close();
            t.sender = null;
            await c.connect();
          }
          release.complete();
          await Future<void>.delayed(const Duration(milliseconds: 5));
          if (kind.startsWith('late-') || kind == 'reconnect-late-resume') {
            final request = VityodControlCodec.decode(sent!);
            t.memory.receiveControl(
              VityodControlCodec.encode(
                VityodControlEnvelope(
                  method: kind == 'late-snapshot'
                      ? 'snapshot.get.result'
                      : 'event.resume.error',
                  requestId: request.requestId,
                  clientInstanceId: 'daemon',
                  idempotencyKey: request.idempotencyKey,
                  deadlineUnixMillis: request.deadlineUnixMillis,
                  params: const {
                    'errorCode': 'late',
                    'context': {'resyncMode': 'full_snapshot'},
                  },
                ),
              ),
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
          expect(unhandled, isEmpty);
          expect(
            c.state.phase,
            kind == 'close-during-send'
                ? VityodConnectionPhase.disconnected
                : VityodConnectionPhase.connected,
          );
          await c.dispose();
          done.complete();
        },
        (e, s) {
          unhandled.add(e);
          done.completeError(e, s);
        },
      );
      await done.future.timeout(const Duration(seconds: 2));
    });
  }
  test(
    'resync completion after close cannot change disconnected state',
    () async {
      final t = ControlledTransport();
      final c = VityodClient(transport: t, clientInstanceId: 'resync');
      await c.connect();
      final resume = VityodControlCodec.decode(t.memory.sent.last);
      t.sender = (p) async {};
      t.memory.receiveControl(
        VityodControlCodec.encode(
          VityodControlEnvelope(
            method: 'event.resume.error',
            requestId: resume.requestId,
            clientInstanceId: 'daemon',
            idempotencyKey: resume.idempotencyKey,
            deadlineUnixMillis: resume.deadlineUnixMillis,
            params: const {
              'errorCode': 'pruned',
              'context': {'resyncMode': 'full_snapshot'},
            },
          ),
        ),
      );
      expect(c.state.phase, VityodConnectionPhase.resyncRequired);
      await c.close();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(c.state.phase, VityodConnectionPhase.disconnected);
      await c.dispose();
    },
  );

  test(
    'close retires response received before blocked send completes',
    () async {
      final t = ControlledTransport();
      final c = VityodClient(transport: t, clientInstanceId: 'close');
      await c.connect();
      final release = Completer<void>();
      t.sender = (p) async {
        t.respond(p);
        await release.future;
      };
      final pending = c.request(
        method: 'test',
        idempotencyKey: 'one',
        deadline: const Duration(seconds: 1),
      );
      final checked = expectLater(pending, throwsA(isA<StateError>()));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await c.close();
      release.complete();
      await checked;
      await c.dispose();
    },
  );
  test('expired dispatch reply cannot trigger resync', () async {
    final t = ControlledTransport();
    final c = VityodClient(transport: t, clientInstanceId: 'dispatch');
    await c.connect();
    await c.dispatch(
      method: 'event.resume',
      idempotencyKey: 'expired',
      deadline: const Duration(milliseconds: 10),
    );
    final r = VityodControlCodec.decode(t.memory.sent.last);
    await Future<void>.delayed(const Duration(milliseconds: 25));
    t.memory.receiveControl(
      VityodControlCodec.encode(
        VityodControlEnvelope(
          method: 'event.resume.error',
          requestId: r.requestId,
          clientInstanceId: 'daemon',
          idempotencyKey: r.idempotencyKey,
          deadlineUnixMillis: r.deadlineUnixMillis,
          params: const {'errorCode': 'late'},
        ),
      ),
    );
    expect(c.state.phase, VityodConnectionPhase.connected);
    await c.dispose();
  });

  test('send and response share one total deadline', () async {
    final t = ControlledTransport();
    final c = VityodClient(transport: t, clientInstanceId: 'budget');
    await c.connect();
    t.sender = (p) async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 80),
          () => t.respond(p),
        ),
      );
    };
    await expectLater(
      c.request(
        method: 'test',
        idempotencyKey: 'budget',
        deadline: const Duration(milliseconds: 120),
      ),
      throwsA(isA<TimeoutException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(c.state.phase, VityodConnectionPhase.connected);
    await c.dispose();
  });
}

class ControlledTransport implements VityodTransport {
  final memory = MemoryVityodTransport();
  Future<void> Function(Uint8List)? sender;
  @override
  Stream<Uint8List> get incomingControl => memory.incomingControl;
  @override
  Stream<VityodBinaryFrame> get incomingBinary => memory.incomingBinary;
  @override
  Future<String> connect() => memory.connect();
  @override
  Future<void> sendControl(Uint8List p) =>
      sender?.call(p) ?? memory.sendControl(p);
  @override
  Future<void> sendBinary(VityodBinaryFrame p) => memory.sendBinary(p);
  @override
  Future<void> close() => memory.close();
  @override
  Future<void> dispose() => memory.dispose();
  void respond(Uint8List bytes) {
    final r = VityodControlCodec.decode(bytes);
    memory.receiveControl(
      VityodControlCodec.encode(
        VityodControlEnvelope(
          method: 'test.result',
          requestId: r.requestId,
          clientInstanceId: r.clientInstanceId,
          idempotencyKey: r.idempotencyKey,
          deadlineUnixMillis: r.deadlineUnixMillis,
          params: const {'ok': true},
        ),
      ),
    );
  }
}
