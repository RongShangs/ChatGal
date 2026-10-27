import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_logger.dart';
import '../../design_system/shell.dart';
import '../../design_system/tokens.dart';
import '../settings/privacy_page.dart';
import '../settings/settings_widgets.dart';

/// 反馈入口：邮件 / QQ 两个渠道，复制或直接交给系统应用打开。
///
/// 另外给一个「把最近日志复制出来」的按钮 —— 出问题时把日志一起发过来，
/// 比只描述现象有用得多（这也是加日志系统的主要目的）。
class FeedbackPage extends StatelessWidget {
  const FeedbackPage({super.key, required this.theme});

  final ChatGalTheme theme;

  Future<void> _copy(BuildContext context, String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已复制$label')));
  }

  Future<void> _launch(BuildContext context, String url, String label) async {
    final ok = await NativeBridge.instance.launch(url);
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('没有能打开$label的应用，可以先复制')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = theme;
    return ChatGalShell(
      theme: t,
      title: '反馈',
      body: ListView(
        padding: const EdgeInsets.all(Spacing.lg),
        children: [
          SettingsNote(
            '遇到问题、想提建议、或者只是想说说玩后感，都欢迎找我。'
            '尽量写清楚：哪一步、期望是什么、实际发生了什么。',
            theme: t,
          ),
          SettingsSectionTitle('邮箱', theme: t),
          _channel(
            t,
            icon: Icons.mail_outline,
            title: kFeedbackEmail,
            subtitle: '适合写长一点的内容，可以带截图与日志文件',
            onCopy: () => _copy(context, kFeedbackEmail, '邮箱地址'),
            onOpen: () => _launch(context, 'mailto:$kFeedbackEmail', '邮箱'),
            openLabel: '写邮件',
          ),
          const SizedBox(height: Spacing.md),
          SettingsSectionTitle('QQ', theme: t),
          _channel(
            t,
            icon: Icons.chat_bubble_outline,
            title: kFeedbackQq,
            subtitle: '适合快速说两句、要即时回复',
            onCopy: () => _copy(context, kFeedbackQq, 'QQ 号'),
            onOpen: () => _launch(
              context,
              'mqqwpa://im/chat?chat_type=wpa&uin=$kFeedbackQq',
              'QQ',
            ),
            openLabel: '打开 QQ',
          ),
          const SizedBox(height: Spacing.lg),
          SettingsSectionTitle('带上日志', theme: t),
          SettingsPanel(
            theme: t,
            padding: const EdgeInsets.all(Spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '反馈时附上最近日志，定位问题会快很多。'
                  '日志只记录本机的运行过程（请求、安装、朗读、错误），不含对话正文。',
                  style: TextStyle(fontSize: 12, height: 1.5, color: t.sub),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          side: BorderSide(color: t.sub.withValues(alpha: 0.4)),
                        ),
                        icon: Icon(Icons.copy_all_outlined,
                            size: 16, color: t.accent),
                        label: Text('复制最近 100 条',
                            style: TextStyle(color: t.accent, fontSize: 13)),
                        onPressed: () {
                          final all = AppLogger.instance.entries;
                          final tail = all.length > 100
                              ? all.sublist(all.length - 100)
                              : all;
                          if (tail.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('还没有日志')),
                            );
                            return;
                          }
                          _copy(
                            context,
                            tail.map((e) => e.line).join('\n'),
                            '${tail.length} 行日志',
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _channel(
    ChatGalTheme t, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onCopy,
    required VoidCallback onOpen,
    required String openLabel,
  }) {
    return SettingsPanel(
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
                child: Icon(icon, size: 18, color: t.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(fontSize: 11.5, color: t.sub),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: BorderSide(color: t.sub.withValues(alpha: 0.4)),
                  ),
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('复制', style: TextStyle(fontSize: 13)),
                  onPressed: onCopy,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: t.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: onOpen,
                  child: Text(openLabel),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
