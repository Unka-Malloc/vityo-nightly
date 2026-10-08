import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vityo_app/src/ide/local_service/vityod_client.dart';

import 'vityod_test_endpoint.dart';

/// Drives a real `vityod` child process for tests.
///
/// Endpoint naming, bundled component naming and the readiness probe are
/// host-specific and live in [VityodTestEndpoint]; this class stays free of
/// host conditionals.
class VityodTestHarness {
  VityodTestHarness._({
    required this.client,
    required Process daemon,
    required Directory directory,
  }) : _daemon = daemon,
       _directory = directory;

  static const VityodTestEndpoint _endpoint = VityodTestEndpoint();

  final VityodClient client;
  final Process _daemon;
  final Directory _directory;

  static bool get isSupported => _endpoint.isSupported;

  static Future<VityodTestHarness> start({
    required String clientId,
    File? executableOverride,
  }) async {
    final executable = executableOverride ?? _findExecutable();
    if (!executable.existsSync()) {
      throw StateError(
        'Build the focused vityod Cargo target before running this test.',
      );
    }
    final directory = await Directory.systemTemp.createTemp('vd-test-');
    final stateDirectory = Directory('${directory.path}/state');
    await stateDirectory.create(recursive: true);
    final endpointPath = _endpoint.pathFor(directory.path);
    final daemon = await Process.start(executable.path, <String>[
      '--serve',
      '--endpoint',
      endpointPath,
      '--state-dir',
      stateDirectory.path,
    ]);
    final daemonLog = <String>[];
    for (final stream in <Stream<List<int>>>[daemon.stdout, daemon.stderr]) {
      unawaited(
        stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach(daemonLog.add),
      );
    }
    try {
      try {
        await _endpoint.waitUntilServing(endpointPath);
      } on TimeoutException catch (error) {
        final tail = daemonLog.length > 10
            ? daemonLog.sublist(daemonLog.length - 10)
            : daemonLog;
        throw TimeoutException(
          '${error.message} (vityod output: ${tail.join(' | ')})',
        );
      }
      final client = VityodClient(
        transport: SocketVityodTransport(endpointPath: endpointPath),
        clientInstanceId: clientId,
      );
      await client.connect();
      return VityodTestHarness._(
        client: client,
        daemon: daemon,
        directory: directory,
      );
    } on Object {
      daemon.kill();
      await daemon.exitCode.timeout(const Duration(seconds: 5));
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> close() async {
    await client.dispose();
    _daemon.kill();
    await _daemon.exitCode.timeout(const Duration(seconds: 5));
    await _directory.delete(recursive: true);
  }
}

File _findExecutable() {
  final name = VityodTestHarness._endpoint.daemonExecutableName;
  for (final candidate
      in VityodTestHarness._endpoint.bundledCandidates(
        Platform.resolvedExecutable,
      )) {
    final bundled = File(candidate);
    if (bundled.existsSync()) return bundled;
  }
  var directory = Directory.current.absolute;
  for (var depth = 0; depth < 12; depth += 1) {
    final candidate = File(
      '${directory.path}/native/vityod/target/debug/$name',
    );
    if (candidate.existsSync()) return candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return File('native/vityod/target/debug/$name');
}
