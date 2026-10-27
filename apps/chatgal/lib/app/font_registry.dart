import 'dart:io';

import 'package:flutter/services.dart';

import '../features/settings/api_settings.dart';
import 'app_logger.dart';

/// 把用户导入的 ttf/otf 注册进 Flutter。
///
/// `FontLoader` 只能注册、不能注销，所以用「加载过的 id」去重；
/// 文件被删掉（或注册失败）就跳过 —— 设置页那边已经把指向它的选择退回默认了。
abstract final class FontRegistry {
  static final Set<String> _loaded = {};

  static Future<void> ensure(AppSettings settings) async {
    for (final font in settings.importedFonts) {
      if (_loaded.contains(font.id)) continue;
      final file = File(font.path);
      if (!file.existsSync() || file.lengthSync() == 0) {
        appLog.w('font', '字体文件缺失，跳过注册：${font.path}');
        continue;
      }
      try {
        final bytes = await file.readAsBytes();
        final loader = FontLoader(font.family);
        loader.addFont(
          Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)),
        );
        await loader.load();
        _loaded.add(font.id);
        appLog.i('font', '已注册导入字体「${font.label}」(${font.family})');
      } catch (e) {
        appLog.e('font', '注册字体失败：${font.label}', e);
      }
    }
  }

  /// 出错时清掉标记，下次还能再试一遍。
  static void forget(String fontId) => _loaded.remove(fontId);
}
