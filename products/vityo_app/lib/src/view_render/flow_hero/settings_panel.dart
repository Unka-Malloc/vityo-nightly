/// The settings panel: a centered modal card over a dimmed scrim. Every row
/// is wired — the theme switch flips the palette live, the model section
/// writes the real provider configuration the agent runtime reads, the link
/// row reads the real agent bridge state, and the scrim or the ✕ closes it.
library;

import 'package:flutter/material.dart';

import 'agent_bridge.dart';
import 'controller.dart';
import 'dropdown.dart';
import '../../view_ide/flow_hero/flow_hero.dart';
import 'palette.dart';

class SettingsPanel extends StatelessWidget {
  const SettingsPanel({super.key, required this.controller});

  final FlowHeroController controller;

  @override
  Widget build(BuildContext context) {
    final FlowHeroController c = controller;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: c.toggleSettings,
          child: ColoredBox(color: Colors.black.withValues(alpha: 0.55)),
        ),
        Center(
          child: ConstrainedBox(
            // The card grows with its content, but never past the window: the
            // body scrolls instead of overflowing.
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height - 48,
            ),
            child: Container(
              width: 420,
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
                  Container(
                    height: 38,
                    padding: const EdgeInsets.only(left: 14, right: 6),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: P.seamLo)),
                    ),
                    child: Row(
                      children: <Widget>[
                        Text('设置', style: P.silkStyle(hi: true)),
                        const Spacer(),
                        InkWell(
                          onTap: c.toggleSettings,
                          borderRadius: BorderRadius.circular(3),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(
                              Icons.close,
                              size: 15,
                              color: P.silkDim,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          _Section(
                            title: '外观',
                            child: Row(
                              children: <Widget>[
                                _ThemeTab(
                                  label: '夜间',
                                  on: P.dark,
                                  onTap: () => _setTheme(c, true),
                                ),
                                const SizedBox(width: 6),
                                _ThemeTab(
                                  label: '白天',
                                  on: !P.dark,
                                  onTap: () => _setTheme(c, false),
                                ),
                              ],
                            ),
                          ),
                          _Section(
                            title: '工作区',
                            child: _WorkspaceRow(controller: c),
                          ),
                          _Section(
                            title: '模型配置',
                            child: _ModelConfigSection(controller: c),
                          ),
                          _Section(
                            title: 'AGENT 连接',
                            child: _LinkRow(bridge: c.bridge),
                          ),
                          _Section(
                            title: '语言服务',
                            child: _LanguageRow(controller: c),
                          ),
                          _Section(
                            title: '执行服务',
                            child: _ExecutionRow(controller: c),
                          ),
                          const _Section(
                            title: '关于',
                            divider: false,
                            child: _AboutRow(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _setTheme(FlowHeroController c, bool dark) {
    c.setDark(dark);
  }
}

/// The OpenAI-compatible provider route. The fields mirror exactly the rules
/// `ProviderConfig::validate` enforces, so what saves here launches there.
class _ModelConfigSection extends StatefulWidget {
  const _ModelConfigSection({required this.controller});

  final FlowHeroController controller;

  @override
  State<_ModelConfigSection> createState() => _ModelConfigSectionState();
}

class _ModelConfigSectionState extends State<_ModelConfigSection> {
  final TextEditingController _endpoint = TextEditingController();
  final TextEditingController _model = TextEditingController();
  final TextEditingController _apiKey = TextEditingController();
  final TextEditingController _contextTokens = TextEditingController();

  FlowHeroModelProvider _provider = FlowHeroModelProvider.custom;
  FlowHeroModelAuthMode _authMode = FlowHeroModelAuthMode.bearerToken;
  bool _advanced = false;
  bool _edited = false;
  bool _saving = false;
  Map<String, String> _errors = const <String, String>{};
  String _failure = '';

  @override
  void initState() {
    super.initState();
    _seed(widget.controller.modelConfig);
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _endpoint.dispose();
    _model.dispose();
    _apiKey.dispose();
    _contextTokens.dispose();
    super.dispose();
  }

  /// The stored configuration arrives asynchronously; adopt it while the user
  /// has not typed anything of their own.
  void _onControllerChanged() {
    if (_edited || !mounted) return;
    final FlowHeroModelConfig? config = widget.controller.modelConfig;
    if (config == null || _matches(config)) return;
    setState(() => _seed(config));
  }

  bool _matches(FlowHeroModelConfig config) =>
      config.endpointBase == _endpoint.text &&
      config.model == _model.text &&
      config.authMode == _authMode &&
      config.provider == _provider &&
      '${config.contextTokens}' == _contextTokens.text;

  void _seed(FlowHeroModelConfig? config) {
    final FlowHeroModelConfig value = config ?? const FlowHeroModelConfig();
    _endpoint.text = value.endpointBase;
    // A DeepSeek route can only hold one of the official IDs: a stored model
    // outside the list falls back to the default, so the dropdown always finds
    // a matching option. A custom route keeps its freely typed name.
    _model.text = value.provider.offersModel(value.model)
        ? value.model
        : value.provider.defaultModel;
    _contextTokens.text = '${value.contextTokens}';
    _authMode = value.authMode;
    _provider = value.provider;
    _apiKey.clear();
  }

  FlowHeroModelConfig _configFromFields() {
    final FlowHeroModelConfig? current = widget.controller.modelConfig;
    return FlowHeroModelConfig(
      endpointBase: _endpoint.text.trim(),
      model: _model.text.trim(),
      contextTokens: int.tryParse(_contextTokens.text.trim()) ?? 0,
      supportsTools: current?.supportsTools ?? true,
      maxConcurrency: current?.maxConcurrency ?? 2,
      authMode: _authMode,
      provider: _provider,
    );
  }

  /// Choosing a provider fills in that route's defaults; every one of them
  /// stays editable, and [FlowHeroModelProvider.custom] fills in nothing.
  void _selectProvider(FlowHeroModelProvider provider) {
    setState(() {
      _provider = provider;
      if (provider == FlowHeroModelProvider.deepSeek) {
        _endpoint.text = kFlowHeroDeepSeekEndpointBase;
        _contextTokens.text = '$kFlowHeroDeepSeekContextTokens';
        // DeepSeek serves a fixed list, so a name typed under another provider
        // is replaced instead of left as an unselectable value.
        _model.text = provider.defaultModel;
        _authMode = FlowHeroModelAuthMode.bearerToken;
      }
      _edited = true;
      _failure = '';
      if (_errors.isNotEmpty) _errors = _currentErrors();
    });
  }

  Map<String, String> _currentErrors() {
    final String typedKey = _apiKey.text.trim();
    return _configFromFields().validateForSave(
      hasStoredApiKey: widget.controller.hasModelApiKey || typedKey.isNotEmpty,
    );
  }

  void _onEdited() {
    setState(() {
      _edited = true;
      _failure = '';
      // Re-validate live only once the user has seen the rules applied.
      if (_errors.isNotEmpty) _errors = _currentErrors();
    });
  }

  Future<void> _save() async {
    final FlowHeroModelConfig config = _configFromFields();
    final Map<String, String> errors = _currentErrors();
    setState(() {
      _errors = errors;
      _failure = '';
      _saving = true;
    });
    if (errors.isNotEmpty) {
      setState(() => _saving = false);
      return;
    }
    final String key = _apiKey.text.trim();
    final FlowHeroModelConfigSaveResult result = await widget.controller
        .saveModelConfig(config, apiKey: key.isEmpty ? null : key);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _errors = result.fieldErrors;
      _failure = result.failureMessage;
      if (result.saved) {
        _apiKey.clear();
        _edited = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool bearer = _authMode == FlowHeroModelAuthMode.bearerToken;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('供应商', style: P.silkStyle(dim: true)),
            const SizedBox(width: 10),
            Expanded(
              child: FlowHeroDropdown<FlowHeroModelProvider>(
                key: const ValueKey<String>('flow-hero-model-provider'),
                value: _provider,
                hint: '选择供应商',
                options: <FlowHeroDropdownOption<FlowHeroModelProvider>>[
                  for (final FlowHeroModelProvider provider
                      in FlowHeroModelProvider.values)
                    FlowHeroDropdownOption<FlowHeroModelProvider>(
                      value: provider,
                      label: provider.label,
                      id: provider.wireValue,
                    ),
                ],
                onChanged: _selectProvider,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _Field(
          fieldKey: const ValueKey<String>('flow-hero-model-endpoint'),
          label: '服务端点',
          controller: _endpoint,
          hint: 'https://host/v1',
          error: _errors['endpointBase'],
          onChanged: (String _) => _onEdited(),
        ),
        const SizedBox(height: 10),
        if (_provider == FlowHeroModelProvider.deepSeek)
          _ModelDropdown(
            models: _provider.modelCandidates,
            value: _model.text,
            error: _errors['model'],
            onChanged: (String model) {
              _model.text = model;
              _onEdited();
            },
          )
        else
          _Field(
            fieldKey: const ValueKey<String>('flow-hero-model-name'),
            label: '模型',
            controller: _model,
            hint: 'model-name',
            error: _errors['model'],
            onChanged: (String _) => _onEdited(),
          ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Text('鉴权', style: P.silkStyle(dim: true)),
            const SizedBox(width: 10),
            _ThemeTab(
              label: 'Bearer 密钥',
              on: bearer,
              onTap: () {
                _authMode = FlowHeroModelAuthMode.bearerToken;
                _onEdited();
              },
            ),
            const SizedBox(width: 6),
            _ThemeTab(
              label: '无需密钥',
              on: !bearer,
              onTap: () {
                _authMode = FlowHeroModelAuthMode.none;
                _onEdited();
              },
            ),
          ],
        ),
        if (bearer) ...<Widget>[
          const SizedBox(height: 10),
          _Field(
            fieldKey: const ValueKey<String>('flow-hero-model-api-key'),
            label: 'API 密钥',
            controller: _apiKey,
            hint: widget.controller.hasModelApiKey ? '已保存 · 留空保持不变' : '未设置',
            obscure: true,
            error: _errors['apiKey'],
            onChanged: (String _) => _onEdited(),
          ),
        ],
        const SizedBox(height: 10),
        InkWell(
          key: const ValueKey<String>('flow-hero-model-advanced-toggle'),
          onTap: () => setState(() => _advanced = !_advanced),
          borderRadius: BorderRadius.circular(3),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: <Widget>[
                Icon(
                  _advanced ? Icons.expand_more : Icons.chevron_right,
                  size: 14,
                  color: P.silkDim,
                ),
                const SizedBox(width: 4),
                Text('高级 · 上下文窗口', style: P.silkStyle(dim: true)),
              ],
            ),
          ),
        ),
        if (_advanced) ...<Widget>[
          const SizedBox(height: 6),
          _Field(
            fieldKey: const ValueKey<String>('flow-hero-model-context-tokens'),
            label: '上下文窗口 tokens',
            controller: _contextTokens,
            hint: '128000',
            error: _errors['contextTokens'],
            onChanged: (String _) => _onEdited(),
          ),
          const SizedBox(height: 10),
          // The two remaining bounds are not configurable: a missing bound in
          // `provider.json` means the runtime applies no cap at all.
          Text(
            '输出上限 · 无限（沿用服务商默认）',
            key: const ValueKey<String>('flow-hero-model-output-limit'),
            style: P.monoStyle(color: P.silkDim, size: 10.5),
          ),
          const SizedBox(height: 4),
          Text(
            '会话 token · 无上限',
            key: const ValueKey<String>('flow-hero-model-session-limit'),
            style: P.monoStyle(color: P.silkDim, size: 10.5),
          ),
        ],
        const SizedBox(height: 12),
        InkWell(
          key: const ValueKey<String>('flow-hero-model-save'),
          onTap: _saving ? null : _save,
          borderRadius: BorderRadius.circular(3),
          child: Container(
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: P.well,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: P.ring),
            ),
            child: Text(
              _saving ? '保存中…' : '保存并重新连接',
              style: P.silkStyle().copyWith(
                color: _saving ? P.silkDim : P.orangeBright,
              ),
            ),
          ),
        ),
        if (_failure.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text(_failure, style: P.monoStyle(color: P.red, size: 10.5)),
        ],
        const SizedBox(height: 10),
        _ModelStatusRow(controller: widget.controller),
      ],
    );
  }
}

/// The route's real state, fed by the bridge — never a claim about a link that
/// was not made.
class _ModelStatusRow extends StatelessWidget {
  const _ModelStatusRow({required this.controller});

  final FlowHeroController controller;

  @override
  Widget build(BuildContext context) {
    final AgentBridge bridge = controller.bridge;
    final bool saved = controller.modelConfigSaved;
    final (Color dot, String label) = switch (bridge.mode) {
      AgentLinkMode.live => (const Color(0xFF30D158), '已连接'),
      AgentLinkMode.connecting => (P.orange, saved ? '已保存 · 连接中…' : '连接中…'),
      AgentLinkMode.failed => (P.red, '连接失败'),
      AgentLinkMode.demo => (P.ledOff, saved ? '已保存 · 未连接' : '未配置'),
    };
    return Row(
      children: <Widget>[
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
        ),
        const SizedBox(width: 8),
        Text(label, style: P.silkStyle()),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            bridge.statusLine,
            style: P.monoStyle(color: P.silkDim, size: 10.5),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// The model field when the provider serves a fixed list: a dropdown instead
/// of free text, so the saved model is always one the route accepts. Carries
/// the same label and error presentation as [_Field].
class _ModelDropdown extends StatelessWidget {
  const _ModelDropdown({
    required this.models,
    required this.value,
    required this.onChanged,
    this.error,
  });

  final List<String> models;
  final String value;
  final ValueChanged<String> onChanged;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('模型', style: P.silkStyle(dim: true)),
        const SizedBox(height: 5),
        FlowHeroDropdown<String>(
          key: const ValueKey<String>('flow-hero-model-name'),
          value: value,
          hint: 'model-name',
          options: <FlowHeroDropdownOption<String>>[
            for (final String model in models)
              FlowHeroDropdownOption<String>(value: model, label: model),
          ],
          onChanged: onChanged,
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(error!, style: P.monoStyle(color: P.red, size: 10)),
          ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.fieldKey,
    required this.label,
    required this.controller,
    required this.onChanged,
    this.hint = '',
    this.obscure = false,
    this.error,
  });

  final Key fieldKey;
  final String label;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hint;
  final bool obscure;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: P.silkStyle(dim: true)),
        const SizedBox(height: 5),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          decoration: BoxDecoration(
            color: P.well,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: error != null ? P.red : P.ring),
          ),
          child: TextField(
            key: fieldKey,
            controller: controller,
            obscureText: obscure,
            onChanged: onChanged,
            style: P.monoStyle(color: P.paperLow, size: 11.5),
            cursorColor: P.orange,
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: hint,
              hintStyle: P.silkStyle(dim: true),
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(error!, style: P.monoStyle(color: P.red, size: 10)),
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
    this.divider = true,
  });

  final String title;
  final Widget child;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        border: divider ? Border(bottom: BorderSide(color: P.seamLo)) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: P.silkStyle(dim: true)),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _ThemeTab extends StatelessWidget {
  const _ThemeTab({required this.label, required this.on, required this.onTap});

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: on ? P.well : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: on ? P.ring : P.seamLo),
        ),
        child: Text(
          label,
          style: P.silkStyle().copyWith(color: on ? P.orangeBright : P.silk),
        ),
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.bridge});

  final AgentBridge bridge;

  @override
  Widget build(BuildContext context) {
    final (Color dot, String label) = switch (bridge.mode) {
      AgentLinkMode.live => (const Color(0xFF30D158), '已连接'),
      AgentLinkMode.connecting => (P.orange, '连接中…'),
      AgentLinkMode.failed => (P.red, '连接失败'),
      AgentLinkMode.demo => (P.ledOff, '演示模式（未连接）'),
    };
    return Row(
      children: <Widget>[
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
        ),
        const SizedBox(width: 8),
        Text(label, style: P.silkStyle()),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            bridge.statusLine,
            style: P.monoStyle(color: P.silkDim, size: 10.5),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// The language-service lamp: green only when a real `styio_lspd` session is
/// live, amber when the engine is honestly on its local heuristic, grey when
/// the route could not be built at all. Mirrors [_LinkRow].
class _LanguageRow extends StatelessWidget {
  const _LanguageRow({required this.controller});

  final FlowHeroController controller;

  @override
  Widget build(BuildContext context) {
    final String version = controller.languageProviderVersion ?? '';
    final (Color dot, String label) = switch (controller.languageMode) {
      FlowHeroLanguageMode.live => (const Color(0xFF30D158), '真实服务'),
      FlowHeroLanguageMode.degraded => (P.orange, '本地启发式降级'),
      FlowHeroLanguageMode.unavailable => (P.ledOff, '不可用'),
    };
    // The status line already carries the server version once observed.
    final String detail =
        version.isEmpty || controller.languageStatusLine.contains(version)
        ? controller.languageStatusLine
        : '${controller.languageStatusLine} · $version';
    return Row(
      children: <Widget>[
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
        ),
        const SizedBox(width: 8),
        Text(label, style: P.silkStyle()),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            detail,
            style: P.monoStyle(color: P.silkDim, size: 10.5),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// The execution route's real state, with the honest next step when a binary
/// is missing: open the install dialog and point at one.
class _ExecutionRow extends StatelessWidget {
  const _ExecutionRow({required this.controller});

  final FlowHeroController controller;

  @override
  Widget build(BuildContext context) {
    final bool live = controller.executionLive;
    final String detail = live
        ? (controller.executionSource?.statusLine ?? '就绪')
        : controller.executionUnavailableReason;
    return Row(
      children: <Widget>[
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: live ? const Color(0xFF30D158) : P.red,
          ),
        ),
        const SizedBox(width: 8),
        Text(live ? 'pafio 就绪' : '不可用', style: P.silkStyle()),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            detail,
            style: P.monoStyle(color: P.silkDim, size: 10.5),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          key: const ValueKey<String>('settings-execution-install'),
          onPressed: controller.openToolchainInstall,
          style: TextButton.styleFrom(
            minimumSize: Size.zero,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: P.orangeBright,
          ),
          child: Text(
            live ? '更换' : '安装',
            style: P.silkStyle().copyWith(color: P.orangeBright, fontSize: 10),
          ),
        ),
      ],
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow();

  @override
  Widget build(BuildContext context) {
    return Text(
      'VITYO — Flow Hero 工作台',
      style: P.monoStyle(color: P.silkDim, size: 10.5),
    );
  }
}

/// The runtime workspace root: the chosen directory once one is selected, or
/// the package-root fallback the workbench already walks. The button opens the
/// same native directory chooser the drawer header uses — one controller
/// method, two entry points.
class _WorkspaceRow extends StatelessWidget {
  const _WorkspaceRow({required this.controller});

  final FlowHeroController controller;

  @override
  Widget build(BuildContext context) {
    final bool selected = controller.workspaceRoot.isNotEmpty;
    final String path = controller.workspaceRootDisplayPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? const Color(0xFF30D158) : P.ledOff,
              ),
            ),
            const SizedBox(width: 8),
            Text(selected ? '已选择' : '未选择 · 演示 / 包根回落', style: P.silkStyle()),
          ],
        ),
        const SizedBox(height: 8),
        Tooltip(
          message: path,
          child: Text(
            path,
            key: const ValueKey<String>('settings-workspace-path'),
            style: P.monoStyle(color: P.silkDim, size: 10.5),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 10),
        InkWell(
          key: const ValueKey<String>('settings-workspace-switch'),
          onTap: () {
            controller.pickWorkspace();
          },
          borderRadius: BorderRadius.circular(3),
          child: Container(
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: P.well,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: P.ring),
            ),
            child: Text(
              '选择工作区…',
              style: P.silkStyle().copyWith(color: P.orangeBright),
            ),
          ),
        ),
      ],
    );
  }
}
