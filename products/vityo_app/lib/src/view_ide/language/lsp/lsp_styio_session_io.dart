import 'dart:async';

import '../../../ide/local_service/vityod_client.dart';
import '../../../ide/local_service/vityod_lsp_gateway.dart';
import 'lsp_process_transport.dart';
import 'lsp_transport.dart';
import 'lsp_vityod_transport.dart';

/// Starts a `styio_lspd` byte session, preferring the vityod-owned process and
/// falling back to a direct child process when vityod is unavailable.
Future<LspByteTransport> createPlatformStyioLspTransport({
  required String executablePath,
  String? workingDirectory,
  Map<String, String> environment = const <String, String>{},
  bool preferVityod = true,
}) async {
  if (preferVityod) {
    final client = await _tryVityodClient();
    if (client != null) {
      try {
        final session = await VityodLspGateway(client: client).start(
          executable: executablePath,
          workingDirectory: workingDirectory,
          environment: environment,
        );
        return _OwnedVityodLspTransport(
          inner: VityodLspTransport(session: session),
          client: client,
        );
      } on Object {
        await client.dispose();
      }
    }
  }
  return startProcessLspTransport(
    executable: executablePath,
    workingDirectory: workingDirectory,
    environment: environment,
  );
}

Future<VityodClient?> _tryVityodClient() async {
  try {
    return await createPlatformVityodClient();
  } on Object {
    return null;
  }
}

class _OwnedVityodLspTransport implements LspByteTransport {
  _OwnedVityodLspTransport({required this.inner, required this.client});

  final VityodLspTransport inner;
  final VityodClient client;

  @override
  Stream<List<int>> get input => inner.input;

  @override
  Future<void> write(List<int> bytes) => inner.write(bytes);

  @override
  Future<void> close() async {
    await inner.close();
    await client.dispose();
  }
}
