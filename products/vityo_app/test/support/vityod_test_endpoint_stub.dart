/// Hosts without `dart:io` cannot start a local `vityod` child process.
final class VityodTestEndpoint {
  const VityodTestEndpoint();

  bool get isSupported => false;

  String get daemonExecutableName => 'vityod';

  List<String> bundledCandidates(String resolvedExecutablePath) =>
      const <String>[];

  String pathFor(String workspaceDirectory) => throw UnsupportedError(
    'Local vityod endpoints are unavailable on this platform.',
  );

  Future<void> waitUntilServing(String endpoint) async => throw UnsupportedError(
    'Local vityod endpoints are unavailable on this platform.',
  );
}
