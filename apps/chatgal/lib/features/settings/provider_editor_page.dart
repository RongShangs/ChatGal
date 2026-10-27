import 'package:flutter/material.dart';

import '../../design_system/shell.dart';
import '../../design_system/tokens.dart';
import 'api_settings.dart';

/// Full-page form for adding or editing a provider preset.
/// Pops with [ProviderPreset] on save (bottom button).
class ProviderEditorPage extends StatefulWidget {
  const ProviderEditorPage({
    super.key,
    required this.theme,
    required this.api,
    this.existing,
  });

  final ChatGalTheme theme;
  final ApiSettingsStore api;

  /// Non-null = edit mode (keeps original id).
  final ProviderPreset? existing;

  @override
  State<ProviderEditorPage> createState() => _ProviderEditorPageState();
}

class _ProviderEditorPageState extends State<ProviderEditorPage> {
  late final TextEditingController _endpoint;
  late final TextEditingController _key;
  late final TextEditingController _model;
  late final TextEditingController _name;
  bool _obscureKey = true;
  bool _loadingModels = false;
  List<String> _models = [];
  String? _selectedModel;
  String? _error;

  static const _presets = <_QuickProvider>[
    _QuickProvider('DeepSeek', 'https://api.deepseek.com/v1'),
    _QuickProvider('OpenAI', 'https://api.openai.com/v1'),
    _QuickProvider('Moonshot', 'https://api.moonshot.cn/v1'),
    _QuickProvider('阿里云百炼', 'https://dashscope.aliyuncs.com/compatible-mode/v1'),
    _QuickProvider('SiliconFlow', 'https://api.siliconflow.cn/v1'),
    _QuickProvider('Groq', 'https://api.groq.com/openai/v1'),
    _QuickProvider(
      '本地模型 · llama.cpp',
      'http://127.0.0.1:8080/v1',
      local: true,
      model: 'spark2.5-1.7b',
    ),
    _QuickProvider(
      '本地模型 · Ollama',
      'http://127.0.0.1:11434/v1',
      local: true,
      model: 'spark2.5:4b',
    ),
    _QuickProvider(
      '局域网电脑',
      'http://192.168.1.10:8080/v1',
      local: true,
      model: 'spark2.5-4b',
    ),
  ];

  bool get _isEdit => widget.existing != null;

