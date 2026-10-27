import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 多角色的**机制完整性**（不做多角色真实内容，但结构必须撑得住）：
///
/// * 角色表由 `characters/` 下的文件夹决定，各自有自己的情绪词与立绘；
/// * 变量是**一个扁平命名空间**（manifest.variables），属主按「最长的角色
///   id 前缀」推导 —— `characterVariables` 分组字段已删；
/// * 共用一幕时 audience 就是 `scene.characters` 里的 charId。
Map<String, String> _pack({List<String> folders = const ['甲', '乙']}) {
  final files = <String, String>{
    'manifest.json': '''
{
  "packageId": "demo.multi",
  "version": "250",
  "name": "多角色",
  "author": "t",
  "description": "d",
  "variables": [
    { "id": "day", "type": "int", "default": 1, "min": 1, "max": 9999 },
    { "id": "甲好感", "type": "int", "default": 50, "min": 0, "max": 100,
      "label": "好感" },
    { "id": "甲信任", "type": "int", "default": 40, "min": 0, "max": 100,
      "label": "信任" },
    { "id": "乙信任", "type": "int", "default": 30, "min": 0, "max": 100,
      "label": "信任" }
  ]
}
''',
    'home.png': '',
    'stories/bg.png': '',
    'stories/start.json': '''
{
  "displayName": "开始",
  "background": "bg.png",
  "narration": "两人都在场。",
  "atmosphere": "灯亮着。",
  "characters": [
    { "charId": "甲", "state": "便服", "emotion": "平常", "scenePrompt": "A" },
    { "charId": "乙", "state": "校服", "emotion": "开心", "scenePrompt": "B" }
  ],
  "fixedEffects": [],
  "target": [ { "kind": [ { "kind": "story", "to": "start" } ] } ]
}
''',
  };
  const states = {'甲': ('便服', '平常'), '乙': ('校服', '开心')};
  for (final id in folders) {
    final (st, emo) = states[id]!;
    files['characters/$id/character.json'] = '''
{
  "id": "$id",
  "prompt": "你是$id。",
  "defaultState": "$st",
  "defaultEmotion": "$emo",
  "states": ["$st"],
  "emotions": ["$emo"]
}
''';
    files['characters/$id/${st}_$emo.png'] = '';
  }
  return files;
}

void main() {
  test('角色表由 characters/ 下的文件夹决定（每个目录一个角色）', () {
    final content = PackageLoader.fromFiles(_pack());
    expect(content.characters.map((c) => c.id), ['乙', '甲']);
    expect(content.character('乙')!.id, '乙');
  });

  test('角色目录缺了 role 声明的变量也没关系：变量表只看 manifest', () {
    // manifest 里没有「乙好感」，只有「乙信任」——不能因为乙没有好感变量就
    // 认为乙不存在。
    final content = PackageLoader.fromFiles(_pack());
    final reg = content.variableRegistry;
    expect(reg.ownerOf('乙信任'), '乙');
    expect(reg.varsOf('乙').map((v) => v.id), ['乙信任']);
  });

  test('每个角色有自己的情绪词与立绘，互不干扰', () {
    final content = PackageLoader.fromFiles(_pack());
    final a = content.character('甲')!;
    final b = content.character('乙')!;
    expect(a.emotions, ['平常']);
    expect(b.emotions, ['开心']);
    expect(a.portraitPathFor('便服', '平常'), 'characters/甲/便服_平常.png');
    expect(b.portraitPathFor('校服', '开心'), 'characters/乙/校服_开心.png');
  });

  test('变量在一个扁平表里，属主按最长角色 id 前缀推导', () {
    final content = PackageLoader.fromFiles(_pack());
    final reg = content.variableRegistry;
    expect(reg.defaults['甲好感'], 50);
    expect(reg.defaults['甲信任'], 40);
    expect(reg.defaults['乙信任'], 30);
    expect(reg.ownerOf('甲好感'), '甲');
    expect(reg.ownerOf('乙信任'), '乙');
    // 系统变量没有属主
    expect(reg.ownerOf('day'), isNull);
    expect(reg.isCharacterVariable('day'), isFalse);
    expect(reg.charIds, ['甲', '乙']);
  });

  test('角色 id 互为前缀时取最长者（「戒戒好感」归「戒戒」而不是「戒」）', () {
    final reg = VariableRegistry.build(
      variables: const [
        VariableDef(id: '戒戒好感', type: 'int'),
        VariableDef(id: '戒信任', type: 'int'),
        VariableDef(id: 'day', type: 'int'),
      ],
      characterIds: const ['戒', '戒戒'],
    );
    expect(reg.ownerOf('戒戒好感'), '戒戒');
    expect(reg.ownerOf('戒信任'), '戒');
    expect(reg.ownerOf('day'), isNull);
  });

  test('重复变量声明会在装载阶段 fail fast', () {
    expect(
      () => VariableRegistry.build(
        variables: const [
          VariableDef(id: '甲好感', type: 'int'),
          VariableDef(id: '甲好感', type: 'int'),
        ],
      ),
      throwsA(isA<PackageFormatException>()),
    );
  });

  test('同一幕两人在场：audience 是两人，各自的 L1 窗口都拿到这轮', () {
    final content = PackageLoader.fromFiles(_pack());
    final scene = content.scenes['start']!;
    final audience = [for (final a in scene.characters) a.charId];
    expect(audience, ['甲', '乙']);

    final bank = MemoryBank();
    bank.recordTurn(DialogueTurn(
      turnId: 't1',
      playerText: '你们好',
      replyText: '……',
      audience: audience,
      storyId: 'start',
      visitId: 0,
      at: DateTime.utc(2026, 9, 13),
    ));
    expect(bank.windowOf('甲').length, 1);
    expect(bank.windowOf('乙').length, 1);
    // 没在场的人既没窗口也不可见
    expect(bank.windowIfExists('丙'), isNull);
  });

  test('新档世界把两个角色的变量都播种，并镜像两人到 presentation.actors', () {
    final content = PackageLoader.fromFiles(_pack());
    final world = initialWorldFor(content);
    expect(world.variables['甲好感'], 50);
    expect(world.variables['甲信任'], 40);
    expect(world.variables['乙信任'], 30);
    expect(world.presentation['actors'], hasLength(2));
    expect(world.presentation['scene'], 'bg.png');
  });
}
