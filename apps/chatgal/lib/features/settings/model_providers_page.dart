import 'package:flutter/material.dart';

import '../../design_system/shell.dart';
import '../../design_system/tokens.dart';
import '../../app/app_logger.dart';
import 'api_settings.dart';
import 'local_model_page.dart';
import 'provider_editor_page.dart';
import 'settings_widgets.dart';

/// 模型供应商（对话用）单独一页。
///
/// 原来是塞在设置首页里的一大段（列表 + 增删改），现在设置首页只留一个入口，
/// 点进来才是管理；主页那颗供应商胶囊也直连这一页。
class ModelProvidersPage extends StatefulWidget {
  const ModelProvidersPage({
    super.key,
    required this.theme,
    required this.api,
    this.onChanged,
  });

  final ChatGalTheme theme;
  final ApiSettingsStore api;
  final VoidCallback? onChanged;

  @override
  State<ModelProvidersPage> createState() => _ModelProvidersPageState();
}

class _ModelProvidersPageState extends State<ModelProvidersPage> {
  AppSettings _settings = AppSettings.empty;

  @override
  void initState() {
    super.initState();
    _settings = widget.api.load();
  }

  Future<void> _persist(AppSettings next) async {
    setState(() => _settings = next);
    await widget.api.update(
      (s) => s.copyWith(
        providers: next.providers,
        activeProviderId: next.activeProviderId,
        clearActiveProvider: next.activeProviderId == null,
      ),
    );
    widget.onChanged?.call();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _toggleProvider(ProviderPreset p, bool? enabled) async {
    if (enabled == null) return;
    final list = _settings.providers
        .map((x) => x.id == p.id ? x.copyWith(enabled: enabled) : x)
        .toList();
    final wasActive = _settings.activeProviderId == p.id;
    appLog.i('provider', '${enabled ? '启用' : '停用'}供应商「${p.name}」');
    await _persist(
      _settings.copyWith(
        providers: list,
        activeProviderId: enabled ? p.id : null,
        // 停用的正是当前启用的那家 → 必须真的把 activeProviderId 清掉，
        // 否则「启用中」标着、实际又不是它。
        clearActiveProvider: !enabled && wasActive,
      ),
    );
  }

  Future<void> _removeProvider(String id) async {
    final removed = _settings.providers.where((x) => x.id == id).toList();
    final list = _settings.providers.where((x) => x.id != id).toList();
    final wasActive = _settings.activeProviderId == id;
    if (removed.isNotEmpty) {
      appLog.i('provider', '删除供应商「${removed.first.name}」');
    }
    await _persist(
      _settings.copyWith(providers: list, clearActiveProvider: wasActive),
    );
  }

  Future<void> _openEditor({ProviderPreset? existing}) async {
    final result = await Navigator.of(context).push<ProviderPreset>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ProviderEditorPage(
          theme: widget.theme,
          api: widget.api,
          existing: existing,
        ),
      ),
    );
    if (result == null) return;

