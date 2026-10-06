import 'dart:io';

/// Candidate paths for a toolchain component shipped inside the Vityo
/// application package, derived from the running app executable.
///
/// The executable layout mirrors the packaged Pafio and `vityod` components:
///
/// - macOS: `<App>.app/Contents/Helpers/<component>`
/// - Windows: `<app directory>/components/<component>.exe`
/// - Linux: `<app directory>/components/<component>`
///
/// [executablePath] defaults to [Platform.resolvedExecutable] and
/// [operatingSystem] to [Platform.operatingSystem]; both are injectable so
/// callers (and tests) can resolve the bundle layout hermetically. Paths are
/// normalized to forward slashes, which Windows accepts for execution.
List<String> bundledToolchainCandidatePaths(
  String componentName, {
  String? executablePath,
  String? operatingSystem,
}) {
  if (componentName.isEmpty) {
    return const <String>[];
  }
  final executable = _normalize(executablePath ?? Platform.resolvedExecutable);
  if (executable.isEmpty) {
    return const <String>[];
  }
  final packageRoot = bundledApplicationPackageRoot(
    executablePath: executable,
    operatingSystem: operatingSystem,
  );
  if (packageRoot == null || packageRoot.isEmpty) {
    return const <String>[];
  }
  final os = (operatingSystem ?? Platform.operatingSystem).toLowerCase();
  if (os == 'macos') {
    return <String>['$packageRoot/Contents/Helpers/$componentName'];
  }
  if (os == 'windows') {
    return <String>[
      '$packageRoot/components/${_withWindowsExtension(componentName)}',
    ];
  }
  return <String>['$packageRoot/components/$componentName'];
}

/// Root of the installed desktop bundle, derived from its running executable.
String? bundledApplicationPackageRoot({
  String? executablePath,
  String? operatingSystem,
}) {
  final executable = _normalize(executablePath ?? Platform.resolvedExecutable);
  if (executable.isEmpty) {
    return null;
  }
  final appDirectory = _parentDirectory(executable);
  if (appDirectory.isEmpty) {
    return null;
  }
  final os = (operatingSystem ?? Platform.operatingSystem).toLowerCase();
  if (os != 'macos') {
    return appDirectory;
  }
  final contentsDirectory = _parentDirectory(appDirectory);
  if (contentsDirectory.isEmpty) {
    return null;
  }
  final packageRoot = _parentDirectory(contentsDirectory);
  return packageRoot.isEmpty ? null : packageRoot;
}

/// App-relative Pafio manifest used to locate the shipped executable.
String? bundledPafioComponentManifestPath({
  String? executablePath,
  String? operatingSystem,
}) {
  final packageRoot = bundledApplicationPackageRoot(
    executablePath: executablePath,
    operatingSystem: operatingSystem,
  );
  if (packageRoot == null) {
    return null;
  }
  final os = (operatingSystem ?? Platform.operatingSystem).toLowerCase();
  final relativePath = os == 'macos'
      ? 'Contents/Resources/pafio-component.json'
      : 'components/pafio-component.json';
  return '$packageRoot/$relativePath';
}

String _withWindowsExtension(String componentName) {
  return RegExp(r'\.exe$', caseSensitive: false).hasMatch(componentName)
      ? componentName
      : '$componentName.exe';
}

String _normalize(String path) {
  return path.replaceAll('\\', '/');
}

String _parentDirectory(String path) {
  final separator = path.lastIndexOf('/');
  if (separator < 0) {
    return '';
  }
  if (separator == 0) {
    return '/';
  }
  return path.substring(0, separator);
}
