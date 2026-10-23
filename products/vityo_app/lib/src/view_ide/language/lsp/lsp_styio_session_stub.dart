import 'lsp_transport.dart';

Future<LspByteTransport> createPlatformStyioLspTransport({
  required String executablePath,
  String? workingDirectory,
  Map<String, String> environment = const <String, String>{},
  bool preferVityod = true,
}) {
  throw UnsupportedError(
    'styio_lspd sessions are unavailable on this platform.',
  );
}
