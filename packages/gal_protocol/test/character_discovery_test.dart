import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 角色由 `characters/<id>/character.json` 的**实际存在**决定。
///
/// manifest 里已经没有任何角色表（`characters` 与 `characterVariables` 都删了），
/// 目录名同时就是角色 id 与游戏内显示名 —— 所以没有 `name` 字段，
/// 基础人格也**内联**在 `prompt` 里（不再有 `promptFile` / `promptBodies`）。
Map<String, String> _pack(List<String> folders) {
  final files = <String, String>{
    // JSONC：作者可以写注释（loader 会剥掉）
    'manifest.json': '''
{
  //包身份
  "packageId": "demo.pack",
  "version": "250",
  "name": "示例",
  "author": "t",
  "description": "d",
  //系统变量
  "variables": [
    { "id": "day", "type": "int", "default": 1, "min": 1, "max": 9999 },
  ]
}
''',
    'home.png': '',
    'stories/bg.png': '',
    'stories/start.json': '{"displayName":"开始","background":"bg.png"}',
  };
  for (final id in folders) {
    files['characters/$id/character.json'] = '''
{
  "id": "$id",
  //基础人格：每次对话都进上下文
  "prompt": "你是$id。",
  "defaultState": "校服",
  "defaultEmotion": "平常",
  "states": ["校服"],
  "emotions": ["平常"],
}
''';
    files['characters/$id/校服_平常.png'] = '';
  }
  return files;
}

void main() {
  test('角色表由 characters/ 下的文件夹决定（按 id 排序，manifest 不再声明）', () {
    final content = PackageLoader.fromFiles(_pack(['b', 'a']));
    expect(content.characters.map((c) => c.id), ['a', 'b']);
    expect(content.character('b')!.id, 'b');
    // 目录名就是显示名：没有单独的 name 字段
    expect(content.character('a')!.id, 'a');
  });

  test('基础人格内联在 character.json 的 prompt 里', () {
    final content = PackageLoader.fromFiles(_pack(['a', 'b']));
    expect(content.character('a')!.prompt, '你是a。');
    expect(content.characters.map((c) => c.prompt), ['你是a。', '你是b。']);
  });

  test('中文状态/情绪原样保留，立绘按命名约定解析', () {
    final content = PackageLoader.fromFiles(_pack(['a']));
    final c = content.character('a')!;
    expect(c.states, ['校服']);
    expect(c.emotions, ['平常']);
    expect(c.defaultState, '校服');
    expect(c.defaultEmotion, '平常');
    // 立绘不再有映射表：唯一来源就是「<状态>_<情绪>.png」
    expect(c.portraitPathFor('校服', '开心'), 'characters/a/校服_开心.png');
    expect(CharacterDef.portraitKey('校服', '开心'), '校服_开心');
  });

  test('state/emotion 省略时回退到角色声明的默认值', () {
    final files = _pack(['a']);
    files['characters/a/character.json'] = '''
{
  "id": "a",
  "prompt": "你。",
  "states": ["便服", "校服"],
  "emotions": ["平常", "开心"],
}
''';
    final content = PackageLoader.fromFiles(files);
    final c = content.character('a')!;
    expect(c.defaultState, '便服', reason: 'states 的第一个');
    expect(c.defaultEmotion, '平常', reason: 'emotions 的第一个');
  });

  test('没有 characters/ 目录的包：角色表为空但不报错（校验器负责提示）', () {
    final files = _pack(const []);
    final content = PackageLoader.fromFiles(files);
    expect(content.characters, isEmpty);
  });
}
