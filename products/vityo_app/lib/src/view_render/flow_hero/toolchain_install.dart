/// Flow Hero's "point at a local binary" install flow.
///
/// There is no downloadable pafio/styio release source today, so the honest
/// path is not a fake download: the user selects an existing local executable,
/// the app verifies it for real (`--version` through the platform process
/// manager, plus the executable check Styio discovery itself performs), persists
/// the choice in `toolchain.json`, and re-boots the execution route. Every state
/// shown here — which locations were probed, the real version output, the real
/// failure, the resulting route — comes from a real probe.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'controller.dart';
import '../../view_ide/flow_hero/flow_hero.dart';
import 'palette.dart';

/// The install dialog. Opened from the RUN strip's unavailable state and from
/// the settings panel's execution row.
class ToolchainInstallDialog extends StatefulWidget {
  const ToolchainInstallDialog({super.key, required this.controller});

  final FlowHeroController controller;

  @override
  State<ToolchainInstallDialog> createState() => _ToolchainInstallDialogState();
}

class _ToolchainInstallDialogState extends State<ToolchainInstallDialog> {
  final Map<FlowHeroToolchainKind, TextEditingController> _paths =
      <FlowHeroToolchainKind, TextEditingController>{};
  final Map<FlowHeroToolchainKind, FlowHeroToolchainProbeResult?> _probes =
      <FlowHeroToolchainKind, FlowHeroToolchainProbeResult?>{};
  final Set<FlowHeroToolchainKind> _probing = <FlowHeroToolchainKind>{};
  final Set<FlowHeroToolchainKind> _saving = <FlowHeroToolchainKind>{};
  final Map<FlowHeroToolchainKind, List<FlowHeroToolchainCandidate>>
  _candidates = {};
  final Map<FlowHeroToolchainKind, String> _discoveryErrors = {};
  final Set<FlowHeroToolchainKind> _discovering = {};
  final Set<FlowHeroToolchainKind> _partialDiscovery = {};
  final Set<FlowHeroToolchainKind> _picking = {};
  final Map<FlowHeroToolchainKind, int> _edits = {};
  String _note = '';
  bool _noteIsFailure = false;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    for (final FlowHeroToolchainKind kind in FlowHeroToolchainKind.values) {
      _paths[kind] = TextEditingController();
      _discovering.add(kind);
      unawaited(_discover(kind));
    }
  }

  Future<void> _discover(FlowHeroToolchainKind kind) async {
    try {
      final candidates = await widget.controller.discoverToolchainCandidates(
        kind,
      );
      if (!mounted) return;
      setState(() {
        _candidates[kind] = candidates;
        if (candidates is FlowHeroToolchainCandidateCatalog &&
            candidates.isPartial) {
          _partialDiscovery.add(kind);
        }
        _discovering.remove(kind);
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _discovering.remove(kind);
        _discoveryErrors[kind] =
            'Could not check local locations. Choose a file below.';
      });
    }
  }

  void _setCandidate(FlowHeroToolchainKind kind, String path) {
    setState(() {
      _paths[kind]!.text = path;
      _edits[kind] = (_edits[kind] ?? 0) + 1;
      _probes[kind] = null;
      _note = '';
    });
  }

  Future<void> _chooseFile(FlowHeroToolchainKind kind) async {
    final revision = _edits[kind] ?? 0;
    setState(() => _picking.add(kind));
    try {
      final path = await widget.controller.chooseToolchainFile(kind);
      if (!mounted || revision != (_edits[kind] ?? 0)) return;
      if (path != null && path.trim().isNotEmpty) {
        _setCandidate(kind, path.trim());
      }
    } on Object {
      if (!mounted) return;
      setState(() {
        _noteIsFailure = true;
        _note =
            'The file chooser is unavailable. Use the manual path fallback.';
      });
    } finally {
      if (mounted) setState(() => _picking.remove(kind));
    }
  }

  @override
  void dispose() {
    for (final TextEditingController controller in _paths.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Both selections remain editable, even when only one tool is missing or
  /// incompatible, so the user can choose a matching pair.
  List<FlowHeroToolchainKind> get _kinds => FlowHeroToolchainKind.values;

  Future<void> _verify(FlowHeroToolchainKind kind) async {
    final String path = _paths[kind]!.text.trim();
    final revision = _edits[kind] ?? 0;
    setState(() {
      _probing.add(kind);
      _probes[kind] = null;
      _note = '';
    });
    final FlowHeroToolchainProbeResult result = await widget.controller
        .probeToolchainCandidate(kind, path);
    if (!mounted) return;
    setState(() {
      _probing.remove(kind);
      _probes[kind] = revision == (_edits[kind] ?? 0) ? result : null;
    });
  }

  Future<void> _save(FlowHeroToolchainKind kind) async {
    final String path = _paths[kind]!.text.trim();
    setState(() {
      _saving.add(kind);
      _note = '';
    });
    final FlowHeroToolchainSaveResult result = await widget.controller
        .saveToolchainOverride(kind, path);
    if (!mounted) return;
    setState(() {
      _saving.remove(kind);
      _noteIsFailure = !result.saved;
      _note = result.saved
          ? <String>[
              '已保存 · ${result.stateLine}',
              if (result.languageNote.isNotEmpty) result.languageNote,
            ].join('\n')
          : result.failureMessage;
    });
  }

  Future<void> _retry() async {
    setState(() => _retrying = true);
    await widget.controller.retryExecutionBoot();
    if (!mounted) return;
    setState(() {
      _retrying = false;
      _noteIsFailure = !widget.controller.executionLive;
      _note = '重新探测完成 · ${widget.controller.executionStatusLabel}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final FlowHeroController c = widget.controller;
    return AnimatedBuilder(
      animation: c,
      builder: (BuildContext context, _) {
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: c.closeToolchainInstall,
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.55)),
            ),
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height - 48,
                ),
                child: Container(
                  key: const ValueKey('toolchain-install-dialog'),
                  width: 480,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: P.panel,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: P.seamLo),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Colors.black87,
                        blurRadius: 34,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _header(c),
                      Flexible(
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                _stateBanner(c),
                                const SizedBox(height: 6),
                                Text(
                                  c.toolchainPairCheck == null
                                      ? 'Runtime compatibility: Not checked'
                                      : 'Runtime compatibility: ${c.toolchainPairCheck!.compatible ? 'Compatible' : 'Incompatible'}',
                                  key: const ValueKey(
                                    'toolchain-install-compatibility',
                                  ),
                                  style: P.monoStyle(
                                    color: P.paperLow,
                                    size: 10.5,
                                  ),
                                ),
                                for (final FlowHeroToolchainKind kind
                                    in _kinds) ...<Widget>[
                                  const SizedBox(height: 14),
                                  _section(kind),
                                ],
                                if (_note.isNotEmpty) ...<Widget>[
                                  const SizedBox(height: 12),
                                  Text(
                                    _note,
                                    key: const ValueKey(
                                      'toolchain-install-note',
                                    ),
                                    style: P.monoStyle(
                                      color: _noteIsFailure
                                          ? P.red
                                          : P.paperLow,
                                      size: 10.5,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      _footer(c),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _header(FlowHeroController c) {
    return Container(
      height: 38,
      padding: const EdgeInsets.only(left: 14, right: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: P.seamLo)),
      ),
      child: Row(
        children: <Widget>[
          Text('工具链安装', style: P.silkStyle(hi: true)),
          const Spacer(),
          InkWell(
            key: const ValueKey('toolchain-install-close'),
            onTap: c.closeToolchainInstall,
            borderRadius: BorderRadius.circular(3),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.close, size: 15, color: P.silkDim),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stateBanner(FlowHeroController c) {
    final bool live = c.executionLive;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 7,
          height: 7,
          margin: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: live ? const Color(0xFF30D158) : P.red,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            live
                ? '执行服务已就绪 · ${c.executionStatusLabel}'
                : '执行服务不可用 · ${c.executionUnavailableReason}',
            key: const ValueKey('toolchain-install-state'),
            style: P.monoStyle(color: P.paperLow, size: 11),
          ),
        ),
      ],
    );
  }

  Widget _section(FlowHeroToolchainKind kind) {
    final FlowHeroToolchainProbeResult? probe = _probes[kind];
    final bool verifying = _probing.contains(kind);
    final bool saving = _saving.contains(kind);
    final List<FlowHeroToolchainCheck> checks =
        widget.controller.toolchainChecks[kind] ??
        const <FlowHeroToolchainCheck>[];
    return Container(
      key: ValueKey<String>('toolchain-install-section-${kind.id}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: P.well,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: P.ring),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(kind.displayName, style: P.silkStyle(hi: true)),
          if (widget.controller
              .resolvedToolchainPath(kind)
              .isNotEmpty) ...<Widget>[
            const SizedBox(height: 5),
            Text(
              'Selected: ${widget.controller.resolvedToolchainOrigin(kind)}\n${widget.controller.resolvedToolchainPath(kind)}',
              key: ValueKey<String>('toolchain-install-selected-${kind.id}'),
              style: P.monoStyle(color: P.paperLow, size: 10.5),
            ),
          ],
          const SizedBox(height: 5),
          Text(
            kind == FlowHeroToolchainKind.pafio
                ? 'Release provenance: Not verified by Vityo'
                : widget.controller.toolchainPairCheck?.releaseProvenance ==
                      'unverified'
                ? 'Release provenance: Unverified (Pafio report)'
                : 'Release provenance: Not verified by Vityo; no supported report',
            key: ValueKey<String>('toolchain-install-provenance-${kind.id}'),
            style: P.monoStyle(color: P.silkDim, size: 10.5),
          ),
          if (kind == FlowHeroToolchainKind.styio &&
              widget.controller.toolchainPairCheck != null)
            Text(
              'Published support: ${switch (widget.controller.toolchainPairCheck!.productSupport) {
                'published' => 'Listed in Pafio matrix',
                'unlisted' => 'Not listed in Pafio matrix',
                _ => 'Not reported',
              }}',
              key: const ValueKey('toolchain-install-product-support'),
              style: P.monoStyle(color: P.silkDim, size: 10.5),
            ),
          const SizedBox(height: 8),
          Text('已检查的位置', style: P.silkStyle(dim: true)),
          const SizedBox(height: 5),
          if (checks.isEmpty)
            Text(
              '（本次探测未记录位置）',
              style: P.monoStyle(color: P.silkDim, size: 10.5),
            )
          else
            for (final FlowHeroToolchainCheck check in checks)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 150,
                      child: Text(
                        check.source,
                        style: P.monoStyle(color: P.silkDim, size: 10.5),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        check.path,
                        style: P.monoStyle(color: P.silk, size: 10.5),
                      ),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: 10),
          Text('Choose a detected installation', style: P.silkStyle(hi: true)),
          const SizedBox(height: 5),
          if (_discovering.contains(kind))
            Text(
              'Checking app, standard locations and PATH…',
              style: P.silkStyle(dim: true),
            )
          else if ((_candidates[kind] ?? const []).isEmpty)
            Text(
              _discoveryErrors[kind] ??
                  'No suggestions found in the checked locations. Choose a file below.',
              style: P.silkStyle(dim: true),
            )
          else
            DropdownButton<String>(
              value:
                  (_candidates[kind] ?? const <FlowHeroToolchainCandidate>[])
                      .any((candidate) => candidate.path == _paths[kind]!.text)
                  ? _paths[kind]!.text
                  : null,
              key: ValueKey<String>('toolchain-install-candidates-${kind.id}'),
              isExpanded: true,
              dropdownColor: P.panel,
              style: P.monoStyle(color: P.paperLow, size: 10.5),
              hint: Text(
                'Select an installation',
                style: P.silkStyle(dim: true),
              ),
              items: [
                for (final candidate in _candidates[kind]!)
                  DropdownMenuItem(
                    value: candidate.path,
                    child: Text(
                      '${candidate.sourceLabel}: ${candidate.path}${candidate.exists ? '' : ' (not found or unavailable)'}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: verifying || saving
                  ? null
                  : (path) {
                      if (path != null) _setCandidate(kind, path);
                    },
            ),
          if (_partialDiscovery.contains(kind))
            Text(
              'Some locations could not be checked. You can still choose a file.',
              key: ValueKey<String>('toolchain-install-partial-${kind.id}'),
              style: P.silkStyle(dim: true),
            ),
          const SizedBox(height: 7),
          Align(
            alignment: Alignment.centerLeft,
            child: _ActionButton(
              buttonKey: ValueKey<String>(
                'toolchain-install-browse-${kind.id}',
              ),
              label: _picking.contains(kind) ? 'Choosing…' : 'Choose file…',
              enabled: !verifying && !saving && !_picking.contains(kind),
              onTap: () => _chooseFile(kind),
            ),
          ),
          const SizedBox(height: 7),
          Text('Manual path (fallback)', style: P.silkStyle(dim: true)),
          const SizedBox(height: 5),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            decoration: BoxDecoration(
              color: P.panel,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: P.ring),
            ),
            child: TextField(
              key: ValueKey<String>('toolchain-install-path-${kind.id}'),
              controller: _paths[kind],
              enabled: !verifying && !saving,
              onChanged: (_) {
                _edits[kind] = (_edits[kind] ?? 0) + 1;
                setState(() => _probes[kind] = null);
              },
              style: P.monoStyle(color: P.paperLow, size: 11.5),
              cursorColor: P.orange,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: kind == FlowHeroToolchainKind.pafio
                    ? '/path/to/pafio'
                    : '/path/to/styio',
                hintStyle: P.silkStyle(dim: true),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              _ActionButton(
                buttonKey: ValueKey<String>(
                  'toolchain-install-verify-${kind.id}',
                ),
                label: verifying ? '验证中…' : '验证',
                enabled: !verifying && !saving && !_picking.contains(kind),
                color: P.orangeBright,
                onTap: () => _verify(kind),
              ),
              const SizedBox(width: 8),
              _ActionButton(
                buttonKey: ValueKey<String>(
                  'toolchain-install-save-${kind.id}',
                ),
                label: saving ? '保存中…' : '保存并启用',
                enabled:
                    !verifying &&
                    !saving &&
                    !_picking.contains(kind) &&
                    (probe?.ok ?? false),
                color: P.orangeBright,
                onTap: () => _save(kind),
              ),
            ],
          ),
          if (probe != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              probe.detail,
              key: ValueKey<String>('toolchain-install-result-${kind.id}'),
              style: P.monoStyle(
                color: probe.ok ? const Color(0xFF30D158) : P.red,
                size: 10.5,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _footer(FlowHeroController c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: P.seamLo)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              c.toolchainStorePersistent
                  ? '选择将写入当前配置目录的 toolchain.json'
                  : '本次会话有效 · 未持久化',
              style: P.monoStyle(color: P.silkDim, size: 10),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: 8),
          _ActionButton(
            buttonKey: const ValueKey('toolchain-install-retry'),
            label: _retrying ? '探测中…' : '重新探测',
            enabled: !_retrying,
            onTap: _retry,
          ),
          const SizedBox(width: 8),
          _ActionButton(
            buttonKey: const ValueKey('toolchain-install-cancel'),
            label: '取消',
            enabled: true,
            onTap: c.closeToolchainInstall,
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.buttonKey,
    required this.label,
    required this.enabled,
    required this.onTap,
    this.color,
  });

  final Key buttonKey;
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color textColor = enabled
        ? (color ?? P.paperLow)
        : P.silkDim.withValues(alpha: 0.6);
    return InkWell(
      key: buttonKey,
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: P.panelHi,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: P.seamLo),
        ),
        child: Text(
          label,
          style: P.silkStyle().copyWith(color: textColor, fontSize: 10),
        ),
      ),
    );
  }
}
