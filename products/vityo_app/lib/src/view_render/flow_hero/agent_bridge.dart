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

final class _AgentBridgeAttachment {
  static var _nextResourceToken = 0;

  _AgentBridgeAttachment({
    required this.generation,
    required this.workspaceRoot,
  }) : resourceToken = '${++_nextResourceToken}';

  final int generation;
  final String workspaceRoot;
  final String resourceToken;
  VityodClient? client;
  var ownsClient = false;
  String? ownedWorkspaceScopeId;
  AgentClientRegistry? registry;
  FlowHeroAgentOperationPort? operationPort;
  AgentClientSession? session;
  StreamSubscription<AgentSessionUpdate>? updates;
  StreamSubscription<AgentPermissionRequest>? permissionUpdates;
  StreamSubscription<FlowHeroWorkspaceChangeReview>? proposalUpdates;
  StreamSubscription<String>? proposalResolutions;
  Future<void>? _releaseFuture;

  int get listenerCount => <Object?>[
    updates,
    permissionUpdates,
    proposalUpdates,
    proposalResolutions,
  ].where((subscription) => subscription != null).length;

  Future<void> release() => _releaseFuture ??= _releaseOwnedResources();

  Future<void> _releaseOwnedResources() async {
    final subscriptions = <Future<void>>[
      if (updates case final subscription?) subscription.cancel(),
      if (permissionUpdates case final subscription?) subscription.cancel(),
      if (proposalUpdates case final subscription?) subscription.cancel(),
      if (proposalResolutions case final subscription?) subscription.cancel(),
    ];
    updates = null;
    permissionUpdates = null;
    proposalUpdates = null;
    proposalResolutions = null;
    try {
      await Future.wait<void>(subscriptions);
    } on Object {
      // Finish releasing the other owners even if a stream failed to cancel.
    }

    final registry = this.registry;
    this.registry = null;
    if (registry != null) {
      try {
        await registry.close();
      } on Object {
        // The registry owns its sessions and connection teardown.
      }
    }

    final operationPort = this.operationPort;
    this.operationPort = null;
    if (operationPort != null) {
      try {
        await operationPort.close();
      } on Object {
        // The bridge still releases the registry and client below.
      }
    }

    final client = this.client;
    final workspaceScopeId = ownedWorkspaceScopeId;
    ownedWorkspaceScopeId = null;
    if (client != null && workspaceScopeId != null) {
      try {
        await client.request(
          method: 'fs.scope.close',
          idempotencyKey:
              'flow-hero-scope-close-$workspaceScopeId-$resourceToken',
          params: <String, Object?>{'scopeId': workspaceScopeId},
        );
      } on Object {
        // The daemon may already have retired the scope with its connection.
      }
    }
    this.client = null;
    final shouldDisposeClient = ownsClient;
    ownsClient = false;
    if (client != null && shouldDisposeClient) {
      try {
        await client.dispose();
      } on Object {
        // The transport may already be closed.
      }
    }
    session = null;
  }
}

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

  _AgentBridgeAttachment? _activeAttachment;
  final List<AgentPermissionRequest> _pendingPermissions =
      <AgentPermissionRequest>[];
  final List<FlowHeroWorkspaceChangeReview> _pendingWorkspaceReviews =
      <FlowHeroWorkspaceChangeReview>[];
  bool _attachStarted = false;
  bool _disposed = false;
  int _lifecycleGeneration = 0;
  String? _requestedRoot;
  Completer<void>? _reconcileCompleter;
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
  int get activeListenerCount => _activeAttachment?.listenerCount ?? 0;

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
    if (_disposed) return Future<void>.value();
    if (_attachStarted) {
      return _reconcileCompleter?.future ?? Future<void>.value();
    }
    _attachStarted = true;
    _engine = engine;
    _onText = onText;
    _onReceipt = onReceipt;
    return _requestReconcile();
  }

  /// Rebuilds the link from the latest selected workspace and model settings.
  /// Concurrent requests share a reconciliation loop; a newer request makes
  /// any pending attachment stale and is applied after that attempt releases
  /// the resources it acquired.
  Future<void> reconnect() async {
    if (_disposed) return;
    final WorkbenchController? engine = _engine;
    final void Function(String text)? onText = _onText;
    final void Function(String text)? onReceipt = _onReceipt;
    if (engine == null || onText == null || onReceipt == null) {
      // Never attached: nothing to rewire, and a later attach remains valid.
      _attachStarted = false;
      return;
    }
    _attachStarted = true;
    _lifecycleGeneration++;
    _requestedRoot = _workspaceRoot;
    await _requestReconcile();
  }

  Future<void> _requestReconcile() {
    if (_disposed) return Future<void>.value();
    _requestedRoot ??= _workspaceRoot;
    // Retire the former store synchronously, including when this request is
    // coalesced into a reconcile loop that is waiting on an older attach.
    _engine?.detachWorkspaceDocumentStore();
    final running = _reconcileCompleter;
    if (running != null) return running.future;

    final operation = Completer<void>();
    _reconcileCompleter = operation;
    unawaited(_runReconcileLoop(operation));
    return operation.future;
  }

  Future<void> _runReconcileLoop(Completer<void> operation) async {
    try {
      while (!_disposed) {
        final int generation = _lifecycleGeneration;
        final String workspaceRoot = _requestedRoot ?? _workspaceRoot;
        final WorkbenchController? engine = _engine;
        final void Function(String text)? onText = _onText;
        final void Function(String text)? onReceipt = _onReceipt;
        if (engine == null || onText == null || onReceipt == null) {
          _attachStarted = false;
          break;
        }

        final previous = _activeAttachment;
        _activeAttachment = null;
        _pendingPermissions.clear();
        _pendingWorkspaceReviews.clear();
        mode = workspaceRoot.isEmpty
            ? AgentLinkMode.demo
            : AgentLinkMode.connecting;
        statusLine = workspaceRoot.isEmpty ? '未配置 Agent 工作区 · 演示会话' : '连接本地服务…';
        _notifyIfAlive();
        if (previous != null) await previous.release();
        if (!_isDesired(generation, workspaceRoot)) continue;

        await _attachWorkspace(
          generation: generation,
          workspaceRoot: workspaceRoot,
          engine: engine,
          onText: onText,
          onReceipt: onReceipt,
        );
        if (!_isDesired(generation, workspaceRoot)) continue;
        break;
      }
      if (!operation.isCompleted) operation.complete();
    } on Object catch (error, stackTrace) {
      if (!operation.isCompleted) operation.completeError(error, stackTrace);
    } finally {
      if (identical(_reconcileCompleter, operation)) {
        _reconcileCompleter = null;
      }
    }
  }

  bool _isDesired(int generation, String workspaceRoot) {
    return !_disposed &&
        generation == _lifecycleGeneration &&
        workspaceRoot == _requestedRoot;
  }

  bool _isActiveAttachment(_AgentBridgeAttachment attachment) {
    return _isDesired(attachment.generation, attachment.workspaceRoot) &&
        identical(_activeAttachment, attachment) &&
        mode == AgentLinkMode.live;
  }

  Future<void> _attachWorkspace({
    required int generation,
    required String workspaceRoot,
    required WorkbenchController engine,
    required void Function(String text) onText,
    required void Function(String text) onReceipt,
  }) async {
    final attachment = _AgentBridgeAttachment(
      generation: generation,
      workspaceRoot: workspaceRoot,
    );
    try {
      if (workspaceRoot.isEmpty) {
        _showDemo(attachment, '未配置 Agent 工作区 · 演示会话');
        return;
      }
      // A runtime launched without a provider configuration exits 78 and the
      // link is red for a reason the user cannot see. Keep the demo explanation.
      if (!await _providerRouteReady()) {
        _showDemo(attachment, '未配置模型 · 演示会话');
        return;
      }
      if (!_isDesired(generation, workspaceRoot)) return;

      final descriptor =
          await (launchResolver ?? resolvePackagedCodingAgentLaunch)(
            workingDirectory: workspaceRoot,
          );
      if (!_isDesired(generation, workspaceRoot)) return;

      final client = await _acquireClient(attachment);
      if (!_isDesired(generation, workspaceRoot)) return;
      if (client == null) {
        _showDemo(attachment, '本地服务不可用 · 演示会话');
        return;
      }

      FlowHeroAgentOperationPort? operationPort;
      try {
        final scope = await client.request(
          method: 'fs.scope.open',
          idempotencyKey: 'flow-hero-fs-${attachment.resourceToken}',
          params: <String, Object?>{
            'scopeId': 'flow-hero',
            'rootPath': workspaceRoot,
          },
        );
        if (!scope.method.endsWith('.error')) {
          attachment.ownedWorkspaceScopeId = 'flow-hero';
        }
        if (!_isDesired(generation, workspaceRoot)) return;
        if (scope.method.endsWith('.error')) {
          throw StateError('workspace scope could not be opened');
        }
        final store = await createWorkspaceDocumentStore(
          vityodClient: client,
          workspaceId: 'flow-hero',
          workspaceRoot: workspaceRoot,
        );
        if (!_isDesired(generation, workspaceRoot)) return;
        if (store is! WorkspaceDocumentOperationStore) {
          throw StateError('workspace operations are unavailable');
        }
        await engine.attachWorkspaceDocumentStore(store);
        if (!_isDesired(generation, workspaceRoot)) return;
        operationPort = FlowHeroAgentOperationPort(
          engine: engine,
          documentStore: store,
          client: client,
          workspaceId: 'flow-hero',
          workspaceRoot: workspaceRoot,
        );
        attachment.operationPort = operationPort;
      } on Object {
        if (!_isDesired(generation, workspaceRoot)) return;
        // No file or terminal capability is advertised without live owners.
      }
      if (!_isDesired(generation, workspaceRoot)) return;

      final registry = AgentClientRegistry(
        descriptors: <String, AgentLaunchDescriptor>{agentId: descriptor},
        client: client,
        operationPort: operationPort,
        policy: flowHeroAgentClientPolicy,
      );
      attachment.registry = registry;
      if (operationPort != null) {
        attachment.proposalUpdates = operationPort.proposalReviews.listen((
          review,
        ) {
          if (!_isActiveAttachment(attachment)) return;
          _pendingWorkspaceReviews.removeWhere(
            (current) => current.reviewId == review.reviewId,
          );
          _pendingWorkspaceReviews.add(review);
          _notifyIfAlive();
        });
        attachment.proposalResolutions = operationPort.resolvedProposalReviews
            .listen((id) {
              if (!_isActiveAttachment(attachment)) return;
              _pendingWorkspaceReviews.removeWhere(
                (review) => review.reviewId == id,
              );
              _notifyIfAlive();
            });
      }
      attachment.permissionUpdates = registry.permissionRequests.listen((
        permission,
      ) {
        if (!_isActiveAttachment(attachment)) return;
        _pendingPermissions.removeWhere((item) => item.id == permission.id);
        _pendingPermissions.add(permission);
        _notifyIfAlive();
      });
      if (!_isDesired(generation, workspaceRoot)) return;

      // A crashed client leaves a stale connection that blocks a fresh open;
      // close it first. Session persistence in the daemon is idempotent.
      try {
        await registry.disconnect(agentId);
      } on Object {
        // The connection may already be gone; opening a fresh session decides.
      }
      if (!_isDesired(generation, workspaceRoot)) return;
      statusLine = '拉起 coding agent…';
      _notifyIfAlive();
      if (!_isDesired(generation, workspaceRoot)) return;
      final session = await registry.newSession(
        agentId: agentId,
        cwd: Uri.directory(workspaceRoot),
      );
      attachment.session = session;
      if (!_isDesired(generation, workspaceRoot)) return;
      attachment.updates = session.updates.listen((update) {
        if (!_isActiveAttachment(attachment)) return;
        final String? text = update.text;
        if (text != null && text.isNotEmpty) {
          onText(text);
        } else if (update.kind != 'message') {
          onReceipt(update.kind);
        }
      });

      if (!_isDesired(generation, workspaceRoot)) return;
      _activeAttachment = attachment;
      mode = AgentLinkMode.live;
      statusLine = agentId;
      _notifyIfAlive();
    } on Object {
      if (_isDesired(generation, workspaceRoot)) {
        mode = AgentLinkMode.failed;
        statusLine = '接线失败 · 演示会话';
        onReceipt('agent 接线失败，请检查本地服务与启动配置。');
        if (_isDesired(generation, workspaceRoot)) _notifyIfAlive();
      }
    } finally {
      if (!identical(_activeAttachment, attachment)) {
        await attachment.release();
      }
    }
  }

  void _showDemo(_AgentBridgeAttachment attachment, String line) {
    if (!_isDesired(attachment.generation, attachment.workspaceRoot)) return;
    mode = AgentLinkMode.demo;
    statusLine = line;
    _notifyIfAlive();
  }

  /// Resolves the client the bridge uses, recording ownership on this attempt.
  /// A provider-supplied client is shared and remains owned by its holder.
  Future<VityodClient?> _acquireClient(
    _AgentBridgeAttachment attachment,
  ) async {
    final Future<VityodClient?> Function()? provider = clientProvider;
    final VityodClient? client;
    if (provider != null) {
      attachment.ownsClient = false;
      client = await provider();
    } else {
      attachment.ownsClient = true;
      client = await (clientFactory ?? createPlatformVityodClient)();
    }
    attachment.client = client;
    return client;
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
    final attachment = _activeAttachment;
    final AgentClientSession? session = attachment?.session;
    if (attachment == null ||
        session == null ||
        !_isActiveAttachment(attachment)) {
      return;
    }
    await session.prompt(text);
  }

  Future<void> decidePermission(String permissionId, String optionId) async {
    final attachment = _activeAttachment;
    final registry = attachment?.registry;
    if (attachment == null ||
        registry == null ||
        !_isActiveAttachment(attachment)) {
      return;
    }
    await registry.resolvePermission(permissionId, optionId);
    if (!_isActiveAttachment(attachment)) return;
    _pendingPermissions.removeWhere((item) => item.id == permissionId);
    _notifyIfAlive();
  }

  void decideWorkspaceProposal(String reviewId, {required bool apply}) {
    final attachment = _activeAttachment;
    if (attachment == null || !_isActiveAttachment(attachment)) return;
    attachment.operationPort?.decideWorkspaceProposal(reviewId, apply: apply);
  }

  void _notifyIfAlive() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _lifecycleGeneration++;
    final engine = _engine;
    engine?.detachWorkspaceDocumentStore();
    final attachment = _activeAttachment;
    _activeAttachment = null;
    _pendingPermissions.clear();
    _pendingWorkspaceReviews.clear();
    if (attachment != null) unawaited(attachment.release());
    super.dispose();
  }
}
