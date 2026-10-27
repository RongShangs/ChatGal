import 'package:flutter/material.dart';

/// 聊天区可用的字体：预设 + 用户导入的字体文件。
///
/// 只作用于**聊天对话**（气泡文字、场景卡正文），不改界面其它地方的字体。
/// 预设不内嵌字体文件，直接用系统通用族名（Android 上分别落到
/// Noto Sans CJK / Noto Serif CJK / Droid Sans Mono），因此 APK 不变大；
/// 用户导入的 ttf/otf 由 `FontRegistry` 在启动时注册进 Flutter。
class ChatFontPreset {
  const ChatFontPreset({
    required this.id,
    required this.label,
    required this.family,
    required this.note,
  });

  final String id;

  /// 下拉里显示的名字。
  final String label;

  /// 传给 TextStyle.fontFamily 的族名；`null` = 跟随系统默认。
  final String? family;

  final String note;
}

/// 预设字体（`id` 固定，导入字体一律 `f_` 前缀，不会撞）。
///
/// 前四个只用系统通用族名（不占体积）；`cute` 是**内嵌**字体
/// （站酷快乐体，SIL OFL，见 `assets/fonts/` 与 pubspec 的 fonts 段），
/// 因为 Android 没有「可爱」这种通用族名可映射。
const List<ChatFontPreset> kChatFontPresets = [
  ChatFontPreset(
    id: 'system',
    label: '系统默认',
    family: null,
    note: '跟随手机系统字体，最稳，中文不缺字',
  ),
  ChatFontPreset(
    id: 'cute',
    label: '可爱圆体 · 站酷快乐体',
    family: kCuteFontFamily,
    note: '圆头笔画、字面蓬松，像手写便签；自带中文字形',
  ),
  ChatFontPreset(
    id: 'sans',
    label: '黑体 / 无衬线',
    family: 'sans-serif',
    note: '笔画均匀，屏幕阅读轻松',
  ),
  ChatFontPreset(
    id: 'serif',
    label: '宋体 / 衬线',
    family: 'serif',
    note: '有笔锋，适合叙事感更强的故事',
  ),
  ChatFontPreset(
    id: 'mono',
    label: '等宽',
    family: 'monospace',
    note: '字距整齐，偏冷',
  ),
];

/// 内嵌可爱字体的族名（必须与 pubspec.yaml 的 `fonts:` 段逐字一致）。
const String kCuteFontFamily = 'ZCOOLKuaiLe';

const String kSystemFontId = 'system';

/// 一个导入进来的字体文件。
class ImportedChatFont {
  const ImportedChatFont({
    required this.id,
    required this.label,
    required this.family,
    required this.path,
    required this.sizeBytes,
  });

  /// `f_` 前缀 + 时间戳。
  final String id;

  /// 用户起的名字（默认取文件名）。
  final String label;

  /// 注册进 Flutter 的族名（等于 id，避免与系统族名冲突）。
  final String family;

  /// 字体文件绝对路径（存在应用数据目录里）。
  final String path;

  final int sizeBytes;

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'family': family,
        'path': path,
        'sizeBytes': sizeBytes,
      };

  factory ImportedChatFont.fromJson(Map<String, Object?> json) {
    final id = '${json['id'] ?? ''}';
    return ImportedChatFont(
      id: id,
      label: '${json['label'] ?? id}',
      family: '${json['family'] ?? id}',
      path: '${json['path'] ?? ''}',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 找出当前选中的族名；找不到（例如导入字体被删了）就退回系统默认。
String? chatFontFamilyOf({
  required String fontId,
  required List<ImportedChatFont> imported,
}) {
  for (final p in kChatFontPresets) {
    if (p.id == fontId) return p.family;
  }
  for (final f in imported) {
    if (f.id == fontId) return f.family;
  }
  return null;
}

String chatFontLabelOf({
  required String fontId,
  required List<ImportedChatFont> imported,
}) {
  for (final p in kChatFontPresets) {
    if (p.id == fontId) return p.label;
  }
  for (final f in imported) {
    if (f.id == fontId) return f.label;
  }
  return kChatFontPresets.first.label;
}

/// 字号范围（逻辑像素）。只影响聊天对话。
const double kChatFontSizeMin = 12;
const double kChatFontSizeMax = 26;
const double kChatFontSizeDefault = 15;

/// 一条聊天文字用哪个字体/字号。
///
/// 抽成纯函数是为了能被单测钉住：聊天页与预览窗必须算出同一个结果，
/// 否则「预览里好看、进游戏不一样」。
TextStyle chatTextStyle({
  required String fontId,
  required List<ImportedChatFont> imported,
  required double fontSize,
  Color? color,
  double height = 1.45,
}) {
  return TextStyle(
    fontFamily: chatFontFamilyOf(fontId: fontId, imported: imported),
    fontSize: fontSize.clamp(kChatFontSizeMin, kChatFontSizeMax),
    height: height,
    color: color,
  );
}
