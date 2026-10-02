/// Agent bridge: wires the chat rail to the real agent stack —
/// vityod gateway → AgentClientRegistry → AgentClientSession — when the local
/// service and the coding-agent runtime are both reachable. Otherwise it
/// stays in demo mode and says so. The header always shows which side of the
/// wire you are on; nothing fake is presented as live.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vityo_agent_protocol/vityo_agent_protocol.dart';

import '../../ide/agent_client/agent_client_models.dart';
import '../../ide/agent_client/agent_client_registry.dart';
import '../../ide/local_service/vityod_client.dart';
import '../../ide/workspace/workspace_document_store_io.dart';
import 'agent_operations.dart';
import 'engine/machine.dart';

enum AgentLinkMode { demo, connecting, live, failed }

const flowHeroAgentClientPolicy = AgentClientPolicy(
  allowedExtensions: <String>{VityoCapability.workspaceChangeProposal},
);

class AgentBridge extends ChangeNotifier {
  static const String agentId = 'vityo-coding-agent';

  // Explicit launch configuration; never embed a developer workstation path.
  static const String agentPackageDir = String.fromEnvironment(
    'VITYO_AGENT_PACKAGE',
  );
  static const String workspaceDir = String.fromEnvironment('VITYO_WORKSPACE');
  static const String dartExecutable = String.fromEnvironment(
    'VITYO_DART_EXECUTABLE',
    defaultValue: 'dart',
  );

  AgentLinkMode mode = AgentLinkMode.demo;
  String statusLine = '演示会话';

  VityodClient? _client;
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

  List<AgentPermissionRequest> get pendingPermissions =>
      List<AgentPermissionRequest>.unmodifiable(_pendingPermissions);

  List<FlowHeroWorkspaceChangeReview> get pendingWorkspaceReviews =>
      List<FlowHeroWorkspaceChangeReview>.unmodifiable(
        _pendingWorkspaceReviews,
      );

  Future<void> attach({
    required WorkbenchController engine,
    required void Function(String text) onText,
    required void Function(String text) onReceipt,
  }) async {
    if (_attachStarted) return;
    _attachStarted = true;
    mode = AgentLinkMode.connecting;
    statusLine = '连接本地服务…';
    notifyListeners();
    if (agentPackageDir.isEmpty || workspaceDir.isEmpty) {
      mode = AgentLinkMode.demo;
      statusLine = '未配置 Agent 工作区 · 演示会话';
      notifyListeners();
      return;
    }
    try {
      _client = await createPlatformVityodClient();
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
            'rootPath': workspaceDir,
          },
        );
        if (scope.method.endsWith('.error')) {
          throw StateError('workspace scope could not be opened');
        }
        final store = VityodWorkspaceDocumentStore(
          client: _client!,
          workspaceId: 'flow-hero',
          workspaceRoot: workspaceDir,
        );
        await store.open();
        await engine.attachWorkspaceDocumentStore(store);
        operationPort = FlowHeroAgentOperationPort(
          engine: engine,
          documentStore: store,
          client: _client!,
          workspaceId: 'flow-hero',
          workspaceRoot: workspaceDir,
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
        descriptors: <String, AgentLaunchDescriptor>{
          agentId: AgentLaunchDescriptor(
            id: agentId,
            executable: dartExecutable,
            arguments: const <String>[
              'run',
              'bin/vityo_coding_agent.dart',
              '--stdio-agent',
            ],
            workingDirectory: agentPackageDir,
          ),
        },
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
        cwd: Uri.directory(workspaceDir),
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

  Future<void> send(String text) async {
    final AgentClientSession? session = _session;
    if (mode != AgentLinkMode.live || session == null) return;
    await session.prompt(text);
  }

  Future<void> decidePermission(
    String permissionId,
    AgentPermissionDecision decision,
  ) async {
    await _registry?.resolvePermission(permissionId, decision);
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
    super.dispose();
  }
}
