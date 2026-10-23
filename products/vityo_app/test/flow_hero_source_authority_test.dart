import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/editor/document_state.dart';
import 'package:vityo_app/src/view_ide/language/contract/language_contract.dart'
    as lang;
import 'package:vityo_app/src/view_ide/language/service/local_styio_language_service.dart';
import 'package:vityo_app/src/view_render/flow_hero/agent_bridge.dart';
import 'package:vityo_app/src/view_render/flow_hero/controller.dart';
import 'package:vityo_app/src/view_render/flow_hero/hero_board.dart';
import 'package:vityo_app/src/view_render/flow_hero/lexer_buf.dart';
import 'package:vityo_app/src/view_render/flow_hero/source_dock.dart';

/// A service stub that reports one real document symbol for [symbolName] — the
/// live-route shape the engine reads for its projection.
class _SymbolService extends LocalStyioLanguageService {
  _SymbolService(this.symbolName);

  final String symbolName;

  @override
  lang.StyioDocumentAnalysis analyzeDocument(DocumentState document) {
    final int raw = document.text.indexOf(symbolName);
    final int start = raw < 0 ? 0 : raw;
    final lang.SourceRange range = lang.SourceRange(
      start: start,
      end: start + symbolName.length,
    );
    return lang.StyioDocumentAnalysis(
      tokenSpans: const <lang.TokenSpan>[],
      semanticSpans: const <lang.SemanticSpan>[],
      diagnostics: const <lang.Diagnostic>[],
      formattingEdits: const <lang.FormattingEdit>[],
      semanticBlocks: const <lang.SemanticBlockRange>[],
      inlayHints: const <lang.InlayHint>[],
      documentSymbols: <lang.DocumentSymbol>[
        lang.DocumentSymbol(
          name: symbolName,
          kind: lang.SymbolKind.variable,
          nameRange: range,
          declarationRange: range,
          detail: 'mock symbol',
        ),
      ],
      referenceSpans: const <lang.ReferenceSpan>[],
    );
  }
}

const String _fixture =
    'pipeline realFlow\n'
    'let staged := source |> normalize\n'
    'let out = staged -> render\n';

void main() {
  late Directory root;
  late String path;

  setUp(() {
    root = Directory.systemTemp.createTempSync('flow_hero_source_');
    path = '${root.path}/real.styio';
    File(path).writeAsStringSync(_fixture);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets('(a) canvas renders the real buffer projection', (
    WidgetTester tester,
  ) async {
    final FlowHeroController controller = FlowHeroController();
    addTearDown(controller.dispose);
    controller.engine.attachLanguageService(_SymbolService('normalize'));
    // Real file I/O must run outside the widget-test fake clock.
    final bool opened =
        await tester.runAsync(() => controller.engine.openPath(path)) ?? false;
    expect(opened, isTrue);
    controller.refreshProjection();

    expect(
      controller.projectionSource,
      FlowHeroProjectionSource.semanticService,
    );
    expect(controller.nodes.map((HeroNode n) => n.id), contains('normalize'));
    expect(controller.edges, isNotEmpty);
    expect(
      controller.nodes.any((HeroNode n) => n.serviceConfirmed),
      isTrue,
      reason: 'the live document symbol confirms a real node',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HeroBoard(controller: controller)),
      ),
    );
    expect(find.text('NORMALIZE'), findsOneWidget);
    expect(find.text('SOURCE'), findsOneWidget);
    expect(find.text('语义服务投影'), findsOneWidget);
  });

  test('(b) the default canvas fabricates no nodes', () {
    final FlowHeroController controller = FlowHeroController();
    addTearDown(controller.dispose);

    expect(controller.nodes, isEmpty);
    expect(controller.edges, isEmpty);
    expect(controller.projectionSource, FlowHeroProjectionSource.none);
    expect(controller.projectionBadgeLabel, isEmpty);
  });

  test('(b) the live projection never falls back to demo node names', () async {
    final FlowHeroController controller = FlowHeroController();
    addTearDown(controller.dispose);
    controller.engine.attachLanguageService(_SymbolService('normalize'));
    expect(await controller.engine.openPath(path), isTrue);
    controller.refreshProjection();

    final Set<String> ids = controller.nodes.map((HeroNode n) => n.id).toSet();
    for (final String legacy in <String>[
      'fetch',
      'valid',
      'dedup',
      'emit',
      'state',
      'enrich',
    ]) {
      expect(
        ids.contains(legacy),
        isFalse,
        reason: 'no hardcoded $legacy node',
      );
    }
    expect(ids, containsAll(<String>['source', 'normalize', 'render', 'out']));
  });

  testWidgets('(c) demo timers do not fire in live mode', (
    WidgetTester tester,
  ) async {
    final FlowHeroController controller = FlowHeroController();
    addTearDown(controller.dispose);

    // The bridge proves a live link: demo injection must stop entirely.
    controller.bridge.mode = AgentLinkMode.live;
    controller.refreshProjection();
    expect(controller.demoModeActive, isFalse);

    await tester.pump(const Duration(seconds: 5));
    expect(controller.nodes.where((HeroNode n) => n.demo), isEmpty);
    expect(controller.messages, isEmpty);
  });

  testWidgets('(c) demo mode injects only clearly-marked demo content', (
    WidgetTester tester,
  ) async {
    final FlowHeroController controller = FlowHeroController();
    addTearDown(controller.dispose);
    expect(controller.demoModeActive, isTrue);

    await tester.pump(const Duration(seconds: 5));
    expect(controller.nodes.where((HeroNode n) => n.demo), isNotEmpty);
    expect(controller.messages, isNotEmpty);
    expect(controller.messages.every((ChatMsg m) => m.demo), isTrue);
  });

  testWidgets('(d) source dock reads real buffer lines for the selected node', (
    WidgetTester tester,
  ) async {
    final FlowHeroController controller = FlowHeroController();
    addTearDown(controller.dispose);
    controller.engine.attachLanguageService(_SymbolService('normalize'));
    final bool opened =
        await tester.runAsync(() => controller.engine.openPath(path)) ?? false;
    expect(opened, isTrue);
    controller.refreshProjection();

    final List<SourceDockLine> lines = controller.sourceLinesFor('normalize');
    expect(lines, isNotEmpty);
    expect(lines.first.lineNo, 2);
    expect(lines.first.text, contains('normalize'));

    controller.select('normalize');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[SourceDock(controller: controller)],
          ),
        ),
      ),
    );
    final Iterable<SourceLine> drawn = tester.widgetList<SourceLine>(
      find.byType(SourceLine),
    );
    expect(
      drawn.any((SourceLine l) => l.line.contains('let staged')),
      isTrue,
      reason: 'the dock shows the real declaration line',
    );
    expect(find.text('无源码位置'), findsNothing);
  });

  testWidgets('(d) a node without a source location says so honestly', (
    WidgetTester tester,
  ) async {
    final FlowHeroController controller = FlowHeroController();
    addTearDown(controller.dispose);

    controller.select('missing');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[SourceDock(controller: controller)],
          ),
        ),
      ),
    );
    expect(find.text('无源码位置'), findsOneWidget);
    expect(find.byType(SourceLine), findsNothing);
    await tester.pump(const Duration(seconds: 5)); // flush demo timers
  });

  testWidgets(
    '(e) the canvas shows an honest empty state without a real buffer',
    (WidgetTester tester) async {
      final FlowHeroController controller = FlowHeroController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: HeroBoard(controller: controller)),
        ),
      );
      expect(controller.nodes, isEmpty);
      expect(find.textContaining('打开工作区文件以生成真实图'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5)); // flush demo timers
    },
  );
}
