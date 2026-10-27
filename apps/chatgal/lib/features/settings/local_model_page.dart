import 'package:flutter/material.dart';

import '../../design_system/shell.dart';
import '../../design_system/tokens.dart';
import 'api_settings.dart';
import 'model_providers_page.dart';
import 'settings_widgets.dart';

/// 本地模型：**端侧推理已经拆成独立应用**（见 `docs/推理引擎.md`）。
///
/// 这一页只告诉玩家三件事：本地推理能带来什么、要去装哪个应用、装完在哪填地址。
/// **不要在这里写实现细节**（引擎名、库体积、构建方式、文档路径）—— 那是给开发者
/// 看的，玩家只关心「怎么让对话不出手机」。
class LocalModelPage extends StatelessWidget {
  const LocalModelPage({
    super.key,
    required this.theme,
    required this.api,
    this.onChanged,
  });

  final ChatGalTheme theme;
  final ApiSettingsStore api;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    return ChatGalShell(
      theme: t,
      title: '本地模型',
      body: ListView(
        padding: const EdgeInsets.all(Spacing.lg),
        children: [
          SettingsPanel(
            theme: t,
            padding: const EdgeInsets.all(Spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.smartphone, size: 16, color: t.accent),
                    const SizedBox(width: 6),
                    Text(
                      '在手机上跑，不联网',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '开启之后，对话、立绘、结算与记忆整理都在你的手机上完成，'
                  '内容不会发送到任何服务器。这部分功能放在了另一个应用里，'
                  '需要单独安装。',
                  style: TextStyle(fontSize: 12, height: 1.5, color: t.sub),
                ),
                const SizedBox(height: 14),
                _step(t, '1', '安装「ChatGal 本地推理引擎」。'),
                _step(t, '2', '打开它，下载一个模型，然后开启服务。'),
                _step(
                  t,
                  '3',
                  '回到这里，在「模型供应商」中新增一条供应商，地址填它在界面上'
                      '显示的那串 http://127.0.0.1 开头的地址，然后启用。',
                ),
                const SizedBox(height: 4),
                Text(
                  '不装也完全不影响使用：对话会走你在「模型供应商」里配置的在线服务；'
                  '一个都没配时，用离线的演示回复。',
                  style: TextStyle(fontSize: 11.5, height: 1.5, color: t.sub),
                ),
              ],
            ),
          ),
          const SizedBox(height: Spacing.md),
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
              icon: const Icon(Icons.cloud_queue, size: 18),
              label: const Text('去「模型供应商」配置'),
              onPressed: () async {
                await Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => ModelProvidersPage(
                      theme: t,
                      api: api,
                      onChanged: onChanged,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: Spacing.sm),
          SettingsNote(
            '同一个网络里的电脑也可以当作推理服务：在电脑上跑好带 API 的服务，'
            '把它的局域网地址填进「模型供应商」就行。',
            theme: t,
          ),
        ],
      ),
    );
  }

  Widget _step(ChatGalTheme t, String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              number,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: t.accent,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, height: 1.5, color: t.ink),
            ),
          ),
        ],
      ),
    );
  }
}
