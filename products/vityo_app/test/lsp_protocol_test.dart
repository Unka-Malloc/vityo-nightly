import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/language/lsp/lsp.dart';

void main() {
  const codec = LspContentFrameCodec();

  group('LspContentFrameCodec', () {
    test('encodes Content-Length by UTF-8 bytes', () {
      final bytes = codec.encode(<String, Object?>{'jsonrpc': '2.0'});
      final header = ascii.decode(bytes.sublist(0, 20));
      expect(header, startsWith('Content-Length: '));
      final body = utf8.decode(bytes.sublist(bytes.indexOf(13) + 4));
      expect(jsonDecode(body), <String, Object?>{'jsonrpc': '2.0'});
    });

    test('decodes a complete frame', () {
      final bytes = codec.encode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 1,
        'result': <String, Object?>{'ok': true},
      });
      final frame = codec.decodeFirst(bytes);
      expect(frame, isNotNull);
      expect(frame!.consumedBytes, bytes.length);
      expect(frame.message['id'], 1);
      expect((frame.message['result']! as Map)['ok'], true);
    });

    test('returns null for a split header', () {
      final bytes = codec.encode(<String, Object?>{'id': 1});
      final split = bytes.length ~/ 2;
      expect(codec.decodeFirst(bytes.sublist(0, split)), isNull);
    });

    test('returns null for a split body then decodes once complete', () {
      final bytes = codec.encode(<String, Object?>{
        'id': 1,
        'result': <String, Object?>{'value': 'x' * 32},
      });
      final bodyStart = bytes.indexOf(13) + 4;
      final header = bytes.sublist(0, bodyStart);
      final body = bytes.sublist(bodyStart);
      final partial = <int>[...header, ...body.sublist(0, 5)];
      expect(codec.decodeFirst(partial), isNull);
      final complete = <int>[...partial, ...body.sublist(5)];
      final frame = codec.decodeFirst(complete);
      expect(frame, isNotNull);
      expect(frame!.consumedBytes, complete.length);
    });

    test('decodes consecutive frames from one buffer', () {
      final first = codec.encode(<String, Object?>{'id': 1, 'result': 1});
      final second = codec.encode(<String, Object?>{'id': 2, 'result': 2});
      final buffer = <int>[...first, ...second];
      final decodedFirst = codec.decodeFirst(buffer)!;
      buffer.removeRange(0, decodedFirst.consumedBytes);
      final decodedSecond = codec.decodeFirst(buffer)!;
      expect(decodedFirst.message['id'], 1);
      expect(decodedSecond.message['id'], 2);
    });

    test('throws on a missing Content-Length header', () {
      final bytes = utf8.encode('X-Test: 1\r\n\r\n{}');
      expect(() => codec.decodeFirst(bytes), throwsA(isA<LspProtocolError>()));
    });
  });

  group('LspTextCoordinates', () {
    test('maps UTF-16 characters through surrogate pairs', () {
      const text = 'a😀b';
      expect(LspTextCoordinates.offsetAt(text, 0, 0), 0);
      expect(LspTextCoordinates.offsetAt(text, 0, 1), 1);
      // The emoji occupies two UTF-16 units, so character 3 lands after it.
      expect(LspTextCoordinates.offsetAt(text, 0, 3), 3);
      expect(LspTextCoordinates.positionAtOffset(text, 3).character, 3);
      expect(LspTextCoordinates.positionAtOffset(text, 4).character, 4);
    });

    test('treats CRLF as a line terminator, not content', () {
      const text = 'abc\r\ndef';
      expect(LspTextCoordinates.offsetAt(text, 0, 3), 3);
      expect(LspTextCoordinates.offsetAt(text, 0, 10), 3);
      expect(LspTextCoordinates.offsetAt(text, 1, 0), 5);
      expect(LspTextCoordinates.offsetAt(text, 1, 3), 8);
      expect(LspTextCoordinates.positionAtOffset(text, 5).line, 1);
    });

    test('clamps beyond the last line to the document end', () {
      const text = 'one\ntwo';
      expect(LspTextCoordinates.offsetAt(text, 9, 0), text.length);
    });

    test('converts an LSP range to source offsets', () {
      const text = 'first\nsecond line\n';
      const range = LspRange(
        start: LspPosition(line: 1, character: 0),
        end: LspPosition(line: 1, character: 6),
      );
      expect(LspTextCoordinates.startOffset(text, range), 6);
      expect(LspTextCoordinates.endOffset(text, range), 12);
    });
  });
}
