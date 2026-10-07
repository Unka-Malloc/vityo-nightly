import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vityo_app/src/frontend_shell/frontend_shell.dart';

import '../test/support/vityod_test_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS resizes and restores the production workbench shell', (
    tester,
  ) async {
    expect(Platform.isMacOS, isTrue, reason: 'run this lane on macOS');
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 960);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    // The production filesystem is daemon-backed. Without this client the
    // bootstrap has an unsupported filesystem and reads default preferences.
    final daemon = await VityodTestHarness.start(
      clientId: 'shell-layout-native-ui',
    );
    addTearDown(daemon.close);
    final bootstrap = await AppBootstrap.load(vityodClient: daemon.client);
    final store = bootstrap.shellLayoutPreferencesStore;
    expect(store, isNotNull);
    final workspaceId = bootstrap.workspaceController.activeProject.id;
    await store!.deletePreferences(workspaceId: workspaceId);
    addTearDown(() => store.deletePreferences(workspaceId: workspaceId));

    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('shell-layout-native-evidence'),
        child: VityoApp(bootstrap: bootstrap),
      ),
    );
    await tester.pump();

    final shell = ShellScope.of(
      tester.element(find.byType(VityoShellScaffold)),
    );
    await shell.loadShellLayoutPreferences();
    await tester.pump();

    expect(
      tester
          .getSize(find.byKey(const ValueKey('workbench-primary-sidebar')))
          .width,
      ShellLayoutPreferences.defaultPrimarySidebarWidth,
    );
    await tester.drag(
      find.byKey(const ValueKey('workbench-primary-sidebar-resize-handle')),
      const Offset(64, 0),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('bottom-tab-problems')));
    await tester.pump();
    expect(shell.activeWorkbenchRoute, BottomSurfaceTab.problems);
    expect(
      find.byKey(const ValueKey('workbench-bottom-panel')),
      findsOneWidget,
    );
    await tester.drag(
      find.byKey(const ValueKey('workbench-bottom-panel-resize-handle')),
      const Offset(0, -56),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('workbench-bottom-panel-toggle')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('workbench-bottom-panel')), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('workbench-bottom-panel-toggle')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('workbench-bottom-panel')),
      findsOneWidget,
    );

    final live = shell.shellLayoutPreferenceController.preferences;
    expect(live.activeWorkbenchRoute, BottomSurfaceTab.problems);
    await shell.persistShellLayoutPreferences();
    final restored = await store.readPreferences(workspaceId: workspaceId);
    expect(restored.activeWorkbenchRoute, BottomSurfaceTab.problems);
    expect(restored.primarySidebarWidth, greaterThanOrEqualTo(300));
    expect(restored.bottomPanelHeight, greaterThanOrEqualTo(270));
    expect(restored.bottomPanelExpanded, isTrue);
    expect(restored.primarySidebarWidth, live.primarySidebarWidth);
    expect(restored.bottomPanelHeight, live.bottomPanelHeight);

    // Reset only the in-memory controller, then prove hydration comes from the
    // saved daemon-backed record rather than the still-live widget state.
    shell.shellLayoutPreferenceController.hydrate(
      ShellLayoutPreferences(workspaceId: workspaceId),
    );
    expect(shell.activeWorkbenchRoute, BottomSurfaceTab.navigate);
    await shell.loadShellLayoutPreferences();
    await tester.pump();
    expect(shell.activeWorkbenchRoute, BottomSurfaceTab.problems);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('workbench-primary-sidebar')))
          .width,
      live.primarySidebarWidth,
    );
    expect(
      find.byKey(const ValueKey('workbench-bottom-panel')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await _captureEvidence(tester);
  });
}

Future<void> _captureEvidence(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('shell-layout-native-evidence')),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  expect(bytes, isNotNull);
  final output = Directory('build/integration_test')
    ..createSync(recursive: true);
  File(
    '${output.path}/vityo-shell-layout-macos.png',
  ).writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
}
