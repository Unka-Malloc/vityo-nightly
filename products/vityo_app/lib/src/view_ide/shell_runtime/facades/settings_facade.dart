part of '../shell_runtime_model.dart';

/// Public settings facade backed by the settings domain controller.
mixin ShellRuntimeSettingsFacade on ShellRuntimeFacadeHost {
  VityoThemeOverride get themeOverride => _settingsController.themeOverride;
  CommandPaletteLivePreferenceController
  get commandPalettePreferenceController =>
      _settingsController.commandPalettePreferenceController;

  PlatformManagerHealthSnapshot? get platformManagerHealth =>
      _settingsController.platformManagerHealth;

  PlatformManagerSettingsSurface? get platformManagerSettingsSurface =>
      _settingsController.platformManagerSettingsSurface;

  CredentialStorageSettingsSurface? get credentialStorageSettingsSurface =>
      _settingsController.credentialStorageSettings;

  PlatformManagerRecoveryActionRoute? get lastPlatformRecoveryRoute =>
      _settingsController.lastPlatformRecoveryRoute;

  bool get platformManagerProbeRunning =>
      _settingsController.platformManagerProbeRunning;

  Future<PlatformManagerHealthSnapshot?> refreshPlatformManagerHealth() =>
      _settingsController.refreshPlatformManagerHealth();

  void handlePlatformRecoveryRoute(PlatformManagerRecoveryActionRoute route) =>
      _settingsController.handlePlatformRecoveryRoute(route);

  void selectPlatformSettingsSection(String sectionId) =>
      _settingsController.selectPlatformSettingsSection(sectionId);

  Future<void> loadThemeOverride({String key = 'default'}) =>
      _settingsController.loadThemeOverride(key: key);

  Future<void> saveThemeOverride(
    VityoThemeOverride override, {
    String key = 'default',
  }) => _settingsController.saveThemeOverride(override, key: key);

  CommandPaletteDisplayPreferences get commandPalettePreferences =>
      _settingsController.commandPalettePreferences;

  Future<CommandPaletteDisplayPreferences> loadCommandPalettePreferences({
    String? workspaceId,
  }) => _settingsController.loadCommandPalettePreferences(
    workspaceId: workspaceId,
  );

  Future<void> saveCommandPalettePreferences(
    CommandPaletteDisplayPreferences preferences,
  ) => _settingsController.saveCommandPalettePreferences(preferences);
}
