import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/flow_hero/flow_hero.dart';
import 'package:vityo_app/src/view_render/flow_hero/controller.dart';
import 'package:vityo_app/src/view_render/flow_hero/toolchain_install.dart';

void main() {
  const candidate = FlowHeroToolchainCandidate(
    path: '/local/pafio',
    sourceLabel: 'System PATH',
    exists: true,
  );
  Future<void> mount(WidgetTester tester, FlowHeroController controller) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ToolchainInstallDialog(controller: controller)),
      ),
    );
    await tester.pump();
  }

  Future<void> finish(
    WidgetTester tester,
    FlowHeroController controller,
  ) async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  }

  String path(WidgetTester tester) => tester
      .widget<TextField>(
        find.byKey(const ValueKey('toolchain-install-path-pafio')),
      )
      .controller!
      .text;

  testWidgets(
    'discovery offers choices without replacing or verifying saved selection',
    (tester) async {
      var probes = 0;
      final controller = FlowHeroController(
        agentEnabled: false,
        initialToolchainSelection: const FlowHeroToolchainSelection(
          pafioPath: '/missing/pafio',
        ),
        toolchainCandidateDiscovery: (kind, selected) async {
          if (kind == FlowHeroToolchainKind.pafio) {
            expect(selected, '/missing/pafio');
          }
          return kind == FlowHeroToolchainKind.pafio ? [candidate] : [];
        },
        toolchainProbe: (kind, path) async {
          probes++;
          return const FlowHeroToolchainProbeResult(
            ok: true,
            detail: 'Version probe passed',
          );
        },
      );
      await mount(tester, controller);
      expect(path(tester), isEmpty);
      expect(controller.toolchainSelection.pafioPath, '/missing/pafio');
      await tester.tap(
        find.byKey(const ValueKey('toolchain-install-candidates-pafio')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('System PATH: /local/pafio').last);
      await tester.pumpAndSettle();
      expect(path(tester), '/local/pafio');
      await tester.enterText(
        find.byKey(const ValueKey('toolchain-install-path-pafio')),
        '/manual-before-verify',
      );
      await tester.pump();
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(const ValueKey('toolchain-install-candidates-pafio')),
            )
            .value,
        isNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('toolchain-install-path-pafio')),
        '/local/pafio',
      );
      await tester.pump();
      expect(probes, 0);
      expect(controller.toolchainSelection.pafioPath, '/missing/pafio');
      await tester.tap(
        find.byKey(const ValueKey('toolchain-install-verify-pafio')),
      );
      await tester.pump();
      expect(probes, 1);
      await tester.enterText(
        find.byKey(const ValueKey('toolchain-install-path-pafio')),
        '/changed/pafio',
      );
      await tester.pump();
      expect(find.text('Version probe passed'), findsNothing);
      await finish(tester, controller);
    },
  );

  testWidgets(
    'native file selection populates path and cancellation preserves it',
    (tester) async {
      var calls = 0;
      final controller = FlowHeroController(
        agentEnabled: false,
        toolchainFilePicker: (_) async => calls++ == 0 ? '/picked/pafio' : null,
      );
      await mount(tester, controller);
      final browse = find.byKey(
        const ValueKey('toolchain-install-browse-pafio'),
      );
      await tester.tap(browse);
      await tester.pump();
      expect(path(tester), '/picked/pafio');
      await tester.tap(browse);
      await tester.pump();
      expect(path(tester), '/picked/pafio');
      await finish(tester, controller);
    },
  );

  testWidgets('late picker does not overwrite newer manual input', (
    tester,
  ) async {
    final picker = Completer<String?>();
    final controller = FlowHeroController(
      agentEnabled: false,
      toolchainFilePicker: (_) => picker.future,
    );
    await mount(tester, controller);
    await tester.tap(
      find.byKey(const ValueKey('toolchain-install-browse-pafio')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('toolchain-install-path-pafio')),
      '/newer/pafio',
    );
    picker.complete('/older/pafio');
    await tester.pump();
    expect(path(tester), '/newer/pafio');
    await finish(tester, controller);
  });

  testWidgets('closed dialog ignores late discovery and picker completions', (
    tester,
  ) async {
    final discovery = Completer<List<FlowHeroToolchainCandidate>>();
    final picker = Completer<String?>();
    final controller = FlowHeroController(
      agentEnabled: false,
      toolchainCandidateDiscovery: (_, _) => discovery.future,
      toolchainFilePicker: (_) => picker.future,
    );
    await mount(tester, controller);
    await tester.tap(
      find.byKey(const ValueKey('toolchain-install-browse-pafio')),
    );
    await tester.pump();
    await finish(tester, controller);
    discovery.complete([candidate]);
    picker.complete('/late/pafio');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'partial scan is disclosed while file selection remains available',
    (tester) async {
      final controller = FlowHeroController(
        agentEnabled: false,
        toolchainCandidateDiscovery: (_, _) async =>
            FlowHeroToolchainCandidateCatalog(const [], isPartial: true),
      );
      await mount(tester, controller);
      expect(
        find.byKey(const ValueKey('toolchain-install-partial-pafio')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('toolchain-install-browse-pafio')),
        findsOneWidget,
      );
      expect(
        find.text(
          'No suggestions found in the checked locations. Choose a file below.',
        ),
        findsNWidgets(2),
      );
      await finish(tester, controller);
    },
  );

  testWidgets(
    'unavailable picker exposes manual fallback without clearing input',
    (tester) async {
      final controller = FlowHeroController(
        agentEnabled: false,
        toolchainFilePicker: (_) async => throw StateError('Unavailable'),
      );
      await mount(tester, controller);
      await tester.enterText(
        find.byKey(const ValueKey('toolchain-install-path-pafio')),
        '/manual/pafio',
      );
      await tester.tap(
        find.byKey(const ValueKey('toolchain-install-browse-pafio')),
      );
      await tester.pump();
      expect(path(tester), '/manual/pafio');
      expect(
        find.text(
          'The file chooser is unavailable. Use the manual path fallback.',
        ),
        findsOneWidget,
      );
      await finish(tester, controller);
    },
  );
}
