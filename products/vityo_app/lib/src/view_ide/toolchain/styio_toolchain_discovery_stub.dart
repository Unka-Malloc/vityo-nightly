import '../environment/environment.dart';
import 'toolchain_catalog.dart';

/// Catalog id for the discovered `styio_lspd` language server.
const String styioLspDaemonToolchainId = 'local-styio-lsp-daemon';

Future<ToolchainCatalog> createPlatformStyioLanguageToolchainCatalog({
  required PlatformManagerBundle platformManagers,
  Map<String, String> environment = const <String, String>{},
  Iterable<String> candidatePaths = const <String>[],
  String? bundledExecutablePath,
}) async {
  return ToolchainCatalog();
}
