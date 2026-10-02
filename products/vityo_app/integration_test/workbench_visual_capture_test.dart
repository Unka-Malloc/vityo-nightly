import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vityo_app/src/frontend_shell/frontend_shell.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('captures obsidian workbench surfaces', (tester) async {
    expect(Platform.isMacOS, isTrue, reason: 'run this lane on macOS');
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 960);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final bootstrap = await AppBootstrap.load();
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('workbench-visual-capture'),
        child: VityoApp(bootstrap: bootstrap),
      ),
    );
    await tester.pumpAndSettle();

    final shell = ShellScope.of(
      tester.element(find.byType(VityoShellScaffold)),
    );

    await _capture(tester, 'obsidian-editor');

    shell.selectWorkbenchRoute(WorkbenchRoute.commandPalette);
    await tester.pumpAndSettle();
    await _capture(tester, 'obsidian-command-palette');

    shell.selectWorkbenchRoute(WorkbenchRoute.settings);
    await tester.pumpAndSettle();
    await _capture(tester, 'obsidian-settings');

    shell.selectWorkbenchRoute(WorkbenchRoute.navigate);
    await tester.pumpAndSettle();
  });
}

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('workbench-visual-capture')),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  expect(bytes, isNotNull);
  final output = Directory('build/integration_test')
    ..createSync(recursive: true);
  File(
    '${output.path}/workbench-$name.png',
  ).writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
}
