import 'dart:io' as io;

Map<String, String> Function() _hostEnvironmentProvider = () =>
    io.Platform.environment;

/// Overrides the environment observed by [readHostEnvironment].
///
/// Tests use it to plant `VITYO_*` toolchain overrides without mutating the
/// real process environment. Passing null restores `Platform.environment`.
void debugOverrideHostEnvironment(Map<String, String>? environment) {
  _hostEnvironmentProvider = environment == null
      ? () => io.Platform.environment
      : () => Map<String, String>.unmodifiable(environment);
}

Map<String, String> readHostEnvironment() {
  return Map<String, String>.unmodifiable(_hostEnvironmentProvider());
}
