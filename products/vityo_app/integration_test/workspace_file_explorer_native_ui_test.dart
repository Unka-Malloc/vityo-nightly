import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vityo_app/src/app/app_bootstrap.dart';
import 'package:vityo_app/src/app/vityo_app.dart';
import 'package:vityo_app/src/ide/workspace/workspace.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS engine drives the production workspace explorer', (
    tester,
  ) async {
    expect(Platform.isMacOS, isTrue, reason: 'run this lane on macOS');
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 960);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final bootstrap = await AppBootstrap.load();
    final temporaryPath =
        'vityo_native_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}.styio';
    final cleanupService = WorkspaceFileOperationService(
      workspaceController: bootstrap.workspaceController,
      documentStore: bootstrap.workspaceDocumentStore,
    );
    final resolvedTemporaryPath = cleanupService.resolvePath(temporaryPath);
    expect(
      await bootstrap.workspaceDocumentStore.documentExists(
        resolvedTemporaryPath,
      ),
      isFalse,
    );
    var cleanupRequired = false;
    addTearDown(() async {
      if (cleanupRequired) {
        await cleanupService.deleteFile(temporaryPath);
      }
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('workspace-explorer-native-evidence'),
        child: VityoApp(bootstrap: bootstrap),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('workspace-explorer')), findsOneWidget);
    expect(find.text('EXPLORER'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('explorer-create-file')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace-path-dialog')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('workspace-path-input')),
      temporaryPath,
    );
    cleanupRequired = true;
    await tester.tap(find.byKey(const ValueKey('workspace-path-apply')));
    await tester.pumpAndSettle();

    final createdFile = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('explorer-file-') &&
          key.value.endsWith(temporaryPath);
    });
    expect(createdFile, findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('explorer-filter')),
      temporaryPath,
    );
    await tester.pump();
    await tester.longPress(createdFile);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('explorer-selection-bar')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('explorer-delete-selected')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('workspace-file-batch-dialog')),
      findsOneWidget,
    );

    await _captureEvidence(tester);

    await tester.tap(
      find.byKey(const ValueKey('workspace-file-batch-confirm')),
    );
    await tester.pumpAndSettle();
    expect(createdFile, findsNothing);
    cleanupRequired = false;
    expect(tester.takeException(), isNull);
  });
}

Future<void> _captureEvidence(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('workspace-explorer-native-evidence')),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  expect(bytes, isNotNull);
  final output = Directory('build/integration_test')
    ..createSync(recursive: true);
  File(
    '${output.path}/vityo-workspace-file-explorer-macos.png',
  ).writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
}
