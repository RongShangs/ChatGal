import 'package:flutter/material.dart';

/// ChatGal design tokens (violet family + pink + dark themes).
class ChatGalTheme {
  const ChatGalTheme({
    required this.id,
    required this.name,
    required this.brightness,
    required this.accent,
    required this.bg,
    required this.card,
    required this.userBubble,
    required this.jjBubble,
    required this.ink,
    required this.sub,
  });

  final String id;
  final String name;
  final Brightness brightness;
  final Color accent;
  final Color bg;
  final Color card;
  final Color userBubble;
  final Color jjBubble;
  final Color ink;
  final Color sub;

  static const violet = ChatGalTheme(
    id: 'violet',
    name: '浅色·紫罗兰',
    brightness: Brightness.light,
    accent: Color(0xFFAA96DA),
    bg: Color(0xFFF9F9F9),
    card: Colors.white,
    userBubble: Color(0xFFAA96DA),
    jjBubble: Color(0xFFF5F0F0),
    ink: Color(0xFF333333),
    sub: Color(0xFF888888),
  );

  static const sakura = ChatGalTheme(
    id: 'sakura',
    name: '浅色·樱花粉',
    brightness: Brightness.light,
    accent: Color(0xFFFF9EBB),
    bg: Color(0xFFFFF9FA),
    card: Colors.white,
    userBubble: Color(0xFFFF9EBB),
    jjBubble: Color(0xFFF9F0F2),
    ink: Color(0xFF333333),
    sub: Color(0xFF888888),
  );

  static const night = ChatGalTheme(
    id: 'night',
    name: '深色·幽夜紫',
    brightness: Brightness.dark,
    accent: Color(0xFF8B78BA),
    bg: Color(0xFF121212),
    card: Color(0xFF1E1E1E),
    userBubble: Color(0xFF6A5794),
    jjBubble: Color(0xFF2A2A2A),
    ink: Color(0xFFE0E0E0),
    sub: Color(0xFF999999),
  );

  static const abyss = ChatGalTheme(
    id: 'abyss',
    name: '深色·深海蓝',
    brightness: Brightness.dark,
    accent: Color(0xFF58A6FF),
    bg: Color(0xFF0D1117),
    card: Color(0xFF161B22),
    userBubble: Color(0xFF316DCA),
    jjBubble: Color(0xFF21262D),
    ink: Color(0xFFE6EDF3),
    sub: Color(0xFF8B949E),
  );

  static const all = [violet, sakura, night, abyss];

  static ChatGalTheme byId(String id) =>
      all.firstWhere((t) => t.id == id, orElse: () => violet);

  ThemeData toThemeData() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      cardColor: card,
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: ink,
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        // 提示（占位）文字明显比正文浅：不这样，示例文案和真填进去的内容
        // 是一个灰度，作者分不清「填了还是没填」（用户反馈）。
        hintStyle: TextStyle(color: sub.withValues(alpha: 0.55)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

/// Spacing scale.
abstract final class Spacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
}

/// Radius scale.
abstract final class Radii {
  static const card = 16.0;
  static const bubble = 16.0;
  static const pill = 24.0;
  static const button = 24.0;
}
