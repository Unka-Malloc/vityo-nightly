import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/editor/document_state.dart';
import 'package:vityo_app/src/view_ide/flow_hero/execution_service.dart';
import 'package:vityo_app/src/view_ide/flow_hero/language_service.dart';
import 'package:vityo_app/src/view_ide/flow_hero/model_config.dart';
import 'package:vityo_app/src/view_ide/flow_hero/toolchain_store.dart';
import 'package:vityo_app/src/view_ide/flow_hero/workspace_store.dart';
import 'package:vityo_app/src/view_ide/language/service/local_styio_language_service.dart';
import 'package:vityo_app/src/view_render/flow_hero/chat_rail.dart';
import 'package:vityo_app/src/view_render/flow_hero/controller.dart';
import 'package:vityo_app/src/view_render/flow_hero/flow_hero.dart';
import 'package:vityo_app/src/view_render/flow_hero/run_strip.dart';

class _WorkspaceStore implements FlowHeroWorkspaceStore {
  _WorkspaceStore(this.root);

  String? root;

  @override
  bool get persistent => true;

  @override
  Future<String?> load() async => root;

  @override
  Future<void> save(String path) async => root = path;
}

class _DelayedWorkspaceStore implements FlowHeroWorkspaceStore {
  final Completer<String?> loaded = Completer<String?>();

  @override
  bool get persistent => true;

  @override
  Future<String?> load() => loaded.future;

  @override
  Future<void> save(String path) async {}
}

class _ToolchainStore implements FlowHeroToolchainStore {
  _ToolchainStore(this.selection);

  FlowHeroToolchainSelection? selection;

  @override
  bool get persistent => true;

  @override
  Future<FlowHeroToolchainSelection?> load() async => selection;

  @override
  Future<void> savePath(FlowHeroToolchainKind kind, String path) async {
    selection = (selection ?? const FlowHeroToolchainSelection()).withPath(
      kind,
      path,
    );
  }

  @override
  Future<void> clearPath(FlowHeroToolchainKind kind) async {
    selection = (selection ?? const FlowHeroToolchainSelection()).withPath(
      kind,
      '',
    );
  }
}

class _LanguageSession extends LocalStyioLanguageService
    implements FlowHeroLanguageSession {
  _LanguageSession(this.workspaceRoot, this.statusLine);

  @override
  final String workspaceRoot;

  @override
  final String statusLine;

  bool disposed = false;
  bool healthy = true;
  int activations = 0;

  @override
  FlowHeroLanguageMode get mode => FlowHeroLanguageMode.live;

  @override
  String get providerId => 'fixture';

  @override
  String? get providerVersion => 'fixture-1';

  @override
  bool get live => healthy && !disposed;

  @override
  void activateRoute() => activations++;

  @override
  Future<FlowHeroLanguageResult?> analyzeFresh(
    DocumentState document, {
    String? filePath,
  }) async => null;

  @override
  Future<void> dispose() async => disposed = true;
}

class _ExecutionSource implements FlowHeroExecutionSource {
  _ExecutionSource(this.statusLine);

  @override
  final String statusLine;

  final Completer<FlowHeroExecutionOutcome> _completion =
      Completer<FlowHeroExecutionOutcome>();
  int starts = 0;
  int cancels = 0;
  bool disposed = false;

  @override
  FlowHeroExecutionMode get mode => FlowHeroExecutionMode.live;

  @override
  bool get live => !disposed;

  @override
  String get unavailableReason => '';

  @override
  Future<FlowHeroExecutionOutcome> execute(
    FlowHeroExecutionKind kind, {
    VoidCallback? onStarted,
  }) {
    starts++;
    onStarted?.call();
    return _completion.future;
  }

  @override
  Future<bool> cancel() async {
    cancels++;
    return true;
  }

  @override
  Future<void> dispose() async => disposed = true;

  void complete(String receipt) {
    _completion.complete(
      FlowHeroExecutionOutcome(
        kind: FlowHeroExecutionKind.run,
        phase: FlowHeroExecutionPhase.succeeded,
        statusLine: '通过',
        receiptText: receipt,
        duration: Duration.zero,
      ),
    );
  }
}

