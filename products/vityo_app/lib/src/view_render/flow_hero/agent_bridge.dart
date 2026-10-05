/// Agent bridge: wires the chat rail to the real agent stack —
/// vityod gateway → AgentClientRegistry → AgentClientSession — when the local
/// service and the coding-agent runtime are both reachable. Otherwise it
/// stays in demo mode and says so. The header always shows which side of the
/// wire you are on; nothing fake is presented as live.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vityo_agent_protocol/vityo_agent_protocol.dart';

import '../../ide/agent_client/agent_launch_paths.dart';
import '../../ide/agent_client/agent_client_models.dart';
import '../../ide/agent_client/agent_client_registry.dart';
import '../../ide/local_service/vityod_client.dart';
import '../../ide/workspace/workspace_document_store.dart';
import 'agent_operations.dart';
import 'engine/machine.dart';

enum AgentLinkMode { demo, connecting, live, failed }

const flowHeroAgentClientPolicy = AgentClientPolicy(
  allowedExtensions: <String>{VityoCapability.workspaceChangeProposal},
);

class AgentBridge extends ChangeNotifier {
  AgentBridge({
    this.clientProvider,
    @visibleForTesting this.clientFactory,
    @visibleForTesting this.launchResolver,
    @visibleForTesting this.workspaceDirectory,
  });

  static const String agentId = firstPartyCodingAgentId;

  // Explicit workspace selection; the Agent executable is packaged with Vityo.
  static const String workspaceDir = String.fromEnvironment('VITYO_WORKSPACE');

  /// The app-shared local-service client supplied by the feature owner. When
  /// set, the bridge uses this exact instance and never disposes it — the
  /// holder owns disposal, and the agent bridge must not tear down the client
  /// the execution and language routes are still using.
  final Future<VityodClient?> Function()? clientProvider;

  /// Test seam: builds the local-service client when no [clientProvider] is
  /// given. Null uses the packaged gateway. A client built here is owned and
  /// disposed by the bridge.
  @visibleForTesting
  final Future<VityodClient?> Function()? clientFactory;

  /// Test seam: resolves the packaged coding-agent descriptor.
  @visibleForTesting
  final Future<AgentLaunchDescriptor> Function({
    required String workingDirectory,
  })?
  launchResolver;

  /// Test seam: overrides the packaged build-time workspace root.
  @visibleForTesting
  final String? workspaceDirectory;

  /// Runtime workspace selection, set through [setWorkspaceRoot]. It outranks
  /// the build-time [workspaceDir] but yields to the [workspaceDirectory] test
  /// seam.
  String? _selectedWorkspace;

  /// Asked before the packaged runtime is launched. False keeps the bridge in
  /// demo mode and names the missing model configuration instead of spawning an
  /// executable that would exit 78 for a missing `provider.json`. Null means
  /// the caller configured the route out of band, so nothing is gated.
  Future<bool> Function()? modelConfigured;

  AgentLinkMode mode = AgentLinkMode.demo;
  String statusLine = '演示会话';

  VityodClient? _client;
  bool _ownsClient = false;
  AgentClientRegistry? _registry;
  FlowHeroAgentOperationPort? _operationPort;
  AgentClientSession? _session;
  StreamSubscription<AgentSessionUpdate>? _updates;
  StreamSubscription<AgentPermissionRequest>? _permissionUpdates;
  StreamSubscription<FlowHeroWorkspaceChangeReview>? _proposalUpdates;
  StreamSubscription<String>? _proposalResolutions;
  final List<AgentPermissionRequest> _pendingPermissions =
      <AgentPermissionRequest>[];
  final List<FlowHeroWorkspaceChangeReview> _pendingWorkspaceReviews =
      <FlowHeroWorkspaceChangeReview>[];
  bool _attachStarted = false;
  bool _reconnecting = false;
  Future<void>? _attachOperation;
  WorkbenchController? _engine;
  void Function(String text)? _onText;
  void Function(String text)? _onReceipt;

  List<AgentPermissionRequest> get pendingPermissions =>
      List<AgentPermissionRequest>.unmodifiable(_pendingPermissions);

  List<FlowHeroWorkspaceChangeReview> get pendingWorkspaceReviews =>
      List<FlowHeroWorkspaceChangeReview>.unmodifiable(
        _pendingWorkspaceReviews,
      );

  /// Test seam: how many runtime streams the bridge is listening to. A
  /// reconnect must leave this unchanged, not doubled.
  @visibleForTesting
  int get activeListenerCount => <StreamSubscription<Object?>?>[
    _updates,
    _permissionUpdates,
    _proposalUpdates,
    _proposalResolutions,
  ].where((StreamSubscription<Object?>? s) => s != null).length;

  /// Test seam: whether an attach may still start (false after a reconnect).
  @visibleForTesting
  bool get attachStarted => _attachStarted;

