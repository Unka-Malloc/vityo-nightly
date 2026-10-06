import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/editor/document_state.dart';
import 'package:vityo_app/src/view_ide/language/contract/language_contract.dart'
    as lang;
import 'package:vityo_app/src/view_ide/language/service/local_styio_language_service.dart';
import 'package:vityo_app/src/view_render/flow_hero/engine/editor.dart';
import 'package:vityo_app/src/view_render/flow_hero/engine/machine.dart';
import 'package:vityo_app/src/view_render/flow_hero/flow_hero.dart';
import 'package:vityo_app/src/view_ide/flow_hero/language_service.dart';
import 'package:vityo_app/src/view_render/flow_hero/palette.dart';
import 'package:vityo_app/src/view_render/flow_hero/tokens.dart';

/// A plain routed service (the shell's sync interface) that answers with a
/// scripted analysis — the service-present path.
class _ScriptedService extends LocalStyioLanguageService {
  _ScriptedService(this.build);

  final lang.StyioDocumentAnalysis Function(String text) build;
  int calls = 0;

  @override
  lang.StyioDocumentAnalysis analyzeDocument(DocumentState document) {
    calls++;
    return build(document.text);
  }
}

/// The async half: a live session whose answers the test controls.
class _LiveService extends LocalStyioLanguageService
    implements FlowHeroAsyncLanguageSource {
  final Completer<FlowHeroLanguageResult?> next =
      Completer<FlowHeroLanguageResult?>();
  String? lastText;
  int analysisCalls = 0;

  @override
  bool get live => true;

  @override
  String get statusLine => 'styio_lspd 0.0.0-test';

  @override
  Future<FlowHeroLanguageResult?> analyzeFresh(
    DocumentState document, {
    String? filePath,
  }) {
    analysisCalls++;
    lastText = document.text;
    return next.future;
  }
}

class _DegradedSession extends LocalStyioLanguageService
    implements FlowHeroLanguageSession {
  _DegradedSession(this.workspaceRoot);

  @override
  final String workspaceRoot;

  @override
  FlowHeroLanguageMode get mode => FlowHeroLanguageMode.degraded;

  @override
  String get providerId => '';

  @override
  String get statusLine => '未配置工作区 · 本地启发式分析';

  @override
  String? get providerVersion => null;

  @override
  bool get live => false;

  @override
  void activateRoute() {}

  @override
  Future<FlowHeroLanguageResult?> analyzeFresh(
    DocumentState document, {
    String? filePath,
  }) async => null;

  @override
  Future<void> dispose() async {}
}

lang.StyioDocumentAnalysis _analysisFor(
  String text, {
  required String ident,
  required String message,
}) {
  final int start = text.indexOf(ident);
  assert(start >= 0, 'the scripted identifier must exist in the buffer');
  final lang.SourceRange range = lang.SourceRange(
    start: start,
    end: start + ident.length,
  );
  return lang.StyioDocumentAnalysis(
    tokenSpans: const <lang.TokenSpan>[],
    semanticSpans: <lang.SemanticSpan>[
      lang.SemanticSpan(range: range, kind: lang.SemanticKind.pipeline),
    ],
    diagnostics: <lang.Diagnostic>[
      lang.Diagnostic(
        severity: lang.DiagnosticSeverity.warning,
        code: 'STYIO-SVC',
        message: message,
        range: range,
      ),
    ],
    formattingEdits: const <lang.FormattingEdit>[],
    semanticBlocks: const <lang.SemanticBlockRange>[],
    inlayHints: const <lang.InlayHint>[],
    documentSymbols: const <lang.DocumentSymbol>[],
    referenceSpans: const <lang.ReferenceSpan>[],
  );
}

