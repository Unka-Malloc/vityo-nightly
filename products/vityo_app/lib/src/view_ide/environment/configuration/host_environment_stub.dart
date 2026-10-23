Map<String, String> Function() _hostEnvironmentProvider = () =>
    const <String, String>{};

/// Overrides the environment observed by [readHostEnvironment]. Passing null
/// restores the empty web environment.
void debugOverrideHostEnvironment(Map<String, String>? environment) {
  _hostEnvironmentProvider = environment == null
      ? () => const <String, String>{}
      : () => Map<String, String>.unmodifiable(environment);
}

Map<String, String> readHostEnvironment() {
  return Map<String, String>.unmodifiable(_hostEnvironmentProvider());
}
