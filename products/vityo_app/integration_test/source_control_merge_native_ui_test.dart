import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vityo_app/src/ide/workspace/workspace.dart';
import 'package:vityo_app/src/view_ide/platform/platform_target.dart';
import 'package:vityo_app/src/view_render/platform/platform.dart';
import 'package:vityo_app/src/view_render/source_control/source_control.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS engine drives the three-way source control merge editor', (
    tester,
  ) async {
    expect(Platform.isMacOS, isTrue, reason: 'run this lane on macOS');
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1000);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    const status = SourceControlStatusSnapshot(
      providerKind: SourceControlProviderKind.git,
      branchName: 'feature/editor',
      changes: <SourceControlFileChange>[
        SourceControlFileChange(
          path: 'lib/editor/input.styio',
          unstagedStatus: SourceControlFileStatus.conflicted,
        ),
      ],
    );
    final workflow = SourceControlMergeWorkflowPlan.fromStatus(status);
    SourceControlConflictResolutionKind? appliedKind;
    int? appliedRevision;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff6750a4),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('source-control-merge-native-evidence'),
            child: SourceControlSurface(
              viewportProfile: resolveViewportProfile(
                platformTarget: PlatformTarget.macos,
                width: 1280,
                height: 900,
              ),
              workspaceFileCount: 12,
              changedDocumentIds: const <String>[],
              status: status,
              mergeWorkflowPlan: workflow,
              mergeEditorSnapshot: const SourceControlMergeEditorSnapshot(
                providerKind: SourceControlProviderKind.git,
                path: 'lib/editor/input.styio',
                available: true,
                baseText: 'selection = base\n',
                currentText: 'selection = current\n',
                incomingText: 'selection = incoming\n',
                workingText:
                    '<<<<<<< HEAD\n'
                    'selection = current\n'
                    '=======\n'
                    'selection = incoming\n'
                    '>>>>>>> feature/input\n',
                baseAvailable: true,
                currentAvailable: true,
                incomingAvailable: true,
                workingExists: true,
                workingRevision: 42,
              ),
              onApplyConflictResolution:
                  (plan, kind, resultText, expectedWorkingRevision) async {
                    expect(plan.path, 'lib/editor/input.styio');
                    appliedKind = kind;
                    appliedRevision = expectedWorkingRevision;
                  },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final useBoth = find.byKey(const ValueKey('source-control-use-both'));
    await tester.ensureVisible(useBoth);
    await tester.pumpAndSettle();
    await tester.tap(useBoth);
    await tester.pumpAndSettle();
    expect(find.text('working tree has markers'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('source-control-apply-merge-result')),
          )
          .onPressed,
      isNotNull,
    );

    await _captureEvidence(tester);

    await tester.tap(
      find.byKey(const ValueKey('source-control-apply-merge-result')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('source-control-confirm-merge-result')),
    );
    await tester.pumpAndSettle();

    expect(appliedKind, SourceControlConflictResolutionKind.acceptBoth);
    expect(appliedRevision, 42);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _captureEvidence(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('source-control-merge-native-evidence')),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  expect(bytes, isNotNull);
  final output = Directory('build/integration_test')
    ..createSync(recursive: true);
  File(
    '${output.path}/vityo-source-control-merge-macos.png',
  ).writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
}
