// Run via scripts/test-windows-dart-pipe.py: every case has a process watchdog.
// Deliberately uses the production connection, never a Dart test double.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vityo_app/src/ide/local_service/transport/windows_named_pipe.dart';
import 'package:vityo_app/src/ide/local_service/transport/socket_transport.dart';

void check(bool value, String reason) {
  if (!value) throw StateError(reason);
}

void phase(String name, [String? scenario]) => stdout.writeln(
  jsonEncode({'phase': name, if (scenario != null) 'case': scenario}),
);

Future<Object?> failure(Future<void> Function() operation) async {
  try {
    await operation();
    return null;
  } catch (error) {
    return error;
  }
}

Future<bool> rejects(Future<void> Function() operation) async =>
    await failure(operation) != null;

void checkAborted(Object? error, String scenario) {
  check(
    error.toString().contains('(Win32 995)'),
    'active write did not complete with ERROR_OPERATION_ABORTED (995): $error',
  );
  phase('active-write-aborted', scenario);
}

Future<void> checkSocketClose(String endpoint) async {
  final transport = SocketVityodTransport(endpointPath: endpoint);
  final controlDone = Completer<void>();
  final binaryDone = Completer<void>();
  transport.incomingControl.listen((_) {}, onDone: controlDone.complete);
  transport.incomingBinary.listen((_) {}, onDone: binaryDone.complete);
  await transport.connect();
  await Future<void>.delayed(const Duration(milliseconds: 250));
  var settled = 0;
  Future<Object?> send(Uint8List payload) async {
    final failed = await failure(() => transport.sendControl(payload));
    settled++;
    return failed;
  }

  final writes = [send(Uint8List(8 * 1024 * 1024)), send(Uint8List(1))];
  await Future<void>.delayed(const Duration(milliseconds: 250));
  check(settled == 0, 'socket writes did not remain pending');
  phase('socket-write-pending');
  final closing = transport.close();
  final repeated = transport.close().then((_) {
    check(
      settled == writes.length,
      'second socket close finished before queued sends settled',
    );
  });
  final reconnectFailure = await failure(() async {
    await transport.connect();
  });
  check(
    reconnectFailure is StateError &&
        reconnectFailure.message == 'transport is already connected',
    'reconnect must be rejected by lifecycle guard, not a busy native pipe',
  );
  await Future.wait([closing, repeated]);
  final failures = await Future.wait(writes);
  check(
    failures.every((error) => error != null),
    'socket queued send survived close',
  );
  checkAborted(failures.first, 'socket-queued-close');
  check(settled == writes.length, 'socket send did not settle');
  check(
    await rejects(() => transport.sendControl(Uint8List(1))),
    'socket send accepted after close',
  );
  await transport.close();
  await transport.dispose();
  await Future.wait([controlDone.future, binaryDone.future]);
}

Future<void> main(List<String> args) async {
  if (!Platform.isWindows || args.length != 3) {
    stderr.writeln('Windows only; invoke the Python watchdog harness');
    exitCode = 2;
    return;
  }
  final scenario = args[0];
  final control = Directory(args[2]);
  try {
    if (scenario == 'socket-queued-close') {
      await checkSocketClose(args[1]);
      phase('passed', scenario);
      return;
    }
    final connection = await WindowsNamedPipeConnection.connect(args[1]);
    final received = StringBuffer();
    final reply = Completer<void>();
    final done = Completer<void>();
    connection.incoming.listen(
      (bytes) {
        received.write(ascii.decode(bytes));
        if (received.toString().contains('pong\n') && !reply.isCompleted) {
          reply.complete();
        }
      },
      onError: (Object error) {
        // EOF/error is acceptable for a disconnected peer; onDone must follow.
      },
      onDone: done.complete,
    );
    phase('connected');
    // Let the production reader submit a read while the server waits for us.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    phase('reader-first');
    if (scenario == 'reader-first') {
      await connection.write(Uint8List.fromList(ascii.encode('ping\n')));
      await reply.future;
      check(received.toString() == 'pong\n', 'incorrect server response');
      await connection.close();
      await done.future;
      await connection.close();
    } else if (scenario == 'peer-disconnect') {
      File('${control.path}/disconnect').writeAsStringSync('disconnect');
      await done.future;
      check(
        await rejects(() => connection.write(Uint8List.fromList([1]))),
        'write after peer disconnect unexpectedly succeeded',
      );
      await connection.close();
      await connection.close();
    } else if (scenario == 'stalled-write' || scenario == 'queued-close') {
      var settled = 0;
      Future<Object?> observe(Uint8List payload) async {
        final failed = await failure(() => connection.write(payload));
        settled++;
        return failed;
      }

      // Well above the server's 4 KiB inbound quota. It never drains the pipe.
      final writes = <Future<Object?>>[observe(Uint8List(8 * 1024 * 1024))];
      if (scenario == 'queued-close') {
        writes.add(observe(Uint8List.fromList([2])));
        writes.add(observe(Uint8List.fromList([3])));
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      check(settled == 0, 'writes did not remain pending before cancellation');
      phase('write-pending');
      final closing = connection.close();
      final repeated = connection.close().then((_) {
        check(
          settled == writes.length,
          'second pipe close finished before queued writes settled',
        );
      });
      await Future.wait([closing, repeated]);
      final failures = await Future.wait(writes);
      check(
        failures.every((error) => error != null),
        'pending or queued write succeeded after cancellation',
      );
      checkAborted(failures.first, scenario);
      check(settled == writes.length, 'unsettled writes after close');
      await done.future;
      check(
        await rejects(() => connection.write(Uint8List.fromList([4]))),
        'write accepted after local close',
      );
      await connection.close();
    } else {
      throw ArgumentError.value(scenario, 'scenario');
    }
    phase('passed', scenario);
    // Do not call exit(): natural exit also verifies no transport isolate or
    // ReceivePort keeps the process alive after successful close.
  } catch (error, stack) {
    stderr.writeln(error);
    stderr.writeln(stack);
    exitCode = 1;
    // A leaked production isolate can prevent exit, so the parent also treats
    // this explicit failure as failure if it subsequently has to kill us.
    phase('failed');
  }
}
