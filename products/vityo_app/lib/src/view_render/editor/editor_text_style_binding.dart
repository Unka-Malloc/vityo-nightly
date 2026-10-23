import 'package:flutter/material.dart';

import '../../ide/editor/editor_render_layers.dart';
import '../../view_ide/language/language_contract.dart';
import '../theme/vityo_theme.dart';

class EditorFlutterTextStyleBinding {
  const EditorFlutterTextStyleBinding({
    required this.semanticThemeBinding,
    this.brightness = Brightness.light,
  });

  factory EditorFlutterTextStyleBinding.foundation({
    Brightness brightness = Brightness.light,
  }) {
    return EditorFlutterTextStyleBinding(
      brightness: brightness,
      semanticThemeBinding: EditorSemanticThemeBinding.fromTheme(
        EditorSemanticTheme.foundation(),
      ),
    );
  }

  final EditorSemanticThemeBinding semanticThemeBinding;
  final Brightness brightness;

  TextStyle styleForToken({
    required TextStyle baseStyle,
    required TokenKind tokenKind,
    required SemanticKind? semanticKind,
    required DiagnosticSeverity? diagnosticSeverity,
  }) {
    final dark = brightness == Brightness.dark;
    var color = _tokenColor(tokenKind, dark: dark);
    var weight = tokenKind == TokenKind.whitespace
        ? FontWeight.w400
        : FontWeight.w500;

    final semanticStyle = semanticKind == null
        ? null
        : semanticThemeBinding.styleForSemanticKind(semanticKind);
    if (semanticStyle != null) {
      final colorIsFoundationLightDefault =
          dark &&
          _isFoundationSemanticColor(
            semanticKind!,
            semanticStyle.foregroundColor,
          );
      if (!colorIsFoundationLightDefault) {
        color = Color(semanticStyle.foregroundColor);
      }
      weight = _fontWeightFromWire(semanticStyle.fontWeight, fallback: weight);
    }

    var decoration = TextDecoration.none;
    var decorationColor = color;
    var decorationStyle = TextDecorationStyle.solid;

    if (diagnosticSeverity != null) {
      final diagnosticStyle = semanticThemeBinding.styleForDiagnosticSeverity(
        diagnosticSeverity,
      );
      decoration = TextDecoration.underline;
      decorationStyle = TextDecorationStyle.wavy;
      Color? boundColor;
      if (diagnosticStyle != null) {
        final styleColor =
            diagnosticStyle.decorationColor ?? diagnosticStyle.foregroundColor;
        final colorIsFoundationLightDefault =
            dark &&
            _isFoundationDiagnosticColor(diagnosticSeverity, styleColor);
        if (!colorIsFoundationLightDefault) {
          boundColor = Color(styleColor);
        }
      }
      decorationColor =
          boundColor ??
          Color(_diagnosticColorValue(diagnosticSeverity, dark: dark));
    }

    return baseStyle.copyWith(
      fontFamily: VityoTheme.monoFontFamily,
      color: color,
      fontWeight: weight,
      decoration: decoration,
      decorationColor: decorationColor,
      decorationStyle: decorationStyle,
    );
  }
}

final EditorSemanticTheme _foundationSemanticTheme =
    EditorSemanticTheme.foundation();

bool _isFoundationSemanticColor(SemanticKind kind, int color) {
  return _foundationSemanticTheme.semanticColors[kind.name] == color;
}

bool _isFoundationDiagnosticColor(DiagnosticSeverity severity, int color) {
  return _foundationSemanticTheme.diagnosticUnderlineColors[severity.name] ==
      color;
}

Color _tokenColor(TokenKind tokenKind, {required bool dark}) {
  if (dark) {
    return switch (tokenKind) {
      TokenKind.keyword => const Color(0xFFE0B46A),
      TokenKind.identifier => const Color(0xFFD6DBE1),
      TokenKind.number => const Color(0xFF93CBB8),
      TokenKind.string => const Color(0xFFA7C69B),
      TokenKind.comment => const Color(0xFF6E767F),
      TokenKind.operator => const Color(0xFF91B3D9),
      TokenKind.punctuation => const Color(0xFF8A929B),
      TokenKind.whitespace => const Color(0xFFD6DBE1),
      TokenKind.unknown => const Color(0xFFF2857A),
    };
  }
  return switch (tokenKind) {
    TokenKind.keyword => const Color(0xFF6450A7),
    TokenKind.identifier => const Color(0xFF2C2725),
    TokenKind.number => const Color(0xFF0F7B68),
    TokenKind.string => const Color(0xFFAF5B33),
    TokenKind.comment => const Color(0xFF9A9185),
    TokenKind.operator => const Color(0xFF255A96),
    TokenKind.punctuation => const Color(0xFF6D655E),
    TokenKind.whitespace => const Color(0xFF2C2725),
    TokenKind.unknown => const Color(0xFFCB4D45),
  };
}

int _diagnosticColorValue(DiagnosticSeverity severity, {required bool dark}) {
  if (dark) {
    return switch (severity) {
      DiagnosticSeverity.error => 0xFFF2857A,
      DiagnosticSeverity.warning => 0xFFEFBE6A,
      DiagnosticSeverity.hint => 0xFF82A6D8,
    };
  }
  return switch (severity) {
    DiagnosticSeverity.error => 0xFFCB4D45,
    DiagnosticSeverity.warning => 0xFFD5962A,
    DiagnosticSeverity.hint => 0xFF6980B5,
  };
}

FontWeight _fontWeightFromWire(String value, {required FontWeight fallback}) {
  return switch (value) {
    '100' => FontWeight.w100,
    '200' => FontWeight.w200,
    '300' => FontWeight.w300,
    '400' || 'normal' => FontWeight.w400,
    '500' => FontWeight.w500,
    '600' => FontWeight.w600,
    '700' || 'bold' => FontWeight.w700,
    '800' => FontWeight.w800,
    '900' => FontWeight.w900,
    _ => fallback,
  };
}
