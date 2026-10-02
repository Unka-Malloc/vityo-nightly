/// Agent bridge: wires the chat rail to the real agent stack —
/// vityod gateway → AgentClientRegistry → AgentClientSession — when the local
/// service and the coding-agent runtime are both reachable. Otherwise it
/// stays in demo mode and says so. The header always shows which side of the
/// wire you are on; nothing fake is presented as live.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../ide/agent_client/agent_client_models.dart';
import '../../ide/agent_client/agent_client_registry.dart';
import '../../ide/local_service/vityod_client.dart';

enum AgentLinkMode { demo, connecting, live, failed }

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
  AgentClientSession? _session;
  StreamSubscription<AgentSessionUpdate>? _updates;
  bool _attachStarted = false;

  Future<void> attach({
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
      );
      // A crashed client leaves a stale connection that blocks a fresh open;
      // close it first. Session persistence in the daemon is idempotent.
      try {
        await _registry!.disconnect(agentId);
      } catch (_) {}
      // File scope + workspace projection for later tool calls; session.new
      // itself only needs the capability-negotiated connection above, so
      // these stay best-effort.
      try {
        await _client!.request(
          method: 'fs.scope.open',
          idempotencyKey:
              'flow-hero-fs-${DateTime.now().microsecondsSinceEpoch}',
          params: const <String, Object?>{
            'scopeId': 'flow-hero',
            'rootPath': workspaceDir,
          },
        );
        await _client!.request(
          method: 'workspace.open',
          idempotencyKey:
              'flow-hero-ws-${DateTime.now().microsecondsSinceEpoch}',
          workspaceId: 'flow-hero',
          params: const <String, Object?>{'rootPath': workspaceDir},
        );
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

  @override
  void dispose() {
    unawaited(_updates?.cancel());
    unawaited(_registry?.close());
    super.dispose();
  }
}
