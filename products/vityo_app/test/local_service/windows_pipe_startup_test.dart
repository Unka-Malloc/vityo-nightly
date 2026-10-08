import 'dart:async';

import 'package:test/test.dart';
import 'package:vityo_app/src/app/platform/desktop_startup_probe_contract.dart';
import 'package:vityo_app/src/ide/local_service/transport/windows_pipe_library.dart';

void main() {
  const request = DesktopStartupProbeRequest(
    candidate: 'vityo.zip',
    evidenceFile: 'startup.json',
  );

  test('Windows evidence waits for frame and verified bundled ABI', () async {
    final frame = Completer<void>();
    final loaded = Completer<int>();
    var inspected = false;
    Map<String, Object?>? written;
    final result = request.recordAfterFirstFrame(
      firstFrameRasterized: frame.future,
      platform: 'windows',
      verifyWindowsPipeLibrary: () {
        inspected = true;
        return loaded.future;
      },
      writeEvidence: (evidence) async => written = evidence,
    );
    expect(inspected, isFalse);
    expect(written, isNull);
    frame.complete();
    await Future<void>.delayed(Duration.zero);
    expect(inspected, isTrue);
    expect(written, isNull);
    loaded.complete(1);
    expect((await result)['windows_pipe_abi'], 1);
    expect(written!['first_frame'], isTrue);
  });

  test(
    'missing DLL, missing verifier and ABI mismatch cannot write success',
    () async {
      final verifiers = <Future<int> Function()?>[
        null,
        () async =>
            throw StateError('Required Windows pipe library is missing'),
        () async => 2,
        () async => 0,
      ];
      for (final verifier in verifiers) {
        var wrote = false;
        await expectLater(
          request.recordAfterFirstFrame(
            firstFrameRasterized: Future<void>.value(),
            platform: 'windows',
            verifyWindowsPipeLibrary: verifier,
            writeEvidence: (_) async => wrote = true,
          ),
          throwsStateError,
        );
        expect(wrote, isFalse);
      }
    },
  );

  test('loader ABI validator rejects incompatible native versions', () {
    validateWindowsPipeLibraryAbi(1);
    for (final version in [0, 2, -1]) {
      expect(() => validateWindowsPipeLibraryAbi(version), throwsStateError);
    }
  });

  test('Linux and macOS startup shape and loading remain unchanged', () async {
    for (final platform in ['linux', 'macos']) {
      final evidence = await request.recordAfterFirstFrame(
        firstFrameRasterized: Future<void>.value(),
        platform: platform,
        verifyWindowsPipeLibrary: () => throw StateError('must not load'),
        writeEvidence: (_) async {},
      );
      expect(
        evidence.keys,
        unorderedEquals([
          'schema_version',
          'candidate',
          'platform',
          'launched',
          'first_frame',
        ]),
      );
    }
  });
}
