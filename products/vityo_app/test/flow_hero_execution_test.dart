import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_render/flow_hero/agent_bridge.dart';
import 'package:vityo_app/src/view_render/flow_hero/controller.dart';
import 'package:vityo_app/src/view_ide/flow_hero/execution_service.dart';
import 'package:vityo_app/src/view_render/flow_hero/flow_hero.dart';
import 'package:vityo_app/src/view_render/flow_hero/hero_board.dart';
import 'package:vityo_app/src/view_render/flow_hero/palette.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_facts.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_manager.dart';
import 'package:vityo_app/src/view_ide/flow_hero/toolchain_store.dart';

import 'support/test_file_system_manager.dart';

/// A scripted execution route for the controller: the test decides when the
/// child "starts" and how it finishes. Nothing here is presented as real.
class _FakeExecutionSource implements FlowHeroExecutionSource {
  _FakeExecutionSource({
    required this.live,
    this.unavailableReason = '',
    this.startManually = false,
  });

  @override
  final bool live;

  @override
  String get statusLine => 'pafio run/test';

  @override
  final String unavailableReason;

  /// When true, `onStarted` fires only from [fireStarted] — lets a test observe
  /// the pending phase.
  final bool startManually;

  Completer<FlowHeroExecutionOutcome> _outcome =
      Completer<FlowHeroExecutionOutcome>();
  VoidCallback? _onStarted;
  FlowHeroExecutionKind? lastKind;
  bool cancelAccepted = true;
  int starts = 0;
  int cancels = 0;

  @override
  FlowHeroExecutionMode get mode =>
      live ? FlowHeroExecutionMode.live : FlowHeroExecutionMode.unavailable;

  @override
  Future<FlowHeroExecutionOutcome> execute(
    FlowHeroExecutionKind kind, {
    VoidCallback? onStarted,
  }) {
    starts++;
    lastKind = kind;
    _onStarted = onStarted;
    _outcome = Completer<FlowHeroExecutionOutcome>();
    if (!startManually) onStarted?.call();
    return _outcome.future;
  }

  void fireStarted() => _onStarted?.call();

  void complete(FlowHeroExecutionOutcome outcome) => _outcome.complete(outcome);

  @override
  Future<bool> cancel() async {
    cancels++;
    return cancelAccepted;
  }

  @override
  Future<void> dispose() async {}
}

/// A scripted route that also carries a real toolchain diagnosis, so the RUN
/// strip's missing state can be exercised per cause.
class _DiagnosedSource
    implements FlowHeroExecutionSource, FlowHeroToolchainDiagnosis {
  _DiagnosedSource({
    this.live = false,
    this.statusLine = 'pafio run/test',
    this.unavailableReason = '',
    this.missingToolchains = const <FlowHeroToolchainKind>{},
    this.toolchainChecks =
        const <FlowHeroToolchainKind, List<FlowHeroToolchainCheck>>{},
    this.unavailableCause,
  });

  @override
  final bool live;

  @override
  final String statusLine;

  @override
  final String unavailableReason;

  @override
  final Set<FlowHeroToolchainKind> missingToolchains;

  @override
  final Map<FlowHeroToolchainKind, List<FlowHeroToolchainCheck>>
  toolchainChecks;

  @override
  final FlowHeroExecutionUnavailableCause? unavailableCause;

  @override
  FlowHeroExecutionMode get mode =>
      live ? FlowHeroExecutionMode.live : FlowHeroExecutionMode.unavailable;

  @override
  Future<FlowHeroExecutionOutcome> execute(
    FlowHeroExecutionKind kind, {
    VoidCallback? onStarted,
  }) async {
    return FlowHeroExecutionOutcome(
      kind: kind,
      phase: FlowHeroExecutionPhase.failed,
      statusLine: '未执行',
      receiptText: '未执行',
      duration: Duration.zero,
    );
  }

  @override
  Future<bool> cancel() async => true;

  @override
  Future<void> dispose() async {}
}

