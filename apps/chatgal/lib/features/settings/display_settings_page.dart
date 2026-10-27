import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../app/app_logger.dart';
import '../../design_system/shell.dart';
import '../../design_system/tokens.dart';
import '../session/chat_layout.dart';
import '../session/portrait_bg_remover.dart';
import 'api_settings.dart';
import 'settings_widgets.dart';

/// 游戏画面设置，顶部带**实时预览**。
///
/// 预览与游戏页共用 [ChatLayout] 的公式（这是上一版预览与实际不符的根因：
/// 预览按「立绘高度 + 留白」摆气泡，游戏页底部其实还有一整块输入栏没算）。
/// 缩放比例同时受宽度与高度约束，画出来的是**真机下半屏的等比切片**；
/// 背景与立绘直接取当前默认包里的真实素材。
class DisplaySettingsPage extends StatefulWidget {
  const DisplaySettingsPage({
    super.key,
    required this.theme,
    required this.api,
    required this.services,
    this.onChanged,
  });

  final ChatGalTheme theme;
  final ApiSettingsStore api;
  final AppServices services;
  final VoidCallback? onChanged;

  @override
  State<DisplaySettingsPage> createState() => _DisplaySettingsPageState();
}

class _DisplaySettingsPageState extends State<DisplaySettingsPage> {
  AppSettings _settings = AppSettings.empty;
  String? _bgPath;
  String? _portraitPath;

  @override
  void initState() {
    super.initState();
    _settings = widget.api.load();
    _loadPreviewAssets();
  }

  void _loadPreviewAssets() {
    try {
      final ref = widget.services.defaultPackageRef();
      if (ref == null) return;
      final session = widget.services.loadPlaySession(ref);
      if (session == null) return;
      _bgPath = session.homeAsset();
      // 不传 state/requested：拿角色默认形态 × 默认情绪的立绘。
      _portraitPath = session.portraitPath();
    } catch (e) {
      appLog.w('display', '预览素材加载失败：$e');
    }
  }

  Future<void> _persist(AppSettings next) async {
    setState(() => _settings = next);
    await widget.api.update(
      (s) => s.copyWith(
        showBg: next.showBg,
        portraitHeight: next.portraitHeight,
        chatBottomPad: next.chatBottomPad,
        chatBottomPadTouched: next.chatBottomPadTouched,
        autoRemoveBg: next.autoRemoveBg,
      ),
    );
    widget.onChanged?.call();
  }

