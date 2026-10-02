import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_render/workbench_demo/workbench_demo.dart';

/// Headless state captures of the step-row workbench demo: the tester drives
/// the WorkbenchController directly — no OS mouse, no window focus — and the
/// golden machinery renders each state to a PNG beside the web reference shots.
///
/// Why matchesGoldenFile instead of RepaintBoundary.toImage by hand: after an
/// engine-completed await (toImage/toByteData) the fake-async zone has no
/// flusher on the stack, so the next tester.pump parks forever. The golden
/// path's test-channel round-trip re-enters the harness, which flushes the
/// zone — the one capture pattern proven to survive capture→pump→capture.
///
/// Run with: flutter test test/workbench_demo_capture_test.dart --update-goldens
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('captures workbench demo states', (tester) async {
    await _loadDemoFonts();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(const WorkbenchDemoApp());
    await tester.pump();
    final dynamic page = tester.state(find.byType(WorkbenchPage));
    final dynamic c = page.controller; // WorkbenchController

    await tester.pump(const Duration(milliseconds: 200));
    await _capture('desktop'); // the generated FLOW board, at rest

    // ignore: unawaited_futures
    c.run();
    await tester.pump(const Duration(milliseconds: 900));
    await _capture('running'); // pulses riding the cables
    await tester.pump(const Duration(milliseconds: 1800)); // fault latches at step 11
    await _capture('held');

    c.setBpm(40.0); // the microscope: slow enough to watch a signal think
    // ignore: unawaited_futures
    c.run(); // the key now says REPLAY
    await tester.pump(const Duration(milliseconds: 1200));
    await _capture('replay');
    await tester.pump(const Duration(milliseconds: 4200)); // re-latched

    c.setBpm(128.0);
    c.clearLoop();
    c.setNotation(false);
    await tester.pump(const Duration(milliseconds: 300));
    await _capture('source');

    c.authorize();
    await tester.pump(const Duration(milliseconds: 900));
    await _capture('authorized');

    c.openFile('util.styio');
    c.setNotation(true);
    await tester.pump(const Duration(milliseconds: 300));
    await _capture('util-flow');
  }, timeout: const Timeout(Duration(minutes: 4)));
}

const String _reviewDir = '../../../.impeccable/review';

Future<void> _capture(String name) async {
  await expectLater(
    find.byKey(const ValueKey<String>('machineCapture')),
    matchesGoldenFile('$_reviewDir/flutter-$name.png'),
  );
}

Future<void> _loadDemoFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.view(File(path).readAsBytesSync().buffer);
  // the tester disables asset fonts; register every bundled face by hand.
  // Fallback chains (Jakarta→Condensed, Plex→Azeret, CJK→PingFang) resolve
  // only on a real OS font manager — headless gets exact family matches only,
  // so Chinese labels stay tofu here; the live window is the truth for those.
  final Map<String, List<String>> faces = <String, List<String>>{
    'IBM Plex Mono': <String>[
      'assets/fonts/plex/IBMPlexMono-Regular.ttf',
      'assets/fonts/plex/IBMPlexMono-Medium.ttf',
      'assets/fonts/plex/IBMPlexMono-SemiBold.ttf',
    ],
    'IBM Plex Sans Condensed': <String>[
      'assets/fonts/plex/IBMPlexSansCondensed-SemiBold.ttf',
      'assets/fonts/plex/IBMPlexSansCondensed-Bold.ttf',
    ],
    'Plus Jakarta Sans': <String>[
      'assets/fonts/PlusJakartaSans-400.ttf',
      'assets/fonts/PlusJakartaSans-500.ttf',
      'assets/fonts/PlusJakartaSans-600.ttf',
      'assets/fonts/PlusJakartaSans-700.ttf',
      'assets/fonts/PlusJakartaSans-800.ttf',
    ],
    'Azeret Mono': <String>[
      'assets/fonts/AzeretMono-400.ttf',
      'assets/fonts/AzeretMono-500.ttf',
      'assets/fonts/AzeretMono-600.ttf',
    ],
  };
  for (final MapEntry<String, List<String>> family in faces.entries) {
    final FontLoader loader = FontLoader(family.key);
    for (final String path in family.value) {
      loader.addFont(bytes(path));
    }
    await loader.load();
  }
}
