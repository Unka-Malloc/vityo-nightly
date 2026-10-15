import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:vityo_daemon_protocol/vityo_daemon_protocol.dart';

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
    required this.drains,
  }) : _daemon = daemon,
       _directory = directory;

  static const VityodTestEndpoint _endpoint = VityodTestEndpoint();

  final List<Future<void>> drains;
  final VityodClient client;
  final Process _daemon;
  final Directory _directory;

  static bool get isSupported => _endpoint.isSupported;

  static Future<VityodTestHarness> start({
    required String clientId,
    String? executablePath,
    Directory? evidenceDirectory,
  }) async {
    final executable = executablePath == null
        ? _findExecutable()
        : File(executablePath);
    if (!executable.existsSync()) {
      throw StateError(
        'Build the focused vityod Cargo target before running this test.',
      );
    }
    final directory = await Directory.systemTemp.createTemp('vd-test-');
    final stateDirectory = Directory(
      '${evidenceDirectory?.path ?? directory.path}/daemon-state',
    );
    await stateDirectory.create(recursive: true);
    final endpointPath = _endpoint.pathFor(directory.path);
    final daemon = await Process.start(executable.path, <String>[
      '--serve',
      '--endpoint',
      endpointPath,
      '--state-dir',
      stateDirectory.path,
    ]);
    final drains = <Future<void>>[];
    if (evidenceDirectory != null) {
      await evidenceDirectory.create(recursive: true);
    }
    var streamIndex = 0;
    for (final stream in <Stream<List<int>>>[daemon.stdout, daemon.stderr]) {
      final sink = evidenceDirectory == null
          ? null
          : File(
              '${evidenceDirectory.path}/daemon-${streamIndex++}.log',
            ).openWrite();
      drains.add(
        stream
            .forEach((bytes) {
              sink?.add(bytes);
            })
            .whenComplete(() async {
              await sink?.close();
            }),
      );
    }
    try {
      await _endpoint.waitUntilServing(
        endpointPath,
        processExit: daemon.exitCode,
      );
      final transport = SocketVityodTransport(endpointPath: endpointPath);
      final client = VityodClient(
        transport: evidenceDirectory == null
            ? transport
            : _RecordedTransport(
                transport,
                File(
                  '${evidenceDirectory.path}/daemon-control.jsonl',
                ).openWrite(),
              ),
        clientInstanceId: clientId,
      );
      await client.connect();
      return VityodTestHarness._(
        client: client,
        daemon: daemon,
        directory: directory,
        drains: drains,
      );
    } on Object {
      daemon.kill();
      await daemon.exitCode;
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> close() async {
    await client.dispose();
    _daemon.kill();
    await _daemon.exitCode;
    await Future.wait(drains);
    await _directory.delete(recursive: true);
  }
}

File _findExecutable() {
  final name = VityodTestHarness._endpoint.daemonExecutableName;
  for (final candidate in VityodTestHarness._endpoint.bundledCandidates(
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

/// Exact private control transcript on the existing real transport. This is
/// enabled only by callers that supply an ignored evidence directory.
final class _RecordedTransport implements VityodTransport {
  _RecordedTransport(this.delegate, this.log);
  final VityodTransport delegate;
  final IOSink log;
  bool disposed = false;
  void record(String direction, Uint8List payload) => log.writeln(
    jsonEncode({
      'direction': direction,
      'payload_base64': base64Encode(payload),
    }),
  );
  @override
  Stream<Uint8List> get incomingControl =>
      delegate.incomingControl.map((payload) {
        record('response', payload);
        return payload;
      });
  @override
  Stream<VityodBinaryFrame> get incomingBinary => delegate.incomingBinary;
  @override
  Future<String> connect() => delegate.connect();
  @override
  Future<void> sendControl(Uint8List payload) {
    record('request', payload);
    return delegate.sendControl(payload);
  }

  @override
  Future<void> sendBinary(VityodBinaryFrame frame) =>
      delegate.sendBinary(frame);
  @override
  Future<void> close() => delegate.close();
  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await delegate.dispose();
    await log.close();
  }
}