void main() {
  testWidgets('unchanged delayed restore enables the live RunStrip', (
    WidgetTester tester,
  ) async {
    final _DelayedWorkspaceStore store = _DelayedWorkspaceStore();
    final _ExecutionSource source = _ExecutionSource('fixture');
    final FlowHeroController controller = FlowHeroController(
      initialWorkspaceRoot: '/fixture/current',
      workspaceStore: store,
      executionBoot: (_, _) async => source,
      providerConfigWriter: const FlowHeroUnavailableProviderConfigWriter(),
    );
    addTearDown(controller.dispose);

    final List<bool> readinessNotifications = <bool>[];
    controller.addListener(
      () => readinessNotifications.add(controller.canExecute),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RunStrip(controller: controller)),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(controller.executionLive, isTrue);
    expect(controller.canExecute, isFalse);
    final Finder runButton = find.descendant(
      of: find.byKey(const ValueKey<String>('run-strip-run')),
      matching: find.byType(InkWell),
    );
    expect(tester.widget<InkWell>(runButton).onTap, isNull);
    readinessNotifications.clear();

    store.loaded.complete(null);
    await tester.pump();
    await controller.workspaceBootSettled;
    await tester.pump();

    expect(controller.canExecute, isTrue);
    expect(readinessNotifications, contains(true));
    expect(tester.widget<InkWell>(runButton).onTap, isNotNull);
  });

  testWidgets(
    'restored workspace and toolchain own both routes; late startup boot is disposed',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final Completer<FlowHeroLanguageSession> firstLanguage =
          Completer<FlowHeroLanguageSession>();
      final List<(String, FlowHeroToolchainSelection)> executionBoots =
          <(String, FlowHeroToolchainSelection)>[];
      final List<(String, FlowHeroToolchainSelection)> languageBoots =
          <(String, FlowHeroToolchainSelection)>[];
      final List<_ExecutionSource> executionSources = <_ExecutionSource>[];
      late _LanguageSession oldLanguage;
      late _LanguageSession currentLanguage;
      final FlowHeroToolchainSelection initialSelection =
          const FlowHeroToolchainSelection(pafioPath: '/fixture/old-pafio');
      final FlowHeroToolchainSelection restoredSelection =
          const FlowHeroToolchainSelection(
            pafioPath: '/fixture/new-pafio',
            styioPath: '/fixture/new-styio',
          );

      await tester.pumpWidget(
        FlowHeroApp(
          workspaceStore: _WorkspaceStore('/fixture/restored-workspace'),
          toolchainStore: _ToolchainStore(restoredSelection),
          initialToolchainSelection: initialSelection,
          providerConfigWriter: const FlowHeroUnavailableProviderConfigWriter(),
          executionBoot: (String root, FlowHeroToolchainSelection selection) {
            executionBoots.add((root, selection));
            final source = _ExecutionSource('route-${executionSources.length}');
            executionSources.add(source);
            return Future<FlowHeroExecutionSource>.value(source);
          },
          languageBoot: (String root, FlowHeroToolchainSelection selection) {
            languageBoots.add((root, selection));
            if (languageBoots.length == 1) {
              oldLanguage = _LanguageSession(root, 'old-startup-session');
              return firstLanguage.future;
            }
            currentLanguage = _LanguageSession(root, 'restored-session');
            return Future<FlowHeroLanguageSession>.value(currentLanguage);
          },
        ),
      );

      final FlowHeroController controller = tester
          .widget<FlowHeroPage>(find.byType(FlowHeroPage))
          .controller;
      await controller.workspaceBootSettled;
      await tester.pump();

      expect(controller.workspaceRoot, '/fixture/restored-workspace');
      expect(controller.toolchainSelection, restoredSelection);
      expect(executionBoots.last.$1, '/fixture/restored-workspace');
      expect(executionBoots.last.$2, restoredSelection);
      expect(languageBoots.last.$1, '/fixture/restored-workspace');
      expect(languageBoots.last.$2, restoredSelection);
      expect(controller.languageStatusLine, 'restored-session');
      expect(currentLanguage.activations, 1);
      expect(executionSources.first.disposed, isTrue);

      firstLanguage.complete(oldLanguage);
      await tester.pump();
      await tester.pump();

      expect(oldLanguage.disposed, isTrue);
      expect(oldLanguage.activations, 0);
      expect(currentLanguage.disposed, isFalse);
      expect(controller.languageStatusLine, 'restored-session');

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('dispatch is invalidated immediately while a new root boots', () async {
    final _ExecutionSource oldRoute = _ExecutionSource('old route');
    final _ExecutionSource newRoute = _ExecutionSource('new route');
    final Completer<FlowHeroExecutionSource> newBoot =
        Completer<FlowHeroExecutionSource>();
    var boots = 0;
    final controller = FlowHeroController(
      initialWorkspaceRoot: '/fixture/old-workspace',
      executionBoot: (String root, FlowHeroToolchainSelection selection) {
        boots++;
        return boots == 1
            ? Future<FlowHeroExecutionSource>.value(oldRoute)
            : newBoot.future;
      },
    );
    addTearDown(controller.dispose);
    await controller.workspaceBootSettled;

    final Future<bool> switching = controller.switchWorkspace(
      '/fixture/new-workspace',
      persist: false,
    );
    expect(controller.workspaceRoot, '/fixture/new-workspace');
    expect(controller.canExecute, isFalse);
    await controller.runExecution(FlowHeroExecutionKind.run);
    expect(oldRoute.starts, 0);

    newBoot.complete(newRoute);
    expect(await switching, isTrue);
    expect(controller.executionSource, same(newRoute));
    expect(controller.canExecute, isTrue);
  });

  test('language readiness follows the attached session health', () async {
    final _LanguageSession session = _LanguageSession(
      '/fixture/workspace',
      'styio_lspd fixture-1',
    );
    final controller = FlowHeroController(
      initialWorkspaceRoot: '/fixture/workspace',
      providerConfigWriter: const FlowHeroUnavailableProviderConfigWriter(),
      languageBoot: (String root, FlowHeroToolchainSelection selection) async =>
          session,
    );
    addTearDown(controller.dispose);
    await controller.workspaceBootSettled;

    expect(controller.languageMode, FlowHeroLanguageMode.live);
    expect(controller.languageLive, isTrue);
    expect(controller.languageStatusLine, 'styio_lspd fixture-1');

    session.healthy = false;

    expect(controller.languageMode, FlowHeroLanguageMode.degraded);
    expect(controller.languageLive, isFalse);
    expect(controller.languageStatusLine, '语言会话不可用 · 本地启发式分析');
  });

  test(
    'an in-flight result stays attached to its origin across a root switch',
    () async {
      final _ExecutionSource oldRoute = _ExecutionSource('old route');
      final _ExecutionSource newRoute = _ExecutionSource('new route');
      final controller = FlowHeroController(
        initialWorkspaceRoot: '/fixture/old-workspace',
        executionBoot:
            (String root, FlowHeroToolchainSelection selection) async =>
                root == '/fixture/old-workspace' ? oldRoute : newRoute,
      );
      addTearDown(controller.dispose);
      await controller.workspaceBootSettled;

      final Future<void> running = controller.runExecution(
        FlowHeroExecutionKind.run,
      );
      expect(oldRoute.starts, 1);
      expect(controller.executionBusy, isTrue);

      await controller.switchWorkspace(
        '/fixture/new-workspace',
        persist: false,
      );
      expect(controller.executionSource, same(newRoute));
      expect(oldRoute.disposed, isFalse);
      expect(controller.lastExecutionOutcome, isNull);
      expect(controller.canExecute, isFalse);

      await controller.cancelExecution();
      expect(oldRoute.cancels, 1);
      expect(oldRoute.disposed, isFalse);
      oldRoute.complete('old workspace result');
      await running;

      expect(controller.executionPhase, FlowHeroExecutionPhase.idle);
      expect(controller.lastExecutionOutcome, isNull);
      expect(controller.canExecute, isTrue);
      expect(oldRoute.disposed, isTrue);
      final ChatMsg receipt = controller.messages.last;
      expect(receipt.receipt, isTrue);
      expect(receipt.executionOrigin?.workspaceRoot, '/fixture/old-workspace');
      expect(
        controller.executionOriginIsCurrent(receipt.executionOrigin),
        isFalse,
      );
    },
  );

  testWidgets('old execution receipts are labeled without exposing the root', (
    WidgetTester tester,
  ) async {
    final controller = FlowHeroController(
      initialWorkspaceRoot: '/fixture/new-workspace',
    );
    addTearDown(controller.dispose);
    const FlowHeroExecutionOrigin origin = FlowHeroExecutionOrigin(
      workspaceRoot: '/fixture/old-workspace',
      toolchainSelection: FlowHeroToolchainSelection(),
    );
    controller.postAgentNote(
      'completed run',
      receipt: true,
      executionOrigin: origin,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatRail(controller: controller)),
      ),
    );

    expect(find.text('结果来自切换前的工作区与工具链'), findsOneWidget);
    expect(find.text('completed run'), findsOneWidget);
    expect(find.text('/fixture/old-workspace'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
