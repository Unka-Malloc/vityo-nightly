import 'document_encoding.dart';
import 'text_buffer/text_buffer.dart';

class DocumentState {
  const DocumentState({
    required this.documentId,
    required String text,
    required this.revision,
    this.encoding,
    this.workspaceRevision,
    int? baseDocumentRevision,
  }) : _text = text,
       baseDocumentRevision = baseDocumentRevision ?? revision;

  DocumentState._fromTextBuffer({
    required this.documentId,
    required TextBufferSnapshot textBufferSnapshot,
    required this.revision,
    this.encoding,
    this.workspaceRevision,
    int? baseDocumentRevision,
  }) : _text = null,
       baseDocumentRevision = baseDocumentRevision ?? revision {
    _snapshotCache[this] = textBufferSnapshot;
  }

  factory DocumentState.fromTextBuffer({
    required String documentId,
    required TextBufferSnapshot textBufferSnapshot,
    required int revision,
    DocumentEncoding? encoding,
    int? workspaceRevision,
    int? baseDocumentRevision,
  }) {
    return DocumentState._fromTextBuffer(
      documentId: documentId,
      textBufferSnapshot: textBufferSnapshot,
      revision: revision,
      encoding: encoding,
      workspaceRevision: workspaceRevision,
      baseDocumentRevision: baseDocumentRevision,
    );
  }

  static final Expando<TextBufferSnapshot> _snapshotCache =
      Expando<TextBufferSnapshot>('DocumentState.textBufferSnapshot');

  final String documentId;
  final String? _text;
  final int revision;
  final DocumentEncoding? encoding;

  /// Document revision observed before the current in-memory edit sequence.
  /// It remains stable while [revision] describes the projected result.
  final int baseDocumentRevision;

  /// Workspace-wide revision captured with this persisted document snapshot.
  /// Null means the producer has not observed a workspace snapshot suitable
  /// for an atomic workspace transaction.
  final int? workspaceRevision;

  /// Materializes the complete source only for consumers that explicitly need
  /// it. Piece-table edits keep this lazy so viewport and input-window work do
  /// not copy a large document after every keystroke.
  String get text => _text ?? textBufferSnapshot.text;

  int get length => _text?.length ?? textBufferSnapshot.length;

  /// Returns a grapheme-safe, line-aligned source slice containing [start] to
  /// [end], or `null` when a single logical line exceeds [maxCodeUnits].
  ///
  /// Line boundaries are Unicode grapheme boundaries, so input adapters can
  /// segment this bounded slice without materializing the complete document.
  DocumentTextWindow? textWindowForRange({
    required int start,
    required int end,
    int maxCodeUnits = 8192,
  }) {
    if (maxCodeUnits <= 0) {
      throw RangeError.value(maxCodeUnits, 'maxCodeUnits', 'must be positive');
    }
    RangeError.checkValidRange(start, end, length);
    if (end - start > maxCodeUnits) return null;

    final snapshot = textBufferSnapshot;
    final starts = snapshot.lineStarts;
    final firstLine = snapshot.positionAt(start).line;
    final lastOffset = end > start ? end - 1 : end;
    final lastLine = snapshot.positionAt(lastOffset).line;
    var windowStartLine = firstLine;
    var windowEndLine = lastLine + 1;

    int offsetForLine(int line) => line < starts.length ? starts[line] : length;

    var windowStart = offsetForLine(windowStartLine);
    var windowEnd = offsetForLine(windowEndLine);
    if (windowEnd - windowStart > maxCodeUnits) return null;

    while (true) {
      final previousStart = windowStartLine > 0
          ? offsetForLine(windowStartLine - 1)
          : null;
      final nextEnd = windowEndLine < starts.length
          ? offsetForLine(windowEndLine + 1)
          : null;
      final canPrepend =
          previousStart != null && windowEnd - previousStart <= maxCodeUnits;
      final canAppend =
          nextEnd != null && nextEnd - windowStart <= maxCodeUnits;
      if (!canPrepend && !canAppend) break;

      final leadingContext = start - windowStart;
      final trailingContext = windowEnd - end;
      if (canPrepend && (!canAppend || leadingContext <= trailingContext)) {
        windowStartLine -= 1;
        windowStart = previousStart;
      } else {
        windowEndLine += 1;
        windowEnd = nextEnd!;
      }
    }

    return DocumentTextWindow(
      start: windowStart,
      text: snapshot.getText(TextRange(start: windowStart, end: windowEnd)),
    );
  }

  TextBufferSnapshot get textBufferSnapshot {
    final cached = _snapshotCache[this];
    if (cached != null) {
      return cached;
    }
    final snapshot = TextBufferSnapshot.fromText(text);
    _snapshotCache[this] = snapshot;
    return snapshot;
  }

  PieceTreeTextBuffer get textBuffer {
    return PieceTreeTextBuffer.fromSnapshot(textBufferSnapshot);
  }

  DocumentState withTextBuffer() {
    textBufferSnapshot;
    return this;
  }

  List<String> get lines => textBufferSnapshot.lines;

  List<int> get lineStarts => textBufferSnapshot.lineStarts;

  int get lineCount => textBufferSnapshot.lineCount;

  String lineAt(int line) => textBufferSnapshot.lineAt(line);

  DocumentPosition positionForOffset(int offset) {
    final position = textBufferSnapshot.positionAt(offset);
    return DocumentPosition(line: position.line, column: position.column);
  }

  int offsetForLineColumn({required int line, required int column}) {
    return textBufferSnapshot.offsetAt(
      TextPosition(line: line < 0 ? 0 : line, column: column < 0 ? 0 : column),
    );
  }

  DocumentState replaceRange({
    required int start,
    required int end,
    required String replacement,
  }) {
    final normalizedStart = start.clamp(0, length);
    final normalizedEnd = end.clamp(normalizedStart, length);
    final nextSnapshot = textBuffer
        .replace(
          TextRange(start: normalizedStart.toInt(), end: normalizedEnd.toInt()),
          replacement,
        )
        .snapshot();

    return DocumentState.fromTextBuffer(
      documentId: documentId,
      textBufferSnapshot: nextSnapshot,
      revision: revision + 1,
      encoding: encoding,
      workspaceRevision: workspaceRevision,
      baseDocumentRevision: baseDocumentRevision,
    );
  }
}

class DocumentPosition extends TextPosition {
  const DocumentPosition({required super.line, required super.column});
}

class DocumentTextWindow {
  const DocumentTextWindow({required this.start, required this.text});

  final int start;
  final String text;

  int get end => start + text.length;

  bool containsRange(int rangeStart, int rangeEnd) =>
      rangeStart >= start && rangeEnd >= rangeStart && rangeEnd <= end;
}
