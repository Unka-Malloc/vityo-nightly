import 'dart:async';

/// Transport-agnostic byte channel for a Language Server Protocol session.
///
/// Implementations deliver raw server bytes through [input] and accept raw
/// client bytes through [write]. The caller owns the process/session backing
/// the channel; this abstraction only moves bytes.
abstract class LspByteTransport {
  Stream<List<int>> get input;

  Future<void> write(List<int> bytes);

  Future<void> close();
}
