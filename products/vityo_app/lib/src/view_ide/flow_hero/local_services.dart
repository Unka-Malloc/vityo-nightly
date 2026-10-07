/// The one local-service connection Flow Hero's boot layer shares.
///
/// vityod owns every real OS capability Flow Hero's boot layer uses: the
/// process manager that spawns `pafio --version` and `styio_lspd`, and the
/// file-system manager that reads and writes `toolchain.json`,
/// `model-config.json`, `provider.json`, and `theme.json`. Building those
/// managers *without* a client yields the honest-but-dead `Unsupported*`
/// variants: the process manager answers every spawn with `blocked`, and the
/// file-system manager answers every existence check with `false`. That is
/// exactly the failure this holder removes — it establishes the platform
/// vityod client once, lazily, and hands the same instance to every consumer,
/// so process execution is structurally supported instead of structurally
/// impossible.
///
/// Unavailability stays honest: when the platform cannot provide a client (a
/// stub build, a missing packaged component, a failed connect) [client] answers
/// null, every consumer keeps its existing degradation path, and nothing is
/// presented as live. The holder also owns disposal — a consumer must never
/// dispose the shared client, only the app that owns the holder does.
library;

import 'package:flutter/foundation.dart';

import '../../ide/local_service/vityod_client.dart';
import 'local_service_contract.dart';

/// Owns the single vityod client Flow Hero boots its local services with.
class FlowHeroLocalServices implements FlowHeroLocalServiceOwner {
  FlowHeroLocalServices({
    Future<VityodClient?> Function()? clientFactory,
    Future<void> Function()? onDispose,
  }) : _clientFactory = clientFactory,
       _onDispose = onDispose;

  /// Test seam: constructs the platform client. Null uses the packaged one.
  final Future<VityodClient?> Function()? _clientFactory;

  /// Releases resources owned by a dedicated acceptance daemon, if any.
  final Future<void> Function()? _onDispose;

  Future<VityodClient?>? _pendingClient;
  VityodClient? _client;
  bool _disposed = false;

  /// Test seam: how many times the platform client was actually constructed.
  /// A correctly shared holder keeps this at 1.
  @visibleForTesting
  int clientCreations = 0;

  bool get disposed => _disposed;

  /// True once the shared client is established and still alive.
  bool get clientAvailable => _client != null;

  /// The shared client, established at most once.
  ///
  /// A failure to establish is remembered as null rather than retried on every
  /// probe: repeatedly launching the packaged daemon would add a multi-second
  /// connect timeout to every boot. Callers treat null as "local service
  /// unavailable" and degrade honestly.
  @override
  Future<VityodClient?> client() {
    if (_disposed) return Future<VityodClient?>.value(null);
    return _pendingClient ??= _establish();
  }

  Future<VityodClient?> _establish() async {
    clientCreations++;
    try {
      final VityodClient? client =
          await (_clientFactory ?? createPlatformVityodClient)();
      if (_disposed) {
        // The holder was torn down while the client was being established; the
        // holder owns it and releases it here so dispose() stays a no-op.
        await _release(client);
        return null;
      }
      _client = client;
      return client;
    } on Object {
      return null;
    }
  }

  /// Disposes the shared client exactly once. Safe after a failed or
  /// still-pending establishment, and safe to call twice.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    VityodClient? client = _client;
    final Future<VityodClient?>? pending = _pendingClient;
    _client = null;
    _pendingClient = null;
    if (client == null && pending != null) {
      try {
        client = await pending;
      } on Object {
        client = null;
      }
    }
    await _release(client);
    await _onDispose?.call();
  }

  Future<void> _release(VityodClient? client) async {
    if (client == null) return;
    try {
      await client.dispose();
    } on Object {
      // The transport is already closed; nothing further to release.
    }
  }
}
