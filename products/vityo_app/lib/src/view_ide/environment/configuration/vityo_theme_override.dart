enum VityoThemePreset { obsidian, parchment, graphite }

class VityoThemeOverride {
  const VityoThemeOverride({
    this.preset,
    this.canvas,
    this.panel,
    this.ink,
    this.accent,
    this.muted,
  });

  final String? preset;
  final int? canvas;
  final int? panel;
  final int? ink;
  final int? accent;
  final int? muted;

  VityoThemePreset? get presetValue {
    final name = preset;
    if (name == null) {
      return null;
    }
    for (final value in VityoThemePreset.values) {
      if (value.name == name) {
        return value;
      }
    }
    return null;
  }

  VityoThemeOverride copyWith({
    String? preset,
    int? canvas,
    int? panel,
    int? ink,
    int? accent,
    int? muted,
  }) {
    return VityoThemeOverride(
      preset: preset ?? this.preset,
      canvas: canvas ?? this.canvas,
      panel: panel ?? this.panel,
      ink: ink ?? this.ink,
      accent: accent ?? this.accent,
      muted: muted ?? this.muted,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (preset != null) 'preset': preset,
      if (canvas != null) 'canvas': canvas,
      if (panel != null) 'panel': panel,
      if (ink != null) 'ink': ink,
      if (accent != null) 'accent': accent,
      if (muted != null) 'muted': muted,
    };
  }

  factory VityoThemeOverride.fromJson(Map<String, Object?> json) {
    return VityoThemeOverride(
      preset: json['preset'] is String ? json['preset'] as String : null,
      canvas: _colorFromJson(json['canvas']),
      panel: _colorFromJson(json['panel']),
      ink: _colorFromJson(json['ink']),
      accent: _colorFromJson(json['accent']),
      muted: _colorFromJson(json['muted']),
    );
  }
}

int? _colorFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is String) {
    final raw = value.trim();
    final hex = raw.startsWith('#') ? raw.substring(1) : raw;
    if (hex.length == 6) {
      return int.tryParse('FF$hex', radix: 16);
    }
    if (hex.length == 8) {
      return int.tryParse(hex, radix: 16);
    }
  }
  return null;
}
