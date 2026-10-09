import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_render/flow_hero/controller.dart';
import 'package:vityo_app/src/view_render/flow_hero/flow_hero.dart';
import 'package:vityo_app/src/view_render/flow_hero/palette.dart';
import 'package:vityo_app/src/view_render/flow_hero/quick_open.dart';
import 'package:vityo_app/src/view_ide/flow_hero/workspace_file_index.dart';

class _FakeIndex implements FlowHeroWorkspaceFileIndex {
  _FakeIndex(this.files);

  final List<String> files;

  @override
  Future<List<String>> listFiles() async => files;
}

/// Flushes the controller's scripted demo timers and tears the tree down, the
/// same ritual the other Flow Hero widget tests use.
Future<void> _drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  late Directory workspace;
  late String alphaPath;
  late String betaPath;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('flow_hero_quick_open_');
    alphaPath = '${workspace.path}/alpha.styio';
    betaPath = '${workspace.path}/beta.txt';
    File(alphaPath).writeAsStringSync('pipeline alpha\n');
    File(betaPath).writeAsStringSync('plain text\n');
  });

  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  Future<FlowHeroController> pumpOverlay(
    WidgetTester tester,
    List<String> files,
  ) async {
    final controller = FlowHeroController(
      workspaceFileIndex: _FakeIndex(files),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FlowHeroQuickOpen(controller: controller)),
      ),
    );
    await tester.pump();
    return controller;
  }

  testWidgets('filters the real file list and opens the chosen file', (
    WidgetTester tester,
  ) async {
    final controller = await pumpOverlay(tester, <String>[alphaPath, betaPath]);

    await tester.enterText(
      find.byKey(const ValueKey('flow-hero-quick-open-input')),
      'beta.txt',
    );
    await tester.pump();

    expect(
      find.byKey(ValueKey<String>('flow-hero-quick-open-result-$betaPath')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('flow-hero-quick-open-result-$alphaPath')),
      findsNothing,
    );

    await tester.runAsync(() async {
      final loaded = Completer<void>();
      void onEngineChanged() {
        if (controller.engine.activeFile.path == betaPath &&
            !loaded.isCompleted) {
          loaded.complete();
        }
      }

      controller.engine.addListener(onEngineChanged);
      try {
        await tester.tap(
          find.byKey(ValueKey<String>('flow-hero-quick-open-result-$betaPath')),
        );
        // Real file I/O must finish before teardown deletes the workspace.
        await loaded.future.timeout(const Duration(seconds: 5));
      } finally {
        controller.engine.removeListener(onEngineChanged);
      }
    });
    await tester.pump();

    expect(controller.activeFile, 'beta.txt');
    expect(controller.engine.activeFile.path, betaPath);
    expect(controller.engine.activeFile.text, 'plain text\n');
    expect(controller.editorMode, isTrue);
    expect(controller.quickOpenVisible, isFalse);

    await _drain(tester);
  });

  testWidgets('an empty workspace shows the honest empty state', (
    WidgetTester tester,
  ) async {
    await pumpOverlay(tester, const <String>[]);

    expect(
      find.byKey(const ValueKey('flow-hero-quick-open-empty')),
      findsOneWidget,
    );
    expect(find.text('工作区没有可打开的文件。'), findsOneWidget);

    await _drain(tester);
  });

  testWidgets('the app opens quick-open from the search box and ⌘K', (
    WidgetTester tester,
  ) async {
    P.dark = true;
    addTearDown(() => P.dark = true);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      FlowHeroApp(
        workspaceFileIndex: _FakeIndex(<String>[alphaPath, betaPath]),
      ),
    );
    await tester.pump();

    expect(find.byType(FlowHeroQuickOpen), findsNothing);

    // The search box is a real control now.
    await tester.tap(find.byKey(const ValueKey('main-title-search-box')));
    await tester.pump();
    await tester.pump();
    expect(find.byType(FlowHeroQuickOpen), findsOneWidget);
    expect(find.textContaining('alpha.styio'), findsWidgets);

    // Escape closes it; ⌘K reopens it.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(FlowHeroQuickOpen), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(find.byType(FlowHeroQuickOpen), findsOneWidget);

    await _drain(tester);
  });
}
