import 'lsp_transport.dart';

Future<LspByteTransport> startProcessLspTransport({
  required String executable,
  List<String> arguments = const <String>[],
  String? workingDirectory,
  Map<String, String> environment = const <String, String>{},
}) {
  throw UnsupportedError(
    'Direct LSP process transport is unavailable on this platform.',
  );
}
