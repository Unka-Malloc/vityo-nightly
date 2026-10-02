import 'package:flutter/material.dart';

import '../../view_ide/environment/configuration/vityo_theme_override.dart';

extension VityoThemeOverrideColorX on VityoThemeOverride {
  Color? get canvasColor => canvas != null ? Color(canvas!) : null;
  Color? get panelColor => panel != null ? Color(panel!) : null;
  Color? get inkColor => ink != null ? Color(ink!) : null;
  Color? get accentColor => accent != null ? Color(accent!) : null;
  Color? get mutedColor => muted != null ? Color(muted!) : null;
}

extension VityoThemePresetX on VityoThemePreset {
  Brightness get brightness => switch (this) {
    VityoThemePreset.obsidian => Brightness.dark,
    VityoThemePreset.parchment => Brightness.light,
    VityoThemePreset.graphite => Brightness.light,
  };
}

class VityoTheme {
  static const String uiFontFamily = 'Plus Jakarta Sans';
  static const String monoFontFamily = 'Azeret Mono';

  static TextStyle mono({
    required Color color,
    double fontSize = 12,
    FontWeight fontWeight = FontWeight.w400,
    double height = 1.5,
    double? letterSpacing,
  }) => TextStyle(
    fontFamily: monoFontFamily,
    color: color,
    fontSize: fontSize,
    fontWeight: fontWeight,
    height: height,
    letterSpacing: letterSpacing,
  );

  static ThemeData resolve({
    VityoThemePreset preset = VityoThemePreset.obsidian,
    VityoThemeOverride overrides = const VityoThemeOverride(),
  }) {
    final palette = _paletteForPreset(preset);
    return _build(palette: palette, overrides: overrides);
  }

  static ThemeData light({
    VityoThemePreset preset = VityoThemePreset.parchment,
    VityoThemeOverride overrides = const VityoThemeOverride(),
  }) {
    final palette = switch (preset.brightness) {
      Brightness.light => _paletteForPreset(preset),
      Brightness.dark => _paletteForPreset(VityoThemePreset.parchment),
    };
    return _build(palette: palette, overrides: overrides);
  }

  static ThemeData dark({
    VityoThemeOverride overrides = const VityoThemeOverride(),
  }) {
    return _build(
      palette: _paletteForPreset(VityoThemePreset.obsidian),
      overrides: overrides,
    );
  }

  static ThemeData _build({
    required _Palette palette,
    required VityoThemeOverride overrides,
  }) {
    final canvas = overrides.canvasColor ?? palette.canvas;
    final panel = overrides.panelColor ?? palette.panel;
    final ink = overrides.inkColor ?? palette.ink;
    final accent = overrides.accentColor ?? palette.accent;
    final muted = overrides.mutedColor ?? palette.muted;
    final dark = palette.brightness == Brightness.dark;

    final tokens = dark
        ? VityoWorkbenchTokens.dark(
            canvas: canvas,
            region: panel,
            ink: ink,
            accent: accent,
            muted: muted,
          )
        : VityoWorkbenchTokens.light(
            canvas: canvas,
            region: panel,
            ink: ink,
            accent: accent,
            muted: muted,
          );

    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: palette.brightness,
        ).copyWith(
          primary: accent,
          onPrimary: tokens.onAccent,
          surface: panel,
          onSurface: ink,
          secondary: dark ? tokens.elevated : const Color(0xFFD4CDC1),
        );

    final textTheme = _textTheme(ink: ink, muted: muted);
    final hairlineSide = BorderSide(color: tokens.divider);

