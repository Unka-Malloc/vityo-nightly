import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/flow_hero/flow_hero.dart';
import 'package:vityo_app/src/view_render/flow_hero/controller.dart';
import 'package:vityo_app/src/view_render/flow_hero/toolchain_install.dart';

class _Controller extends FlowHeroController {
  _Controller(this.pair) : super(agentEnabled: false);
  final FlowHeroToolchainPairCheck pair;
  @override
  FlowHeroToolchainPairCheck get toolchainPairCheck => pair;
  @override
  String resolvedToolchainPath(FlowHeroToolchainKind kind) =>
      '/selected/${kind.id}';
  @override
  String resolvedToolchainOrigin(FlowHeroToolchainKind kind) =>
      'Saved user selection';
  @override
  String get executionUnavailableReason => pair.compatible ? '' : pair.message;
  @override
  bool get executionLive => pair.compatible;
}

void main() {
  for (final reported in [true, false]) {
    testWidgets('compatible pair with provenance reported=$reported', (
      tester,
    ) async {
      final controller = _Controller(
        FlowHeroToolchainPairCheck(
          compatible: true,
          productSupport: reported ? 'published' : '',
          releaseProvenance: reported ? 'unverified' : '',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ToolchainInstallDialog(controller: controller)),
        ),
      );
      expect(find.text('Runtime compatibility: Compatible'), findsOneWidget);
      expect(
        find.text('Selected: Saved user selection\n/selected/pafio'),
        findsOneWidget,
      );
      expect(
        find.text('Release provenance: Not verified by Vityo'),
        findsOneWidget,
      );
      expect(
        find.text(
          reported
              ? 'Release provenance: Unverified (Pafio report)'
              : 'Release provenance: Not verified by Vityo; no supported report',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          reported
              ? 'Published support: Listed in Pafio matrix'
              : 'Published support: Not reported',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }
  testWidgets('compatibility failure remains prominent beside provenance', (
    tester,
  ) async {
    final controller = _Controller(
      const FlowHeroToolchainPairCheck(
        compatible: false,
        message: 'Missing capability: jsonl_diagnostics',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ToolchainInstallDialog(controller: controller)),
      ),
    );
    expect(
      find.textContaining('Missing capability: jsonl_diagnostics'),
      findsOneWidget,
    );
    expect(find.text('Runtime compatibility: Incompatible'), findsOneWidget);
    expect(
      find.text('Release provenance: Not verified by Vityo'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