  /// 本地服务（llama.cpp / Ollama / LM Studio）不校验 Key，也不要求公网地址。
  bool _looksLocal(String endpoint) {
    final e = endpoint.toLowerCase();
    return e.contains('127.0.0.1') ||
        e.contains('localhost') ||
        e.contains('0.0.0.0') ||
        e.contains('192.168.') ||
        e.contains('10.0.') ||
        e.contains('172.16.') ||
        e.contains('172.17.') ||
        e.contains('172.18.');
  }

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _endpoint = TextEditingController(text: e?.endpoint ?? '');
    _key = TextEditingController(text: e?.apiKey ?? '');
    _model = TextEditingController(text: e?.model ?? '');
    _selectedModel = e?.model.isEmpty == false ? e!.model : null;
    // API Key 的提示文案要看 Base URL 是不是本地地址，所以要跟着重绘。
    _endpoint.addListener(_onEndpointChanged);
  }

  void _onEndpointChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _endpoint.removeListener(_onEndpointChanged);
    _endpoint.dispose();
    _key.dispose();
    _model.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _fetchModels() async {
    setState(() {
      _loadingModels = true;
      _error = null;
    });
    try {
      final list = await widget.api.fetchModels(
        endpoint: _endpoint.text.trim(),
        apiKey: _key.text.trim(),
      );
      // 这是全屏路由、超时最长 20s，玩家完全来得及先返回：必须挡住迟到的 setState。
      if (!mounted) return;
      setState(() {
        _models = list;
        _loadingModels = false;
        if (list.isEmpty) _error = '接口返回空模型列表';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingModels = false;
        _error = '获取模型列表失败：$e';
      });
    }
  }

  void _applyPreset(_QuickProvider p) {
    setState(() {
      _endpoint.text = p.url;
      if (!_isEdit && _name.text.trim().isEmpty) _name.text = p.name;
      if (_model.text.trim().isEmpty && p.model.isNotEmpty) {
        _model.text = p.model;
        _selectedModel = p.model;
      }
      _error = null;
    });
  }

  void _save() {
    final note = _name.text.trim();
    final endpoint = _endpoint.text.trim();
    final key = _key.text.trim();
    final model = _model.text.trim();
    final local = _looksLocal(endpoint);
    if (note.isEmpty) {
      setState(() => _error = '请填写供应商备注（列表标题）');
      return;
    }
    if (!endpoint.startsWith('http')) {
      setState(() => _error = '请输入合法的 Base URL');
      return;
    }
    // 本地推理服务一般不校验 Key，强制填会让人没法保存。
    if (key.isEmpty && !local) {
      setState(() => _error = '请输入 API Key（本地服务可以留空）');
      return;
    }
    if (model.isEmpty) {
      setState(() => _error = '请选择或填写模型');
      return;
    }
    Navigator.of(context).pop(
      ProviderPreset(
        id: _isEdit ? widget.existing!.id : ApiSettingsStore.newId(),
        name: note,
        endpoint: endpoint,
        apiKey: key,
        model: model,
        enabled: _isEdit ? widget.existing!.enabled : true,
        isLocal: local,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    return ChatGalShell(
      theme: t,
      title: _isEdit ? '编辑供应商' : '新增供应商',
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(Spacing.lg),
              children: [
                TextField(
                  controller: _name,
                  decoration: InputDecoration(
                    labelText: '备注 / 列表标题',
                    hintText: '例如：我的 DeepSeek、公司号',
                    helperText: '会作为供应商列表里的标题显示',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  '常见服务商（点击填入 URL）',
                  style: TextStyle(fontSize: 12, color: t.sub),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _presets.map((p) {
                    final selected = _endpoint.text.trim() == p.url;
                    return ActionChip(
                      label: Text(
                        p.name,
                        style: TextStyle(
                          fontSize: 12,
                          color: selected ? Colors.white : t.ink,
                        ),
                      ),
                      backgroundColor: selected
                          ? t.accent
                          : t.accent.withValues(alpha: 0.12),
                      side: BorderSide(
                        color: selected
                            ? t.accent
                            : t.accent.withValues(alpha: 0.3),
                      ),
                      onPressed: () => _applyPreset(p),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _endpoint,
                  decoration: InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://api.deepseek.com/v1',
                    helperText: '多数 OpenAI 兼容服务需带 /v1；点上方预设可自动填入',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _key,
                  obscureText: _obscureKey,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    helperText: _looksLocal(_endpoint.text)
                        ? '本地服务一般不校验 Key，可以留空'
                        : null,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureKey ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () =>
                          setState(() => _obscureKey = !_obscureKey),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _model,
                        decoration: InputDecoration(
                          labelText: '模型 ID',
                          hintText: _models.isEmpty
                              ? 'deepseek-chat'
                              : '可从下方选择',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: '获取模型列表',
                      onPressed: _loadingModels ? null : _fetchModels,
                      icon: _loadingModels
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_download, size: 20),
                    ),
                  ],
                ),
                if (_loadingModels) ...[
                  const SizedBox(height: 8),
                  Text(
                    '正在获取模型列表…',
                    style: TextStyle(fontSize: 12, color: t.sub),
                  ),
                ],
                if (_models.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '从列表选择模型：',
                    style: TextStyle(fontSize: 12, color: t.sub),
                  ),
                  const SizedBox(height: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _models.length,
                      itemBuilder: (_, i) {
                        final m = _models[i];
                        final sel = _selectedModel == m || _model.text == m;
                        return ListTile(
                          dense: true,
                          title: Text(m, style: const TextStyle(fontSize: 13)),
                          trailing: sel
                              ? Icon(Icons.check_circle,
                                  size: 18, color: t.accent)
                              : Icon(Icons.circle_outlined,
                                  size: 18, color: t.sub),
                          onTap: () => setState(() {
                            _selectedModel = m;
                            _model.text = m;
                          }),
                        );
                      },
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 24),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(color: t.sub.withValues(alpha: 0.4)),
                      ),
                      child: Text('取消', style: TextStyle(color: t.sub)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: t.accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _save,
                      child: Text(_isEdit ? '保存修改' : '保存供应商'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickProvider {
  const _QuickProvider(this.name, this.url, {this.local = false, this.model = ''});

  final String name;
  final String url;

  /// 本地/局域网地址：不强制填 API Key。
  final bool local;

  /// 点这个预设时顺手填上的模型 ID（本地模型的名字每家人不同，省一步输入）。
  final String model;
}
