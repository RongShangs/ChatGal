import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 校验器拦的是**作者面**的契约：情景/事件的 `target` 出口、`require` 表达式、
/// 变量注册、立绘齐全、资源存在。
///
/// 这一版把「引擎层固定约定」也一起降级了：
/// * `home.png` 缺失只是 warning（主页用主题色兜底，包照样能装）；
/// * `target` 为空只是 warning（「到此为止」是合法情景）；
/// * 不再要求出口末条必须是无条件兜底 —— 判定改成「首个 require 成立者锁定」。
Map<String, String> pack() => {
      'manifest.json': '''
{
  //包身份
  "packageId": "demo.pack",
  "version": "7",
  "name": "示例包",
  "author": "t",
  "description": "d",
  "variables": [
    { "id": "day", "type": "int", "default": 1, "min": 1, "max": 9999 },
    { "id": "demo好感", "type": "int", "default": 50, "min": 0, "max": 100, "role": "affection" },
    { "id": "demo信任", "type": "int", "default": 50, "min": 0, "max": 100, "role": "trust" }
  ]
}
''',
      'home.png': '',
      'stories/bg.png': '',
      'characters/demo/character.json': '''
{
  "id": "demo",
  "prompt": "你是 demo。",
  "defaultState": "便服",
  "defaultEmotion": "平常",
  "states": ["便服", "睡裙"],
  "emotions": ["平常", "开心"]
}
''',
      for (final st in const ['便服', '睡裙'])
        for (final em in const ['平常', '开心'])
          'characters/demo/${st}_$em.png': '',
      'stories/start.json': '''
{
  "displayName": "第 1 天 · 白天",
  "background": "bg.png",
  "narration": "开场词",
  "atmosphere": "窗外下着雨。",
  "characters": [
    { "charId": "demo", "state": "便服", "emotion": "平常", "scenePrompt": "本幕：出租屋，第一天。" }
  ],
  // start 就是第 1 天：不在这里加 day（「入口 +1」要配 day 默认 0，见 day 约定的那条用例）
  "fixedEffects": [],
  "settlement": [
    { "var": "demo好感", "prompt": "本幕她是否更亲近：有明确证据才给整数增量，否则 0。", "maxAbsDelta": 3 },
    { "var": "demo信任", "prompt": "本幕她是否更敢把事情交给你：有证据才给增量，否则 0。", "maxAbsDelta": 3 }
  ],
  "target": [
    {
      "require": "\\"day\\" >= 7 & \\"demo好感\\" < 60",
      "kind": [ { "kind": "event", "to": "end_demo" } ]
    },
    {
      "require": "\\"day\\" >= 7",
      "kind": [ { "kind": "story", "to": "s1" } ]
    },
    {
      "kind": [ { "kind": "story", "to": "start" } ]
    }
  ]
}
''',
      'stories/s1.json': '''
{
  "displayName": "第 2 天",
  "characters": [
    { "charId": "demo", "state": "睡裙", "emotion": "开心", "scenePrompt": "本幕：第二天。" }
  ],
  "target": [
    { "kind": [ { "kind": "story", "to": "start" } ] }
  ]
}
''',
      'events/end_demo/event.json': '''
{
  "slides": [
    { "image": "cover.png", "text": ["第一句", "第二句"] },
    { "image": null, "text": ["第三句"] }
  ],
  "target": [
    { "kind": [ { "kind": "story", "to": "start" } ] }
  ]
}
''',
      'events/end_demo/cover.png': '',
    };

ValidationReport validate(Map<String, String> files) =>
    const PackageValidator().validate(PackageLoader.fromFiles(files));

