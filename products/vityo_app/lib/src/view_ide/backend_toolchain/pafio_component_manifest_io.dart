import 'dart:io';

/// Reads package-owned metadata beside the installed Vityo executable.
Future<String?> readBundledPafioComponentManifest(String path) async {
  try {
    return await File(path).readAsString();
  } on FileSystemException {
    return null;
  }
}
