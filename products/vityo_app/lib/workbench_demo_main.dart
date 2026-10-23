import 'package:flutter/material.dart';
import 'package:vityo_app/src/view_render/workbench_demo/workbench_demo.dart';

/// Scratch entry point for launching the Sep-30 workbench demo shell
/// directly, without touching the production `main.dart` boot path.
///
/// Run with:
///   flutter run -t lib/workbench_demo_main.dart -d macos
void main() {
  runApp(const WorkbenchDemoApp());
}