  String get _workspaceRoot =>
      (workspaceDirectory ?? _selectedWorkspace ?? workspaceDir).trim();

  /// The workspace root the next attach or reconnect uses.
  String get workspaceRoot => _workspaceRoot;

  /// Points the link at [path] for the next attach or reconnect. An empty path
  /// clears the selection and falls back to the build-time workspace.
  ///
  /// The bridge does not rewire itself here: the caller owns the rebuild (see
  /// `FlowHeroController.switchWorkspace`), so a selection change can be
  /// persisted and re-rooted before the new session is opened. An already
  /// attached link keeps its old root until [reconnect] runs.
  void setWorkspaceRoot(String path) {
    final String trimmed = path.trim();
    _selectedWorkspace = trimmed.isEmpty ? null : trimmed;
  }

  Future<void> attach({
    required WorkbenchController engine,
    required void Function(String text) onText,
    required void Function(String text) onReceipt,
  }) {
    final Future<void> operation = _attach(
      engine: engine,
      onText: onText,
      onReceipt: onReceipt,
    );
    _attachOperation = operation;
    return operation;
  }

  Future<void> _attach({
    required WorkbenchController engine,
    required void Function(String text) onText,
    required void Function(String text) onReceipt,
  }) async {
    if (_attachStarted) return;
    _attachStarted = true;
    _engine = engine;
    _onText = onText;
    _onReceipt = onReceipt;
    mode = AgentLinkMode.connecting;
    statusLine = '连接本地服务…';
    notifyListeners();
    final String workspaceRoot = _workspaceRoot;
    if (workspaceRoot.isEmpty) {
      mode = AgentLinkMode.demo;
      statusLine = '未配置 Agent 工作区 · 演示会话';
      notifyListeners();
      return;
    }
    // A runtime launched without a provider configuration exits 78 and the
    // link is red for a reason the user cannot see. Say the real reason here
    // instead, and stay in demo mode rather than claiming a failed handshake.
    if (!await _providerRouteReady()) {
      mode = AgentLinkMode.demo;
      statusLine = '未配置模型 · 演示会话';
      notifyListeners();
      return;
    }
    try {
      final descriptor =
          await (launchResolver ?? resolvePackagedCodingAgentLaunch)(
            workingDirectory: workspaceRoot,
          );
      _client = await _acquireClient();
      if (_client == null) {
        mode = AgentLinkMode.demo;
        statusLine = '本地服务不可用 · 演示会话';
        notifyListeners();
        return;
      }
      FlowHeroAgentOperationPort? operationPort;
      try {
        final scope = await _client!.request(
          method: 'fs.scope.open',
          idempotencyKey:
              'flow-hero-fs-${DateTime.now().microsecondsSinceEpoch}',
          params: <String, Object?>{
            'scopeId': 'flow-hero',
            'rootPath': workspaceRoot,
          },
        );
        if (scope.method.endsWith('.error')) {
          throw StateError('workspace scope could not be opened');
        }
        final store = await createWorkspaceDocumentStore(
          vityodClient: _client!,
          workspaceId: 'flow-hero',
          workspaceRoot: workspaceRoot,
        );
        if (store is! WorkspaceDocumentOperationStore) {
          throw StateError('workspace operations are unavailable');
        }
        await engine.attachWorkspaceDocumentStore(store);
        operationPort = FlowHeroAgentOperationPort(
          engine: engine,
          documentStore: store,
          client: _client!,
          workspaceId: 'flow-hero',
          workspaceRoot: workspaceRoot,
        );
        _operationPort = operationPort;
        _proposalUpdates = operationPort.proposalReviews.listen((review) {
          _pendingWorkspaceReviews.removeWhere(
            (current) => current.reviewId == review.reviewId,
          );
          _pendingWorkspaceReviews.add(review);
          notifyListeners();
        });
        _proposalResolutions = operationPort.resolvedProposalReviews.listen((
          id,
        ) {
          _pendingWorkspaceReviews.removeWhere(
            (review) => review.reviewId == id,
          );
          notifyListeners();
        });
      } on Object {
        // No file or terminal capability is advertised without live owners.
      }
      _registry = AgentClientRegistry(
        descriptors: <String, AgentLaunchDescriptor>{agentId: descriptor},
        client: _client!,
        operationPort: operationPort,
        policy: flowHeroAgentClientPolicy,
      );
      _permissionUpdates = _registry!.permissionRequests.listen((permission) {
        _pendingPermissions.removeWhere((item) => item.id == permission.id);
        _pendingPermissions.add(permission);
        notifyListeners();
      });
      // A crashed client leaves a stale connection that blocks a fresh open;
      // close it first. Session persistence in the daemon is idempotent.
      try {
        await _registry!.disconnect(agentId);
      } catch (_) {}
      statusLine = '拉起 coding agent…';
      notifyListeners();
      _session = await _registry!.newSession(
        agentId: agentId,
        cwd: Uri.directory(workspaceRoot),
      );
      _updates = _session!.updates.listen((AgentSessionUpdate u) {
        final String? text = u.text;
        if (text != null && text.isNotEmpty) {
          onText(text);
        } else if (u.kind != 'message') {
          onReceipt(u.kind);
        }
      });
      // The green lamp already says the link is live — just name the peer.
      mode = AgentLinkMode.live;
      statusLine = agentId;
      notifyListeners();
    } catch (error) {
      mode = AgentLinkMode.failed;
      statusLine = '接线失败 · 演示会话';
      onReceipt('agent 接线失败，请检查本地服务与启动配置。');
      notifyListeners();
    }
  }

