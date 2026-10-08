import 'dart:io';

/// Raw byte peer for the real-daemon DAP transport test on every desktop host.
Future<void> main() async {
  await for (final bytes in stdin) {
    stdout.add(bytes);
    await stdout.flush();
  }
}
