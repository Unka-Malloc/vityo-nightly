/// The native directory chooser Flow Hero's workspace switch opens.
///
/// `file_selector` is the Flutter first-party picker; `getDirectoryPath` maps
/// to `NSOpenPanel` on macOS, and to the platform's own directory chooser
/// elsewhere. The chooser is the only place Flow Hero asks the host for a path,
/// and it never decides anything: the controller adopts whatever path comes
/// back and persists it.
///
/// A host without a picker implementation (unit tests, unsupported platforms)
/// answers null instead of throwing at the call site, so a missing chooser
/// reads as "the user cancelled" rather than a crash.
library;

import 'package:file_selector/file_selector.dart';

/// Opens the platform directory chooser, seeded at [currentRoot] when one is
/// known. Returns the chosen absolute path, or null when the user cancels or no
/// chooser is available.
Future<String?> pickFlowHeroWorkspaceDirectory(String currentRoot) async {
  final String initial = currentRoot.trim();
  try {
    final String? path = await getDirectoryPath(
      initialDirectory: initial.isEmpty ? null : initial,
      confirmButtonText: '选择工作区',
    );
    final String trimmed = (path ?? '').trim();
    return trimmed.isEmpty ? null : trimmed;
  } on Object {
    return null;
  }
}
