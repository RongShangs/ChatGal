import 'dart:convert';

import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// `stories/<情景id>.json` 是**扁平**结构：文件名 stem 就是 id，文件里不再写
/// `id`，也没有 `enter` / `leave` / `exit` 三层包装与 `segment` 时段概念。
///
/// `id` 因此变成 `SceneDef.fromJson` 的**必填命名参数**（由 loader 从文件名
/// 传进来），而不是 JSON 里的字段。
void main() {
  test('id 来自文件名（命名参数），文件里写 id 也不认', () {
    final scene = SceneDef.fromJson(
      {'id': '别的名字', 'displayName': '晚上·家里'},
      id: 'ji_q',
    );
    expect(scene.id, 'ji_q');
    expect(scene.displayName, '晚上·家里');
  });

  test('displayName 缺省时回退成情景 id', () {
    expect(SceneDef.fromJson(const {}, id: 'start').displayName, 'start');
  });

  test('扁平字段逐个落地：背景/入场词/气氛/角色/固定效果', () {
    final scene = SceneDef.fromJson(
      {
        'displayName': '白天·学校',
        'background': 'xx_q.png',
        'narration': '入场词',
        'atmosphere': '转场气氛',
        'characters': [
          {'charId': '戒戒', 'state': '校服', 'emotion': '平常', 'scenePrompt': '本幕提示'},
        ],
        'fixedEffects': [
          {'id': 'day', 'value': 1},
          {'id': '戒戒好感', 'value': -3},
        ],
      },
      id: 'day',
    );
    expect(scene.background, 'xx_q.png');
    expect(scene.narration, '入场词');
    expect(scene.atmosphere, '转场气氛');
    final actor = scene.characters.single;
    expect(actor.charId, '戒戒');
    expect(actor.state, '校服');
    expect(actor.emotion, '平常');
    expect(actor.scenePrompt, '本幕提示');
    // 正数为加、负数为减：符号只是 value 的符号，不再有「绝对赋值」
    expect(scene.fixedEffects.map((f) => f.id), ['day', '戒戒好感']);
    expect(scene.fixedEffects.map((f) => f.value), [1, -3]);
    // 结算与出口：本幕没写 → 不结算 + 没有出口（都是合法状态）
    expect(scene.settlement, isEmpty);
    expect(scene.target, isEmpty);
  });

  test('省略 narration/atmosphere/characters/fixedEffects/target 都能解析', () {
    final scene = SceneDef.fromJson(const {}, id: 'x');
    expect(scene.narration, '');
    expect(scene.atmosphere, '');
    expect(scene.characters, isEmpty);
    expect(scene.fixedEffects, isEmpty);
    expect(scene.target, isEmpty);
    expect(scene.background, isNull);
  });

  test('characters[] 缺 charId → 直接报错（不能静默少一个角色）', () {
    expect(
      () => SceneDef.fromJson(
        {
          'characters': [
            {'state': '校服'},
          ],
        },
        id: 'x',
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('fixedEffects 的 value 必须是数字（正加负减）', () {
    expect(
      () => SceneDef.fromJson(
        {
          'fixedEffects': [
            {'id': 'day', 'value': '1'},
          ],
        },
        id: 'x',
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  group('settlement：每个变量一个块（自己的提示词 + 自己的上限）', () {
    test('每个块的字段都读出来，onNoEvidence 缺省是 zero', () {
      final scene = SceneDef.fromJson(const {
        'settlement': [
          {'var': '戒戒好感', 'prompt': '更亲近则 +1', 'maxAbsDelta': 3},
          {
            'var': '戒戒堕落',
            'prompt': '越界则 +1',
            'maxAbsDelta': 5,
            'onNoEvidence': 'abort',
          },
        ],
      }, id: 'x');
      expect(scene.settlement.length, 2);
      expect(scene.settlement[0].varId, '戒戒好感');
      expect(scene.settlement[0].prompt, '更亲近则 +1');
      expect(scene.settlement[0].maxAbsDelta, 3);
      expect(scene.settlement[0].onNoEvidence, 'zero');
      expect(scene.settlement[1].varId, '戒戒堕落');
      expect(scene.settlement[1].maxAbsDelta, 5);
      expect(scene.settlement[1].onNoEvidence, 'abort');
    });

    test('不写 → 本幕不结算（合法情景，不是错误）', () {
      final scene = SceneDef.fromJson(const {}, id: 'x');
      expect(scene.settlement, isEmpty);
    });


    test('块里缺 var → 直接报错（不能静默少结算一个变量）', () {
      expect(
        () => SceneDef.fromJson(
          const {
            'settlement': [
              {'prompt': '忘了写变量'},
            ],
          },
          id: 'x',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('toJson 写回冻结形状', () {
      final scene = SceneDef.fromJson(const {
        'settlement': [
          {'var': 'a', 'prompt': 'p', 'maxAbsDelta': 2},
        ],
      }, id: 'x');
      final json = scene.toJson()['settlement'] as List;
      expect(json.single, {
        'var': 'a',
        'prompt': 'p',
        'maxAbsDelta': 2,
        'onNoEvidence': 'zero',
      });
    });
  });

  group('target：出口块数组', () {
    test('顺序即优先级；不写 require 的块是无条件兜底', () {
      final scene = SceneDef.fromJson(
        {
          'target': [
            {
              'require': '"day" == 14 & "戒戒好感" + "戒戒信任" < 120',
              'kind': [
                {'kind': 'event', 'to': 'end_badend14'},
              ],
            },
            {
              'kind': [
                {'kind': 'story', 'to': '1-7day'},
              ],
            },
          ],
        },
        id: 'x',
      );
      expect(scene.target, hasLength(2));
      expect(scene.target.first.require, '"day" == 14 & "戒戒好感" + "戒戒信任" < 120');
      expect(scene.target.first.isFallback, isFalse);
      expect(scene.target.first.kinds.single.kind, 'event');
      expect(scene.target.first.kinds.single.to, 'end_badend14');
      expect(scene.target.last.require, isNull);
      expect(scene.target.last.isFallback, isTrue);
      expect(scene.target.last.kinds.single.to, '1-7day');
    });

    test('require 写空串等同于没写（兜底块）', () {
      final block = TargetBlock.fromJson(const {
        'require': '   ',
        'kind': [
          {'kind': 'appShell', 'to': 'home'},
        ],
      });
      expect(block.require, isNull);
      expect(block.isFallback, isTrue);
      expect(block.kinds.single.kind, 'appShell');
    });

    test('kind 的出口目的地不再有 weight（块内等概率）', () {
      final block = TargetBlock.fromJson(const {
        'kind': [
          {'kind': 'story', 'to': 'a', 'weight': 3},
          {'kind': 'story', 'to': 'b'},
        ],
      });
      // weight 只是被忽略：两条目的地都留下，判定时等概率
      expect(block.kinds.map((k) => k.to), ['a', 'b']);
    });

    test('ExitTarget 缺 kind 或 to → 报错', () {
      expect(
        () => ExitTarget.fromJson(const {'kind': 'story'}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('initialWorldFor：注册表默认值 + 入场 fixedEffects', () {
    PackageContent contentWith(Map<String, Object?> entryJson) {
      return PackageLoader.fromFiles({
        'manifest.json': '''
{
  "packageId": "p",
  "version": "1",
  "name": "n",
  "author": "a",
  "description": "d",
  "variables": [
    { "id": "day", "type": "int", "default": 1, "min": 1, "max": 9999 },
    { "id": "戒戒好感", "type": "int", "default": 50, "min": 0, "max": 100 }
  ]
}
''',
        'home.png': '',
        'stories/start.json': _encode(entryJson),
      });
    }

    test('正数为加、负数为减，day 缺省是 1', () {
      final content = contentWith({
        'displayName': '开始',
        'fixedEffects': [
          {'id': '戒戒好感', 'value': -20},
          {'id': 'day', 'value': 2},
        ],
      });
      final world = initialWorldFor(content);
      expect(world.variables['戒戒好感'], 30, reason: '50 - 20');
      expect(world.variables['day'], 3, reason: '1 + 2');
      expect(world.rngState, 1);
    });

    test('不再有 segment / endingId：story 只是 day 的镜像', () {
      final content = contentWith(const {'displayName': '开始'});
      final world = initialWorldFor(content);
      expect(world.variables.containsKey('segment'), isFalse);
      expect(world.variables.containsKey('endingId'), isFalse);
      expect(world.story['storyId'], 'start');
      expect(world.story['day'], world.variables['day']);
      expect(world.presentation['cursor'], isA<Map>());
    });

    test('manifest 常量：入口固定 start、主页背景固定 home.png', () {
      expect(PackageManifest.entrypointId, 'start');
      expect(PackageManifest.homeBackgroundFile, 'home.png');
    });
  });
}

String _encode(Map<String, Object?> json) => jsonEncode(json);
