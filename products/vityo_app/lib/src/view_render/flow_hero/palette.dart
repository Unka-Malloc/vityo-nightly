/// Flow Hero palette: dark values come from the workbench tokens (`C`), light
/// values are the day-mode derivation. One switch, read everywhere as `P.x`.
///
/// Day mode is a warm paper scheme, not a grey film over the dark values:
/// drafting-paper creams with real value separation between room, panel and
/// raised face, warm ink text, milled tan seams, and deep-cut signal lamps
/// (redDeep / orangeDeep / yellowDeep) so the lamp grade reads on paper. The
/// FLOW canvas goes paper too — a light drafting sheet with warm dots — so
/// nothing stays charcoal and clashes with the chrome.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

class P {
  const P._();

  static bool dark = true;

  // ── structure ────────────────────────────────────────────────
  static Color get room => dark ? C.room : const Color(0xFFE7DFCC);
  static Color get panel => dark ? C.panel : const Color(0xFFF6F0E1);
  static Color get panelHi => dark ? C.panelHi : const Color(0xFFFCF9EE);
  static Color get recess => dark ? C.recess : const Color(0xFFE2D9C2);
  static Color get well => dark ? C.well : const Color(0xFFEAE2CD);
  static Color get seamHi => dark ? C.seamHi : const Color(0xFFFFFDEF);
  static Color get seamLo => dark ? C.seamLo : const Color(0xFFB3A888);

  /// The editor bed: charcoal cut in dark mode, a fresh page in day mode.
  static Color get bed => dark ? C.recess : const Color(0xFFF7F2E4);

  // ── canvas (FLOW board) ──────────────────────────────────────
  static Color get canvasTop => dark ? const Color(0xFF0D0D0D) : const Color(0xFFF1EADA);
  static Color get canvasBottom => dark ? const Color(0xFF0A0A0A) : const Color(0xFFE8DFC7);
  static Color get gridDot => dark ? const Color(0xFF1C1C1C) : const Color(0xFFD7CCAC);
  static Color get cableCold => dark ? const Color(0xFF2E2E2E) : const Color(0xFFC2B592);

  /// Hot-lead orange: bright on charcoal, deep cut on paper.
  static Color get hotWire => dark ? C.orange : C.orangeDeep;

  /// Card drop shadow base: black at night, warm umber on paper.
  static Color get cardShadow => dark ? Colors.black : const Color(0xFF6B5732);

  // ── ink ──────────────────────────────────────────────────────
  static Color get bone => dark ? C.bone : const Color(0xFF211B10);
  static Color get paper => dark ? C.paper : const Color(0xFF161105);
  static Color get paperLow => dark ? C.paperLow : const Color(0xFF3A3122);
  static Color get silk => dark ? C.silk : const Color(0xFF7D7259);
  static Color get silkHi => dark ? C.silkHi : const Color(0xFF4A4130);
  static Color get silkDim => dark ? C.silkDim : const Color(0xFFA2967A);

  // ── signal (same lamp grade both modes; deep cuts read on paper) ──
  static Color get red => dark ? C.red : C.redDeep;
  static Color get redBright => dark ? C.redBright : C.redDeep;
  static Color get orange => C.orange;
  static Color get orangeBright => dark ? C.orangeBright : C.orangeDeep;
  static Color get yellow => dark ? C.yellow : C.yellowDeep;
  static Color get yellowBright => dark ? C.yellowBright : C.yellowDeep;

  static Color get ledOff => dark ? C.ledOff : const Color(0xFFCEC3A6);
  static Color get ring => dark ? C.terminalRing : const Color(0xFFA49676);

  /// The gutter's rule line: near-black cut at night, tan seam on paper.
  static Color get gutterRule => dark ? C.gutterRule : seamLo;

  /// Silkscreen label style resolved for the current mode.
  static TextStyle silkStyle({bool hi = false, bool dim = false}) => TextStyle(
        fontFamily: kSans,
        fontFamilyFallback: kSansFallback,
        fontSize: 11,
        height: 14 / 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.32,
        color: hi ? silkHi : (dim ? silkDim : silk),
      );

  static TextStyle monoStyle({Color? color, double size = 11.5}) => TextStyle(
        fontFamily: kMono,
        fontFamilyFallback: kMonoFallback,
        fontSize: size,
        height: 1.65,
        color: color ?? bone,
      );
}
