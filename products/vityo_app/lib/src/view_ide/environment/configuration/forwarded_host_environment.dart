import 'host_environment.dart';

/// The host environment entries a daemon-launched child needs but cannot infer.
///
/// `vityod` clears the child environment and applies only what the request
/// supplies, filtering keys by shape. A tool resolves its home directory and
/// toolchain caches from these entries; without them it aborts with a bare
/// non-zero exit or an unresolved home.
Map<String, String> forwardedHostEnvironment() {
  const forwardedKeys = <String>[
    'HOME',
    'USERPROFILE',
    'TMPDIR',
    'TEMP',
    'TMP',
    'FLUTTER_ROOT',
    'PUB_CACHE',
    'DART_SDK',
    'PATH',
  ];
  final environment = readHostEnvironment();
  final forwarded = <String, String>{};
  for (final key in forwardedKeys) {
    final value = environment[key];
    if (value != null && value.isNotEmpty) {
      forwarded[key] = value;
    }
  }
  return forwarded;
}