FlowHeroExecutionOutcome _outcome(
  FlowHeroExecutionKind kind,
  FlowHeroExecutionPhase phase, {
  String statusLine = '通过 · 0.10s',
  String receiptText = 'run 通过 · 0.10s',
}) {
  return FlowHeroExecutionOutcome(
    kind: kind,
    phase: phase,
    statusLine: statusLine,
    receiptText: receiptText,
    duration: const Duration(milliseconds: 100),
    exitCode: phase == FlowHeroExecutionPhase.succeeded ? 0 : 1,
  );
}

/// A process manager that answers with a scripted result and, optionally,
/// writes the receipt pafio would have written.
class _ScriptedProcessManager extends UnsupportedProcessManager {
  _ScriptedProcessManager(this._handler)
    : super(facts: ProcessFacts.linuxDebianArm());

  final Future<ProcessCommandResult> Function(ProcessCommandRequest) _handler;
  final List<List<String>> commands = <List<String>>[];

  @override
  Future<ProcessCommandResult> run(ProcessCommandRequest request) {
    commands.add(request.arguments);
    return _handler(request);
  }
}

ProcessCommandResult _succeeded({
  required ProcessCommandRequest request,
  required String stdout,
  Duration duration = const Duration(milliseconds: 42),
}) {
  return ProcessCommandResult(
    status: ProcessCommandStatus.succeeded,
    executablePath: request.executablePath,
    arguments: request.arguments,
    exitCode: 0,
    stdout: stdout,
    stderr: '',
    duration: duration,
  );
}

ProcessCommandResult _failed({
  required ProcessCommandRequest request,
  required int exitCode,
  required String stderr,
}) {
  return ProcessCommandResult(
    status: ProcessCommandStatus.failed,
    executablePath: request.executablePath,
    arguments: request.arguments,
    exitCode: exitCode,
    stdout: '',
    stderr: stderr,
    duration: const Duration(milliseconds: 30),
  );
}