    return ThemeData(
      useMaterial3: false,
      brightness: palette.brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: canvas,
      cardColor: panel,
      dividerColor: tokens.divider,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: tokens.hover,
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: accent.withValues(alpha: 0.28),
        selectionHandleColor: accent,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(muted.withValues(alpha: 0.38)),
        trackColor: const WidgetStatePropertyAll(Colors.transparent),
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(999),
        thumbVisibility: const WidgetStatePropertyAll(false),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: panel,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: panel,
        selectedItemColor: accent,
        unselectedItemColor: muted,
      ),
      textTheme: textTheme,
      tabBarTheme: TabBarThemeData(
        labelColor: accent,
        unselectedLabelColor: muted,
      ),
      cardTheme: CardThemeData(
        color: panel,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: hairlineSide,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.transparent,
        selectedColor: tokens.accentSoft,
        disabledColor: tokens.elevated,
        deleteIconColor: muted,
        labelStyle: textTheme.labelSmall ?? const TextStyle(),
        secondaryLabelStyle: textTheme.labelSmall?.copyWith(color: ink),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        side: hairlineSide,
        shape: const StadiumBorder(),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: tokens.elevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: tokens.divider),
        ),
        textStyle: textTheme.labelSmall?.copyWith(color: ink),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: tokens.elevated,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: hairlineSide,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: tokens.elevated,
        elevation: 0,
        textStyle: textTheme.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: hairlineSide,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? tokens.editor : canvas,
        labelStyle: textTheme.labelMedium?.copyWith(color: muted),
        hintStyle: textTheme.bodyMedium?.copyWith(color: muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: hairlineSide,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: hairlineSide,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: accent),
        ),
      ),
      extensions: <ThemeExtension<dynamic>>[tokens, const VityoMotion()],
    );
  }

  static TextTheme _textTheme({required Color ink, required Color muted}) {
    const family = uiFontFamily;
    const base = TextTheme(
      displaySmall: TextStyle(
        fontFamily: family,
        fontSize: 26,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
        height: 1.2,
      ),
      headlineSmall: TextStyle(
        fontFamily: family,
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        height: 1.25,
      ),
      titleLarge: TextStyle(
        fontFamily: family,
        fontSize: 15.5,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        height: 1.3,
      ),
      titleMedium: TextStyle(
        fontFamily: family,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.05,
        height: 1.3,
      ),
      titleSmall: TextStyle(
        fontFamily: family,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      bodyLarge: TextStyle(
        fontFamily: family,
        fontSize: 13,
        fontWeight: FontWeight.w400,
        height: 1.5,
      ),
      bodyMedium: TextStyle(
        fontFamily: family,
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 1.45,
      ),
      bodySmall: TextStyle(
        fontFamily: family,
        fontSize: 10.5,
        fontWeight: FontWeight.w400,
        height: 1.4,
      ),
      labelLarge: TextStyle(
        fontFamily: family,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      labelMedium: TextStyle(
        fontFamily: family,
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
      ),
      labelSmall: TextStyle(
        fontFamily: family,
        fontSize: 10,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.3,
      ),
    );
    final colored = base.apply(bodyColor: ink, displayColor: ink);
    return colored.copyWith(
      bodySmall: colored.bodySmall?.copyWith(color: muted),
    );
  }

  static _Palette _paletteForPreset(VityoThemePreset preset) {
    return switch (preset) {
      VityoThemePreset.obsidian => const _Palette(
        brightness: Brightness.dark,
        canvas: Color(0xFF0F1013),
        panel: Color(0xFF15171B),
        ink: Color(0xFFE9EBED),
        accent: Color(0xFFE6B566),
        muted: Color(0xFF929AA3),
      ),
      VityoThemePreset.parchment => const _Palette(
        brightness: Brightness.light,
        canvas: Color(0xFFF7F4EB),
        panel: Color(0xFFFFFDF5),
        ink: Color(0xFF2D2416),
        accent: Color(0xFFC7522A),
        muted: Color(0xFFA09880),
      ),
      VityoThemePreset.graphite => const _Palette(
        brightness: Brightness.light,
        canvas: Color(0xFFEDEFF2),
        panel: Color(0xFFFFFFFF),
        ink: Color(0xFF1E252B),
        accent: Color(0xFF2F6F73),
        muted: Color(0xFF62717C),
      ),
    };
  }
}

@immutable
final class VityoMotion extends ThemeExtension<VityoMotion> {
  const VityoMotion({
    this.micro = const Duration(milliseconds: 140),
    this.fast = const Duration(milliseconds: 220),
    this.surface = const Duration(milliseconds: 360),
    this.overlay = const Duration(milliseconds: 560),
    this.emphasized = const Cubic(0.32, 0.72, 0.0, 1.0),
    this.standard = const Cubic(0.2, 0.0, 0.0, 1.0),
  });

  final Duration micro;
  final Duration fast;
  final Duration surface;
  final Duration overlay;
  final Curve emphasized;
  final Curve standard;

  static VityoMotion of(BuildContext context) =>
      Theme.of(context).extension<VityoMotion>() ?? const VityoMotion();

  @override
  VityoMotion copyWith({
    Duration? micro,
    Duration? fast,
    Duration? surface,
    Duration? overlay,
    Curve? emphasized,
    Curve? standard,
  }) => VityoMotion(
    micro: micro ?? this.micro,
    fast: fast ?? this.fast,
    surface: surface ?? this.surface,
    overlay: overlay ?? this.overlay,
    emphasized: emphasized ?? this.emphasized,
    standard: standard ?? this.standard,
  );

  @override
  VityoMotion lerp(covariant VityoMotion? other, double t) {
    if (other == null) return this;
    return VityoMotion(
      micro: t < 0.5 ? micro : other.micro,
      fast: t < 0.5 ? fast : other.fast,
      surface: t < 0.5 ? surface : other.surface,
      overlay: t < 0.5 ? overlay : other.overlay,
      emphasized: t < 0.5 ? emphasized : other.emphasized,
      standard: t < 0.5 ? standard : other.standard,
    );
  }
}

@immutable
final class VityoWorkbenchTokens extends ThemeExtension<VityoWorkbenchTokens> {
  const VityoWorkbenchTokens({
    required this.canvas,
    required this.region,
    required this.editor,
    required this.elevated,
    required this.hover,
    required this.selection,
    required this.divider,
    required this.focus,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.success,
    required this.warning,
    required this.error,
    required this.blocked,
  });

  factory VityoWorkbenchTokens.light({
    required Color canvas,
    required Color region,
    required Color ink,
    required Color accent,
    required Color muted,
  }) => VityoWorkbenchTokens(
    canvas: canvas,
    region: region,
    editor: const Color(0xFFFFFEFA),
    elevated: const Color(0xFFFFFFFF),
    hover: ink.withValues(alpha: 0.06),
    selection: accent.withValues(alpha: 0.18),
    divider: ink.withValues(alpha: 0.14),
    focus: accent,
    ink: ink,
    muted: muted,
    accent: accent,
    onAccent: const Color(0xFFFFFFFF),
    accentSoft: accent.withValues(alpha: 0.10),
    success: const Color(0xFF277447),
    warning: const Color(0xFFA35A12),
    error: const Color(0xFFB3261E),
    blocked: const Color(0xFF7A5269),
  );

  factory VityoWorkbenchTokens.dark({
    required Color canvas,
    required Color region,
    required Color ink,
    required Color accent,
    required Color muted,
  }) => VityoWorkbenchTokens(
    canvas: canvas,
    region: region,
    editor: const Color(0xFF101114),
    elevated: const Color(0xFF1B1E24),
    hover: Colors.white.withValues(alpha: 0.05),
    selection: accent.withValues(alpha: 0.18),
    divider: Colors.white.withValues(alpha: 0.055),
    focus: accent,
    ink: ink,
    muted: muted,
    accent: accent,
    onAccent: const Color(0xFF241A05),
    accentSoft: accent.withValues(alpha: 0.12),
    success: const Color(0xFF7CC98E),
    warning: const Color(0xFFEFBE6A),
    error: const Color(0xFFF2857A),
    blocked: const Color(0xFFC79BC8),
  );

  final Color canvas;
  final Color region;
  final Color editor;
  final Color elevated;
  final Color hover;
  final Color selection;
  final Color divider;
  final Color focus;
  final Color ink;
  final Color muted;
  final Color accent;
  final Color onAccent;
  final Color accentSoft;
  final Color success;
  final Color warning;
  final Color error;
  final Color blocked;

  static VityoWorkbenchTokens of(BuildContext context) =>
      Theme.of(context).extension<VityoWorkbenchTokens>() ??
      fallbackFor(Theme.brightnessOf(context));

  /// Token set for contexts that never installed the Vityo theme (bare
  /// `MaterialApp` harnesses, widget-unit tests).
  static VityoWorkbenchTokens fallbackFor(Brightness brightness) {
    return switch (brightness) {
      Brightness.dark => VityoWorkbenchTokens.dark(
        canvas: const Color(0xFF0F1013),
        region: const Color(0xFF15171B),
        ink: const Color(0xFFE9EBED),
        accent: const Color(0xFFE6B566),
        muted: const Color(0xFF929AA3),
      ),
      Brightness.light => VityoWorkbenchTokens.light(
        canvas: const Color(0xFFF7F4EB),
        region: const Color(0xFFFFFDF5),
        ink: const Color(0xFF2D2416),
        accent: const Color(0xFFC7522A),
        muted: const Color(0xFFA09880),
      ),
    };
  }

  @override
  VityoWorkbenchTokens copyWith({
    Color? canvas,
    Color? region,
    Color? editor,
    Color? elevated,
    Color? hover,
    Color? selection,
    Color? divider,
    Color? focus,
    Color? ink,
    Color? muted,
    Color? accent,
    Color? onAccent,
    Color? accentSoft,
    Color? success,
    Color? warning,
    Color? error,
    Color? blocked,
  }) => VityoWorkbenchTokens(
    canvas: canvas ?? this.canvas,
    region: region ?? this.region,
    editor: editor ?? this.editor,
    elevated: elevated ?? this.elevated,
    hover: hover ?? this.hover,
    selection: selection ?? this.selection,
    divider: divider ?? this.divider,
    focus: focus ?? this.focus,
    ink: ink ?? this.ink,
    muted: muted ?? this.muted,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    accentSoft: accentSoft ?? this.accentSoft,
    success: success ?? this.success,
    warning: warning ?? this.warning,
    error: error ?? this.error,
    blocked: blocked ?? this.blocked,
  );

  @override
  VityoWorkbenchTokens lerp(covariant VityoWorkbenchTokens? other, double t) {
    if (other == null) return this;
    return VityoWorkbenchTokens(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      region: Color.lerp(region, other.region, t)!,
      editor: Color.lerp(editor, other.editor, t)!,
      elevated: Color.lerp(elevated, other.elevated, t)!,
      hover: Color.lerp(hover, other.hover, t)!,
      selection: Color.lerp(selection, other.selection, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      focus: Color.lerp(focus, other.focus, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      error: Color.lerp(error, other.error, t)!,
      blocked: Color.lerp(blocked, other.blocked, t)!,
    );
  }
}

class _Palette {
  const _Palette({
    required this.brightness,
    required this.canvas,
    required this.panel,
    required this.ink,
    required this.accent,
    required this.muted,
  });

  final Brightness brightness;
  final Color canvas;
  final Color panel;
  final Color ink;
  final Color accent;
  final Color muted;
}
