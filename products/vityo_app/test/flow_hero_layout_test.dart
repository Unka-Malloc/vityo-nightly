import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_render/flow_hero/chat_rail.dart';
import 'package:vityo_app/src/view_render/flow_hero/editor_stage.dart';
import 'package:vityo_app/src/view_render/flow_hero/flow_hero.dart';
import 'package:vityo_app/src/view_render/flow_hero/hero_board.dart';
import 'package:vityo_app/src/view_render/flow_hero/palette.dart';
import 'package:vityo_app/src/view_render/flow_hero/rail.dart';
import 'package:vityo_app/src/view_render/flow_hero/run_strip.dart';
import 'package:vityo_app/src/view_render/flow_hero/settings_panel.dart';
import 'package:vityo_app/src/view_render/flow_hero/source_dock.dart';
import 'package:vityo_app/src/view_render/flow_hero/workspace_drawer.dart';

/// The window splits into a main column and an agent column, each a thin
/// 38pt title strip over its content, with a single 1pt seam between them
/// and an invisible 7pt drag sash overlaid on the seam.
void main() {
  testWidgets('split title strips follow the draggable agent-column seam', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const FlowHeroApp());
    // Let the agent bridge fail over to demo mode (no plugins in tests).
    await tester.pump();

    final Finder chatRail = find.byType(ChatRail);
    final Finder seam = find.byKey(const ValueKey('chat-split-line'));
    final Finder sash = find.byKey(const ValueKey('chat-split-handle'));
    final Finder mainStrip = find.byKey(const ValueKey('main-title-strip'));
    final Finder agentStrip = find.byKey(const ValueKey('agent-title-strip'));
    expect(chatRail, findsOneWidget);
    expect(seam, findsOneWidget);
    expect(sash, findsOneWidget);
    expect(mainStrip, findsOneWidget);
    expect(agentStrip, findsOneWidget);

    // Each strip is 38pt at the top of its column. The 1pt seam is the same
    // line for the strips and the content below: it kisses the agent
    // column's left edge and runs the full window height.
    Rect railRect = tester.getRect(chatRail);
    final Rect seamRect = tester.getRect(seam);
    Rect sashRect = tester.getRect(sash);
    expect(tester.getRect(mainStrip).height, 38);
    expect(tester.getRect(agentStrip).height, 38);
    expect(tester.getRect(mainStrip).top, 0);
    expect(tester.getRect(agentStrip).top, 0);
    expect(seamRect.width, 1);
    expect(seamRect.top, 0);
    expect(seamRect.bottom, 800);
    expect(tester.getRect(mainStrip).right, seamRect.left);
    expect(tester.getRect(agentStrip).left, seamRect.right);
    expect(railRect.left, seamRect.right);
    expect(railRect.width, 300);

    // The invisible sash centres on the seam: 3pt over the canvas, the line,
    // 3pt over the agent column.
    expect(sashRect.left, railRect.left - 4);
    expect(sashRect.right, railRect.left + 3);
    expect(sashRect.top, 0);
    expect(sashRect.bottom, 800);

    // The search box keeps equal right/top/bottom margins inside the strip
    // (the strip's bottom hairline is not part of the gap).
    final Finder searchBox = find.byKey(
      const ValueKey('main-title-search-box'),
    );
    expect(searchBox, findsOneWidget);
    final Rect searchRect = tester.getRect(searchBox);
    final Rect mainStripRect = tester.getRect(mainStrip);
    expect(mainStripRect.right - searchRect.right, 6.5);
    expect(searchRect.top - mainStripRect.top, 6.5);
    expect((mainStripRect.bottom - 1) - searchRect.bottom, 6.5);

    // The link lamp alone rides the agent strip's right edge — no repeated
    // peer name; the lamp's tooltip keeps the detail line one hover away.
    final Finder lamp = find.byKey(const ValueKey('agent-status-lamp'));
    expect(lamp, findsOneWidget);
    expect(tester.getRect(lamp).right, tester.getRect(agentStrip).right - 12);
    expect(
      find.descendant(of: agentStrip, matching: find.byType(Text)),
      findsOneWidget, // just the AGENT label itself
    );

    // Right column: conversation above, input box below, header on top.
    final Rect inputRect = tester.getRect(find.byType(TextField));
    expect(inputRect.top, greaterThan(38));
    expect(inputRect.bottom, lessThanOrEqualTo(railRect.bottom));
    expect(tester.getRect(agentStrip).bottom, lessThan(inputRect.top));

    // Left column: navigation rail on the left, canvas to its right.
    final Rect navRect = tester.getRect(find.byType(HeroRail));
    expect(navRect.left, 0);
    expect(navRect.top, 38);

    // Dragging the sash widens/narrows the agent column; the seam and both
    // strips follow.
    await tester.drag(sash, const Offset(-100, 0));
    await tester.pump();
    railRect = tester.getRect(chatRail);
    sashRect = tester.getRect(sash);
    expect(railRect.width, 400);
    expect(railRect.left, tester.getRect(seam).right);
    expect(tester.getRect(agentStrip).left, railRect.left);
    expect(tester.getRect(mainStrip).right, tester.getRect(seam).left);
    expect(sashRect.right, railRect.left + 3);

    await tester.drag(sash, const Offset(50, 0));
    await tester.pump();
    expect(tester.getRect(chatRail).width, 350);

    // The width clamps instead of squeezing the canvas away.
    await tester.drag(sash, const Offset(2000, 0));
    await tester.pump();
    expect(tester.getRect(chatRail).width, 240);
    await tester.drag(sash, const Offset(-2000, 0));
    await tester.pump();
    expect(tester.getRect(chatRail).width, 560);

    // Flush the scripted demo timers, then tear the tree down cleanly.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('editor mode docks the run strip into the main title strip', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const FlowHeroApp());
    await tester.pump();

    // Flow mode: the run strip floats on the canvas, below the title strip.
    final Finder mainStrip = find.byKey(const ValueKey('main-title-strip'));
    expect(
      find.descendant(of: mainStrip, matching: find.byType(RunStrip)),
      findsNothing,
    );
    expect(tester.getRect(find.byType(RunStrip)).top, greaterThan(38));

    // The default canvas has no real workspace buffer, so it honestly projects
    // nothing. Open one to get a real node, then select it: the source dock
    // pops up — a canvas component.
    final Directory workspace = Directory.systemTemp.createTempSync(
      'flow_hero_layout_',
    );
    addTearDown(() {
      if (workspace.existsSync()) workspace.deleteSync(recursive: true);
    });
    final String path = '${workspace.path}/layout.styio';
    File(path).writeAsStringSync(
      'pipeline layoutFlow\nlet staged := source |> normalize\n',
    );
    final HeroBoard board = tester.widget<HeroBoard>(find.byType(HeroBoard));
    // Real file I/O must run outside the widget-test fake clock.
    await tester.runAsync(() => board.controller.engine.openPath(path));
    await tester.pump();
    await tester.tap(find.text('NORMALIZE'));
    await tester.pump();
    expect(find.byType(SourceDock), findsOneWidget);

    // Switch to the editor via the rail.
    await tester.tap(find.byIcon(Icons.code));
    await tester.pump();

    // The run strip docks into the editor's own toolbar, and canvas
    // components (dock included) stay on the canvas.
    final Finder stage = find.byType(EditorStage);
    expect(stage, findsOneWidget);
    expect(find.byType(SourceDock), findsNothing);
    final Finder docked = find.descendant(
      of: stage,
      matching: find.byType(RunStrip),
    );
    expect(docked, findsOneWidget);
    expect(find.byType(RunStrip), findsOneWidget);
    expect(
      find.descendant(of: mainStrip, matching: find.byType(RunStrip)),
      findsNothing,
    );
    expect(find.text('USER_SYNC'), findsOneWidget);
    expect(find.byKey(const ValueKey('main-title-search-box')), findsOneWidget);

    // The docked strip sits with equal 4pt top/bottom/right margins inside
    // the 34pt toolbar (the toolbar's bottom hairline is not part of the
    // gap) — the same rule the main strip's search box follows.
    final Rect toolbarRect = tester.getRect(
      find.byKey(const ValueKey('editor-toolbar')),
    );
    final Rect stripRect = tester.getRect(docked);
    expect(toolbarRect.height, 34);
    expect(stripRect.height, 25);
    expect(stripRect.top - toolbarRect.top, 4);
    expect((toolbarRect.bottom - 1) - stripRect.bottom, 4);
    expect(toolbarRect.right - stripRect.right, 4);

    // The editor's top bar holds no duplicate file tab, no hint text, and
    // no duplicate rail actions — only editor-local ones (save).
    expect(find.text('user_sync.sty'), findsNothing);
    expect(find.textContaining('真实引擎缓冲'), findsNothing);
    expect(
      find.descendant(
        of: stage,
        matching: find.byIcon(Icons.account_tree_outlined),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: stage, matching: find.byIcon(Icons.folder_outlined)),
      findsNothing,
    );
    expect(
      find.descendant(of: stage, matching: find.byIcon(Icons.save_outlined)),
      findsOneWidget,
    );

    // The status strip reports real buffer facts, never a demo label.
    expect(find.text('演示缓冲'), findsNothing);
    expect(find.textContaining(RegExp(r'^\d+ 行 · \d+ B$')), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('workspace drawer resizes by dragging its sash', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const FlowHeroApp());
    await tester.pump();

    // Closed: no sash, zero-width drawer.
    expect(find.byKey(const ValueKey('tree-split-handle')), findsNothing);

    // Open the drawer from the rail and let the reveal animation finish.
    await tester.tap(find.byIcon(Icons.folder_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final Finder drawer = find.byType(WorkspaceDrawer);
    final Finder sash = find.byKey(const ValueKey('tree-split-handle'));
    expect(sash, findsOneWidget);
    expect(tester.getRect(drawer).width, 200);

    // The sash centres on the drawer's right edge and spans its height.
    Rect sashRect = tester.getRect(sash);
    expect(sashRect.left, HeroRail.width + 200 - 3);
    expect(sashRect.top, 38);
    expect(sashRect.bottom, 800);

    // Drag right with frames between events, like a real pointer: the width
    // tracks the pointer exactly — the reveal animation must not smooth (and
    // lag) a live drag. (A compressed tester.drag dispatches start→end with
    // no frame in between, which can only observe the settle.)
    final TestGesture g = await tester.startGesture(tester.getCenter(sash));
    await g.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(tester.getRect(drawer).width, 230);
    await g.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(tester.getRect(drawer).width, 260);
    await g.up();
    await tester.pump();
    sashRect = tester.getRect(sash);
    expect(sashRect.left, HeroRail.width + 260 - 3);

    // Clamps at both ends instead of crushing the canvas or the tree.
    await tester.drag(sash, const Offset(-2000, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getRect(drawer).width, 160);
    await tester.drag(sash, const Offset(2000, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getRect(drawer).width, 420);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('settings panel opens from the rail and switches theme live', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() {
      P.dark = true; // the palette is a process-wide static
    });

    await tester.pumpWidget(const FlowHeroApp());
    await tester.pump();

    expect(find.byType(SettingsPanel), findsNothing);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();

    expect(find.byType(SettingsPanel), findsOneWidget);
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('AGENT 连接'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);

    // The theme switch flips the palette live.
    expect(P.dark, isTrue);
    await tester.tap(find.text('白天'));
    await tester.pump();
    expect(P.dark, isFalse);

    // The ✕ closes the panel.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.byType(SettingsPanel), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('main strip degrades without overflow on a narrow column', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const FlowHeroApp());
    await tester.pump();

    // 800pt window with the default 300pt agent column leaves the main strip
    // ~412pt: the search box steps aside instead of overflowing.
    expect(find.text('搜索命令 / 文件…'), findsNothing);
    expect(find.byKey(const ValueKey('main-title-strip')), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-title-strip')), findsOneWidget);

    // The run strip shrinks with the canvas and reads real execution state —
    // the old hardcoded throughput counter is gone.
    final Finder runStrip = find.byType(RunStrip);
    expect(runStrip, findsOneWidget);
    expect(tester.getRect(runStrip).width, lessThanOrEqualTo(443 - 24));
    expect(find.text('0 EVT/S'), findsNothing);
    expect(find.text('42 EVT/S'), findsNothing);
    expect(find.byKey(const ValueKey('run-strip-missing')), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('main strip and run strip keep full content on wide windows', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const FlowHeroApp());
    await tester.pump();

    expect(find.text('搜索命令 / 文件…'), findsOneWidget);
    // No fake throughput: only the honest execution readout.
    expect(find.text('0 EVT/S'), findsNothing);
    expect(find.text('42 EVT/S'), findsNothing);
    expect(find.byKey(const ValueKey('run-strip-missing')), findsOneWidget);
    // No feature runtime is composed in this widget test, so the strip names
    // the missing execution service instead of booting platform services.
    expect(find.text('未接线 · 未配置执行服务'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