  /// Rebuilds the link from scratch — used after the model configuration
  /// changed. The previous session and its subscriptions are torn down first,
  /// so a second attach never doubles listeners.
  Future<void> reconnect() async {
    if (_reconnecting) return;
    _reconnecting = true;
    try {
      final Future<void>? inflight = _attachOperation;
      if (inflight != null) {
        try {
          await inflight;
        } on Object {
          // A failed attach already reported itself; teardown cleans up.
        }
      }
      final WorkbenchController? engine = _engine;
      final void Function(String text)? onText = _onText;
      final void Function(String text)? onReceipt = _onReceipt;
      if (engine == null || onText == null || onReceipt == null) {
        // Never attached: nothing to rewire, and the next attach is not blocked.
        _attachStarted = false;
        return;
      }
      await _teardown();
      _attachStarted = false;
      await attach(engine: engine, onText: onText, onReceipt: onReceipt);
    } finally {
      _reconnecting = false;
    }
  }

  /// Drops every runtime subscription and connection this bridge owns.
  Future<void> _teardown() async {
    final StreamSubscription<AgentSessionUpdate>? updates = _updates;
    final StreamSubscription<AgentPermissionRequest>? permissions =
        _permissionUpdates;
    final StreamSubscription<FlowHeroWorkspaceChangeReview>? proposals =
        _proposalUpdates;
    final StreamSubscription<String>? resolutions = _proposalResolutions;
    _updates = null;
    _permissionUpdates = null;
    _proposalUpdates = null;
    _proposalResolutions = null;
    await updates?.cancel();
    await permissions?.cancel();
    await proposals?.cancel();
    await resolutions?.cancel();
    _pendingPermissions.clear();
    _pendingWorkspaceReviews.clear();
    final AgentClientRegistry? registry = _registry;
    final VityodClient? client = _client;
    _session = null;
    _registry = null;
    _operationPort = null;
    _client = null;
    if (registry != null) {
      try {
        await registry.disconnect(agentId);
      } on Object {
        // The connection may already be gone; close() below is the real guard.
      }
      try {
        await registry.close();
      } on Object {
        // Nothing further to release.
      }
    }
    if (client != null && _ownsClient) {
      try {
        await client.dispose();
      } on Object {
        // The transport is already closed.
      }
    }
    _ownsClient = false;
    notifyListeners();
  }

  /// Resolves the client the bridge uses, recording who owns it.
  ///
  /// A [clientProvider]-supplied client is the app's shared instance: the
  /// bridge borrows it and must not dispose it. A client built by the bridge
  /// (its own [clientFactory], or the packaged gateway) is owned and disposed
  /// on teardown.
  Future<VityodClient?> _acquireClient() async {
    final Future<VityodClient?> Function()? provider = clientProvider;
    if (provider != null) {
      _ownsClient = false;
      return provider();
    }
    _ownsClient = true;
    return (clientFactory ?? createPlatformVityodClient)();
  }

  Future<bool> _providerRouteReady() async {
    final Future<bool> Function()? probe = modelConfigured;
    if (probe == null) return true;
    try {
      return await probe();
    } on Object {
      return false;
    }
  }

  Future<void> send(String text) async {
    final AgentClientSession? session = _session;
    if (mode != AgentLinkMode.live || session == null) return;
    await session.prompt(text);
  }

  Future<void> decidePermission(String permissionId, String optionId) async {
    await _registry?.resolvePermission(permissionId, optionId);
    _pendingPermissions.removeWhere((item) => item.id == permissionId);
    notifyListeners();
  }

  void decideWorkspaceProposal(String reviewId, {required bool apply}) {
    _operationPort?.decideWorkspaceProposal(reviewId, apply: apply);
  }

  @override
  void dispose() {
    unawaited(_updates?.cancel());
    unawaited(_permissionUpdates?.cancel());
    unawaited(_proposalUpdates?.cancel());
    unawaited(_proposalResolutions?.cancel());
    _pendingPermissions.clear();
    _pendingWorkspaceReviews.clear();
    unawaited(_operationPort?.close());
    unawaited(_registry?.close());
    if (_ownsClient) unawaited(_client?.dispose());
    super.dispose();
  }
}
