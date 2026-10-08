import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_daemon_protocol/vityo_daemon_protocol.dart';

import '../../tool/windows_named_pipe_regression.dart' as fixture;

void main() {
  test('outer pipe fixture is a valid backpressured control frame', () {
    expect(fixture.windowsPipeControlFixtureBytes, greaterThan(4096));
    expect(
      fixture.windowsPipeControlFixtureBytes,
      vityodMaxControlPayloadBytes,
    );
    const header = VityodFrameHeader(
      kind: VityodFrameKind.control,
      streamId: 0,
      sequence: 1,
      payloadLength: fixture.windowsPipeControlFixtureBytes,
    );
    expect(
      VityodFrameHeader.decode(header.encode()).payloadLength,
      fixture.windowsPipeControlFixtureBytes,
    );
  });

  test('oversized control frame still fails before native I/O', () {
    expect(
      () => const VityodFrameHeader(
        kind: VityodFrameKind.control,
        streamId: 0,
        sequence: 1,
        payloadLength: 8 * 1024 * 1024,
      ).encode(),
      throwsA(
        isA<VityodProtocolException>().having(
          (error) => error.code,
          'code',
          'frame_too_large',
        ),
      ),
    );
  });
}