void main() {
  group('real Pafio pair-check contract', () {
    Future<FlowHeroToolchainPairCheck> probe(
      Object payload, {
      int exitCode = 0,
      void Function(ProcessCommandRequest)? inspect,
    }) => checkFlowHeroToolchainPair(
      process: _ScriptedProcessManager((request) async {
        inspect?.call(request);
        return ProcessCommandResult(
          status: exitCode == 0
              ? ProcessCommandStatus.succeeded
              : ProcessCommandStatus.failed,
          executablePath: request.executablePath,
          arguments: request.arguments,
          exitCode: exitCode,
          stdout: jsonEncode(payload),
          stderr: '',
          duration: Duration.zero,
        );
      }),
      pafioBinaryPath: '/selected/pafio',
      styioBinaryPath: '/selected/styio',
      workspaceRoot: '/project',
      manifestPath: '/project/pafio.toml',
      environment: const {'PAIR_TEST': 'yes'},
    );

    Map<String, Object?> compilerCheck(String status) => {
      'name': 'styio',
      'status': status,
      'message': 'compiler contract status',
      'detail': {
        'supported_compile_plan_versions': [1],
      },
    };

    test('checks exact selected pair without executing or syncing', () async {
      final result = await probe(
        {
          'command': 'doctor',
          'ok': true,
          'checks': [compilerCheck('ok')],
        },
        inspect: (request) {
          expect(request.executablePath, '/selected/pafio');
          expect(request.arguments, [
            '--json',
            'doctor',
            '--manifest-path',
            '/project/pafio.toml',
            '--styio-bin',
            '/selected/styio',
          ]);
          expect(request.workingDirectory, '/project');
          expect(request.environment['PAIR_TEST'], 'yes');
        },
      );
      expect(result.compatible, isTrue);
      expect(result.advisory, isFalse);
    });

    test(
      'unlisted local product version is advisory after contract checks',
      () async {
        final result = await probe({
          'command': 'doctor',
          'checks': [compilerCheck('warning')],
        });
        expect(result.compatible, isTrue);
        expect(result.advisory, isTrue);
      },
    );

    test('unrelated doctor errors do not hide a compatible pair', () async {
      final result = await probe({
        'command': 'doctor',
        'ok': false,
        'checks': [
          compilerCheck('ok'),
          {'name': 'lockfile', 'status': 'error'},
        ],
      }, exitCode: 1);
      expect(result.compatible, isTrue);
    });

    for (final payload in <Object>[
      {
        'command': 'doctor',
        'checks': [compilerCheck('error')],
      },
      {
        'command': 'doctor',
        'checks': [
          {'name': 'styio', 'status': 'ok'},
        ],
      },
      {
        'command': 'doctor',
        'checks': [compilerCheck('ok'), compilerCheck('ok')],
      },
      {'command': 'doctor', 'checks': []},
      {
        'command': 'run',
        'checks': [compilerCheck('ok')],
      },
      'invalid JSON shape',
    ]) {
      test('rejects missing or contradictory pair evidence $payload', () async {
        expect((await probe(payload)).compatible, isFalse);
      });
    }
  });

  group('controller RUN/TEST states', () {
    test('a failed rerun replaces the prior successful result', () async {
      final source = _FakeExecutionSource(live: true);
      final controller = FlowHeroController(executionSource: source);
      addTearDown(controller.dispose);
      final first = controller.runExecution(FlowHeroExecutionKind.run);
      source.complete(
        _outcome(
          FlowHeroExecutionKind.run,
          FlowHeroExecutionPhase.succeeded,
          receiptText: 'first success',
        ),
      );
      await first;
      expect(controller.lastExecutionOutcome?.succeeded, isTrue);
      final second = controller.runExecution(FlowHeroExecutionKind.run);
      expect(controller.lastExecutionOutcome, isNull);
      source.complete(
        _outcome(
          FlowHeroExecutionKind.run,
          FlowHeroExecutionPhase.failed,
          statusLine: 'compile failed',
          receiptText: 'second failed',
        ),
      );
      await second;
      expect(controller.executionPhase, FlowHeroExecutionPhase.failed);
      expect(controller.lastExecutionOutcome?.receipt, isNull);
      expect(controller.executionStatusLabel, 'compile failed');
      expect(controller.messages.last.text, contains('second failed'));
      expect(controller.messages.last.text, isNot(contains('first success')));
    });

    test('an unavailable route disables RUN and names the reason', () async {
      final source = _FakeExecutionSource(
        live: false,
        unavailableReason: '未发现 pafio · 请安装或设置 VITYO_PAFIO_BIN',
      );
      final controller = FlowHeroController(executionSource: source);
      addTearDown(controller.dispose);

      expect(controller.executionLive, isFalse);
      expect(controller.canExecute, isFalse);
      expect(controller.executionStatusLabel, contains('未发现 pafio'));

      await controller.runExecution(FlowHeroExecutionKind.run);
      expect(source.starts, 0, reason: 'nothing may start when unavailable');
      expect(controller.executionPhase, FlowHeroExecutionPhase.idle);
    });

    test(
      'RUN moves pending → running → succeeded and posts the receipt',
      () async {
        final source = _FakeExecutionSource(live: true, startManually: true);
        final controller = FlowHeroController(executionSource: source);
        addTearDown(controller.dispose);

        expect(controller.canExecute, isTrue);
        unawaited(controller.runExecution(FlowHeroExecutionKind.run));
        await Future<void>.delayed(Duration.zero);

        expect(source.starts, 1);
        expect(source.lastKind, FlowHeroExecutionKind.run);
        expect(controller.executionPhase, FlowHeroExecutionPhase.pending);

        source.fireStarted();
        expect(controller.executionPhase, FlowHeroExecutionPhase.running);

        source.complete(
          _outcome(
            FlowHeroExecutionKind.run,
            FlowHeroExecutionPhase.succeeded,
            receiptText: 'run 通过 · 0.10s · 阶段 3 · 产物 2 · 会话 s-1',
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(controller.executionPhase, FlowHeroExecutionPhase.succeeded);
        final ChatMsg receipt = controller.messages.last;
        expect(receipt.receipt, isTrue);
        expect(receipt.demo, isFalse);
        expect(receipt.text, contains('会话 s-1'));
      },
    );

    test('a failed run posts the real failure, not a success story', () async {
      final source = _FakeExecutionSource(live: true);
      final controller = FlowHeroController(executionSource: source);
      addTearDown(controller.dispose);

      unawaited(controller.runExecution(FlowHeroExecutionKind.test));
      await Future<void>.delayed(Duration.zero);
      source.complete(
        _outcome(
          FlowHeroExecutionKind.test,
          FlowHeroExecutionPhase.failed,
          statusLine: '失败 · exit 1',
          receiptText: 'test 失败 · boom · 0.03s',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.executionPhase, FlowHeroExecutionPhase.failed);
      expect(controller.messages.last.text, contains('失败'));
      expect(controller.messages.last.receipt, isTrue);
    });

    test(
      'STOP asks the route to cancel and reports a refusal honestly',
      () async {
        final source = _FakeExecutionSource(live: true);
        final controller = FlowHeroController(executionSource: source);
        addTearDown(controller.dispose);

        unawaited(controller.runExecution(FlowHeroExecutionKind.run));
        await Future<void>.delayed(Duration.zero);
        expect(controller.executionBusy, isTrue);

        source.cancelAccepted = false;
        await controller.cancelExecution();
        expect(source.cancels, 1);
        expect(controller.messages.last.text, contains('无法中断'));

        source.complete(
          _outcome(
            FlowHeroExecutionKind.run,
            FlowHeroExecutionPhase.failed,
            statusLine: '已中断',
            receiptText: 'run 已中断 · 0.05s',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(controller.executionPhase, FlowHeroExecutionPhase.failed);
      },
    );
  });

  group('real execution runtime glue', () {
    late Directory workspace;

    setUp(() {
      workspace = Directory.systemTemp.createTempSync('flow_hero_exec_');
    });

    tearDown(() {
      if (workspace.existsSync()) workspace.deleteSync(recursive: true);
    });

    FlowHeroExecutionRuntime runtimeWith(
      _ScriptedProcessManager process, {
      required String pafioPath,
      Map<String, String> environment = const <String, String>{},
    }) {
      return FlowHeroExecutionRuntime.forTesting(
        process: process,
        fileSystem: TestFileSystemManager.linuxDebianArm(),
        workspaceRoot: workspace.path,
        pafioBinaryPath: pafioPath,
        styioBinaryPath: '/usr/bin/styio',
        manifestPath: '${workspace.path}/pafio.toml',
        environment: environment,
      );
    }

    test('parses the pafio envelope and reads the real receipt', () async {
      final buildRoot =
          '${workspace.path}${Platform.pathSeparator}.pafio${Platform.pathSeparator}build${Platform.pathSeparator}s-1';
      Directory(buildRoot).createSync(recursive: true);
      File('$buildRoot/receipt.json').writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schema_version': 1,
          'tool': 'styio',
          'intent': 'run',
          'session_id': 's-1',
          'executed': true,
          'phases': <String>['parse', 'lower', 'emit'],
          'artifacts': <String>['bin/app', 'app.log'],
        }),
      );

      final process = _ScriptedProcessManager((request) async {
        expect(request.environment['HOME'], '/isolated/home');
        expect(request.environment['PAFIO_HOME'], '/isolated/pafio');
        request.onStarted?.call(
          const ProcessCommandHandle(
            processHandleId: 'h-1',
            sourceManager: 'scripted',
          ),
        );
        return _succeeded(
          request: request,
          stdout: jsonEncode(<String, Object?>{
            'status': 'succeeded',
            'command': 'run',
            'intent': 'run',
            'mode': 'execute',
            'styio': <String, Object?>{
              'status': 'succeeded',
              'process': <String, Object?>{'exit_code': 0},
            },
            'message': 'Project binary run completed through pafio.',
            'plan': <String, Object?>{'build_root': '.pafio/build/s-1'},
          }),
        );
      });
      final runtime = runtimeWith(
        process,
        pafioPath: '/usr/local/bin/pafio',
        environment: const {
          'HOME': '/isolated/home',
          'PAFIO_HOME': '/isolated/pafio',
        },
      );
      addTearDown(runtime.dispose);

      bool started = false;
      final outcome = await runtime.execute(
        FlowHeroExecutionKind.run,
        onStarted: () => started = true,
      );

      expect(started, isTrue);
      expect(outcome.phase, FlowHeroExecutionPhase.succeeded);
      expect(outcome.statusLine, contains('通过'));
      expect(outcome.receipt?.sessionId, 's-1');
      expect(outcome.receipt?.phases, hasLength(3));
      expect(outcome.receipt?.artifacts, hasLength(2));
      // The real command pafio is asked to run.
      expect(process.commands.single, <String>[
        '--json',
        'run',
        '--manifest-path',
        '${workspace.path}/pafio.toml',
        '--styio-bin',
        '/usr/bin/styio',
      ]);
    });

    test('a non-zero exit becomes an honest failure', () async {
      final oldBuild = Directory('${workspace.path}/.pafio/build/previous')
        ..createSync(recursive: true);
      File('${oldBuild.path}/receipt.json').writeAsStringSync(
        jsonEncode({
          'schema_version': 1,
          'intent': 'test',
          'session_id': 'old-success',
          'executed': true,
          'tool': 'styio',
          'artifacts': <String>[],
        }),
      );
      final process = _ScriptedProcessManager(
        (request) async => _failed(
          request: request,
          exitCode: 2,
          stderr: jsonEncode(<String, Object?>{'message': 'compile failed'}),
        ),
      );
      final runtime = runtimeWith(process, pafioPath: '/usr/local/bin/pafio');
      addTearDown(runtime.dispose);

      final outcome = await runtime.execute(FlowHeroExecutionKind.test);

      expect(outcome.phase, FlowHeroExecutionPhase.failed);
      expect(outcome.exitCode, 2);
      expect(outcome.statusLine, contains('exit 2'));
      expect(outcome.receiptText, contains('compile failed'));
      expect(outcome.receipt, isNull);
      expect(outcome.receiptText, isNot(contains('old-success')));
    });

    for (final scenario in <String>[
      'invalid envelope',
      'missing receipt',
      'wrong intent',
      'not executed',
      'unsupported receipt',
      'outside workspace',
      'missing session',
      'empty session',
      'wrong tool',
      'malformed artifacts',
      'malformed phases',
    ]) {
      test('zero exit cannot prove success with $scenario', () async {
        final buildRoot = Directory('${workspace.path}/.pafio/build/current')
          ..createSync(recursive: true);
        if (scenario != 'missing receipt') {
          File('${buildRoot.path}/receipt.json').writeAsStringSync(
            jsonEncode({
              'schema_version': scenario == 'unsupported receipt' ? 99 : 1,
              'tool': scenario == 'wrong tool' ? 'other' : 'styio',
              'intent': scenario == 'wrong intent' ? 'test' : 'run',
              if (scenario != 'missing session')
                'session_id': scenario == 'empty session' ? '  ' : 'fixture',
              'executed': scenario != 'not executed',
              'artifacts': scenario == 'malformed artifacts'
                  ? [42]
                  : <String>[],
              if (scenario == 'malformed phases') 'phases': [42],
            }),
          );
        }
        final process = _ScriptedProcessManager(
          (request) async => _succeeded(
            request: request,
            stdout: scenario == 'invalid envelope'
                ? 'not a result'
                : jsonEncode({
                    'status': 'succeeded',
                    'command': 'run',
                    'intent': 'run',
                    'mode': 'execute',
                    'styio': {
                      'status': 'succeeded',
                      'process': {'exit_code': 0},
                    },
                    'plan': {
                      'build_root': scenario == 'outside workspace'
                          ? '../outside'
                          : '.pafio/build/current',
                    },
                  }),
          ),
        );
        final runtime = runtimeWith(process, pafioPath: '/chosen/pafio');
        addTearDown(runtime.dispose);
        final outcome = await runtime.execute(FlowHeroExecutionKind.run);
        expect(outcome.phase, FlowHeroExecutionPhase.failed);
        expect(outcome.statusLine, '结果未验证');
        expect(outcome.receipt, isNull);
      });
    }

    test('a workspace-less boot is unavailable and never runs', () async {
      final runtime = await FlowHeroExecutionRuntime.boot(workspaceRoot: '');
      addTearDown(runtime.dispose);

      expect(runtime.live, isFalse);
      expect(runtime.unavailableReason, contains('未配置工作区'));

      final outcome = await runtime.execute(FlowHeroExecutionKind.run);
      expect(outcome.phase, FlowHeroExecutionPhase.failed);
      expect(outcome.receiptText, contains('未执行'));
    });
  });

  group('the running app', () {
    Future<void> boot(
      WidgetTester tester,
      FlowHeroExecutionSource source,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(() => P.dark = true);
      await tester.pumpWidget(FlowHeroApp(executionSource: source));
      await tester.pump();
    }

    Future<void> shutdown(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }

    testWidgets(
      'the test button runs the real route and posts only its receipt',
      (WidgetTester tester) async {
        final source = _FakeExecutionSource(live: true);
        await boot(tester, source);

        await tester.tap(find.byIcon(Icons.check_circle_outline));
        await tester.pump();
        expect(source.starts, 1);
        expect(source.lastKind, FlowHeroExecutionKind.test);

        source.complete(
          _outcome(
            FlowHeroExecutionKind.test,
            FlowHeroExecutionPhase.succeeded,
            receiptText: 'test 通过 · 0.04s · 阶段 2',
          ),
        );
        await tester.pump();

        expect(find.textContaining('test 通过'), findsOneWidget);
        // The old hardcoded claim is gone.
        expect(find.textContaining('flow_model_test 全部通过'), findsNothing);
        await shutdown(tester);
      },
    );

    testWidgets(
      'RUN/TEST stay disabled and surface the reason when unavailable',
      (WidgetTester tester) async {
        final source = _FakeExecutionSource(
          live: false,
          unavailableReason: '未发现 pafio · 请安装或设置 VITYO_PAFIO_BIN',
        );
        await boot(tester, source);

        expect(find.byKey(const ValueKey('run-strip-missing')), findsOneWidget);
        expect(find.byKey(const ValueKey('run-strip-run')), findsNothing);
        expect(find.byKey(const ValueKey('run-strip-clear')), findsNothing);
        expect(find.textContaining('未发现 pafio'), findsWidgets);

        await tester.tap(find.byIcon(Icons.check_circle_outline));
        await tester.pump();
        expect(source.starts, 0);
        await shutdown(tester);
      },
    );
    testWidgets('the title badge follows the agent link mode', (
      WidgetTester tester,
    ) async {
      P.dark = true;
      addTearDown(() => P.dark = true);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const FlowHeroApp());
      await tester.pump();

      // No agent workspace is configured in tests: the honest demo lamp.
      expect(find.text('DEMO'), findsOneWidget);
      expect(find.text('LIVE'), findsNothing);

      final FlowHeroController controller = tester
          .widget<HeroBoard>(find.byType(HeroBoard))
          .controller;
      controller.bridge.mode = AgentLinkMode.live;
      controller.refreshProjection();
      await tester.pump();

      expect(find.text('LIVE'), findsOneWidget);
      expect(find.text('DEMO'), findsNothing);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('the run strip missing state', () {
    Future<void> pumpStrip(
      WidgetTester tester,
      FlowHeroController controller,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(() => P.dark = true);
      await tester.pumpWidget(
        AnimatedBuilder(
          animation: controller,
          builder: (BuildContext context, _) =>
              MaterialApp(home: FlowHeroPage(controller: controller)),
        ),
      );
      await tester.pump();
    }

    Future<void> shutdown(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }

    FlowHeroController controllerWith(FlowHeroExecutionSource source) {
      final FlowHeroController controller = FlowHeroController(
        executionSource: source,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    String headline(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey('run-strip-missing-headline')))
        .data!;

    String reason(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey('run-strip-missing-reason')))
        .data!;

    // The absent transport is the point of the redesign: no dead chrome.
    void expectNoTransport(WidgetTester tester) {
      expect(find.text('RUN'), findsNothing);
      expect(find.byKey(const ValueKey('run-strip-run')), findsNothing);
      expect(find.byKey(const ValueKey('run-strip-clear')), findsNothing);
      expect(find.byKey(const ValueKey('run-strip-status')), findsNothing);
    }

    testWidgets('a missing pafio names the tool and where it was sought', (
      WidgetTester tester,
    ) async {
      final controller = controllerWith(
        _DiagnosedSource(
          statusLine: '未发现 pafio',
          unavailableReason: '未发现 pafio · 请安装或设置 VITYO_PAFIO_BIN',
          missingToolchains: const <FlowHeroToolchainKind>{
            FlowHeroToolchainKind.pafio,
          },
          toolchainChecks:
              <FlowHeroToolchainKind, List<FlowHeroToolchainCheck>>{
                FlowHeroToolchainKind.pafio: const <FlowHeroToolchainCheck>[
                  FlowHeroToolchainCheck(
                    source: '环境变量 VITYO_PAFIO_BIN',
                    path: '（未设置）',
                  ),
                  FlowHeroToolchainCheck(source: '已保存的用户选择', path: '（未保存）'),
                  FlowHeroToolchainCheck(
                    source: '系统路径',
                    path: '/usr/local/bin/pafio',
                  ),
                ],
              },
          unavailableCause: FlowHeroExecutionUnavailableCause.toolchain,
        ),
      );
      await pumpStrip(tester, controller);

      expect(find.byKey(const ValueKey('run-strip-missing')), findsOneWidget);
      expectNoTransport(tester);
      expect(headline(tester), 'Pafio 未就绪');
      expect(reason(tester), contains('未发现 pafio'));
      expect(reason(tester), contains('已查找'));
      expect(reason(tester), contains('环境变量 VITYO_PAFIO_BIN'));
      expect(find.text('安装'), findsOneWidget);
      await shutdown(tester);
    });

    testWidgets('a missing styio compiler is not reported as pafio', (
      WidgetTester tester,
    ) async {
      final controller = controllerWith(
        _DiagnosedSource(
          statusLine: '未发现 styio 编译器',
          unavailableReason: '未发现 styio 编译器 · 设置 VITYO_STYIO_BIN',
          missingToolchains: const <FlowHeroToolchainKind>{
            FlowHeroToolchainKind.styio,
          },
          toolchainChecks:
              <FlowHeroToolchainKind, List<FlowHeroToolchainCheck>>{
                FlowHeroToolchainKind.styio: const <FlowHeroToolchainCheck>[
                  FlowHeroToolchainCheck(
                    source: '环境变量 VITYO_STYIO_BIN',
                    path: '（未设置）',
                  ),
                ],
              },
          unavailableCause: FlowHeroExecutionUnavailableCause.toolchain,
        ),
      );
      await pumpStrip(tester, controller);

      expectNoTransport(tester);
      expect(headline(tester), 'Styio 未就绪');
      expect(reason(tester), contains('未发现 styio 编译器'));
      expect(find.textContaining('pafio'), findsNothing);
      await shutdown(tester);
    });

    testWidgets('both missing tools read as a toolchain, listing each', (
      WidgetTester tester,
    ) async {
      final controller = controllerWith(
        _DiagnosedSource(
          statusLine: '未发现 pafio',
          unavailableReason: '未发现 pafio · 请安装或设置 VITYO_PAFIO_BIN',
          missingToolchains: const <FlowHeroToolchainKind>{
            FlowHeroToolchainKind.pafio,
            FlowHeroToolchainKind.styio,
          },
          toolchainChecks:
              <FlowHeroToolchainKind, List<FlowHeroToolchainCheck>>{
                FlowHeroToolchainKind.pafio: const <FlowHeroToolchainCheck>[
                  FlowHeroToolchainCheck(
                    source: '系统路径',
                    path: '/usr/local/bin/pafio',
                  ),
                ],
                FlowHeroToolchainKind.styio: const <FlowHeroToolchainCheck>[
                  FlowHeroToolchainCheck(
                    source: '系统路径',
                    path: '/usr/local/bin/styio',
                  ),
                ],
              },
          unavailableCause: FlowHeroExecutionUnavailableCause.toolchain,
        ),
      );
      await pumpStrip(tester, controller);

      expectNoTransport(tester);
      expect(headline(tester), '执行工具链未就绪');
      expect(reason(tester), contains('pafio'));
      expect(reason(tester), contains('styio'));
      await shutdown(tester);
    });

    testWidgets('an unconfigured workspace owns the copy, not pafio', (
      WidgetTester tester,
    ) async {
      final controller = controllerWith(
        _DiagnosedSource(
          statusLine: '未配置工作区',
          unavailableReason: '未配置工作区 · 无法执行项目',
          unavailableCause: FlowHeroExecutionUnavailableCause.workspace,
        ),
      );
      await pumpStrip(tester, controller);

      expect(find.byKey(const ValueKey('run-strip-missing')), findsOneWidget);
      expectNoTransport(tester);
      expect(headline(tester), '未配置工作区');
      expect(find.textContaining('pafio'), findsNothing);
      expect(find.text('修复'), findsOneWidget);
      await shutdown(tester);
    });

    testWidgets('a workspace without pafio.toml says exactly that', (
      WidgetTester tester,
    ) async {
      final controller = controllerWith(
        _DiagnosedSource(
          statusLine: '工作区缺少 pafio.toml',
          unavailableReason: '工作区缺少 pafio.toml',
          unavailableCause: FlowHeroExecutionUnavailableCause.manifest,
        ),
      );
      await pumpStrip(tester, controller);

      expectNoTransport(tester);
      expect(headline(tester), '工作区缺少 pafio.toml');
      expect(find.text('安装'), findsNothing);
      expect(find.text('修复'), findsOneWidget);
      await shutdown(tester);
    });

    testWidgets('the missing state renders on the day palette too', (
      WidgetTester tester,
    ) async {
      P.dark = false;
      addTearDown(() => P.dark = true);
      final controller = controllerWith(
        _DiagnosedSource(
          statusLine: '未发现 pafio',
          unavailableReason: '未发现 pafio · 请安装或设置 VITYO_PAFIO_BIN',
          missingToolchains: const <FlowHeroToolchainKind>{
            FlowHeroToolchainKind.pafio,
          },
          unavailableCause: FlowHeroExecutionUnavailableCause.toolchain,
        ),
      );
      await pumpStrip(tester, controller);

      expect(find.byKey(const ValueKey('run-strip-missing')), findsOneWidget);
      expectNoTransport(tester);
      expect(headline(tester), 'Pafio 未就绪');
      await shutdown(tester);
    });

    testWidgets('the probe is announced while the route boots', (
      WidgetTester tester,
    ) async {
      final Completer<FlowHeroExecutionSource> boot =
          Completer<FlowHeroExecutionSource>();
      final FlowHeroController controller = FlowHeroController(
        executionBoot: (String _, FlowHeroToolchainSelection selection) =>
            boot.future,
      );
      addTearDown(controller.dispose);
      await pumpStrip(tester, controller);

      expect(find.byKey(const ValueKey('run-strip-probing')), findsOneWidget);
      expect(find.text('RUN'), findsNothing);
      expect(find.byKey(const ValueKey('run-strip-run')), findsNothing);
      expect(find.byKey(const ValueKey('run-strip-install')), findsNothing);

      boot.complete(_DiagnosedSource(live: true));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('run-strip-probing')), findsNothing);
      // The title and the RUN control both read RUN.
      expect(find.text('RUN'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('run-strip-run')), findsOneWidget);
      await shutdown(tester);
    });

    testWidgets('the install action opens the toolchain dialog', (
      WidgetTester tester,
    ) async {
      final controller = controllerWith(
        _DiagnosedSource(
          statusLine: '未发现 pafio',
          unavailableReason: '未发现 pafio · 请安装或设置 VITYO_PAFIO_BIN',
          missingToolchains: const <FlowHeroToolchainKind>{
            FlowHeroToolchainKind.pafio,
          },
          unavailableCause: FlowHeroExecutionUnavailableCause.toolchain,
        ),
      );
      await pumpStrip(tester, controller);

      expect(
        find.byKey(const ValueKey('toolchain-install-dialog')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('run-strip-install')));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('toolchain-install-dialog')),
        findsOneWidget,
      );
      await shutdown(tester);
    });

    testWidgets('a live route keeps the RUN title and transport', (
      WidgetTester tester,
    ) async {
      final controller = controllerWith(_DiagnosedSource(live: true));
      await pumpStrip(tester, controller);

      expect(find.byKey(const ValueKey('run-strip')), findsOneWidget);
      // The title and the RUN control both read RUN: the live strip is intact.
      expect(find.text('RUN'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('run-strip-run')), findsOneWidget);
      expect(find.byKey(const ValueKey('run-strip-clear')), findsOneWidget);
      expect(find.byKey(const ValueKey('run-strip-status')), findsOneWidget);
      expect(find.byKey(const ValueKey('run-strip-missing')), findsNothing);
      expect(find.byKey(const ValueKey('run-strip-install')), findsNothing);
      await shutdown(tester);
    });
  });
}
