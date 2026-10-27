import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 事件的**选择题出口**（`choice`）：事件专有，与 `target` 二选一。
///
/// 选择题 = 播完最后一屏后，把选项铺给玩家点；选项直接写去哪，
/// 不判数值、不随机。所以它既不需要 `require`，也没有权重。

/// 一个最小合规包，事件正文由参数给。
Map<String, String> packWithEvent(String eventBody) => {
      'manifest.json': '{"packageId":"demo.choice","version":"1","name":"示例包",'
          '"author":"t","description":"d",'
          '"variables":[{"id":"day","type":"int","default":1}]}',
      'home.png': '',
      'stories/bg.png': '',
      'characters/demo/character.json':
          '{"id":"demo","prompt":"你是 demo。","states":["便服"],"emotions":["平常"],'
              '"defaultState":"便服","defaultEmotion":"平常"}',
      'characters/demo/便服_平常.png': '',
      'stories/start.json': '{"displayName":"第一幕","background":"bg.png",'
          '"narration":"n",'
          '"characters":[{"charId":"demo","state":"便服","emotion":"平常",'
          '"scenePrompt":"本幕：家里。"}],'
          '"fixedEffects":[],'
          '"target":[{"kind":[{"kind":"story","to":"第二幕"}]}]}',
      'stories/第二幕.json': '{"displayName":"第二幕","background":"bg.png",'
          '"narration":"n",'
          '"characters":[{"charId":"demo","state":"便服","emotion":"平常",'
          '"scenePrompt":"本幕：学校。"}],'
          '"fixedEffects":[],"target":[]}',
      'events/end_demo/event.json': eventBody,
      'events/end_demo/cover.png': '',
    };

ValidationReport validate(String eventBody) => const PackageValidator()
    .validate(PackageLoader.fromFiles(packWithEvent(eventBody)));

/// 手工拼一份 PackageContent：loader 对悬空出口会直接 fail fast，
/// 想单独测校验器的引用完整性就不能走 loader。
PackageContent contentOf(EventDef event) => PackageContent(
      manifest: const PackageManifest(
        packageId: 'p',
        version: '7',
        name: 'n',
        author: 'a',
        description: 'd',
      ),
      characters: const [],
      variables: const [],
      scenes: {
        'start': SceneDef.fromJson(const {'displayName': '第一幕'}, id: 'start'),
      },
      sceneGraph: SceneGraph(
        scenes: {
          'start':
              SceneDef.fromJson(const {'displayName': '第一幕'}, id: 'start'),
        },
        entrypoint: 'start',
      ),
      eventDefs: {'end_demo': event},
    );

/// 一个合法的事件：一块 slides + 选择题出口。
String eventWithChoice(String choice) =>
    '{"slides":[{"image":"cover.png","text":["结束了。"]}],"choice":$choice}';

