import 'dart:async';
import 'dart:io';

import 'package:vityo_app/src/ide/local_service/transport/windows_named_pipe.dart';

/// Host-specific route from a test harness to a freshly started `vityod`.
///
/// POSIX hosts reach the daemon through a Unix domain socket; Windows reaches
/// it through the daemon's private `\\.\pipe\vityo-` named-pipe namespace.
/// Endpoint naming, bundled component naming and readiness probing are the only
/// host-specific parts, so they live behind this adapter instead of turning the
/// platform-neutral harness into a set of host conditionals.
final class VityodTestEndpoint {
  const VityodTestEndpoint();

  /// The daemon validates this prefix and the 256-character pipe limit.
  static const String _windowsPipePrefix = r'\\.\pipe\vityo-';

  static const Duration _readinessDeadline = Duration(seconds: 15);

  bool get isSupported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  String get daemonExecutableName =>
      Platform.isWindows ? 'vityod.exe' : 'vityod';

  /// Candidate paths for a daemon shipped next to a packaged application.
  List<String> bundledCandidates(String resolvedExecutablePath) {
    final executable = File(resolvedExecutablePath);
    if (Platform.isWindows) {
      return <String>[
        '${executable.parent.path}/components/$daemonExecutableName',
      ];
    }
    if (Platform.isMacOS) {
      return <String>[
        '${executable.parent.parent.path}/Helpers/$daemonExecutableName',
      ];
    }
    return <String>[
      '${executable.parent.path}/components/$daemonExecutableName',
    ];
  }

  String pathFor(String workspaceDirectory) {
    if (!Platform.isWindows) {
      return '$workspaceDirectory/service.sock';
    }
    final sanitized = workspaceDirectory
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final suffix = sanitized.length > 40
        ? sanitized.substring(sanitized.length - 40)
        : sanitized;
    return '$_windowsPipePrefix$suffix';
  }

  Future<void> waitUntilServing(String endpoint) async {
    if (Platform.isWindows) {
      await _waitForNamedPipe(endpoint);
      return;
    }
    await _waitForUnixSocket(endpoint);
  }

  Future<void> _waitForUnixSocket(String endpoint) async {
    final deadline = DateTime.now().add(_readinessDeadline);
    while (true) {
      try {
        final probe = await Socket.connect(
          InternetAddress(endpoint, type: InternetAddressType.unix),
          0,
        );
        probe.destroy();
        return;
      } on SocketException {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('vityod test endpoint was not created');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  }

  /// A named pipe reports `ERROR_FILE_NOT_FOUND` before the daemon creates it,
  /// so readiness is probed by opening and immediately closing a connection.
  Future<void> _waitForNamedPipe(String endpoint) async {
    final deadline = DateTime.now().add(_readinessDeadline);
    while (true) {
      try {
        final probe = await WindowsNamedPipeConnection.connect(endpoint);
        await probe.close();
        return;
      } on WindowsNamedPipeUnavailable {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('vityod test endpoint was not created');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }
}
