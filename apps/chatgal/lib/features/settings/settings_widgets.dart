import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';

/// 设置类页面共用的卡片容器。
class SettingsPanel extends StatelessWidget {
  const SettingsPanel({
    super.key,
    required this.theme,
    required this.child,
    this.padding,
  });

  final ChatGalTheme theme;
  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: Spacing.sm),
      decoration: BoxDecoration(
        color: theme.card,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: theme.sub.withValues(alpha: 0.12)),
      ),
      padding: padding,
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class SettingsSectionTitle extends StatelessWidget {
  const SettingsSectionTitle(this.text, {super.key, required this.theme});

  final String text;
  final ChatGalTheme theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: theme.ink,
        ),
      ),
    );
  }
}

/// 一行「点进去」的入口：图标 + 标题 + 副标题 + 右侧说明 + 箭头。
class SettingsEntryTile extends StatelessWidget {
  const SettingsEntryTile({
    super.key,
    required this.theme,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailingText,
    this.onTap,
  });

  final ChatGalTheme theme;
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? trailingText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SettingsPanel(
      theme: theme,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        leading: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: theme.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, size: 18, color: theme.accent),
        ),
        title: Text(
          title,
          style: TextStyle(color: theme.ink, fontWeight: FontWeight.w600),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 11.5,
                  color: theme.sub,
                  height: 1.4,
                ),
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (trailingText != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 110),
                child: Text(
                  trailingText!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, color: theme.sub),
                ),
              ),
            Icon(Icons.chevron_right, size: 18, color: theme.sub),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

/// 一小段说明文字（不放在卡片里）。
class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key, required this.theme, this.pad = true});

  final String text;
  final ChatGalTheme theme;
  final bool pad;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: pad ? Spacing.md : 4),
      child: Text(
        text,
        style: TextStyle(fontSize: 11.5, height: 1.55, color: theme.sub),
      ),
    );
  }
}
