import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../interaction/diagnostics_panel_state_store.dart';

/// Owns the Problems panel selection/filter state and persists it through
/// [DiagnosticsPanelStateStore] so the panel restores across sessions.
final class DiagnosticsPanelStateController extends ChangeNotifier {
  DiagnosticsPanelStateController({
    required this.workspaceId,
    this.store,
    this.log,
  });

  final String Function() workspaceId;
  final DiagnosticsPanelStateStore? store;
  final void Function(String message)? log;

  DiagnosticsPanelState? _state;
  bool _restored = false;
  String? _loadedWorkspaceId;
  Future<void>? _loadFuture;

  DiagnosticsPanelState? get state => _state;
  bool get restored => _restored;

  Future<void> load() {
    final effectiveStore = store;
    final id = workspaceId();
    if (effectiveStore == null) {
      return Future<void>.value();
    }
    final inFlight = _loadFuture;
    if (_loadedWorkspaceId == id && inFlight != null) {
      return inFlight;
    }
    late final Future<void> loadFuture;
    loadFuture = _restore(store: effectiveStore, workspaceId: id).whenComplete(
      () {
        if (identical(_loadFuture, loadFuture)) {
          _loadFuture = null;
        }
      },
    );
    _loadedWorkspaceId = id;
    _loadFuture = loadFuture;
    return loadFuture;
  }

  Future<void> _restore({
    required DiagnosticsPanelStateStore store,
    required String workspaceId,
  }) async {
    try {
      final restored = await store.readState(workspaceId: workspaceId);
      _state = restored;
      _restored = true;
      notifyListeners();
    } on Object catch (error) {
      log?.call('Problems panel state restore failed: $error');
    }
  }

  void record(DiagnosticsPanelState state) {
    _state = state;
    _restored = true;
    notifyListeners();
    unawaited(_persist(state));
  }

  Future<void> _persist(DiagnosticsPanelState state) async {
    final effectiveStore = store;
    if (effectiveStore == null) {
      return;
    }
    try {
      await effectiveStore.saveState(
        state: state.copyWith(workspaceId: workspaceId()),
      );
    } on Object catch (error) {
      log?.call('Problems panel state save failed: $error');
    }
  }
}
