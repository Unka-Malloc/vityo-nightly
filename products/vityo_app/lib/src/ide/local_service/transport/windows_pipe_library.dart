import 'dart:ffi';
import 'dart:io';

const windowsPipeLibraryName = 'vityo_windows_pipe.dll';
const windowsPipeLibraryAbi = 1;
const _configuredLibrary = String.fromEnvironment('VITYO_WINDOWS_PIPE_LIBRARY');
final _bundledProbeLibrary = openWindowsPipeLibrary(bundledOnly: true);

/// Resolves only an explicit absolute test/build path or the application bundle.
/// Never searches the current directory, PATH, or a runtime environment variable.
String windowsPipeLibraryPath(String executable, {String overridePath = ''}) {
  final selected = overridePath.isNotEmpty
      ? overridePath
      : '${executable.substring(0, executable.lastIndexOf(RegExp(r'[\\/]')) + 1)}$windowsPipeLibraryName';
  if (!RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(selected) ||
      selected.substring(2).contains(':') ||
      selected.contains('\u0000')) {
    throw ArgumentError('Windows pipe library requires a drive-absolute path');
  }
  final normalized = Uri.file(
    selected,
    windows: true,
  ).normalizePath().toFilePath(windows: true);
  if (!RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(normalized)) {
    throw ArgumentError('Windows pipe library path escapes its drive root');
  }
  if (normalized.split(RegExp(r'[\\/]')).last.toLowerCase() !=
      windowsPipeLibraryName) {
    throw ArgumentError('Unexpected Windows pipe library filename');
  }
  return normalized;
}

void validateWindowsPipeLibraryAbi(int version) {
  if (version != windowsPipeLibraryAbi) {
    throw StateError('Incompatible Windows pipe library ABI');
  }
}

/// The installed startup probe must inspect the bundle, never a test override.
int verifyBundledWindowsPipeLibrary() {
  // Keep this reference for process lifetime, like the transport binding. A
  // running app may already have function pointers into this same module.
  final version = _bundledProbeLibrary
      .lookupFunction<Uint32 Function(), int Function()>(
        'vityo_pipe_abi_version',
      );
  final result = version();
  validateWindowsPipeLibraryAbi(result);
  return result;
}

DynamicLibrary openWindowsPipeLibrary({bool bundledOnly = false}) {
  final path = windowsPipeLibraryPath(
    Platform.resolvedExecutable,
    overridePath: bundledOnly ? '' : _configuredLibrary,
  );
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('Required Windows pipe library is missing: $path');
  }
  // Resolve links before loading and reject a link redirected to a UNC path.
  final canonical = windowsPipeLibraryPath(
    Platform.resolvedExecutable,
    overridePath: file.resolveSymbolicLinksSync(),
  );
  final library = DynamicLibrary.open(canonical);
  try {
    final version = library.lookupFunction<Uint32 Function(), int Function()>(
      'vityo_pipe_abi_version',
    );
    validateWindowsPipeLibraryAbi(version());
    // Validate the complete ABI before any handle or pending I/O is created.
    for (final symbol in const [
      'vityo_pipe_create_file',
      'vityo_pipe_create_event',
      'vityo_pipe_read',
      'vityo_pipe_write',
      'vityo_pipe_get_result',
    ]) {
      library.lookup<NativeFunction<Void Function()>>(symbol);
    }
  } catch (_) {
    library.close();
    rethrow;
  }
  return library;
}
