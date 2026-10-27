import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_logger.dart';
import '../../app/app_services.dart';
import '../../design_system/shell.dart';
import '../../design_system/tokens.dart';
import '../logs/log_page.dart';
import '../settings/feedback_page.dart';
import '../settings/privacy_page.dart';
import '../settings/settings_widgets.dart';
import 'update_service.dart';

/// 「帮助与关于」页：原先设置里的「关于」整组迁到这里，并补上交流群、
/// 支持作者、开源仓库与版本更新。
///
/// 层级（玩家从上往下看）：版本与更新 → 交流 → 支持 → 隐私与反馈 → 其他。
class HelpAboutPage extends StatefulWidget {
  const HelpAboutPage({
    super.key,
    required this.theme,
    required this.services,
  });

  final ChatGalTheme theme;
  final AppServices services;

  @override
  State<HelpAboutPage> createState() => _HelpAboutPageState();
}

class _HelpAboutPageState extends State<HelpAboutPage> {
  final UpdateService _updater = const UpdateService();
  UpdateInfo? _update;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _checkUpdate();
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    final info = await _updater.check();
    if (!mounted) return;
    setState(() {
      _update = info;
      _checking = false;
    });
  }

  Future<void> _copy(BuildContext context, String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已复制$label')));
  }

  /// 帮助页里的外链一律交系统浏览器打开。
  Future<void> _openUrl(
    BuildContext context,
    ChatGalTheme t, {
    required String url,
    required String title,
  }) async {
    final launched = await NativeBridge.instance.launch(url);
    if (launched) return;
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('当前打不开这个地址，可以复制到浏览器'),
        action: SnackBarAction(
          label: '复制',
          onPressed: () => _copy(context, url, '地址'),
        ),
      ),
    );
  }

  /// 加群：只复制群号，不跳转。
  Future<void> _copyQqGroup(BuildContext context) async {
    await _copy(context, kChatGalQqGroup, 'QQ 群号');
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final info = _update;
    final hasUpdate = info?.hasUpdate ?? false;

    return ChatGalShell(
      theme: t,
      title: '帮助与关于',
      body: ListView(
        padding: const EdgeInsets.all(Spacing.lg),
        children: [
          // ---------- 版本与更新 ----------
          SettingsSectionTitle('版本与更新', theme: t),
          SettingsPanel(
            theme: t,
            padding: const EdgeInsets.all(Spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: t.accent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        hasUpdate ? Icons.system_update : Icons.verified_outlined,
                        size: 18,
                        color: t.accent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '当前版本 ${info?.currentVersion ?? kAppVersion}',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: t.ink,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _statusLine(info),
                            style: TextStyle(fontSize: 11.5, color: t.sub),
                          ),
                        ],
                      ),
                    ),
                    if (hasUpdate)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFC107).withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '有新版本',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: t.ink,
                          ),
                        ),
                      ),
                  ],
                ),
                if (hasUpdate &&
                    (info?.releaseNotes.isNotEmpty ?? false)) ...[
                  const SizedBox(height: 10),
                  Text(
                    info!.releaseNotes,
                    style: TextStyle(fontSize: 11.5, height: 1.45, color: t.sub),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          side: BorderSide(color: t.sub.withValues(alpha: 0.4)),
                        ),
                        onPressed: _checking ? null : _checkUpdate,
                        child: Text(
                          _checking ? '检查中…' : '检查更新',
                          style: TextStyle(color: t.accent, fontSize: 13),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SettingsEntryTile(
            theme: t,
            icon: Icons.cloud_download_outlined,
            title: '从 GitHub 下载',
            subtitle: '开源发布页，安装包与说明都在这里',
            onTap: () => _openUrl(
              context,
              t,
              url: kGithubReleasesUrl,
              title: 'GitHub 下载',
            ),
          ),
          SettingsEntryTile(
            theme: t,
            icon: Icons.language,
            title: '从ChatGal官网下载',
            subtitle: kOfficialSiteUrl,
            onTap: () => _openUrl(
              context,
              t,
              url: kOfficialSiteUrl,
              title: 'ChatGal 官网',
            ),
          ),

          // ---------- 交流 ----------
          SettingsSectionTitle('交流', theme: t),
          SettingsEntryTile(
            theme: t,
            icon: Icons.groups_outlined,
            title: 'ChatGal QQ 交流群',
            subtitle: '群号 $kChatGalQqGroup · 点击复制',
            trailingText: '复制群号',
            onTap: () => _copyQqGroup(context),
          ),
          SettingsEntryTile(
            theme: t,
            icon: Icons.code,
            title: '开源仓库',
            subtitle: '内容包与发布说明都在这里',
            onTap: () => _openUrl(
              context,
              t,
              url: kGithubRepoUrl,
              title: '开源仓库',
            ),
          ),

          // ---------- 支持 ----------
          SettingsSectionTitle('支持戎戎', theme: t),
          SettingsPanel(
            theme: t,
            padding: const EdgeInsets.all(Spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '如果 ChatGal 让你觉得有意思，可以来爱发电请作者喝杯水。'
                  '支持是自愿的，不影响游玩。',
                  style: TextStyle(fontSize: 12, height: 1.5, color: t.sub),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: t.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.favorite_outline, size: 16),
                    label: const Text('打开爱发电'),
                    onPressed: () => _openUrl(
                      context,
                      t,
                      url: kAfdianUrl,
                      title: '爱发电',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  kAfdianUrl,
                  style: TextStyle(fontSize: 11, color: t.sub),
                ),
              ],
            ),
          ),

          // ---------- 隐私与反馈 ----------
          SettingsSectionTitle('隐私与反馈', theme: t),
          SettingsEntryTile(
            theme: t,
            icon: Icons.privacy_tip_outlined,
            title: '隐私政策',
            subtitle: kPrivacyPolicyUrl,
            onTap: () => _openUrl(
              context,
              t,
              url: kPrivacyPolicyUrl,
              title: '隐私政策',
            ),
          ),
          SettingsEntryTile(
            theme: t,
            icon: Icons.forum_outlined,
            title: '反馈',
            subtitle: '邮箱 $kFeedbackEmail 或 QQ $kFeedbackQq',
            onTap: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute(builder: (_) => FeedbackPage(theme: t)),
              );
            },
          ),

          // ---------- 其他 ----------
          SettingsSectionTitle('其他', theme: t),
          SettingsEntryTile(
            theme: t,
            icon: Icons.receipt_long_outlined,
            title: '运行日志',
            subtitle: '看这次运行发生了什么（请求、安装、朗读、错误）',
            trailingText: '${AppLogger.instance.entries.length} 条',
            onTap: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => LogPage(theme: t, api: widget.services.api),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  String _statusLine(UpdateInfo? info) {
    if (info == null) return '点「检查更新」看看有没有新版本';
    if (!info.checked) return '这次没检查成功，可以稍后再试';
    if (info.hasUpdate) {
      final latest = info.latestVersion;
      return '发现新版本 $latest，可以从下面的入口下载安装';
    }
    return '已经是最新版本';
  }
}