void main() {
  test('示例包是合规 v2：三幕（start + 一个情景 + 一个事件）+ 中文变量', () {
    final content = PackageLoader.fromFiles(pack());
    final report = const PackageValidator().validate(content);
    expect(report.isValid, isTrue, reason: report.toString());
    expect(report.warnings, isEmpty, reason: report.toString());
    expect(content.scenes.keys.toSet(), {'start', 's1'});
    expect(content.sceneGraph!.entrypoint, 'start');
    expect(content.eventDefs.keys, ['end_demo']);
    // 角色变量在同一个扁平表里，属主按最长角色 id 前缀推导
    final reg = content.variableRegistry;
    expect(reg.ownerOf('demo信任'), 'demo');
    expect(reg.defaults['demo好感'], 50);
  });

  test('require 是合法中缀表达式：解析通过、引用的变量都注册过', () {
    final report = validate(pack());
    expect(report.isValid, isTrue, reason: report.toString());
  });

  group('day 默认值要和「入口那一幕」配套（约定：默认 0 + 入场 +1 = 第 1 天）', () {
    /// 把 day 的默认值改掉（原 fixture 是 1）。
    void setDayDefault(Map<String, String> files, String value) {
      files['manifest.json'] = files['manifest.json']!.replaceFirst(
        '{ "id": "day", "type": "int", "default": 1, "min": 1, "max": 9999 }',
        '{ "id": "day", "type": "int", "default": $value }',
      );
    }

    /// 给 start 的入场改值塞一条 day +1。
    void bumpDayAtStart(Map<String, String> files) {
      files['stories/start.json'] = files['stories/start.json']!.replaceFirst(
        '"fixedEffects": []',
        '"fixedEffects": [ { "id": "day", "value": 1 } ]',
      );
    }

    test('默认 0 + 入口 day +1 → 不报警（默认包 / 教学包都是这套写法）', () {
      final files = pack();
      setDayDefault(files, '0');
      bumpDayAtStart(files);
      final report = validate(files);
      expect(report.isValid, isTrue, reason: report.toString());
      expect(report.warnings, isEmpty, reason: report.toString());
    });

    test('默认 0 但入口没写 day +1 → warning（开局会停在第 0 天）', () {
      final files = pack();
      setDayDefault(files, '0');
      final report = validate(files);
      expect(report.isValid, isTrue, reason: report.toString());
      expect(
        report.warnings.any(
          (w) => w.path == '/stories/start.json/fixedEffects',
        ),
        isTrue,
        reason: report.toString(),
      );
    });

    test('入口写了 day +1 但默认值还是 1 → warning（开局直接第 2 天）', () {
      final files = pack();
      bumpDayAtStart(files);
      final report = validate(files);
      expect(report.isValid, isTrue, reason: report.toString());
      expect(
        report.warnings.any((w) => w.path == '/manifest/variables/day/default'),
        isTrue,
        reason: report.toString(),
      );
    });

    test('默认 1、入口不加（不用 +1 约定的包）→ 不报警，也不拦', () {
      final files = pack();
      final report = validate(files);
      expect(report.isValid, isTrue, reason: report.toString());
      expect(report.warnings, isEmpty, reason: report.toString());
    });

    test('入口里给别的变量加值不算（只盯 day）', () {
      final files = pack();
      files['stories/start.json'] = files['stories/start.json']!.replaceFirst(
        '"fixedEffects": []',
        '"fixedEffects": [ { "id": "demo好感", "value": 5 } ]',
      );
      final report = validate(files);
      expect(report.warnings, isEmpty, reason: report.toString());
    });
  });

  test('require 语法错 → error（装载期就拦，不留到运行时）', () {
    final files = pack();
    files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "target": [
    { "require": "\\"day\\" = 7", "kind": [ { "kind": "story", "to": "start" } ] }
  ]
}
''';
    final report = validate(files);
    expect(report.isValid, isFalse);
    expect(
      report.errors.any((e) => e.message.contains('require') && e.path.contains('target/0/require')),
      isTrue,
      reason: report.toString(),
    );
  });

  test('require 引用未注册变量 → error（读不到值 = 条件恒假）', () {
    final files = pack();
    files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "target": [
    { "require": "\\"打错名字\\" > 1", "kind": [ { "kind": "story", "to": "start" } ] }
  ]
}
''';
    final report = validate(files);
    expect(report.isValid, isFalse);
    expect(report.errors.any((e) => e.code == ErrorCodes.unknownVariable), isTrue);
  });

  test('target 为空只是 warning：「到此为止」是合法情景', () {
    final files = pack();
    files['stories/s1.json'] = '{"displayName":"第 2 天"}';
    final report = validate(files);
    expect(report.isValid, isTrue, reason: report.toString());
    expect(
      report.warnings.any((w) => w.path == '/stories/s1.json/target'),
      isTrue,
      reason: report.toString(),
    );
  });

  test('走不到的情景报 warning（新写一幕却忘了接出口）', () {
    final files = pack();
    // 把 start 复制成一份孤儿幕：没有任何出口指向它。
    files['stories/orphan.json'] = files['stories/start.json']!;
    final report = validate(files);
    expect(report.isValid, isTrue, reason: '只报 warning，不该拦包');
    expect(
      report.warnings.any((w) => w.path == '/stories/orphan.json'),
      isTrue,
      reason: report.toString(),
    );
  });

  test('可达的情景不报可达性 warning（示例包本身干净）', () {
    // 上一条的反面：能走到的幕不能被误报。
    final report = validate(pack());
    expect(report.warnings, isEmpty, reason: report.toString());
  });

  test('出口末条不是兜底也合规（首个 require 成立者锁定）', () {
    final files = pack();
    files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "target": [
    { "require": "\\"day\\" > 999", "kind": [ { "kind": "story", "to": "start" } ] }
  ]
}
''';
    final report = validate(files);
    expect(report.isValid, isTrue, reason: report.toString());
  });

  test('缺 home.png 从 error 降为 warning（主页会用主题色兜底）', () {
    final files = pack()..remove('home.png');
    final report = validate(files);
    expect(report.isValid, isTrue, reason: report.toString());
    expect(
      report.warnings.any((w) => w.path == '/home.png'),
      isTrue,
      reason: report.toString(),
    );
  });

  test('graph.json / assets/ 仍然一律禁止', () {
    final files = pack()
      ..['graph.json'] = '{"endingChecks":[]}'
      ..['assets/index.json'] = '{"assets":[]}'
      ..['assets/bg/xx.png'] = '';
    final report = validate(files);
    expect(report.isValid, isFalse);
    expect(
      report.errors.map((e) => e.code),
      contains(ErrorCodes.forbiddenField),
    );
    expect(
      report.errors.where((e) => e.path.contains('assets')).length,
      greaterThanOrEqualTo(2),
    );
  });

  test('一个角色都没有 → error（没有角色就没人可对话）', () {
    final files = pack();
    files.removeWhere((k, _) => k.startsWith('characters/'));
    final report = validate(files);
    expect(report.isValid, isFalse);
    expect(
      report.errors.any((e) => e.message.contains('至少要有一个角色')),
      isTrue,
      reason: report.toString(),
    );
    // 同时：情景里点名的 charId 也会各自报错（角色目录没了）
    expect(
      report.errors.any((e) => e.message.contains('没有对应的 characters/')),
      isTrue,
    );
  });

  test('某幕没有出场角色 → warning（能装，但那一幕没人可对话）', () {
    final files = pack();
    files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "target": [ { "kind": [ { "kind": "story", "to": "start" } ] } ]
}
''';
    final report = validate(files);
    expect(report.isValid, isTrue, reason: report.toString());
    expect(
      report.warnings.any((w) => w.message.contains('没有出场角色')),
      isTrue,
      reason: report.toString(),
    );
  });

  test('缺立绘（states × emotions 不齐）要报错并点名缺哪一张', () {
    final files = pack()..remove('characters/demo/睡裙_开心.png');
    final report = validate(files);
    expect(report.isValid, isFalse);
    expect(
      report.errors.any((e) => e.message.contains('睡裙_开心')),
      isTrue,
      reason: report.toString(),
    );
    // 命名约定是唯一来源：报错里带上「<状态>_<情绪>.png」
    expect(
      report.errors
          .firstWhere((e) => e.message.contains('睡裙_开心'))
          .path,
      '/characters/demo',
    );
  });

  test('角色没声明 states / emotions → 报错', () {
    final files = pack();
    files['characters/demo/character.json'] =
        '{"id":"demo","prompt":"你。","states":[],"emotions":[]}';
    final report = validate(files);
    expect(report.isValid, isFalse);
    expect(report.errors.any((e) => e.message.contains('states')), isTrue);
    expect(report.errors.any((e) => e.message.contains('emotions')), isTrue);
  });

  test('defaultState / defaultEmotion 不在声明里 → 报错', () {
    final files = pack();
    files['characters/demo/character.json'] = '''
{
  "id": "demo",
  "prompt": "你。",
  "defaultState": "校服",
  "defaultEmotion": "生气",
  "states": ["便服"],
  "emotions": ["平常"]
}
''';
    final report = validate(files);
    expect(report.isValid, isFalse);
    expect(report.errors.any((e) => e.path.endsWith('/defaultState')), isTrue);
    expect(report.errors.any((e) => e.path.endsWith('/defaultEmotion')), isTrue);
  });

  test('情景引用了不存在的 charId → 报错', () {
    final files = pack();
    files['stories/start.json'] =
        files['stories/start.json']!.replaceAll('"charId": "demo"', '"charId": "幽灵"');
    final report = validate(files);
    expect(report.isValid, isFalse);
    expect(report.errors.any((e) => e.code == ErrorCodes.unknownCharacter), isTrue);
  });

  test('background 指向不存在的图 → 报错', () {
    final files = pack();
    files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "background": "nope.png",
  "target": [ { "kind": [ { "kind": "story", "to": "start" } ] } ]
}
''';
    final report = validate(files);
    expect(report.isValid, isFalse);
    expect(report.errors.any((e) => e.hint == 'nope.png'), isTrue);
  });

  group('settlement：每个变量一个块（自己的提示词 + 自己的上限）', () {
    test('不写 settlement → 本幕不结算，合规', () {
      final files = pack();
      files['stories/start.json'] = '''
{
  "displayName": "第 1 天",
  "target": [ { "kind": [ { "kind": "story", "to": "start" } ] } ]
}
''';
      expect(validate(files).isValid, isTrue);
    });

    test('块里没写 prompt → 报错（模型不知道该按什么标准加减）', () {
      final files = pack();
      files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "settlement": [ { "var": "demo好感" } ],
  "target": [ { "kind": [ { "kind": "story", "to": "start" } ] } ]
}
''';
      final report = validate(files);
      expect(report.isValid, isFalse);
      expect(
        report.errors.any((e) => e.path.endsWith('/settlement/0/prompt')),
        isTrue,
        reason: report.toString(),
      );
    });

    test('块里没写 var → 加载期就抛（不能静默少结算一个变量）', () {
      final files = pack();
      files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "settlement": [ { "prompt": "忘了写变量" } ],
  "target": [ { "kind": [ { "kind": "story", "to": "start" } ] } ]
}
''';
      expect(() => validate(files), throwsA(isA<ArgumentError>()));
    });

    test('settlement 引用未注册变量 → 报错', () {
      final files = pack();
      files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "settlement": [ { "var": "打错名字", "prompt": "给增量" } ],
  "target": [ { "kind": [ { "kind": "story", "to": "start" } ] } ]
}
''';
      final report = validate(files);
      expect(report.isValid, isFalse);
      expect(report.errors.any((e) => e.code == ErrorCodes.unknownVariable), isTrue);
    });

    test('同一个变量写两个块 → 报错（要合并成一条）', () {
      final files = pack();
      files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "settlement": [
    { "var": "demo好感", "prompt": "a" },
    { "var": "demo好感", "prompt": "b" }
  ],
  "target": [ { "kind": [ { "kind": "story", "to": "start" } ] } ]
}
''';
      final report = validate(files);
      expect(report.isValid, isFalse);
      expect(report.errors.any((e) => e.code == ErrorCodes.duplicateId), isTrue);
    });

    test('onNoEvidence 只能是 zero / abort', () {
      final files = pack();
      files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "settlement": [ { "var": "demo好感", "prompt": "给增量", "onNoEvidence": "random" } ],
  "target": [ { "kind": [ { "kind": "story", "to": "start" } ] } ]
}
''';
      final report = validate(files);
      expect(report.isValid, isFalse);
      expect(
        report.errors.any((e) => e.path.endsWith('/settlement/0/onNoEvidence')),
        isTrue,
      );
    });

    test('maxAbsDelta 必须为正', () {
      final files = pack();
      files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "settlement": [ { "var": "demo好感", "prompt": "给增量", "maxAbsDelta": 0 } ],
  "target": [ { "kind": [ { "kind": "story", "to": "start" } ] } ]
}
''';
      expect(validate(files).isValid, isFalse);
    });

    test('结算只能作用于数值变量（字符串变量 → 报错）', () {
      final files = pack();
      files['manifest.json'] = '''
{
  "packageId": "demo.pack",
  "version": "1",
  "name": "示例",
  "variables": [
    { "id": "day", "type": "int", "default": 1, "min": 1 },
    { "id": "demo好感", "type": "int", "default": 50 },
    { "id": "备注", "type": "string", "default": "" }
  ]
}
''';
      files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "settlement": [ { "var": "备注", "prompt": "给增量" } ],
  "target": [ { "kind": [ { "kind": "story", "to": "start" } ] } ]
}
''';
      final report = validate(files);
      expect(report.isValid, isFalse);
      expect(report.errors.any((e) => e.code == ErrorCodes.invalidType), isTrue);
    });

  });

  group('fixedEffects：正加负减，所以只能作用在数值变量上', () {
    test('未注册变量 → 报错', () {
      final files = pack();
      files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "fixedEffects": [ { "id": "打错名字", "value": 1 } ],
  "target": [ { "kind": [ { "kind": "story", "to": "start" } ] } ]
}
''';
      final report = validate(files);
      expect(report.isValid, isFalse);
      expect(report.errors.any((e) => e.code == ErrorCodes.unknownVariable), isTrue);
    });

    test('作用在非数值变量上 → 报错', () {
      final files = pack();
      files['manifest.json'] = files['manifest.json']!.replaceFirst(
        '{ "id": "day", "type": "int", "default": 1, "min": 1, "max": 9999 },',
        '{ "id": "day", "type": "int", "default": 1, "min": 1, "max": 9999 },\n'
            '    { "id": "flag", "type": "bool", "default": false },',
      );
      files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "fixedEffects": [ { "id": "flag", "value": 1 } ],
  "target": [ { "kind": [ { "kind": "story", "to": "start" } ] } ]
}
''';
      final report = validate(files);
      expect(report.isValid, isFalse);
      expect(report.errors.any((e) => e.code == ErrorCodes.invalidType), isTrue);
    });

    test('value 为 0 → 报错（这条什么也不做，应该删掉）', () {
      final files = pack();
      files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "fixedEffects": [ { "id": "day", "value": 0 } ],
  "target": [ { "kind": [ { "kind": "story", "to": "start" } ] } ]
}
''';
      final report = validate(files);
      expect(report.isValid, isFalse);
      expect(report.errors.any((e) => e.path.endsWith('/fixedEffects/0/value')), isTrue);
    });

    test('负数（减）是合法的', () {
      final files = pack();
      files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "fixedEffects": [ { "id": "demo好感", "value": -5 } ],
  "target": [ { "kind": [ { "kind": "story", "to": "start" } ] } ]
}
''';
      expect(validate(files).isValid, isTrue);
    });
  });

  group('事件的图片按 events/<id>/<image> 校验', () {
    test('图片不存在 → 报错并给出实际路径', () {
      final files = pack();
      files['events/end_demo/event.json'] = '''
{
  "slides": [ { "image": "nope.png", "text": ["一句"] } ],
  "target": [ { "kind": [ { "kind": "story", "to": "start" } ] } ]
}
''';
      final report = validate(files);
      expect(report.isValid, isFalse);
      expect(report.errors.any((e) => e.hint == 'events/end_demo/nope.png'), isTrue);
    });

    test('image: null（沿用上一张）不参与校验', () {
      final report = validate(pack());
      expect(report.isValid, isTrue, reason: report.toString());
    });

    test('events 没有出口只是 warning', () {
      final files = pack();
      files['events/end_demo/event.json'] = '''
{ "slides": [ { "image": "cover.png", "text": ["一句"] } ] }
''';
      final report = validate(files);
      expect(report.isValid, isTrue, reason: report.toString());
      expect(
        report.warnings.any((w) => w.path == '/events/end_demo/event.json/target'),
        isTrue,
      );
    });

    test('事件没有任何 slides → 报错', () {
      final files = pack();
      files['events/end_demo/event.json'] = '{"slides":[]}';
      expect(validate(files).isValid, isFalse);
    });
  });

  group('出口与情景/事件的引用完整性', () {
    /// 手工拼一份 PackageContent：loader 对悬空出口会直接 fail fast，
    /// 所以想单独测校验器这几条判断，就不能走 loader。
    PackageContent contentOf({
      required Map<String, SceneDef> scenes,
      Map<String, EventDef> eventDefs = const {},
    }) =>
        PackageContent(
          manifest: const PackageManifest(
            packageId: 'p',
            version: '7',
            name: 'n',
            author: 'a',
            description: 'd',
          ),
          characters: const [],
          variables: const [],
          scenes: scenes,
          sceneGraph: SceneGraph(scenes: scenes, entrypoint: 'start'),
          eventDefs: eventDefs,
        );

    SceneDef sceneWith(String id, List<Map<String, Object?>> target) =>
        SceneDef.fromJson({'displayName': '第 2 天', 'target': target}, id: id);

    test('出口指向不存在的情景 / 事件 → 报错', () {
      final report = const PackageValidator().validate(
        contentOf(
          scenes: {
            'start': sceneWith('start', const [
              {
                'kind': [
                  {'kind': 'story', 'to': '没有这一幕'},
                ],
              },
              {
                'kind': [
                  {'kind': 'event', 'to': '没有这个事件'},
                ],
              },
            ]),
          },
        ),
      );
      expect(report.isValid, isFalse);
      expect(
        report.errors.any((e) => e.code == ErrorCodes.unknownReference),
        isTrue,
        reason: report.toString(),
      );
      expect(
        report.errors.any((e) => e.code == ErrorCodes.unknownEvent),
        isTrue,
        reason: report.toString(),
      );
    });

    test('kind 不支持的出口目的地 → 报错', () {
      final report = const PackageValidator().validate(
        contentOf(
          scenes: {
            'start': sceneWith('start', const [
              {
                'kind': [
                  {'kind': 'video', 'to': 'x'},
                ],
              },
            ]),
          },
        ),
      );
      expect(report.isValid, isFalse);
      expect(report.errors.any((e) => e.path.endsWith('/kind/0/kind')), isTrue);
    });

    test('appShell 出口不需要 to 指向任何文件', () {
      final files = pack();
      files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "target": [ { "kind": [ { "kind": "appShell", "to": "home" } ] } ]
}
''';
      expect(validate(files).isValid, isTrue);
    });

    test('story 出口也可以指向事件（结局 → 事件）', () {
      final files = pack();
      expect(validate(files).isValid, isTrue);
      final content = PackageLoader.fromFiles(files);
      expect(content.scene('start')!.target.first.kinds.single.to, 'end_demo');
    });
  });

  group('loader 层的硬约束', () {
    test('缺 stories/start.json：加载阶段拒绝（入口固定 start）', () {
      final files = pack()..remove('stories/start.json');
      expect(() => PackageLoader.fromFiles(files), throwsA(isA<StateError>()));
    });

    test('version 不是数字（例如 "1.0.0"）→ manifest 解析阶段就拒绝', () {
      final files = pack();
      files['manifest.json'] = files['manifest.json']!
          .replaceFirst('"version": "7"', '"version": "1.0.0"');
      expect(
        () => PackageLoader.fromFiles(files),
        throwsA(isA<PackageFormatException>()),
      );
    });

    test('packageId 含路径穿越（如 ../outside）→ manifest 解析阶段就拒绝', () {
      final files = pack();
      files['manifest.json'] = files['manifest.json']!
          .replaceFirst('"packageId": "demo.pack"', '"packageId": "../outside"');
      expect(
        () => PackageLoader.fromFiles(files),
        throwsA(isA<PackageFormatException>()),
      );
    });

    test('packageId 含路径分隔符 / 或以点开头 → 拒绝', () {
      for (final bad in const ['a/b', r'a\b', '.hidden', 'a..b', 'a b']) {
        final files = pack();
        files['manifest.json'] = files['manifest.json']!
            .replaceFirst('"packageId": "demo.pack"', '"packageId": "$bad"');
        expect(
          () => PackageLoader.fromFiles(files),
          throwsA(isA<PackageFormatException>()),
          reason: 'packageId=$bad 应该被拒绝',
        );
      }
    });

    test('老字段（schemaVersion / entrypoints / characterVariables …）被忽略：写了也不报错', () {
      final files = pack();
      files['manifest.json'] = files['manifest.json']!
          .replaceFirst('"variables": [', '''
  "schemaVersion": 2,
  "engineCompatibility": "*",
  "entrypoints": ["main"],
  "license": "CC0",
  "contentTags": ["x"],
  "variables": [''');
      final content = PackageLoader.fromFiles(files);
      // 入口仍然固定是 start，不是 manifest 里写的 main
      expect(content.sceneGraph!.entrypoint, 'start');
      expect(content.manifest.version, '7');
    });

    test('v1 布局（stories/main/nodes.json）被拒绝：没有可识别的情景文件', () {
      final files = pack()
        ..remove('stories/start.json')
        ..remove('stories/s1.json')
        ..['stories/main/nodes.json'] = '[{"id":"n1"}]';
      expect(() => PackageLoader.fromFiles(files), throwsA(isA<StateError>()));
    });

    test('出口指向不存在的情景：loader 也 fail fast（不只靠校验器）', () {
      final files = pack();
      files['stories/s1.json'] = '''
{
  "displayName": "第 2 天",
  "target": [ { "kind": [ { "kind": "story", "to": "没有这一幕" } ] } ]
}
''';
      expect(() => PackageLoader.fromFiles(files), throwsA(isA<StateError>()));
    });

    test('情景 id 是文件名 stem：文件里写 id 不生效', () {
      final files = pack();
      files['stories/ji_q.json'] = '{"id":"别的名字","displayName":"晚上·家里"}';
      final content = PackageLoader.fromFiles(files);
      expect(content.scenes.containsKey('ji_q'), isTrue);
      expect(content.scenes.containsKey('别的名字'), isFalse);
      expect(content.scenes['ji_q']!.displayName, '晚上·家里');
    });
  });
}