void main() {
  test('合法选择题：标题 + 两个选项（回主页 / 去情景）→ 通过', () {
    final report = validate(
      eventWithChoice(
        '{"title":"要继续留在这里吗？",'
        '"options":['
        '{"text":"回到主页","kind":"appShell","to":"home"},'
        '{"text":"继续留在这里","kind":"story","to":"第二幕"}]}',
      ),
    );
    expect(report.isValid, isTrue, reason: report.toString());
  });

  test('标题可以留空，选项也能指向另一个事件', () {
    final report = validate(
      eventWithChoice(
        '{"options":[{"text":"看下一段","kind":"event","to":"end_demo"}]}',
      ),
    );
    expect(report.isValid, isTrue, reason: report.toString());
  });

  test('choice 与 target 同时写 → error（出口二选一）', () {
    final report = validate(
      '{"slides":[{"image":"cover.png","text":["结束了。"]}],'
      '"target":[{"kind":[{"kind":"appShell","to":"home"}]}],'
      '"choice":{"options":[{"text":"回主页","kind":"appShell","to":"home"}]}}',
    );
    expect(report.isValid, isFalse);
    expect(
      report.errors.any((e) => e.message.contains('二选一')),
      isTrue,
      reason: report.toString(),
    );
  });

  test('选项超过 5 个 → error', () {
    final options = <String>[
      for (var i = 1; i <= 6; i++)
        '{"text":"选项$i","kind":"appShell","to":"home"}',
    ].join(',');
    final report = validate(eventWithChoice('{"options":[$options]}'));
    expect(report.isValid, isFalse);
    expect(
      report.errors.any((e) => e.message.contains('最多 5 个选项')),
      isTrue,
      reason: report.toString(),
    );
  });

  test('一个选项都没有 → error（玩家点到最后一屏没得选）', () {
    final report = validate(eventWithChoice('{"options":[]}'));
    expect(report.isValid, isFalse);
    expect(
      report.errors.any((e) => e.message.contains('至少要有一个选项')),
      isTrue,
      reason: report.toString(),
    );
  });

  test('选项没写字 → error（会是一个空按钮）', () {
    final report = validate(
      eventWithChoice(
        '{"options":[{"text":"","kind":"appShell","to":"home"}]}',
      ),
    );
    expect(report.isValid, isFalse);
    expect(
      report.errors.any((e) => e.message.contains('空按钮')),
      isTrue,
      reason: report.toString(),
    );
  });

  test('选项指向不存在的情景 / 事件 → error', () {
    EventDef withOption(String kind, String to) => EventDef.fromJson(
          {
            'slides': [
              {
                'image': null,
                'text': ['结束了。'],
              },
            ],
            'choice': {
              'options': [
                {'text': '去那边', 'kind': kind, 'to': to},
              ],
            },
          },
          id: 'end_demo',
        );

    final missingScene =
        const PackageValidator().validate(contentOf(withOption('story', '第三幕')));
    expect(missingScene.isValid, isFalse);
    expect(
      missingScene.errors.any((e) => e.code == ErrorCodes.unknownReference),
      isTrue,
      reason: missingScene.toString(),
    );

    final missingEvent =
        const PackageValidator().validate(contentOf(withOption('event', 'end_ghost')));
    expect(missingEvent.isValid, isFalse);
    expect(
      missingEvent.errors.any((e) => e.code == ErrorCodes.unknownEvent),
      isTrue,
      reason: missingEvent.toString(),
    );

    final badKind = const PackageValidator()
        .validate(contentOf(withOption('video', 'x')));
    expect(badKind.isValid, isFalse);
  });

  test('装载期就 fail fast：选项指向不存在的情景 → 抛错', () {
    expect(
      () => PackageLoader.fromFiles(
        packWithEvent(
          eventWithChoice(
            '{"options":[{"text":"去那边","kind":"story","to":"第三幕"}]}',
          ),
        ),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('EventDef 解析与写回：有 choice 时不写 target', () {
    final def = EventDef.fromJson(
      {
        'slides': [
          {
            'image': 'cover.png',
            'text': ['结束了。'],
          },
        ],
        'choice': {
          'title': '要继续留在这里吗？',
          'options': [
            {'text': '回到主页', 'kind': 'appShell', 'to': 'home'},
            {'text': '继续留在这里', 'kind': 'story', 'to': '第二幕'},
          ],
        },
      },
      id: 'end_demo',
    );
    expect(def.hasChoice, isTrue);
    expect(def.choice!.title, '要继续留在这里吗？');
    expect(def.choice!.options.map((o) => o.text), ['回到主页', '继续留在这里']);
    expect(def.choice!.options.first.target.kind, 'appShell');
    expect(def.target, isEmpty);

    final json = def.toJson();
    expect(json.containsKey('choice'), isTrue);
    expect(json.containsKey('target'), isFalse);
  });

  test('没有 choice 的事件照旧写 target', () {
    final def = EventDef.fromJson(
      {
        'slides': [
          {
            'image': null,
            'text': ['结束了。'],
          },
        ],
        'target': [
          {
            'kind': [
              {'kind': 'appShell', 'to': 'home'},
            ],
          },
        ],
      },
      id: 'end_demo',
    );
    expect(def.hasChoice, isFalse);
    final json = def.toJson();
    expect(json.containsKey('choice'), isFalse);
    expect(json['target'], hasLength(1));
  });

  test('choice 写成数组 / 字符串 → 解析期报错，不当成「没写」（复审：出口会静默消失）', () {
    // 数组（照着 target 抄错了）、字符串都是一眼像对的写法：
    // 静默当成「没写」会让作者的出口凭空消失。
    for (final bad in const ['[ ]', '"home"']) {
      try {
        PackageLoader.fromFiles(
          packWithEvent(
            '{"slides":[{"image":null,"text":["一句"]}],"choice":$bad}',
          ),
        );
        fail('choice=$bad 应该被拒绝');
      } on PackageFormatException catch (e) {
        expect(e.errors.single.path, '/events/end_demo/choice', reason: bad);
        expect(e.errors.single.message, contains('必须是对象'), reason: bad);
      }
    }
  });

  test('target 写成对象 → 解析期报错（同样不能静默当成没有出口）', () {
    expect(
      () => PackageLoader.fromFiles(
        packWithEvent(
          '{"slides":[{"image":null,"text":["一句"]}],'
          '"target":{"kind":[{"kind":"appShell","to":"home"}]}}',
        ),
      ),
      throwsA(isA<PackageFormatException>()),
    );
  });

  test('choice 的选项写坏（缺 to）→ 装载期报错并点名是哪个事件', () {
    try {
      PackageLoader.fromFiles(
        packWithEvent(
          '{"slides":[{"image":null,"text":["一句"]}],'
          '"choice":{"options":[{"text":"回去","kind":"appShell"}]}}',
        ),
      );
      fail('缺 to 的选项应该被拒绝');
    } on ArgumentError catch (e) {
      expect('${e.message}', contains('end_demo'));
    }
  });

  test('choice 存在但没有选项 → toJson 不会把有效的 target 丢掉', () {
    final def = EventDef.fromJson(
      {
        'slides': [
          {
            'image': null,
            'text': ['结束了。'],
          },
        ],
        // 结构合法、但没有选项：hasChoice 为假，等于没写选择题
        'choice': {'options': <Object?>[]},
        'target': [
          {
            'kind': [
              {'kind': 'appShell', 'to': 'home'},
            ],
          },
        ],
      },
      id: 'end_demo',
    );
    expect(def.hasChoice, isFalse);
    final json = def.toJson();
    expect(json.containsKey('choice'), isFalse);
    expect(json['target'], hasLength(1));
  });

  test('appShell 只认 home（复审：体检/装载都得拦，不然按钮文字与去向对不上）', () {
    final bad = validate(
      eventWithChoice(
        '{"options":[{"text":"回设置","kind":"appShell","to":"settings"}]}',
      ),
    );
    expect(bad.isValid, isFalse);
    expect(
      bad.errors.any((e) => e.message.contains('appShell 只能去 home')),
      isTrue,
      reason: bad.toString(),
    );

    // 情景的出口块同样受这条约束（同一份 _validateExitTarget）
    final files = packWithEvent(
      eventWithChoice(
        '{"options":[{"text":"回主页","kind":"appShell","to":"home"}]}',
      ),
    );
    files['stories/第二幕.json'] = '{"displayName":"第二幕","narration":"n",'
        '"fixedEffects":[],'
        '"target":[{"kind":[{"kind":"appShell","to":"settings"}]}]}';
    final report =
        const PackageValidator().validate(PackageLoader.fromFiles(files));
    expect(report.isValid, isFalse);
    expect(
      report.errors.any((e) => e.message.contains('appShell 只能去 home')),
      isTrue,
      reason: report.toString(),
    );
  });
}