void main() {
  group('service absent', () {
    test('the local heuristic stays and names itself', () {
      final engine = WorkbenchController();
      addTearDown(engine.dispose);

      expect(engine.languageServiceConfigured, isFalse);
      expect(engine.analysisOrigin, FlowHeroAnalysisOrigin.heuristic);
      expect(engine.activeDiags.single.ident, 'routeIn');
      expect(engine.activeSemanticSpans, isEmpty);
      expect(engine.activeServiceDiagnostics, isEmpty);
    });

    test('a workspace-less boot is honestly degraded', () async {
      final runtime = await FlowHeroLanguageRuntime.boot(workspaceRoot: '');
      addTearDown(runtime.dispose);

      expect(runtime.mode, FlowHeroLanguageMode.degraded);
      expect(runtime.live, isFalse);
      expect(runtime.statusLine, contains('本地启发式'));
    });
  });

  group('service present', () {
    test('real diagnostics and tokens replace the heuristic', () {
      final service = _ScriptedService(
        (String text) => _analysisFor(
          text,
          ident: 'mainFlow',
          message: 'mainFlow is never consumed',
        ),
      );
      final engine = WorkbenchController(languageService: service);
      addTearDown(engine.dispose);

      expect(engine.languageServiceConfigured, isTrue);
      expect(engine.analysisOrigin, FlowHeroAnalysisOrigin.service);
      expect(engine.activeDiags.single.ident, 'mainFlow');
      expect(engine.activeDiags.single.line, 0);
      expect(
        engine.activeServiceDiagnostics.single.message,
        'mainFlow is never consumed',
      );
      expect(
        engine.activeSemanticSpans.single.kind,
        lang.SemanticKind.pipeline,
      );
      // The board's hanging route follows the service's ident, not the rule.
      expect(engine.graph.routes.single.bare, isFalse);
    });

    test('an edit re-asks the service', () {
      final service = _ScriptedService(
        (String text) => _analysisFor(
          text,
          ident: 'staged',
          message: 'staged is never consumed',
        ),
      );
      final engine = WorkbenchController(languageService: service);
      addTearDown(engine.dispose);
      final int before = service.calls;

      engine.onBufferChanged('${engine.activeFile.text}\n', line: 1, column: 1);

      expect(service.calls, greaterThan(before));
      expect(engine.analysisOrigin, FlowHeroAnalysisOrigin.service);
    });

    testWidgets('semantic tokens colour the buffer', (
      WidgetTester tester,
    ) async {
      P.dark = true;
      addTearDown(() => P.dark = true);
      final service = _ScriptedService(
        (String text) => _analysisFor(
          text,
          ident: 'mainFlow',
          message: 'mainFlow is never consumed',
        ),
      );
      final engine = WorkbenchController(languageService: service);
      addTearDown(engine.dispose);
      final HighlightController highlight = HighlightController(engine);
      addTearDown(highlight.dispose);
      highlight.text = engine.activeFile.text;

      late TextSpan span;
      await tester.pumpWidget(
        Builder(
          builder: (BuildContext context) {
            span = highlight.buildTextSpan(
              context: context,
              style: null,
              withComposing: false,
            );
            return const SizedBox.shrink();
          },
        ),
      );

      final TextSpan? pipelineSpan = _childWithText(span, 'mainFlow');
      expect(pipelineSpan, isNotNull);
      expect(pipelineSpan!.style!.color, C.redBright);
    });
  });

  group('live async route', () {
    late Directory root;
    late String path;

    setUp(() {
      root = Directory.systemTemp.createTempSync('flow_hero_lsp_');
      path = '${root.path}/live.styio';
      File(path).writeAsStringSync('pipeline svc\nlet dangling = a <- b\n');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('daemon results land after the buffer is open', () async {
      final service = _LiveService();
      final engine = WorkbenchController(languageService: service);
      addTearDown(engine.dispose);

      expect(await engine.openPath(path), isTrue);
      expect(service.analysisCalls, 1);
      expect(service.lastText, contains('pipeline svc'));

      service.next.complete(
        FlowHeroLanguageResult(
          analysis: _analysisFor(
            'pipeline svc\nlet dangling = a <- b\n',
            ident: 'pipeline',
            message: 'daemon finding',
          ),
          authoritative: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(engine.analysisOrigin, FlowHeroAnalysisOrigin.service);
      expect(engine.activeServiceDiagnostics.single.message, 'daemon finding');
      expect(
        engine.activeSemanticSpans.single.kind,
        lang.SemanticKind.pipeline,
      );
    });

    test('a non-authoritative answer falls back to the heuristic', () async {
      final service = _LiveService();
      final engine = WorkbenchController(languageService: service);
      addTearDown(engine.dispose);

      expect(await engine.openPath(path), isTrue);
      service.next.complete(
        const FlowHeroLanguageResult(
          analysis: lang.StyioDocumentAnalysis(
            tokenSpans: <lang.TokenSpan>[],
            semanticSpans: <lang.SemanticSpan>[],
            diagnostics: <lang.Diagnostic>[],
            formattingEdits: <lang.FormattingEdit>[],
            semanticBlocks: <lang.SemanticBlockRange>[],
            inlayHints: <lang.InlayHint>[],
            documentSymbols: <lang.DocumentSymbol>[],
            referenceSpans: <lang.ReferenceSpan>[],
          ),
          authoritative: false,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(engine.analysisOrigin, FlowHeroAnalysisOrigin.heuristic);
      expect(engine.activeSemanticSpans, isEmpty);
    });

    test('edits debounce into one follow-up analysis', () async {
      final service = _LiveService();
      final engine = WorkbenchController(languageService: service);
      addTearDown(engine.dispose);

      expect(await engine.openPath(path), isTrue);
      service.next.complete(null);
      await Future<void>.delayed(Duration.zero);
      final int before = service.analysisCalls;

      engine.onBufferChanged('pipeline svc\n', line: 1, column: 1);
      engine.onBufferChanged('pipeline svc\n\n', line: 1, column: 1);
      expect(service.analysisCalls, before, reason: 'the debounce is pending');

      await Future<void>.delayed(const Duration(milliseconds: 320));
      expect(service.analysisCalls, before + 1);
      expect(service.lastText, 'pipeline svc\n\n');
    });
  });

  group('the running app', () {
    Future<void> boot(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(() => P.dark = true);
      await tester.pumpWidget(
        FlowHeroApp(
          languageBoot: (String root, _) async => _DegradedSession(root),
        ),
      );
      await tester.pump();
    }

    Future<void> shutdown(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }

    testWidgets('the settings panel names the route honestly', (
      WidgetTester tester,
    ) async {
      await boot(tester);
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pump();

      expect(find.text('语言服务'), findsOneWidget);
      expect(find.text('本地启发式降级'), findsOneWidget);
      await shutdown(tester);
    });

    testWidgets('the editor strip marks the degraded heuristic source', (
      WidgetTester tester,
    ) async {
      await boot(tester);
      await tester.tap(find.byIcon(Icons.code));
      await tester.pump();

      expect(find.textContaining('从未被消费'), findsOneWidget);
      expect(find.text('本地启发式（降级）'), findsOneWidget);
      await shutdown(tester);
    });
  });
}

TextSpan? _childWithText(TextSpan span, String text) {
  final List<InlineSpan>? children = span.children;
  if (children == null) return null;
  for (final InlineSpan child in children) {
    if (child is TextSpan && child.text == text) return child;
  }
  return null;
}
