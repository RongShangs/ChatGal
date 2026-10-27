import 'dart:convert';
import 'dart:io';

import 'package:chatgal/app/app_logger.dart';
import 'package:chatgal/features/session/chat_layout.dart';
import 'package:chatgal/features/settings/api_settings.dart';
import 'package:chatgal/features/settings/chat_font.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('chatgal_settings_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  void writeSettings(Map<String, Object?> json) {
    File(p.join(root.path, 'app_settings.json'))
        .writeAsStringSync(jsonEncode(json));
  }

  group('消息流留白调整的默认值迁移', () {
    test('从没手动调过 + 值是历史默认（35 / 60）→ 归零', () {
      for (final legacy in ChatLayout.legacyDefaultPads) {
        writeSettings({'chatBottomPad': legacy});
        expect(
          ApiSettingsStore(root.path).load().chatBottomPad,
          ChatLayout.defaultChatBottomPad,
          reason: '历史默认 $legacy 应迁到 0',
        );
      }
    });

    test('用户拖过（touched=true）后，任何默认值变动都不动他的值', () {
      for (final v in [60, 35, 45, 80, 0]) {
        writeSettings({'chatBottomPad': v, 'chatBottomPadTouched': true});
        expect(
          ApiSettingsStore(root.path).load().chatBottomPad,
          v.toDouble(),
          reason: '手动设的 $v 应保留',
        );
      }
    });

    test('没拖过但值不是历史默认（手改 JSON）→ 也保留', () {
      writeSettings({'chatBottomPad': 55});
      expect(ApiSettingsStore(root.path).load().chatBottomPad, 55);
    });

    test('负数留白能存能读（-160~120）', () {
      writeSettings({'chatBottomPad': -60, 'chatBottomPadTouched': true});
      expect(ApiSettingsStore(root.path).load().chatBottomPad, -60);
    });

    test('越界值被夹回区间', () {
      writeSettings({'chatBottomPad': 999, 'chatBottomPadTouched': true});
      expect(ApiSettingsStore(root.path).load().chatBottomPad,
          ChatLayout.padMax);
      writeSettings({'chatBottomPad': -999, 'chatBottomPadTouched': true});
      expect(ApiSettingsStore(root.path).load().chatBottomPad,
          ChatLayout.padMin);
    });

    test('没有这个字段时用新默认值 0', () {
      writeSettings({'themeId': 'violet'});
      expect(ApiSettingsStore(root.path).load().chatBottomPad,
          ChatLayout.defaultChatBottomPad);
    });

    test('touched 标记会被写进设置文件', () async {
      final store = ApiSettingsStore(root.path);
      await store.save(store.load().copyWith(chatBottomPadTouched: true));
      final text =
          File(p.join(root.path, 'app_settings.json')).readAsStringSync();
      expect(text, contains('"chatBottomPadTouched":true'));
      expect(store.load().chatBottomPadTouched, isTrue);
    });
  });

  group('日志上限', () {
    test('默认 1000，能存能读，越界会被夹', () async {
      expect(AppSettings.empty.logMaxEntries, 1000);
      final store = ApiSettingsStore(root.path);
      final s = store.load().copyWith(logMaxEntries: 2000);
      await store.save(s);
      expect(store.load().logMaxEntries, 2000);

      writeSettings({'logMaxEntries': 5});
      expect(store.load().logMaxEntries, AppLogger.minMaxEntries);
      writeSettings({'logMaxEntries': 999999});
      expect(store.load().logMaxEntries, AppLogger.maxMaxEntries);
    });

    test('日志上限改了会被写进文件（下次启动照此恢复）', () async {
      final store = ApiSettingsStore(root.path);
      await store.save(store.load().copyWith(logMaxEntries: 500));
      final text = File(p.join(root.path, 'app_settings.json')).readAsStringSync();
      expect(text, contains('"logMaxEntries":500'));
    });
  });

  group('字体选择收口', () {
    test('指向已删除的导入字体时退回系统默认', () {
      writeSettings({'chatFontId': 'f_不存在'});
      expect(ApiSettingsStore(root.path).load().chatFontId, kSystemFontId);
    });

    test('可爱体是预设之一，且族名固定（要与 pubspec 的 fonts 段一致）', () {
      final cute = kChatFontPresets.firstWhere((p) => p.id == 'cute');
      expect(cute.family, kCuteFontFamily);
      expect(kCuteFontFamily, 'ZCOOLKuaiLe');
      writeSettings({'chatFontId': 'cute'});
      expect(ApiSettingsStore(root.path).load().chatFontId, 'cute');
    });
  });
}
