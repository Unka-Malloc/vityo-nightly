import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';
import 'package:vityo_app/src/view_ide/flow_hero/flow_hero.dart';
import 'package:vityo_app/src/view_ide/toolchain/toolchain.dart';
import 'package:vityo_app/src/view_render/flow_hero/controller.dart';
import 'package:vityo_app/src/view_ide/flow_hero/execution_service.dart';
import 'package:vityo_app/src/view_render/flow_hero/flow_hero.dart';
import 'package:vityo_app/src/view_render/flow_hero/palette.dart';

import 'support/vityod_test_harness.dart';

/// A scripted execution route that also carries the toolchain diagnosis the
/// install dialog reads. Nothing here is presented as a real probe.
class _FakeSource
    implements FlowHeroExecutionSource, FlowHeroToolchainDiagnosis {
  _FakeSource({
    required this.live,
    this.unavailableReason = '',
    this.missingToolchains = const <FlowHeroToolchainKind>{},
    this.toolchainChecks =
        const <FlowHeroToolchainKind, List<FlowHeroToolchainCheck>>{},
  });

  @override
  final bool live;

  @override
  String get statusLine => 'pafio run/test';

  @override
  final String unavailableReason;

  @override
  final Set<FlowHeroToolchainKind> missingToolchains;

  @override
  final Map<FlowHeroToolchainKind, List<FlowHeroToolchainCheck>>
  toolchainChecks;

  int starts = 0;

  /// This scripted route always reports a missing tool set instead of a
  /// classified cause; the strip's toolchain branch reads that directly.
  @override
  FlowHeroExecutionUnavailableCause? get unavailableCause => null;

  @override
  FlowHeroExecutionMode get mode =>
      live ? FlowHeroExecutionMode.live : FlowHeroExecutionMode.unavailable;

  @override
  Future<FlowHeroExecutionOutcome> execute(
    FlowHeroExecutionKind kind, {
    VoidCallback? onStarted,
  }) async {
    starts++;
    onStarted?.call();
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

class _FakeToolchainStore implements FlowHeroToolchainStore {
  FlowHeroToolchainSelection? stored;
  Completer<FlowHeroToolchainSelection?>? loadGate;
  Completer<void>? saveGate;
  final List<String> saves = <String>[];

  @override
  bool get persistent => true;

  @override
  Future<FlowHeroToolchainSelection?> load() async {
    final Completer<FlowHeroToolchainSelection?>? gate = loadGate;
    return gate == null ? stored : await gate.future;
  }

  @override
  Future<void> savePath(FlowHeroToolchainKind kind, String path) async {
    await saveGate?.future;
    saves.add('${kind.id}=$path');
    stored = (stored ?? const FlowHeroToolchainSelection()).withPath(
      kind,
      path,
    );
  }

  @override
  Future<void> clearPath(FlowHeroToolchainKind kind) async {
    stored = (stored ?? const FlowHeroToolchainSelection()).withPath(kind, '');
  }
}

Map<FlowHeroToolchainKind, List<FlowHeroToolchainCheck>> _pafioChecks() {
  return <FlowHeroToolchainKind, List<FlowHeroToolchainCheck>>{
    FlowHeroToolchainKind.pafio: const <FlowHeroToolchainCheck>[
      FlowHeroToolchainCheck(source: '环境变量 VITYO_PAFIO_BIN', path: '（未设置）'),
      FlowHeroToolchainCheck(source: '已保存的用户选择', path: '（未保存）'),
      FlowHeroToolchainCheck(
        source: '应用内置',
        path: '/Apps/Vityo.app/Contents/Resources/pafio-component.json',
      ),
      FlowHeroToolchainCheck(source: '系统路径', path: '/usr/local/bin/pafio'),
    ],
  };
}

void main() {
  group('controller install flow', () {
    late _FakeToolchainStore store;
    late List<FlowHeroToolchainSelection> boots;

    FlowHeroController build({
      required Future<FlowHeroToolchainProbeResult> Function(
        FlowHeroToolchainKind,
        String,
      )
      probe,
      FlowHeroLanguageBoot? languageBoot,
    }) {
      boots = <FlowHeroToolchainSelection>[];
      final controller = FlowHeroController(
        executionSource: _FakeSource(
          live: false,
          unavailableReason: '未发现 pafio · 请安装或设置 VITYO_PAFIO_BIN',
          missingToolchains: const <FlowHeroToolchainKind>{
            FlowHeroToolchainKind.pafio,
          },
          toolchainChecks: _pafioChecks(),
        ),
        toolchainStore: store,
        toolchainProbe: probe,
        languageBoot: languageBoot,
        executionBoot: (String _, FlowHeroToolchainSelection selection) async {
          boots.add(selection);
          if (selection.pafioPath.isEmpty) {
            return _FakeSource(
              live: false,
              unavailableReason: '未发现 pafio · 请安装或设置 VITYO_PAFIO_BIN',
              missingToolchains: const <FlowHeroToolchainKind>{
                FlowHeroToolchainKind.pafio,
              },
              toolchainChecks: _pafioChecks(),
            );
          }
          return _FakeSource(live: true);
        },
      );
      addTearDown(controller.dispose);
      return controller;
    }

    setUp(() => store = _FakeToolchainStore());

    test('the missing detail and checked locations are exposed', () async {
      final controller = build(
        probe: (FlowHeroToolchainKind _, String __) async =>
            const FlowHeroToolchainProbeResult(ok: true, detail: 'ok'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.missingToolchains, <FlowHeroToolchainKind>{
        FlowHeroToolchainKind.pafio,
      });
      expect(
        controller.toolchainChecks[FlowHeroToolchainKind.pafio]?.map(
          (FlowHeroToolchainCheck c) => c.source,
        ),
        contains('环境变量 VITYO_PAFIO_BIN'),
      );
    });

    test('probeToolchainCandidate reports the real failure', () async {
      final controller = build(
        probe: (FlowHeroToolchainKind _, String path) async =>
            const FlowHeroToolchainProbeResult(
              ok: false,
              detail: 'pafio 验证失败 · exit 3',
              failure: 'exit 3',
            ),
      );
      await Future<void>.delayed(Duration.zero);

      final result = await controller.probeToolchainCandidate(
        FlowHeroToolchainKind.pafio,
        '/tmp/pafio',
      );
      expect(result.ok, isFalse);
      expect(result.failure, 'exit 3');
    });

    test('a probe that throws becomes an honest failure result', () async {
      final controller = build(
        probe: (FlowHeroToolchainKind _, String __) async =>
            throw StateError('boom'),
      );
      await Future<void>.delayed(Duration.zero);

      final result = await controller.probeToolchainCandidate(
        FlowHeroToolchainKind.pafio,
        '/tmp/pafio',
      );
      expect(result.ok, isFalse);
      expect(result.detail, contains('无法探测'));
    });

    test(
      'saving persists, re-boots the route, and reports the new state',
      () async {
        final controller = build(
          probe: (FlowHeroToolchainKind _, String __) async =>
              const FlowHeroToolchainProbeResult(ok: true, detail: 'ok'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(controller.executionLive, isFalse);

        final result = await controller.saveToolchainOverride(
          FlowHeroToolchainKind.pafio,
          '/tmp/pafio',
        );

        expect(result.saved, isTrue);
        expect(store.saves, <String>['pafio=/tmp/pafio']);
        expect(controller.toolchainSelection.pafioPath, '/tmp/pafio');
        expect(controller.executionLive, isTrue);
        expect(result.stateLine, 'pafio run/test');
        expect(boots.last.pafioPath, '/tmp/pafio');
      },
    );

    test(
      'dispatch stays gated until a toolchain choice is persisted',
      () async {
        store.saveGate = Completer<void>();
        final List<_FakeSource> routes = <_FakeSource>[];
        final controller = FlowHeroController(
          toolchainStore: store,
          executionBoot:
              (String _, FlowHeroToolchainSelection selection) async {
                final source = _FakeSource(live: true);
                routes.add(source);
                return source;
              },
        );
        addTearDown(controller.dispose);
        await controller.workspaceBootSettled;
        expect(controller.canExecute, isTrue);

        final Future<FlowHeroToolchainSaveResult> saving = controller
            .saveToolchainOverride(
              FlowHeroToolchainKind.pafio,
              '/tmp/next-pafio',
            );
        expect(controller.canExecute, isFalse);
        expect(controller.executionUnavailableReason, '正在保存工具链选择…');
        await controller.runExecution(FlowHeroExecutionKind.run);
        expect(routes.first.starts, 0);

        store.saveGate!.complete();
        final FlowHeroToolchainSaveResult result = await saving;
        expect(result.saved, isTrue);
        expect(routes, hasLength(2));
        expect(controller.toolchainSelection.pafioPath, '/tmp/next-pafio');
        expect(controller.canExecute, isTrue);
      },
    );

    test(
      'a manual toolchain choice wins over startup restore completing mid-save',
      () async {
        store
          ..loadGate = Completer<FlowHeroToolchainSelection?>()
          ..saveGate = Completer<void>();
        final List<FlowHeroToolchainSelection> routes =
            <FlowHeroToolchainSelection>[];
        final controller = FlowHeroController(
          toolchainStore: store,
          executionBoot:
              (String _, FlowHeroToolchainSelection selection) async {
                routes.add(selection);
                return _FakeSource(live: true);
              },
        );
        addTearDown(controller.dispose);
        final Future<void> startup = controller.workspaceBootSettled;
        final Future<FlowHeroToolchainSaveResult> saving = controller
            .saveToolchainOverride(
              FlowHeroToolchainKind.pafio,
              '/tmp/manual-pafio',
            );

        store.loadGate!.complete(
          const FlowHeroToolchainSelection(
            pafioPath: '/tmp/stale-pafio',
            styioPath: '/tmp/stale-styio',
          ),
        );
        await startup;
        expect(
          controller.toolchainSelection,
          const FlowHeroToolchainSelection(),
          reason: 'startup restore waits behind the in-flight user choice',
        );

        store.saveGate!.complete();
        expect((await saving).saved, isTrue);
        expect(
          controller.toolchainSelection,
          const FlowHeroToolchainSelection(pafioPath: '/tmp/manual-pafio'),
        );
        expect(
          routes.any((selection) => selection.pafioPath == '/tmp/stale-pafio'),
          isFalse,
          reason: 'the stale restored route must never boot',
        );
      },
    );

    test(
      'a failed toolchain save releases the still-current stored selection',
      () async {
        store
          ..loadGate = Completer<FlowHeroToolchainSelection?>()
          ..saveGate = Completer<void>();
        final controller = FlowHeroController(
          toolchainStore: store,
          executionBoot: (String _, FlowHeroToolchainSelection __) async =>
              _FakeSource(live: true),
        );
        addTearDown(controller.dispose);
        final Future<void> startup = controller.workspaceBootSettled;
        final Future<FlowHeroToolchainSaveResult> saving = controller
            .saveToolchainOverride(
              FlowHeroToolchainKind.pafio,
              '/tmp/unpersisted-pafio',
            );
        const FlowHeroToolchainSelection restored = FlowHeroToolchainSelection(
          pafioPath: '/tmp/stored-pafio',
          styioPath: '/tmp/stored-styio',
        );
        store.loadGate!.complete(restored);
        await startup;
        store.saveGate!.completeError(StateError('write failed'));

        expect((await saving).saved, isFalse);
        expect(controller.toolchainSelection, restored);
      },
    );

    test('an empty path is refused before anything is written', () async {
      final controller = build(
        probe: (FlowHeroToolchainKind _, String __) async =>
            const FlowHeroToolchainProbeResult(ok: true, detail: 'ok'),
      );
      await Future<void>.delayed(Duration.zero);

      final result = await controller.saveToolchainOverride(
        FlowHeroToolchainKind.pafio,
        '   ',
      );
      expect(result.saved, isFalse);
      expect(store.saves, isEmpty);
    });

    test(
      'fixing Styio reports honestly when the language route cannot re-boot',
      () async {
        final controller = build(
          probe: (FlowHeroToolchainKind _, String __) async =>
              const FlowHeroToolchainProbeResult(ok: true, detail: 'ok'),
          languageBoot: (String _, FlowHeroToolchainSelection __) async {
            throw StateError('language boot unavailable');
          },
        );
        await Future<void>.delayed(Duration.zero);

        final result = await controller.saveToolchainOverride(
          FlowHeroToolchainKind.styio,
          '/tmp/styio',
        );
        expect(result.saved, isTrue);
        expect(result.languageNote, contains('语言服务将在重启后使用新工具链'));
      },
    );

    test(
      'the restored Styio selection owns the language route at startup',
      () async {
        store.stored = const FlowHeroToolchainSelection(
          styioPath: '/tmp/styio',
        );
        final List<FlowHeroToolchainSelection> languageBoots =
            <FlowHeroToolchainSelection>[];
        final controller = FlowHeroController(
          executionSource: _FakeSource(
            live: false,
            unavailableReason: '未发现 styio',
          ),
          toolchainStore: store,
          executionBoot:
              (String _, FlowHeroToolchainSelection selection) async =>
                  _FakeSource(live: selection.styioPath.isNotEmpty),
          languageBoot: (String _, FlowHeroToolchainSelection selection) async {
            languageBoots.add(selection);
            throw StateError('no language runtime in this test');
          },
        );
        addTearDown(controller.dispose);
        for (int i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(controller.toolchainSelection.styioPath, '/tmp/styio');
        expect(controller.executionLive, isTrue);
        expect(languageBoots.last.styioPath, '/tmp/styio');
      },
    );

    test('openToolchainInstall toggles the dialog state', () async {
      final controller = build(
        probe: (FlowHeroToolchainKind _, String __) async =>
            const FlowHeroToolchainProbeResult(ok: true, detail: 'ok'),
      );
      await Future<void>.delayed(Duration.zero);

      controller.openToolchainInstall();
      expect(controller.toolchainInstallVisible, isTrue);
      controller.closeToolchainInstall();
      expect(controller.toolchainInstallVisible, isFalse);
    });
  });

  group('boot with a persisted toolchain', () {
    setUpAll(() async {
      if (VityodTestHarness.isSupported) {
        _harnessInstance = await VityodTestHarness.start(
          clientId: 'flow-hero-toolchain-install-test',
        );
      }
    });

    tearDownAll(() => _harnessInstance?.close());

    test(
      'a stored pafio/styio turns a previously-unavailable route live',
      () async {
        final tempRoot = await Directory.systemTemp.createTemp(
          'flow_hero_toolchain_boot_',
        );
        addTearDown(() => tempRoot.delete(recursive: true));
        final managers = await _managers(tempRoot);
        final pafioPath = managers.fileSystem.joinPath(<String>[
          tempRoot.path,
          'custom',
          'pafio',
        ]);
        final styioPath = managers.fileSystem.joinPath(<String>[
          tempRoot.path,
          'custom',
          'styio',
        ]);
        await _makeVersionBinary(
          managers,
          pafioPath,
          doctorStyioPath: styioPath,
        );
        await _makeVersionBinary(managers, styioPath);
        await managers.fileSystem.writeText(
          managers.fileSystem.joinPath(<String>[tempRoot.path, 'pafio.toml']),
          '[project]\nname = "demo"\n',
        );

        final offline = await FlowHeroExecutionRuntime.boot(
          workspaceRoot: tempRoot.path,
          platformManagers: managers,
          environment: const <String, String>{},
          pafioSystemCandidatePaths: const <String>[],
        );
        addTearDown(offline.dispose);
        expect(offline.live, isFalse);
        expect(
          offline.missingToolchains,
          contains(FlowHeroToolchainKind.pafio),
          reason: 'no pafio is reachable without the stored selection',
        );

        final online = await FlowHeroExecutionRuntime.boot(
          workspaceRoot: tempRoot.path,
          platformManagers: managers,
          environment: const <String, String>{},
          pafioSystemCandidatePaths: const <String>[],
          toolchainSelection: FlowHeroToolchainSelection(
            pafioPath: pafioPath,
            styioPath: styioPath,
          ),
        );
        addTearDown(online.dispose);

        expect(online.live, isTrue);
        expect(online.pafioBinaryPath, pafioPath);
        expect(online.styioBinaryPath, styioPath);
        expect(online.missingToolchains, isEmpty);
        expect(
          online.toolchainChecks[FlowHeroToolchainKind.pafio],
          isNotEmpty,
          reason: 'the checks recorded by boot are shown in the dialog',
        );
      },
      skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
    );

    test(
      'the stored Styio path is probed before a bundled copy (env > stored > bundled)',
      () async {
        final tempRoot = await Directory.systemTemp.createTemp(
          'flow_hero_toolchain_order_',
        );
        addTearDown(() => tempRoot.delete(recursive: true));
        final managers = await _managers(tempRoot);
        final appExecutable = '${tempRoot.path}/Vityo.app/Contents/MacOS/vityo';
        final bundledStyio =
            '${tempRoot.path}/Vityo.app/Contents/Helpers/styio';
        final storedStyio = managers.fileSystem.joinPath(<String>[
          tempRoot.path,
          'stored',
          'styio',
        ]);
        await _makeVersionBinary(managers, bundledStyio);
        await _makeVersionBinary(managers, storedStyio);

        // boot delivers a stored Styio pick as the probe's explicit override,
        // i.e. the slot between the real environment and the bundled copy.
        final catalog = await createPlatformStyioLanguageToolchainCatalog(
          platformManagers: managers,
          environment: <String, String>{'VITYO_STYIO_BIN': storedStyio},
          bundledExecutablePath: appExecutable,
          candidatePaths: const <String>[],
        );

        expect(
          catalog.active(ToolchainKind.languageService)?.executablePath,
          storedStyio,
        );
        expect(storedStyio, isNot(bundledStyio));
      },
      skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
    );
  });

  group('the running app', () {
    late _FakeToolchainStore store;
    late bool probeOk;
    late int bootCount;

    FlowHeroController buildController({FlowHeroExecutionBoot? boot}) {
      bootCount = 0;
      final controller = FlowHeroController(
        executionSource: _FakeSource(
          live: false,
          unavailableReason: '未发现 pafio · 请安装或设置 VITYO_PAFIO_BIN',
          missingToolchains: const <FlowHeroToolchainKind>{
            FlowHeroToolchainKind.pafio,
          },
          toolchainChecks: _pafioChecks(),
        ),
        toolchainStore: store,
        toolchainProbe: (FlowHeroToolchainKind kind, String path) async {
          if (probeOk) {
            return const FlowHeroToolchainProbeResult(
              ok: true,
              detail: 'pafio 1.2.3',
              versionOutput: 'pafio 1.2.3',
            );
          }
          return const FlowHeroToolchainProbeResult(
            ok: false,
            detail: 'pafio 验证失败 · exit 3',
            failure: 'exit 3',
          );
        },
        executionBoot:
            boot ??
            (String _, FlowHeroToolchainSelection selection) async {
              bootCount++;
              if (selection.pafioPath.isEmpty) {
                return _FakeSource(
                  live: false,
                  unavailableReason: '未发现 pafio · 请安装或设置 VITYO_PAFIO_BIN',
                  missingToolchains: const <FlowHeroToolchainKind>{
                    FlowHeroToolchainKind.pafio,
                  },
                  toolchainChecks: _pafioChecks(),
                );
              }
              return _FakeSource(live: true);
            },
      );
      addTearDown(controller.dispose);
      return controller;
    }

    Future<void> boot(
      WidgetTester tester,
      FlowHeroController controller,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(() => P.dark = true);
      await tester.pumpWidget(
        // Mirrors FlowHeroApp: the page is a projection of the controller, so
        // the test drives it through the same AnimatedBuilder the app uses.
        AnimatedBuilder(
          animation: controller,
          builder: (BuildContext context, _) =>
              MaterialApp(home: FlowHeroPage(controller: controller)),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    Future<void> shutdown(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }

    setUp(() {
      P.dark = true;
      store = _FakeToolchainStore();
      probeOk = false;
    });

    testWidgets(
      'the strip opens a dialog that shows the real checked locations',
      (WidgetTester tester) async {
        final controller = buildController();
        await boot(tester, controller);

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
        expect(
          find.byKey(const ValueKey('toolchain-install-section-pafio')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('toolchain-install-section-styio')),
          findsOneWidget,
          reason: 'an installed tool can still be replaced to select a pair',
        );
        expect(find.text('环境变量 VITYO_PAFIO_BIN'), findsOneWidget);
        expect(find.text('已保存的用户选择'), findsOneWidget);
        expect(find.text('/usr/local/bin/pafio'), findsOneWidget);
        await shutdown(tester);
      },
    );

    for (final missingKind in FlowHeroToolchainKind.values) {
      testWidgets(
        'the other tool can be selected while only ${missingKind.id} is missing',
        (WidgetTester tester) async {
          final selectedKind = FlowHeroToolchainKind.values.firstWhere(
            (kind) => kind != missingKind,
          );
          final controller = FlowHeroController(
            executionSource: _FakeSource(
              live: false,
              unavailableReason: '未发现 ${missingKind.id}',
              missingToolchains: <FlowHeroToolchainKind>{missingKind},
            ),
            toolchainStore: store,
            toolchainProbe: (FlowHeroToolchainKind _, String __) async =>
                const FlowHeroToolchainProbeResult(ok: true, detail: 'ok'),
            executionBoot: (String _, FlowHeroToolchainSelection __) async =>
                _FakeSource(
                  live: false,
                  unavailableReason: '未发现 ${missingKind.id}',
                  missingToolchains: <FlowHeroToolchainKind>{missingKind},
                ),
          );
          addTearDown(controller.dispose);
          await boot(tester, controller);
          controller.openToolchainInstall();
          await tester.pump();

          final selectedPath = '/tmp/selected-${selectedKind.id}';
          final pathField = find.byKey(
            ValueKey('toolchain-install-path-${selectedKind.id}'),
          );
          await tester.ensureVisible(pathField);
          await tester.enterText(pathField, selectedPath);
          final verify = find.byKey(
            ValueKey('toolchain-install-verify-${selectedKind.id}'),
          );
          await tester.ensureVisible(verify);
          await tester.tap(verify);
          await tester.pump();
          await tester.pump();
          final save = find.byKey(
            ValueKey('toolchain-install-save-${selectedKind.id}'),
          );
          await tester.ensureVisible(save);
          await tester.tap(save);
          await tester.pump();
          await tester.pump();

          expect(store.saves, <String>['${selectedKind.id}=$selectedPath']);
          expect(controller.executionLive, isFalse);
          for (final kind in FlowHeroToolchainKind.values) {
            expect(
              find.byKey(ValueKey('toolchain-install-section-${kind.id}')),
              findsOneWidget,
            );
          }
          await shutdown(tester);
        },
      );
    }

    testWidgets('both missing tools get a section, pafio first', (
      WidgetTester tester,
    ) async {
      final controller = FlowHeroController(
        executionSource: _FakeSource(
          live: false,
          unavailableReason: '未发现 pafio · 请安装或设置 VITYO_PAFIO_BIN',
          missingToolchains: const <FlowHeroToolchainKind>{
            FlowHeroToolchainKind.pafio,
            FlowHeroToolchainKind.styio,
          },
          toolchainChecks:
              <FlowHeroToolchainKind, List<FlowHeroToolchainCheck>>{
                ..._pafioChecks(),
                FlowHeroToolchainKind.styio: const <FlowHeroToolchainCheck>[
                  FlowHeroToolchainCheck(
                    source: '环境变量 VITYO_STYIO_BIN',
                    path: '（未设置）',
                  ),
                ],
              },
        ),
        toolchainStore: store,
        toolchainProbe: (FlowHeroToolchainKind _, String __) async =>
            const FlowHeroToolchainProbeResult(ok: true, detail: 'ok'),
      );
      addTearDown(controller.dispose);
      await boot(tester, controller);

      await tester.tap(find.byKey(const ValueKey('run-strip-install')));
      await tester.pump();

      final Finder pafio = find.byKey(
        const ValueKey('toolchain-install-section-pafio'),
      );
      final Finder styio = find.byKey(
        const ValueKey('toolchain-install-section-styio'),
      );
      expect(pafio, findsOneWidget);
      expect(styio, findsOneWidget);
      expect(
        tester.getTopLeft(pafio).dy,
        lessThan(tester.getTopLeft(styio).dy),
        reason: 'pafio is shown first',
      );
      expect(find.text('环境变量 VITYO_STYIO_BIN'), findsOneWidget);
      await shutdown(tester);
    });

    testWidgets('a failed 验证 shows the real failure and blocks saving', (
      WidgetTester tester,
    ) async {
      final controller = buildController();
      await boot(tester, controller);
      await tester.tap(find.byKey(const ValueKey('run-strip-install')));
      await tester.pump();

      await tester.enterText(
        find.byKey(const ValueKey('toolchain-install-path-pafio')),
        '/tmp/pafio',
      );
      await tester.tap(
        find.byKey(const ValueKey('toolchain-install-verify-pafio')),
      );
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('exit 3'), findsOneWidget);
      expect(store.saves, isEmpty);

      // Saving without a passing verification is not offered.
      await tester.tap(
        find.byKey(const ValueKey('toolchain-install-save-pafio')),
      );
      await tester.pump();
      expect(store.saves, isEmpty);
      await shutdown(tester);
    });

    testWidgets('a passing 验证 then 保存并启用 persists and re-boots the strip', (
      WidgetTester tester,
    ) async {
      final controller = buildController();
      await boot(tester, controller);
      await tester.tap(find.byKey(const ValueKey('run-strip-install')));
      await tester.pump();

      await tester.enterText(
        find.byKey(const ValueKey('toolchain-install-path-pafio')),
        '/tmp/pafio',
      );
      probeOk = true;
      await tester.tap(
        find.byKey(const ValueKey('toolchain-install-verify-pafio')),
      );
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('pafio 1.2.3'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('toolchain-install-save-pafio')),
      );
      await tester.pump();
      await tester.pump();

      expect(store.saves, <String>['pafio=/tmp/pafio']);
      expect(controller.executionLive, isTrue);
      expect(bootCount, greaterThan(0));
      expect(
        find.byKey(const ValueKey('toolchain-install-note')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('toolchain-install-cancel')));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('toolchain-install-dialog')),
        findsNothing,
      );
      expect(find.text('pafio run/test'), findsOneWidget);
      await shutdown(tester);
    });

    testWidgets('重新探测 re-boots and reports the real state', (
      WidgetTester tester,
    ) async {
      final controller = buildController();
      await boot(tester, controller);
      final int before = bootCount;

      await tester.tap(find.byKey(const ValueKey('run-strip-install')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('toolchain-install-retry')));
      await tester.pump();
      await tester.pump();

      expect(bootCount, greaterThan(before));
      expect(
        find.byKey(const ValueKey('toolchain-install-note')),
        findsOneWidget,
      );
      await shutdown(tester);
    });

    testWidgets('the settings panel execution row opens the dialog', (
      WidgetTester tester,
    ) async {
      final controller = buildController();
      await boot(tester, controller);

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pump();
      expect(find.text('执行服务'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('settings-execution-install')),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('toolchain-install-dialog')),
        findsOneWidget,
      );
      await shutdown(tester);
    });
  });
}

VityodTestHarness? _harnessInstance;

Future<PlatformManagerBundle> _managers(Directory root) async {
  final harness = _harnessInstance;
  if (harness == null) {
    throw StateError('vityod test harness is unavailable.');
  }
  final context = PlatformContextSnapshot.compose(
    targetId: 'flow-hero-toolchain',
    fileSystem: FileSystemFacts.linuxDebianArm(targetId: 'flow-hero-toolchain'),
    shell: ShellFacts.linuxDebianArm(
      targetId: 'flow-hero-toolchain',
      defaultShellPath: '/bin/sh',
    ),
  );
  return createPlatformManagerBundle(
    platformContext: context,
    vityodClient: harness.client,
    workspaceRoot: root.path,
  );
}

Future<void> _makeVersionBinary(
  PlatformManagerBundle managers,
  String path, {
  String? doctorStyioPath,
}) async {
  final doctorResponse = jsonEncode(<String, Object?>{
    'command': 'doctor',
    'checks': <Object?>[
      <String, Object?>{
        'name': 'styio',
        'status': 'ok',
        'detail': <String, Object?>{
          'binary': doctorStyioPath,
          'supported_compile_plan_versions': <int>[1],
        },
      },
    ],
  });
  await managers.fileSystem.writeText(
    path,
    '#!/bin/sh\n'
    'if [ "\$1" = "--version" ]; then echo "1.2.3"; exit 0; fi\n'
    '${doctorStyioPath == null ? '' : 'if [ "\$1" = "--json" ] && [ "\$2" = "doctor" ]; then\n'
              "  echo '$doctorResponse'\n"
              '  exit 0\n'
              'fi\n'}'
    'exit 2\n',
  );
  await managers.fileSystem.setExecutable(path);
}
