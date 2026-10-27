import 'package:chatgal/features/settings/chat_font.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('聊天字体', () {
    test('预设字体的族名', () {
      expect(
        chatFontFamilyOf(fontId: 'system', imported: const []),
        isNull,
      );
      expect(chatFontFamilyOf(fontId: 'serif', imported: const []), 'serif');
      expect(chatFontFamilyOf(fontId: 'mono', imported: const []), 'monospace');
    });

    test('导入字体按 id 找到族名', () {
      const f = ImportedChatFont(
        id: 'f_1',
        label: '我的宋体',
        family: 'f_1',
        path: '/tmp/f_1.ttf',
        sizeBytes: 10,
      );
      expect(chatFontFamilyOf(fontId: 'f_1', imported: const [f]), 'f_1');
      expect(chatFontLabelOf(fontId: 'f_1', imported: const [f]), '我的宋体');
    });

    test('指向已删除的字体会退回系统默认（不静默用别人的字体）', () {
      expect(chatFontFamilyOf(fontId: 'f_gone', imported: const []), isNull);
      expect(
        chatFontLabelOf(fontId: 'f_gone', imported: const []),
        kChatFontPresets.first.label,
      );
    });

    test('字号被夹在合法区间内', () {
      final small = chatTextStyle(fontId: 'system', imported: const [], fontSize: 2);
      expect(small.fontSize, kChatFontSizeMin);
      final big = chatTextStyle(fontId: 'system', imported: const [], fontSize: 99);
      expect(big.fontSize, kChatFontSizeMax);
    });

    test('只改字体的设置不会碰到字号', () {
      const f = ImportedChatFont(
        id: 'f_2',
        label: 'X',
        family: 'f_2',
        path: '/tmp/x.ttf',
        sizeBytes: 1,
      );
      final style = chatTextStyle(
        fontId: 'f_2',
        imported: const [f],
        fontSize: 18,
        color: const Color(0xFF112233),
      );
      expect(style.fontFamily, 'f_2');
      expect(style.fontSize, 18);
      expect(style.color, const Color(0xFF112233));
    });

    test('导入字体的 json 往返', () {
      const f = ImportedChatFont(
        id: 'f_3',
        label: '标题字体',
        family: 'f_3',
        path: '/tmp/f_3.otf',
        sizeBytes: 2048,
      );
      final back = ImportedChatFont.fromJson(f.toJson());
      expect(back.id, f.id);
      expect(back.label, f.label);
      expect(back.path, f.path);
      expect(back.sizeBytes, f.sizeBytes);
    });
  });
}
