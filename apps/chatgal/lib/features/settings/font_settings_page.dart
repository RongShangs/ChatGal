import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/app_logger.dart';
import '../../app/font_registry.dart';
import '../../design_system/shell.dart';
import '../../design_system/tokens.dart';
import 'api_settings.dart';
import 'chat_font.dart';
import 'settings_widgets.dart';

/// 字体设置：**只对聊天对话生效**。
///
/// 预设字体不内嵌文件（用系统通用族名），所以 APK 不会变大；
/// 想让角色用某款特定字体，就自己导入 ttf/otf，文件复制到应用数据目录，
/// 由 `FontRegistry` 注册后按族名引用。界面上方的预览卡就是聊天气泡的缩小版，
/// 改字体/字号立刻能看到结果。
class FontSettingsPage extends StatefulWidget {
  const FontSettingsPage({
    super.key,
    required this.theme,
    required this.api,
    this.onChanged,
  });

  final ChatGalTheme theme;
  final ApiSettingsStore api;
  final VoidCallback? onChanged;

  @override
  State<FontSettingsPage> createState() => _FontSettingsPageState();
}

class _FontSettingsPageState extends State<FontSettingsPage> {
  AppSettings _settings = AppSettings.empty;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _settings = widget.api.load();
  }

  Future<void> _persist(AppSettings next) async {
    setState(() => _settings = next);
    await widget.api.update(
      (s) => s.copyWith(
        chatFontId: next.chatFontId,
        chatFontSize: next.chatFontSize,
        importedFonts: next.importedFonts,
      ),
    );
    widget.onChanged?.call();
  }

  Future<void> _importFont() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      // 与创作台导入包用同一套写法：custom + allowedExtensions。
      // 认不出的扩展名在 Android 侧会落到 `*/*`，不会把字体文件藏起来。
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['ttf', 'otf', 'ttc'],
      );
      if (picked.isEmpty) return;
      final path = picked.first.path;
      if (!mounted) return;
      if (path == null) {
        _toast('无法读取所选字体路径');
        return;
      }
      final ext = path.toLowerCase();
      if (!ApiSettingsStore.fontExtensions.any(ext.endsWith)) {
        _toast('只支持 ${ApiSettingsStore.fontExtensions.join(' / ')} 字体文件');
        return;
      }
      final font = await widget.api.importFontFile(path);
      final next = _settings.copyWith(
        importedFonts: [..._settings.importedFonts, font],
        chatFontId: font.id,
      );
      await _persist(next);
      // 新导入的字体必须当场注册，否则选它也不会立刻生效。
      await FontRegistry.ensure(next);
      appLog.i('font', '导入字体「${font.label}」（${font.sizeBytes} 字节）');
      if (!mounted) return;
      setState(() {});
      _toast('已导入并启用「${font.label}」');
    } catch (e) {
      appLog.e('font', '导入字体失败', e);
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _deleteFont(ImportedChatFont font) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: widget.theme.card,
        title: Text(
          '删除字体「${font.label}」？',
          style: TextStyle(color: widget.theme.ink),
        ),
        content: Text(
          '会删掉应用数据目录里的那个字体文件。正在用它的话，聊天字体回到系统默认。',
          style: TextStyle(color: widget.theme.sub, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: widget.theme.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.api.deleteFontFile(font);
    FontRegistry.forget(font.id);
    final rest = _settings.importedFonts.where((f) => f.id != font.id).toList();
    final next = _settings.copyWith(
      importedFonts: rest,
      chatFontId: _settings.chatFontId == font.id
          ? kSystemFontId
          : _settings.chatFontId,
    );
    appLog.i('font', '删除导入字体「${font.label}」');
    await _persist(next);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final family = chatFontFamilyOf(
      fontId: _settings.chatFontId,
      imported: _settings.importedFonts,
    );
    final size = _settings.chatFontSize;

    return ChatGalShell(
      theme: t,
      title: '字体与字号',
      body: ListView(
        padding: const EdgeInsets.all(Spacing.lg),
        children: [
          SettingsNote('下面这些只影响聊天对话，界面本身的字体不变。', theme: t),
          _preview(t, family, size),
          // 层级：先「多大」（字号），再「哪一种」（字体），最后才是导入的。
          SettingsSectionTitle('字号', theme: t),
          SettingsPanel(
            theme: t,
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.md,
              Spacing.md,
              8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '聊天文字 · ${size.round()}px',
                  style: TextStyle(fontSize: 12.5, color: t.ink),
                ),
                Slider(
                  value: size.clamp(kChatFontSizeMin, kChatFontSizeMax),
                  min: kChatFontSizeMin,
                  max: kChatFontSizeMax,
                  divisions: (kChatFontSizeMax - kChatFontSizeMin).round(),
                  activeColor: t.accent,
                  label: '${size.round()}px',
                  onChanged: (v) => setState(
                    () => _settings = _settings.copyWith(chatFontSize: v),
                  ),
                  onChangeEnd: (v) =>
                      _persist(_settings.copyWith(chatFontSize: v)),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${kChatFontSizeMin.round()}px',
                      style: TextStyle(fontSize: 10.5, color: t.sub),
                    ),
                    TextButton(
                      onPressed: () => _persist(
                        _settings.copyWith(
                          chatFontSize: kChatFontSizeDefault,
                          chatFontId: kSystemFontId,
                        ),
                      ),
                      child: Text(
                        '恢复默认',
                        style: TextStyle(fontSize: 12, color: t.accent),
                      ),
                    ),
                    Text(
                      '${kChatFontSizeMax.round()}px',
                      style: TextStyle(fontSize: 10.5, color: t.sub),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: Spacing.sm),
          SettingsSectionTitle('预设字体', theme: t),
          ...kChatFontPresets.map((p) {
            final selected = _settings.chatFontId == p.id;
            return SettingsPanel(
              theme: t,
              child: InkWell(
                onTap: () => _persist(_settings.copyWith(chatFontId: p.id)),
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.md),
                  child: Row(
                    children: [
                      Icon(
                        selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 18,
                        color: selected ? t.accent : t.sub,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.label,
                              style: TextStyle(
                                fontFamily: p.family,
                                fontSize: 14,
                                color: t.ink,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              p.note,
                              style: TextStyle(fontSize: 11.5, color: t.sub),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: Spacing.sm),
          SettingsSectionTitle('我导入的字体', theme: t),
          if (_settings.importedFonts.isEmpty)
            SettingsPanel(
              theme: t,
              padding: const EdgeInsets.all(Spacing.md),
              child: Text(
                '还没有导入字体。点下面按钮选一个 .ttf / .otf / .ttc 文件，'
                '导入后会立刻注册并切过去。',
                style: TextStyle(fontSize: 12, height: 1.5, color: t.sub),
              ),
            ),
          ..._settings.importedFonts.map((f) {
            final selected = _settings.chatFontId == f.id;
            return SettingsPanel(
              theme: t,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 2,
                ),
                leading: Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: selected ? t.accent : t.sub,
                ),
                title: Text(
                  f.label,
                  style: TextStyle(
                    fontFamily: f.family,
                    fontSize: 14,
                    color: t.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  '${(f.sizeBytes / 1024).round()} KB · ${f.path.split(Platform.pathSeparator).last}',
                  style: TextStyle(fontSize: 11, color: t.sub),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: '删除',
                  icon: Icon(Icons.delete_outline, size: 18, color: t.sub),
                  onPressed: () => _deleteFont(f),
                ),
                onTap: () => _persist(_settings.copyWith(chatFontId: f.id)),
              ),
            );
          }),
          const SizedBox(height: Spacing.xs),
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
              onPressed: _importing ? null : _importFont,
              icon: _importing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.upload_file, size: 18),
              label: const Text('导入字体文件'),
            ),
          ),
          const SizedBox(height: Spacing.md),
          SettingsNote(
            '导入的字体文件复制在应用数据目录（fonts/）里，卸载应用会一起清掉。'
            '字体本身不含中文时，中文会回落到系统字体，这是正常的。',
            theme: t,
            pad: false,
          ),
        ],
      ),
    );
  }

  /// 预览卡：两个假气泡，字体的真实渲染效果。
  Widget _preview(ChatGalTheme t, String? family, double size) {
    Widget bubble(String text, bool isUser) => Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: isUser ? t.userBubble : t.jjBubble,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontFamily: family,
            fontSize: size,
            height: 1.45,
            color: isUser ? Colors.white : t.ink,
          ),
        ),
      ),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.md),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: t.sub.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.visibility_outlined, size: 14, color: t.sub),
              const SizedBox(width: 5),
              Text('预览', style: TextStyle(fontSize: 11, color: t.sub)),
            ],
          ),
          const SizedBox(height: 10),
          bubble('今天……你回来得好早。', false),
          bubble('路上没堵车。你吃饭了吗？', true),
        ],
      ),
    );
  }
}
