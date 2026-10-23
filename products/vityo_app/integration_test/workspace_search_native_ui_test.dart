import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vityo_app/src/ide/workspace/workspace.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';
import 'package:vityo_app/src/view_ide/platform/platform_target.dart';
import 'package:vityo_app/src/view_render/platform/platform.dart';
import 'package:vityo_app/src/view_render/search/search.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS engine drives workspace search and watcher recovery', (
    tester,
  ) async {
    expect(Platform.isMacOS, isTrue, reason: 'run this lane on macOS');
    final facts = FileSystemFacts.linuxDebianArm().copyWith(
      operatingSystem: 'macos',
      distributionId: 'macos',
      distributionName: 'macOS',
    );
    final telemetry = WorkspaceSearchWatcherBackpressureTracker(facts: facts)
        .recordProviderOverflow(
          const FileSystemWatchOverflowException(
            operation: 'integration.watch',
            droppedEventCount: 4,
          ),
        );
    var recovered = false;
    String? submittedQuery;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('workspace-search-native-evidence'),
            child: WorkspaceSearchSurface(
              viewportProfile: resolveViewportProfile(
                platformTarget: PlatformTarget.macos,
                width: 1200,
                height: 800,
              ),
              workspaceFileCount: 2,
              workspaceFiles: const <String>[
                'src/main.styio',
                'src/render.styio',
              ],
              watcherSnapshot: WorkspaceSearchIndexWatcherSnapshot(
                status: WorkspaceSearchIndexWatcherStatus.failed,
                workspaceRoot: '/workspace/integration',
                recursive: true,
                backpressure: telemetry,
                recoveryPlan: WorkspaceSearchWatcherRecoveryPlan.forOverflow(
                  workspaceRoot: '/workspace/integration',
                  facts: facts,
                ),
                message:
                    'Watcher overflow detected; full index recovery is ready.',
              ),
              onRecoverWatcher: () async {
                recovered = true;
              },
              onSearch: (query) async {
                submittedQuery = query;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('workspace-search-query-input')),
      'render',
    );
    await tester.tap(find.byKey(const ValueKey('workspace-search-submit')));
    await tester.pump();
    expect(submittedQuery, 'render');

    await tester.ensureVisible(
      find.byKey(const ValueKey('workspace-search-watcher-recover')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('workspace-search-watcher-recover')),
    );
    await tester.pump();
    expect(recovered, isTrue);
    expect(find.text('dropped 4'), findsOneWidget);
    expect(find.text('Recovery: fsevents-full-rescan'), findsOneWidget);

    await _captureEvidence(tester);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _captureEvidence(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('workspace-search-native-evidence')),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  expect(bytes, isNotNull);
  final output = Directory('build/integration_test')
    ..createSync(recursive: true);
  File(
    '${output.path}/vityo-workspace-search-macos.png',
  ).writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
}
