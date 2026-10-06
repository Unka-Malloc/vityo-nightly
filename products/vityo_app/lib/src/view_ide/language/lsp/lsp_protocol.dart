import 'dart:convert';

/// Raised when a peer sends bytes that cannot be decoded as LSP framing.
class LspProtocolError implements Exception {
  const LspProtocolError(this.message);

  final String message;

  @override
  String toString() => 'LspProtocolError($message)';
}

class LspContentFrame {
  const LspContentFrame({required this.message, required this.consumedBytes});

  final Map<String, Object?> message;
  final int consumedBytes;
}

/// Content-Length framed JSON-RPC codec, matching the LSP 3.17 base protocol.
///
/// Bodies are UTF-8 and `Content-Length` counts body bytes, not code units.
class LspContentFrameCodec {
  const LspContentFrameCodec();

  static final List<int> _crlfTerminator = utf8.encode('\r\n\r\n');
  static final List<int> _lfTerminator = utf8.encode('\n\n');

  List<int> encode(Map<String, Object?> message) {
    final body = utf8.encode(jsonEncode(message));
    final header = ascii.encode('Content-Length: ${body.length}\r\n\r\n');
    return <int>[...header, ...body];
  }

  /// Decodes the first complete frame in [bytes].
  ///
  /// Returns null when the buffer holds only a partial header or body; callers
  /// accumulate more bytes and retry. Throws [LspProtocolError] for malformed
  /// headers or non-object bodies.
  LspContentFrame? decodeFirst(List<int> bytes) {
    final headerEnd = _indexOfSequence(bytes, _crlfTerminator);
    final terminatorLength = _crlfTerminator.length;
    final resolvedHeaderEnd = headerEnd >= 0
        ? headerEnd
        : _indexOfSequence(bytes, _lfTerminator);
    if (resolvedHeaderEnd < 0) {
      return null;
    }
    final effectiveTerminator = headerEnd >= 0
        ? terminatorLength
        : _lfTerminator.length;
    final headerText = ascii.decode(
      bytes.sublist(0, resolvedHeaderEnd),
      allowInvalid: true,
    );
    final contentLength = _contentLengthFromHeader(headerText);
    final bodyStart = resolvedHeaderEnd + effectiveTerminator;
    final bodyEnd = bodyStart + contentLength;
    if (bytes.length < bodyEnd) {
      return null;
    }
    final bodyText = utf8.decode(bytes.sublist(bodyStart, bodyEnd));
    final decoded = jsonDecode(bodyText);
    if (decoded is! Map) {
      throw const LspProtocolError('LSP frame body must be a JSON object.');
    }
    return LspContentFrame(
      message: decoded.map(
        (key, value) => MapEntry<String, Object?>(key.toString(), value),
      ),
      consumedBytes: bodyEnd,
    );
  }

  int _contentLengthFromHeader(String headerText) {
    for (final line in headerText.split(RegExp(r'\r?\n'))) {
      final separatorIndex = line.indexOf(':');
      if (separatorIndex < 0) {
        continue;
      }
      final name = line.substring(0, separatorIndex).trim().toLowerCase();
      if (name != 'content-length') {
        continue;
      }
      final value = int.tryParse(line.substring(separatorIndex + 1).trim());
      if (value == null || value < 0) {
        throw LspProtocolError('Invalid LSP Content-Length: $line');
      }
      return value;
    }
    throw const LspProtocolError('Missing LSP Content-Length header.');
  }
}

class LspRequestIdGenerator {
  int _next = 0;

  int next() => ++_next;
}

class LspPosition {
  const LspPosition({required this.line, required this.character});

  factory LspPosition.fromJson(Object? value) {
    if (value is! Map) {
      return const LspPosition(line: 0, character: 0);
    }
    return LspPosition(
      line: _intValue(value['line']) ?? 0,
      character: _intValue(value['character']) ?? 0,
    );
  }

  final int line;
  final int character;

  Map<String, Object?> toJson() => <String, Object?>{
    'line': line,
    'character': character,
  };

  @override
  String toString() => 'LspPosition($line, $character)';
}

class LspRange {
  const LspRange({required this.start, required this.end});

  factory LspRange.fromJson(Object? value) {
    if (value is! Map) {
      return const LspRange(
        start: LspPosition(line: 0, character: 0),
        end: LspPosition(line: 0, character: 0),
      );
    }
    return LspRange(
      start: LspPosition.fromJson(value['start']),
      end: LspPosition.fromJson(value['end']),
    );
  }

  final LspPosition start;
  final LspPosition end;

  Map<String, Object?> toJson() => <String, Object?>{
    'start': start.toJson(),
    'end': end.toJson(),
  };

  @override
  String toString() => 'LspRange($start, $end)';
}

/// Converts between LSP positions (line/UTF-16 character) and Dart string
/// offsets (also UTF-16 code units).
///
/// Line splitting mirrors the daemon: lines break on `\n` and a trailing `\r`
/// is treated as terminator, not content.
abstract final class LspTextCoordinates {
  static int offsetAtPosition(String text, LspPosition position) {
    return offsetAt(text, position.line, position.character);
  }

  static int offsetAt(String text, int line, int character) {
    final targetLine = line < 0 ? 0 : line;
    final targetCharacter = character < 0 ? 0 : character;
    var currentLine = 0;
    var lineStart = 0;
    while (currentLine < targetLine) {
      final newline = text.indexOf('\n', lineStart);
      if (newline < 0) {
        return text.length;
      }
      lineStart = newline + 1;
      currentLine += 1;
    }
    var contentEnd = text.indexOf('\n', lineStart);
    if (contentEnd < 0) {
      contentEnd = text.length;
    }
    if (contentEnd > lineStart &&
        text.codeUnitAt(contentEnd - 1) == 0x0D /* \r */ ) {
      contentEnd -= 1;
    }
    final target = lineStart + targetCharacter;
    return target > contentEnd ? contentEnd : target;
  }

  static LspPosition positionAtOffset(String text, int offset) {
    final clamped = offset < 0
        ? 0
        : offset > text.length
        ? text.length
        : offset;
    var line = 0;
    var lineStart = 0;
    while (true) {
      final newline = text.indexOf('\n', lineStart);
      if (newline < 0 || newline >= clamped) {
        break;
      }
      line += 1;
      lineStart = newline + 1;
    }
    return LspPosition(line: line, character: clamped - lineStart);
  }

  static int startOffset(String text, LspRange range) {
    return offsetAtPosition(text, range.start);
  }

  static int endOffset(String text, LspRange range) {
    final start = startOffset(text, range);
    final end = offsetAtPosition(text, range.end);
    return end < start ? start : end;
  }
}

int? _intValue(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return null;
}

int _indexOfSequence(List<int> bytes, List<int> sequence) {
  if (sequence.isEmpty || bytes.length < sequence.length) {
    return -1;
  }
  for (var index = 0; index <= bytes.length - sequence.length; index += 1) {
    var matched = true;
    for (var offset = 0; offset < sequence.length; offset += 1) {
      if (bytes[index + offset] != sequence[offset]) {
        matched = false;
        break;
      }
    }
    if (matched) {
      return index;
    }
  }
  return -1;
}
