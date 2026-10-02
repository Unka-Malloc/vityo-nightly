import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/main.dart' as app_entrypoint;
import 'package:vityo_app/src/ide/platform/desktop_startup_probe_contract.dart';
import 'package:vityo_app/src/view_render/flow_hero/flow_hero.dart';

void main() {
  testWidgets('ordinary entrypoint launches the existing Flow Hero app', (
    tester,
  ) async {
    app_entrypoint.main(<String>[]);
    await tester.pump();

    expect(find.byType(FlowHeroApp), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  group('DesktopStartupProbeRequest', () {
    test('leaves an ordinary launch unchanged', () {
      expect(
        DesktopStartupProbeRequest.parse(<String>['project.styio']),
        isNull,
      );
    });

    test('parses the explicit candidate and evidence destination', () {
      final request = DesktopStartupProbeRequest.parse(<String>[
        '--vityo-startup-probe',
        '--vityo-candidate',
        'vityo-nightly-linux-0.1.0.deb',
        '--vityo-evidence-file',
        'build/evidence/startup.json',
      ]);

      expect(request, isNotNull);
      expect(request!.candidate, 'vityo-nightly-linux-0.1.0.deb');
      expect(request.evidenceFile, 'build/evidence/startup.json');
    });

    test('rejects incomplete, duplicate, and unknown Vityo arguments', () {
      for (final arguments in <List<String>>[
        <String>['--vityo-startup-probe'],
        <String>['--vityo-startup-probe', '--vityo-candidate', 'vityo.deb'],
        <String>[
          '--vityo-startup-probe',
          '--vityo-startup-probe',
          '--vityo-candidate',
          'vityo.deb',
          '--vityo-evidence-file',
          'evidence.json',
        ],
        <String>['--vityo-unrecognized'],
      ]) {
        expect(
          () => DesktopStartupProbeRequest.parse(arguments),
          throwsFormatException,
        );
      }
    });

    test('rejects a candidate value that could disclose or act as a path', () {
      expect(
        () => DesktopStartupProbeRequest.parse(<String>[
          '--vityo-startup-probe',
          '--vityo-candidate',
          '../private/vityo.deb',
          '--vityo-evidence-file',
          'evidence.json',
        ]),
        throwsFormatException,
      );
    });

    test(
      'records only after the actual rasterized-frame future completes',
      () async {
        final request = DesktopStartupProbeRequest.parse(<String>[
          '--vityo-startup-probe',
          '--vityo-candidate',
          'vityo-nightly-linux-0.1.0.deb',
          '--vityo-evidence-file',
          'build/evidence/startup.json',
        ])!;
        final frameRasterized = Completer<void>();
        Map<String, Object?>? writtenEvidence;
        final recording = request.recordAfterFirstFrame(
          firstFrameRasterized: frameRasterized.future,
          platform: 'linux',
          writeEvidence: (evidence) async {
            writtenEvidence = evidence;
          },
        );

        expect(writtenEvidence, isNull);
        frameRasterized.complete();
        final evidence = await recording;

        expect(evidence, <String, Object?>{
          'schema_version': 1,
          'candidate': 'vityo-nightly-linux-0.1.0.deb',
          'platform': 'linux',
          'launched': true,
          'first_frame': true,
        });
        expect(writtenEvidence, evidence);
        expect(evidence.keys.toSet(), <String>{
          'schema_version',
          'candidate',
          'platform',
          'launched',
          'first_frame',
        });
      },
    );

    test('does not write evidence when frame rasterization fails', () async {
      final request = DesktopStartupProbeRequest.parse(<String>[
        '--vityo-startup-probe',
        '--vityo-candidate',
        'vityo-nightly-linux-0.1.0.deb',
        '--vityo-evidence-file',
        'build/evidence/startup.json',
      ])!;
      final frameRasterized = Completer<void>();
      var wroteEvidence = false;
      final recording = request.recordAfterFirstFrame(
        firstFrameRasterized: frameRasterized.future,
        platform: 'linux',
        writeEvidence: (_) async {
          wroteEvidence = true;
        },
      );
      frameRasterized.completeError(StateError('frame failed'));

      await expectLater(recording, throwsStateError);
      expect(wroteEvidence, isFalse);
    });
  });
}
