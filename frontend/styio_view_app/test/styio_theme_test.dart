import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:styio_view_app/src/theme/styio_theme.dart';

void main() {
  test('theme override round-trips user layer colors', () {
    const override = StyioThemeOverride(
      canvas: Color(0xFF101820),
      panel: Color(0xFFFAFAFA),
      accent: Color(0xFF00A878),
    );

    final decoded = StyioThemeOverride.fromJson(override.toJson());
    final theme = StyioTheme.light(overrides: decoded);

    expect(decoded.canvas, const Color(0xFF101820));
    expect(decoded.panel, const Color(0xFFFAFAFA));
    expect(decoded.accent, const Color(0xFF00A878));
    expect(theme.scaffoldBackgroundColor, const Color(0xFF101820));
    expect(theme.cardColor, const Color(0xFFFAFAFA));
    expect(theme.colorScheme.primary, const Color(0xFF00A878));
  });

  test('theme override accepts hash colors for persisted JSON payloads', () {
    final override = StyioThemeOverride.fromJson(<String, Object?>{
      'canvas': '#202124',
      'ink': '#F8F9FA',
    });
    final theme = StyioTheme.light(overrides: override);

    expect(theme.scaffoldBackgroundColor, const Color(0xFF202124));
    expect(theme.textTheme.bodyMedium?.color, const Color(0xFFF8F9FA));
  });
}