    if (existing == null) {
      final list = [..._settings.providers, result];
      await _persist(
        _settings.copyWith(providers: list, activeProviderId: result.id),
      );
      appLog.i(
        'provider',
        '新增供应商「${result.name}」${result.isLocal ? '（本地）' : ''}',
      );
      _toast('已保存供应商「${result.name}」');
    } else {
      final list = _settings.providers
          .map((x) => x.id == result.id ? result : x)
          .toList();
      await _persist(_settings.copyWith(providers: list));
      appLog.i('provider', '更新供应商「${result.name}」');
      _toast('已更新「${result.name}」');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final active = _settings.activeProvider;
    return ChatGalShell(
      theme: t,
      title: '模型供应商',
      body: ListView(
        padding: const EdgeInsets.all(Spacing.lg),
        children: [
          SettingsSectionTitle('当前启用', theme: t),
          SettingsPanel(
            theme: t,
            padding: const EdgeInsets.all(Spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  active == null
                      ? '未启用：对话使用 Mock 演示'
                      : '${active.name} · ${active.model}',
                  style: TextStyle(color: t.ink, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  active == null
                      ? '没有启用的供应商时，游戏不会真的请求模型，只用固定回复演示流程。'
                      : active.endpoint,
                  style: TextStyle(fontSize: 11.5, color: t.sub, height: 1.4),
                ),
                if (active != null && active.isLocal) ...[
                  const SizedBox(height: 6),
                  Text(
                    '本地/局域网地址：请确认设备能访问到它（同 Wi-Fi 用局域网 IP，'
                    '或 adb reverse 映射 127.0.0.1）。',
                    style: TextStyle(fontSize: 11, color: t.sub, height: 1.4),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: Spacing.md),
          SettingsPanel(
            theme: t,
            child: SwitchListTile(
              value: _settings.streamOutput,
              activeThumbColor: t.accent,
              title: Text(
                '流式输出',
                style: TextStyle(color: t.ink, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '打开：回复边生成边显示（真实流式打字）。\n'
                '关闭：等整段写完后再按打字机速度播一遍。',
                style: TextStyle(fontSize: 12, color: t.sub, height: 1.4),
              ),
              onChanged: (v) async {
                appLog.i('provider', '流式输出 → $v');
                await widget.api.update((s) => s.copyWith(streamOutput: v));
                if (!mounted) return;
                setState(() => _settings = widget.api.load());
                widget.onChanged?.call();
              },
            ),
          ),
          const SizedBox(height: Spacing.md),
          SettingsSectionTitle('供应商列表', theme: t),
          if (_settings.providers.isEmpty)
            SettingsPanel(
              theme: t,
              padding: const EdgeInsets.all(Spacing.md),
              child: Text(
                '还没有供应商预设，点下方「新增供应商」。',
                style: TextStyle(color: t.sub),
              ),
            ),
          ..._settings.providers.map((p) {
            final isActive =
                _settings.activeProviderId == p.id ||
                (p.enabled && _settings.activeProviderId == null);
            return SettingsPanel(
              theme: t,
              child: Column(
                children: [
                  CheckboxListTile(
                    value: isActive,
                    activeColor: t.accent,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            p.name,
                            style: TextStyle(color: t.ink),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (p.isLocal) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: t.accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '本地',
                              style: TextStyle(fontSize: 10, color: t.accent),
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      '${p.endpoint}\n模型：${p.model}',
                      style: TextStyle(fontSize: 12, color: t.sub),
                    ),
                    isThreeLine: true,
                    onChanged: (v) => _toggleProvider(p, v),
                  ),
                  if (isActive)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '启用中',
                          style: TextStyle(fontSize: 11, color: t.accent),
                        ),
                      ),
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        onPressed: () => _openEditor(existing: p),
                        icon: Icon(
                          Icons.edit_outlined,
                          size: 16,
                          color: t.accent,
                        ),
                        label: Text(
                          '编辑',
                          style: TextStyle(color: t.accent, fontSize: 13),
                        ),
                      ),
                      TextButton(
                        onPressed: () => _removeProvider(p.id),
                        child: Text(
                          '删除',
                          style: TextStyle(color: t.sub, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: Spacing.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: t.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add),
              label: const Text('新增供应商'),
            ),
          ),
          const SizedBox(height: Spacing.lg),
          SettingsSectionTitle('本地模型', theme: t),
          SettingsEntryTile(
            theme: t,
            icon: Icons.memory,
            title: '本地模型',
            subtitle: '想在手机上离线跑，需要另外装一个应用 —— 点进去看步骤',
            trailingText: '查看',
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => LocalModelPage(
                  theme: t,
                  api: widget.api,
                  onChanged: widget.onChanged,
                ),
              ),
            ),
          ),
          SettingsNote(
            'OpenAI 兼容：GET /models、POST /chat/completions。'
            '对话上下文会发送给已启用的供应商；密钥为本地明文存储。',
            theme: t,
          ),
        ],
      ),
    );
  }
}
