import 'host_environment.dart';

/// The non-secret host entries a daemon-launched child needs but cannot infer.
///
/// `vityod` clears the child environment. Keep discovery-only overrides and
/// ambient credentials out of its protocol: [source] may be the full host map,
/// but only this allowlist crosses the boundary. Windows launch essentials
/// SYSTEMROOT, COMSPEC and PATHEXT supplement the home/temp/toolchain entries.
/// Names are canonicalized and deduplicated case-insensitively; conflicting
/// values and credential-shaped values fail closed without echoing the value.
Map<String, String> forwardedHostEnvironment({Map<String, String>? source}) {
  const forwardedKeys = <String>{
    'HOME',
    'USERPROFILE',
    'TMPDIR',
    'TEMP',
    'TMP',
    'FLUTTER_ROOT',
    'PUB_CACHE',
    'DART_SDK',
    'PATH',
    'SYSTEMROOT',
    'COMSPEC',
    'PATHEXT',
  };
  final environment = source ?? readHostEnvironment();
  final forwarded = <String, String>{};
  for (final entry in environment.entries) {
    final key = entry.key.toUpperCase();
    if (!forwardedKeys.contains(key)) continue;
    final lower = entry.value.toLowerCase();
    // Match the daemon's value rejection, not a permissive replacement for it.
    // Never sanitize a credential into a different executable path.
    if (lower.startsWith('bearer ') || lower.contains('access_token=')) {
      throw StateError(
        'Credential-like host environment value denied for $key.',
      );
    }
    final previous = forwarded[key];
    if (previous != null && previous != entry.value) {
      throw StateError('Conflicting host environment values denied for $key.');
    }
    forwarded[key] = entry.value;
  }
  forwarded.removeWhere((_, value) => value.isEmpty);
  return forwarded;
}