  /// 带符号显示（0 不显示成 +0）。
  static String _signed(double v) {
    final n = v.round();
    return n > 0 ? '+$n' : '$n';
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final s = _settings;

    return ChatGalShell(
      theme: t,
      title: '游戏画面',
      body: ListView(
        padding: const EdgeInsets.all(Spacing.lg),
        children: [
          _preview(t, s),
          SettingsNote(
            '预览按屏幕宽度等比缩放，只画下半屏（立绘与留白都在这一段）。'
            '素材来自当前默认包；改完在**下次进入游戏**时生效。',
            theme: t,
          ),
          SettingsSectionTitle('背景', theme: t),
          SettingsPanel(
            theme: t,
            child: SwitchListTile(
              value: s.showBg,
              activeThumbColor: t.accent,
              title: Text('显示场景背景', style: TextStyle(color: t.ink)),
              subtitle: Text(
                '关闭后游戏页使用纯色主题背景',
                style: TextStyle(fontSize: 11.5, color: t.sub),
              ),
              onChanged: (v) => _persist(s.copyWith(showBg: v)),
            ),
          ),
          SettingsSectionTitle('立绘', theme: t),
          SettingsPanel(
            theme: t,
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.md,
              Spacing.md,
              6,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '立绘高度 · ${s.portraitHeight.round()}px',
                        style: TextStyle(fontSize: 12.5, color: t.ink),
                      ),
                    ),
                    Text(
                      '直接控制立绘区高度',
                      style: TextStyle(fontSize: 10.5, color: t.sub),
                    ),
                  ],
                ),
                Slider(
                  value: ChatLayout.portrait(s.portraitHeight),
                  min: 140,
                  max: 420,
                  divisions: 28,
                  activeColor: t.accent,
                  label: s.portraitHeight.round().toString(),
                  onChanged: (v) => setState(
                    () => _settings = _settings.copyWith(portraitHeight: v),
                  ),
                  onChangeEnd: (v) =>
                      _persist(_settings.copyWith(portraitHeight: v)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '自动抠图（去掉立绘纯色背景）',
                    style: TextStyle(fontSize: 12.5, color: t.ink),
                  ),
                  subtitle: Text(
                    '四角取色后把同色像素置透明；需要时再开，首次切换有一次性处理开销',
                    style: TextStyle(fontSize: 10.5, color: t.sub, height: 1.4),
                  ),
                  value: s.autoRemoveBg,
                  activeThumbColor: t.accent,
                  onChanged: (v) async {
                    // 开关翻面要让缓存失效，否则预览与游戏页还会拿到旧结果。
                    portraitBgRemover.clearCache();
                    appLog.i('display', '自动抠图${v ? '开启' : '关闭'}');
                    await _persist(s.copyWith(autoRemoveBg: v));
                  },
                ),
                const SizedBox(height: 6),
              ],
            ),
          ),
          SettingsSectionTitle('消息流', theme: t),
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
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '消息流留白调整 · ${_signed(s.chatBottomPad)}px',
                        style: TextStyle(fontSize: 12.5, color: t.ink),
                      ),
                    ),
                    Text(
                      '正数往上推，负数靠近立绘',
                      style: TextStyle(fontSize: 10.5, color: t.sub),
                    ),
                  ],
                ),
                Slider(
                  value: ChatLayout.pad(s.chatBottomPad),
                  min: ChatLayout.padMin,
                  max: ChatLayout.padMax,
                  divisions: (ChatLayout.padMax - ChatLayout.padMin) ~/ 5,
                  activeColor: t.accent,
                  label: _signed(s.chatBottomPad),
                  onChanged: (v) => setState(
                    () => _settings = _settings.copyWith(chatBottomPad: v),
                  ),
                  onChangeEnd: (v) => _persist(
                    _settings.copyWith(
                      chatBottomPad: v,
                      // 手动拖过就记下来：以后再改默认值也不会覆盖你的选择。
                      chatBottomPadTouched: true,
                    ),
                  ),
                ),
                Text(
                  '底部留白 = 立绘 + 输入栏 + 本值：默认 0 就是「消息贴在立绘上方」。'
                  '想让它更松就往正拖，想让它压下来甚至盖住立绘就往负拖。',
                  style: TextStyle(fontSize: 10.5, height: 1.45, color: t.sub),
                ),
                const SizedBox(height: 6),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 预览窗口：背景 + 两条气泡 + 立绘，全部按屏幕宽度等比缩放。
  /// 预览窗：**按游戏页的真实结构自下而上画** ——
  /// 输入栏 → 立绘 → 消息流（底部留白 = 底部整块 + 留白调整）。
  ///
  /// 上一版只按宽度缩放、不画输入栏，于是「消息流留白」看着和游戏里不一样；
  /// 现在输入栏高度优先取**游戏页实测值**（[ChatLayout.measuredInputBarHeight]，
  /// 进过一次游戏就有），没进过游戏时退回一个示意高度。
  Widget _preview(ChatGalTheme t, AppSettings s) {
    const double windowHeight = 300;
    const double phoneWidth = 390;
    // 两条气泡 + 一点余量：让窗口至少能装下「最后一条气泡 → 屏幕底」这一段。
    const double bubbleRoom = 150;

    return ValueListenableBuilder<double>(
      valueListenable: ChatLayout.measuredInputBarHeight,
      builder: (context, measuredInputBar, _) {
        final portraitL = ChatLayout.portrait(s.portraitHeight);
        final padL = ChatLayout.pad(s.chatBottomPad);
        final inputBarL = measuredInputBar > 0
            ? measuredInputBar
            : kSchematicInputBarHeight;
        final bubblesBottomL = ChatLayout.messageBottomInset(
          portraitHeight: s.portraitHeight,
          chatBottomPad: s.chatBottomPad,
          bottomBlockHeight: portraitL + inputBarL,
        );
        final regionL = bubblesBottomL + bubbleRoom;

        return LayoutBuilder(
          builder: (context, c) {
            final maxW = c.maxWidth.isFinite ? c.maxWidth : 340.0;
            // 既要装下横向的 390，也要装下纵向的这一段：取更小的那个比例。
            final k = math.min(maxW / phoneWidth, windowHeight / regionL);
            final sliceW = phoneWidth * k;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: sliceW,
                    height: windowHeight,
                    decoration: BoxDecoration(
                      color: t.bg,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: t.sub.withValues(alpha: 0.22)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (s.showBg && _bgPath != null)
                          Image.file(
                            File(_bgPath!),
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) =>
                                ColoredBox(color: t.accent),
                          )
                        else
                          ColoredBox(color: s.showBg ? t.accent : t.bg),
                        // 消息流：底部留白 = 底部整块（立绘 + 输入栏）+ 留白调整。
                        Positioned(
                          left: 6 * k,
                          right: 6 * k,
                          bottom: bubblesBottomL * k,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _previewBubble(t, k, '今天……你回来得好早。', false),
                              Align(
                                alignment: Alignment.centerRight,
                                child: _previewBubble(t, k, '路上没堵车。', true),
                              ),
                            ],
                          ),
                        ),
                        // 立绘：贴在输入栏上方（游戏页就是「立绘 + 输入栏」一整块）。
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: inputBarL * k,
                          height: portraitL * k,
                          child: _portrait(t, s.autoRemoveBg),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: inputBarL * k,
                          child: _previewInputBar(t, k),
                        ),
                        Positioned(
                          top: 6,
                          left: 6,
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6 * k,
                              vertical: 2 * k,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '实时预览',
                              style: TextStyle(
                                fontSize: (10 * k).clamp(7.0, 10.0),
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '整块底部 ${(portraitL + inputBarL).round()}px'
                  '（立绘 ${portraitL.round()} + 输入栏 ${inputBarL.round()}）'
                  ' · 留白调整 ${_signed(padL)}px'
                  ' · 消息底距屏幕底 ${(bubblesBottomL).round()}px'
                  '${measuredInputBar > 0 ? ' · 输入栏为实测值' : ' · 输入栏为示意高度'}',
                  style: TextStyle(fontSize: 10.5, color: t.sub),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 示意输入栏（还没进过游戏、拿不到实测高度时用；约等于输入框 + 两行快捷回复）。
  static const double kSchematicInputBarHeight = 128;

  Widget _previewInputBar(ChatGalTheme t, double k) {
    return Container(
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(12 * k)),
      ),
      padding: EdgeInsets.fromLTRB(6 * k, 6 * k, 6 * k, 6 * k),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 快捷回复两小块
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _previewChip(t, k, 46),
              SizedBox(height: 3 * k),
              _previewChip(t, k, 38),
            ],
          ),
          SizedBox(width: 5 * k),
          Expanded(
            child: Container(
              height: 26 * k,
              decoration: BoxDecoration(
                color: t.bg,
                borderRadius: BorderRadius.circular(9 * k),
              ),
            ),
          ),
          SizedBox(width: 4 * k),
          Container(
            width: 20 * k,
            height: 20 * k,
            decoration: BoxDecoration(
              color: t.accent.withValues(alpha: 0.25),
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewChip(ChatGalTheme t, double k, double width) {
    return Container(
      width: width * k,
      height: 11 * k,
      decoration: BoxDecoration(
        color: t.sub.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }

  Widget _previewBubble(ChatGalTheme t, double k, String text, bool isUser) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: EdgeInsets.symmetric(horizontal: 10 * k, vertical: 7 * k),
      constraints: BoxConstraints(maxWidth: 220 * k),
      decoration: BoxDecoration(
        color: isUser ? t.userBubble : t.jjBubble,
        borderRadius: BorderRadius.circular(14 * k),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: (14 * k).clamp(8.0, 16.0),
          height: 1.4,
          color: isUser ? Colors.white : t.ink,
        ),
      ),
    );
  }

  Widget _portrait(ChatGalTheme t, bool removeBg) {
    final path = _portraitPath;
    if (path == null) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          width: 70,
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: t.accent.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Text('无立绘', style: TextStyle(fontSize: 10, color: t.sub)),
        ),
      );
    }
    if (!removeBg) {
      return Image.file(
        File(path),
        fit: BoxFit.contain,
        alignment: Alignment.bottomCenter,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    }
    return FutureBuilder<ui.Image?>(
      future: portraitBgRemover.process(path),
      builder: (context, snap) {
        final img = snap.data;
        if (img == null) {
          return Image.file(
            File(path),
            fit: BoxFit.contain,
            alignment: Alignment.bottomCenter,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          );
        }
        return RawImage(
          image: img,
          fit: BoxFit.contain,
          alignment: Alignment.bottomCenter,
        );
      },
    );
  }
}
