import 'dart:convert';

import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 内容包的 JSON 允许 `//` / `/* */` 注释与尾逗号：作者要在文件里解释每个字段
/// 是干什么的。剥注释只做「剥离」，不改写数据 —— 字符串字面量里的 `//`
/// （URL、正则）与转义引号都不能被误伤。
void main() {
  group('stripJsonComments', () {
    test('去掉行注释，保留换行与正文', () {
      final out = stripJsonComments('''
{
  //这是注释
  "a": 1 //行尾注释
}
''');
      expect(jsonDecode(out), {'a': 1});
    });

    test('去掉块注释', () {
      expect(
        jsonDecode(stripJsonComments('{/*一段\n多行\n说明*/"a":1}')),
        {'a': 1},
      );
    });

    test('字符串里的 // 与注释符不被当成注释', () {
      expect(
        jsonDecode(stripJsonComments('{"url":"https://x.test/a//b"}')),
        {'url': 'https://x.test/a//b'},
      );
      expect(
        jsonDecode(stripJsonComments('{"s":"/* 不是注释 */"}')),
        {'s': '/* 不是注释 */'},
      );
    });

    test('转义引号不会把字符串提前结束掉', () {
      expect(
        jsonDecode(stripJsonComments(r'{"s":"a\"// b"}')),
        {'s': 'a"// b'},
      );
    });

    test('尾逗号被删掉（对象与数组）', () {
      expect(
        jsonDecode(stripJsonComments('{"a":[1,2,],"b":{"c":1,},}')),
        {
          'a': [1, 2],
          'b': {'c': 1},
        },
      );
    });

    test('字符串里的逗号 + 括号不受尾逗号处理影响', () {
      expect(
        jsonDecode(stripJsonComments('{"s":"a,]"}\n')),
        {'s': 'a,]'},
      );
    });

    test('BOM 头被剥掉', () {
      expect(jsonDecode(stripJsonComments('\uFEFF{"a":1}')), {'a': 1});
    });
  });

  group('loader 端到端：带注释与尾逗号的包能正常装载', () {
    Map<String, String> pack() => {
          'manifest.json': '''
{
  //包身份
  "packageId": "demo.jsonc",
  "version": "7",     //版本号只能是数字
  "name": "带注释的包",
  "author": "t",
  "description": "d",
  "variables": [
    { "id": "day", "type": "int", "default": 1, "min": 1, "max": 9999 },
  ],
}
''',
          'home.png': '',
          'characters/jj/character.json': '''
{
  "id": "jj",
  /* 基础人格：一次讲清楚她是谁 */
  "prompt": "你是 jj，说话很短。",
  "states": ["校服",],
  "emotions": ["平常",],
  "defaultState": "校服",
  "defaultEmotion": "平常",
}
''',
          'characters/jj/校服_平常.png': '',
          'stories/start.json': '''
{
  //情景展示名
  "displayName": "开始",
  //出口：没写 require 的块是兜底
  "target": [
    { "kind": [ { "kind": "story", "to": "start" } ] },
  ],
}
''',
        };

    test('manifest / character / story 都能读出来', () {
      final content = PackageLoader.fromFiles(pack());
      expect(content.manifest.version, '7');
      expect(content.manifest.name, '带注释的包');
      expect(content.variableRegistry.contains('day'), isTrue);
      final c = content.character('jj')!;
      expect(c.prompt, '你是 jj，说话很短。');
      expect(c.states, ['校服']);
      final start = content.scenes['start']!;
      expect(start.displayName, '开始');
      expect(start.target.single.isFallback, isTrue);
    });

    test('decodeJsonc 对坏 JSON 仍然抛 FormatException', () {
      expect(() => decodeJsonc('{不是 json}'), throwsA(isA<FormatException>()));
    });
  });
}
