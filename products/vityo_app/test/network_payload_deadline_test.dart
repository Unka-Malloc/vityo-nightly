import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/network/network_manager_io.dart';

void main() {
  test(
    'binary payload waits for completion when its deadline is omitted',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestReceived = Completer<void>();
      final releaseBody = Completer<void>();
      server.listen((request) async {
        if (!requestReceived.isCompleted) requestReceived.complete();
        await releaseBody.future;
        request.response.add(const <int>[0x50, 0x41, 0x46, 0x49, 0x4f]);
        await request.response.close();
      });
      addTearDown(() async {
        if (!releaseBody.isCompleted) releaseBody.complete();
        await server.close(force: true);
      });

      final manager = LocalNetworkManager.linuxDebianArmForTest();
      final download = manager.getBytes(
        Uri.parse('http://${server.address.address}:${server.port}/artifact'),
        timeout: null,
      );
      await requestReceived.future;

      final completedBeforeRelease = await Future.any<bool>(<Future<bool>>[
        download.then((_) => true),
        Future<void>.delayed(
          const Duration(milliseconds: 50),
        ).then((_) => false),
      ]);
      expect(completedBeforeRelease, isFalse);

      releaseBody.complete();
      final response = await download;
      expect(response.succeeded, isTrue);
      expect(response.bytes, const <int>[0x50, 0x41, 0x46, 0x49, 0x4f]);
    },
  );
}
