import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design_system/shell.dart';
import '../../design_system/tokens.dart';
import 'privacy_page.dart';

/// 原生 WebView 打不开时的应用内兜底页。
///
/// 不假装自己是网页：直接说明「应用内网页不可用」，把地址与复制入口给出来，
/// 并给一个「交给系统浏览器」的按钮。这样即使通道挂了，用户也不会被卡住。
class PrivacyFallbackPage extends StatelessWidget {
  const PrivacyFallbackPage({super.key, required this.theme});

  final ChatGalTheme theme;

  @override
  Widget build(BuildContext context) {
    return ChatGalShell(
      theme: theme,
      title: '隐私政策',
      body: ListView(
        padding: const EdgeInsets.all(Spacing.lg),
        children: [
          Container(
            padding: const EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: theme.card,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: theme.sub.withValues(alpha: 0.12)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '应用内网页当前不可用',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: theme.ink,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '可能是当前平台不支持原生 WebView（例如桌面调试）。'
                  '下面是隐私政策页面的地址，可以复制到浏览器打开。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: theme.sub,
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  kPrivacyPolicyUrl,
                  style: TextStyle(fontSize: 12.5, color: theme.accent),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('复制地址'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          side: BorderSide(
                            color: theme.sub.withValues(alpha: 0.4),
                          ),
                        ),
                        onPressed: () async {
                          await Clipboard.setData(
                            const ClipboardData(text: kPrivacyPolicyUrl),
                          );
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制隐私政策地址')),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('用浏览器打开'),
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () async {
                          final ok = await NativeBridge.instance
                              .launch(kPrivacyPolicyUrl);
                          if (!context.mounted) return;
                          if (!ok) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('没有可用的浏览器，请手动复制地址'),
                              ),
                            );
                          }
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
}
