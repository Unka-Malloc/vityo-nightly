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

  Future<void> waitUntilServing(
    String endpoint, {
    Future<int>? processExit,
  }) async {
    int? exited;
    unawaited(
      processExit?.then((code) {
        exited = code;
      }),
    );
    if (Platform.isWindows) {
      await _waitForNamedPipe(endpoint, () => exited);
      return;
    }
    await _waitForUnixSocket(endpoint, () => exited);
  }

  Future<void> _waitForUnixSocket(
    String endpoint,
    int? Function() exited,
  ) async {
    while (true) {
      try {
        final probe = await Socket.connect(
          InternetAddress(endpoint, type: InternetAddressType.unix),
          0,
        );
        probe.destroy();
        return;
      } on SocketException {
        if (exited() != null) {
          throw StateError(
            'vityod exited before creating its endpoint: ${exited()}',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  }

  /// A named pipe reports `ERROR_FILE_NOT_FOUND` before the daemon creates it,
  /// so readiness is probed by opening and immediately closing a connection.
  Future<void> _waitForNamedPipe(
    String endpoint,
    int? Function() exited,
  ) async {
    while (true) {
      try {
        final probe = await WindowsNamedPipeConnection.connect(endpoint);
        await probe.close();
        return;
      } on WindowsNamedPipeUnavailable {
        if (exited() != null) {
          throw StateError(
            'vityod exited before creating its endpoint: ${exited()}',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }
}
