import 'package:flutter/material.dart' hide Chip;
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_render/workbench_demo/flow_model.dart';
import 'package:vityo_app/src/view_render/workbench_demo/machine.dart';
import 'package:vityo_app/src/view_render/workbench_demo/workbench_demo.dart';

/// The workbench's real behaviours, driven at 1440x900 through the widgets the
/// operator actually touches: the notation tablist, the editor's buffer, the
/// analyzer, the interlock, the transport and the rail.
void main() {
  WorkbenchController controllerOf(WidgetTester tester) =>
      tester.widget<Machine>(find.byType(Machine)).controller;

  /// The machine at a desktop size. It runs wider than the review capture on
  /// purpose: the test font is not the shipped face, so silkscreen labels
  /// measure wider here than they do on the panel.
  Future<void> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const WorkbenchDemoApp());
    await tester.pump(const Duration(milliseconds: 60));
  }

  testWidgets('the machine comes up on FLOW with the entry file projected', (WidgetTester tester) async {
    await boot(tester);

    final WorkbenchController c = controllerOf(tester);
    expect(c.showFlow, isTrue);
    expect(c.activeFile.name, 'main.styio');
    expect(c.tail, 'Styio · Graph · main.styio');
    expect(c.armedCount, 16);
    expect(c.status, 'LOOP IDLE');
    expect(c.bpm, 128);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SOURCE is a real buffer: the analyzer marks it and the fix clears it', (WidgetTester tester) async {
    await boot(tester);

    final WorkbenchController c = controllerOf(tester);
    await tester.tap(find.text('SOURCE'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(c.showFlow, isFalse);
    expect(c.tail, 'main.styio · 11 lines · LF');
    expect(c.activeDiags.single.ident, 'routeIn');
    // the finding reaches the panel: a wavy underline, a gutter lamp and the strip
    expect(find.textContaining('routeIn 从未被消费'), findsOneWidget);

    // the fix, typed into the buffer the way an operator types it
    await tester.enterText(
      find.byType(TextField),
      kMainStyio.replaceFirst('  emit staged', '  emit staged\n  emit routeIn'),
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(c.activeDiags, isEmpty);
    expect(c.mainDiags, isEmpty);
    expect(find.textContaining('从未被消费'), findsNothing);
    expect(c.tail, 'main.styio · 12 lines · LF');

    // the graph answers: the input route seats in the target's underside
    final BoardRoute route = c.graph.routes.single;
    expect(route.bare, isFalse);
    expect(route.endY, 156);
    expect(c.graph.strays, isEmpty);
    expect(c.graph.chips.any((Chip chip) => chip.label == 'routeIn'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a clean buffer passes all sixteen steps', (WidgetTester tester) async {
    await boot(tester);

    final WorkbenchController c = controllerOf(tester);
    await tester.tap(find.text('SOURCE'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.enterText(
      find.byType(TextField),
      kMainStyio.replaceFirst('  emit staged', '  emit staged\n  emit routeIn'),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.text('FLOW'));
    await tester.pump(const Duration(milliseconds: 60));

    await tester.tap(find.text('RUN'));
    await tester.pump(const Duration(milliseconds: 60));
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(c.status, 'PASS · 16/16 · GOLDEN CLEAN');
    expect(c.faults, 0);
    expect(c.verifyWhite, isTrue);
    expect(find.text('RUN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a finding holds the loop at golden, and REPLAY repeats it', (WidgetTester tester) async {
    await boot(tester);

    final WorkbenchController c = controllerOf(tester);
    await tester.tap(find.text('RUN'));
    await tester.pump(const Duration(milliseconds: 40));
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(c.status, 'HELD · STEP 11 GOLDEN · REPLAY OR CLEAR');
    expect(c.faults, 1);
    expect(c.faultStepLit, isTrue);
    expect(c.flowHold, isTrue);
    // HELD is not a dead end: the key says what pressing it will do
    expect(find.text('REPLAY'), findsOneWidget);

    await tester.tap(find.text('REPLAY'));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 200));
    expect(c.status, startsWith('REPLAY · STEP'));
    expect(c.status, contains('FAULT IN'));
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(c.status, 'HELD · STEP 11 GOLDEN · REPLAY OR CLEAR');
    expect(c.lastRunSeconds, isNotNull);

    await tester.tap(find.text('CLEAR'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(c.status, 'LOOP IDLE');
    expect(c.faultStepLit, isFalse);
    expect(find.text('RUN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the interlock latches and issues the session receipt', (WidgetTester tester) async {
    await boot(tester);

    expect(find.text('No receipts · awaiting first authorization'), findsOneWidget);
    await tester.tap(find.textContaining('AUTHORIZE'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.textContaining('ARMED'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 800));
    final WorkbenchController c = controllerOf(tester);
    expect(c.authorized, isTrue);
    expect(find.text('AUTHORIZED'), findsOneWidget);
    expect(find.text('RECEIPT 0142'), findsOneWidget);
    expect(find.text('VERIFIED · 3 HUNKS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the rail fits one instrument and the explorer opens real buffers', (WidgetTester tester) async {
    await boot(tester);

    final WorkbenchController c = controllerOf(tester);
    await tester.tap(find.byTooltip('Files'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(c.instrument, Instrument.files);
    expect(find.text('main.styio'), findsOneWidget);
    expect(find.text('256 B'), findsOneWidget);
    expect(find.text('95 B'), findsOneWidget);
    expect(find.text('72 B'), findsOneWidget);

    await tester.tap(find.text('util.styio'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(c.activeFile.name, 'util.styio');
    expect(c.showFlow, isFalse); // opening a file shows its source
    expect(c.tail, 'util.styio · 7 lines · LF');

    await tester.tap(find.text('styio.toml'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(c.activeFile.name, 'styio.toml');
    expect(c.flowTabEnabled, isFalse); // FLOW refuses to project a config file
    await tester.tap(find.text('FLOW'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(c.showFlow, isFalse);

    // styio.toml configures the machine: edit the tempo and it takes effect
    await tester.enterText(find.byType(TextField), kStyioToml.replaceFirst('128.0', '96.0'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(c.bpm, 96);
    expect(c.stepMs, closeTo(60000 / 96 / 4, 0.001));

    // util.styio has its own board
    await tester.tap(find.byTooltip('Files'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.text('util.styio'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('FLOW'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(c.showFlow, isTrue);
    expect(c.graph.modules.map((GraphModule m) => m.name), <String>['clamp01', 'gain', 'bias']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the tempo tube, the step row and the status strip are all state', (WidgetTester tester) async {
    await boot(tester);

    final WorkbenchController c = controllerOf(tester);
    await tester.tap(find.byTooltip('Tempo up'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(c.bpm, 129);
    await tester.tap(find.byTooltip('Tempo down'));
    await tester.tap(find.byTooltip('Tempo down'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(c.bpm, 127);
    expect(c.stepMs, closeTo(60000 / 127 / 4, 0.001));

    // a step key disarms and the loop head counts it
    await tester.tap(find.bySemanticsLabel('step 1 buffer'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(c.armedCount, 15);
    expect(find.text('15/16 Armed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
