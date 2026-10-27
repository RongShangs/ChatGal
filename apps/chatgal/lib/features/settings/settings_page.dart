import 'package:flutter/material.dart';

import '../../app/app_logger.dart';
import '../../app/app_services.dart';
import '../../design_system/shell.dart';
import '../../design_system/tokens.dart';
import 'api_settings.dart';
import 'chat_font.dart';
import 'display_settings_page.dart';
import 'font_settings_page.dart';
import 'memory_settings_page.dart';
import 'model_providers_page.dart';
import 'settings_widgets.dart';
import 'voice_settings_page.dart';

/// 设置首页。
/// 供应商 → 偏好（回复长度/语音/记忆）→ 外观（含游戏画面）。
/// 「关于」整组（日志 / 隐私 / 反馈）已迁到主页的「帮助与关于」。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.theme,
    required this.services,
    this.onSettingsChanged,
  });

  final ChatGalTheme theme;
  final AppServices services;
  final VoidCallback? onSettingsChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppSettings _settings = AppSettings.empty;
  double _lengthIndex = 0;

  @override
  void initState() {
    super.initState();
    _settings = widget.services.api.load();
    _lengthIndex = switch (_settings.replyLength) {
      'medium' => 1,
      'long' => 2,
      _ => 0,
    };
    appLog.d('settings', '打开设置页');
  }

  String get _lengthId =>
      _lengthIndex == 0 ? 'short' : (_lengthIndex == 1 ? 'medium' : 'long');

  Future<void> _patch(AppSettings Function(AppSettings) transform) async {
    try {
      final updated = await widget.services.api.update(transform);
      if (!mounted) return;
      setState(() => _settings = updated);
      widget.onSettingsChanged?.call();
    } catch (e) {
      appLog.e('settings', '设置保存失败', e);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('设置保存失败：$e')),
      );
    }
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => page),
    );
    if (!mounted) return;
    setState(() => _settings = widget.services.api.load());
  }

  Future<void> _setTheme(String themeId) async {
    appLog.i('settings', '主题切到 $themeId');
    await _patch((s) => s.copyWith(themeId: themeId));
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final active = _settings.activeProvider;
    final fontLabel = chatFontLabelOf(
      fontId: _settings.chatFontId,
      imported: _settings.importedFonts,
    );

    return ChatGalShell(
      theme: t,
      title: '设置',
      body: ListView(
        padding: const EdgeInsets.all(Spacing.lg),
        children: [
          SettingsEntryTile(
            theme: t,
            icon: Icons.cloud_queue,
            title: active == null ? '未启用供应商' : active.name,
            subtitle: active == null
                ? '当前为 Mock 演示对话，点进去添加供应商'
                : '${active.model} · ${active.isLocal ? '本地' : '云端'}',
            trailingText: '管理',
            onTap: () => _open(
              ModelProvidersPage(
                theme: t,
                api: widget.services.api,
                onChanged: widget.onSettingsChanged,
              ),
            ),
          ),

          SettingsSectionTitle('偏好', theme: t),
          SettingsPanel(
            theme: t,
            padding:
                const EdgeInsets.fromLTRB(Spacing.md, Spacing.sm, Spacing.md, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '回复长度 · ${replyLengthLabel(_lengthId)}',
                  style: TextStyle(fontSize: 12.5, color: t.ink),
                ),
                Slider(
                  value: _lengthIndex,
                  min: 0,
                  max: 2,
                  divisions: 2,
                  activeColor: t.accent,
                  label: replyLengthLabel(_lengthId),
                  onChanged: (v) => setState(() => _lengthIndex = v),
                  onChangeEnd: (v) async {
                    final id =
                        v == 0 ? 'short' : (v == 1 ? 'medium' : 'long');
                    await _patch((s) => s.copyWith(replyLength: id));
                  },
                ),
                Text(
                  replyLengthHint(_lengthId),
                  style: TextStyle(fontSize: 11, color: t.sub, height: 1.4),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
          SettingsEntryTile(
            theme: t,
            icon: Icons.record_voice_over_outlined,
            title: '语音配置',
            subtitle: _settings.tts.enabled
                ? '已开启 · 音色 ${_settings.tts.voice} · 语速 '
                    '${_settings.tts.speed.toStringAsFixed(2)}x'
                : '关闭中（点进去配置云端 TTS 与语速、音色）',
            trailingText: _settings.tts.enabled ? '已开启' : '已关闭',
            onTap: () => _open(
              VoiceSettingsPage(
                theme: t,
                api: widget.services.api,
                onChanged: widget.onSettingsChanged,
              ),
            ),
          ),
          SettingsEntryTile(
            theme: t,
            icon: Icons.psychology_outlined,
            title: '五层记忆阈值',
            subtitle: 'L1 缓冲 · L2→L5 各层升层条数 · L5 上限 · 关键词上限',
            trailingText: '设置',
            onTap: () => _open(
              MemorySettingsPage(
                theme: t,
                api: widget.services.api,
                initial: _settings,
                onChanged: widget.onSettingsChanged,
              ),
            ),
          ),

          SettingsSectionTitle('外观', theme: t),
          SettingsPanel(
            theme: t,
            padding: const EdgeInsets.fromLTRB(
                Spacing.md, Spacing.md, Spacing.md, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '主题色',
                  style: TextStyle(fontSize: 12.5, color: t.ink),
                ),
                const SizedBox(height: 8),
                Row(
                  children: ChatGalTheme.all.map((th) {
                    final selected = _settings.themeId == th.id;
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Material(
                          color: selected
                              ? th.accent.withValues(alpha: 0.16)
                              : t.bg,
                          borderRadius: BorderRadius.circular(20),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(20),
                            onTap: () => _setTheme(th.id),
                            child: Container(
                              height: 54,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: selected
                                      ? t.accent
                                      : t.sub.withValues(alpha: 0.14),
                                ),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: th.accent,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: selected
                                            ? t.ink
                                            : t.sub.withValues(alpha: 0.3),
                                        width: selected ? 2 : 1,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    th.name.split('·').last,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: selected ? t.ink : t.sub,
                                      fontWeight: selected
                                          ? FontWeight.w700
                                          : null,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
          SettingsEntryTile(
            theme: t,
            icon: Icons.text_fields,
            title: '字体与字号',
            subtitle: '只对聊天对话生效，可导入自己的字体文件',
            trailingText: '$fontLabel · ${_settings.chatFontSize.round()}px',
            onTap: () => _open(
              FontSettingsPage(
                theme: t,
                api: widget.services.api,
                onChanged: widget.onSettingsChanged,
              ),
            ),
          ),
          SettingsEntryTile(
            theme: t,
            icon: Icons.photo_size_select_large,
            title: '游戏画面设置',
            subtitle: '场景背景开关 · 立绘高度 · 消息流留白 · 自动抠图'
                '（页内可实时预览）',
            trailingText: '立绘 ${_settings.portraitHeight.round()}px',
            onTap: () => _open(
              DisplaySettingsPage(
                theme: t,
                api: widget.services.api,
                services: widget.services,
                onChanged: widget.onSettingsChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
