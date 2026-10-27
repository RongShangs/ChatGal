import 'dart:io';

import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 默认包五结局的**完整边界矩阵**。
///
/// day7_3（好感生死线）与 day14_3（四块优先级链）的所有临界点：
/// - 59/60：第 7 天好感闸
/// - 119/120：第 14 天好感+信任闸
/// - 35/36、65/66：堕落度闸（箱庭共生 / 心跳加速 / 开始堕落）
///
/// 每个边界都测「差一点进不去」与「刚好进去」两侧，确保条件判定是
/// 闭区间/开区间的正确一侧。
({PackageContent content, SceneGraph graph}) load() {
  final root = Directory(
    '${Directory.current.path}/../../content/default_v2',
  );
  expect(root.existsSync(), isTrue, reason: root.path);
  final rootPath = root.absolute.path.replaceAll(r'\', '/');
  final files = <String, String>{};
  for (final f in root.listSync(recursive: true).whereType<File>()) {
    final rel = f.path.replaceAll(r'\', '/').substring(rootPath.length + 1);
    files[rel] = rel.endsWith('.png') ? '' : f.readAsStringSync();
  }
  final content = PackageLoader.fromFiles(files);
  return (content: content, graph: content.sceneGraph!);
}

/// 从 day7_3 或 day14_3 离场一次，返回路由到的事件或下一幕。
Future<String> leaveFrom(
  PackageContent content,
  SceneGraph graph,
  String sceneId, {
  required int affection,
  required int trust,
  int obedience = 50,
  int depravity = 0,
  int day = 14,
}) async {
  final reg = content.variableRegistry;
  final c = TransitionCoordinator(graph: graph, registry: reg);
  final world = WorldSnapshot(
    variables: {
      ...reg.defaults,
      'day': day,
      '戒戒好感': affection,
      '戒戒信任': trust,
      '戒戒服从': obedience,
      '戒戒堕落': depravity,
    },
    characters: const {},
    eventHistory: const {},
    story: {'storyId': sceneId, 'day': day},
    presentation: const {},
    rngState: 1,
  );
  final r = await c.leaveCurrent(
    sessionId: 's',
    world: world,
    messages: const [],
    baseRevision: 0,
    provider: const MockSettlementProvider(),
    cursor: RuntimeCursor(storyId: sceneId, visitId: 0),
  );
  expect(r.accepted, isTrue, reason: r.error);
  if (r.targetKind == 'event') return r.nextEventId!;
  return r.nextSceneId!;
}

/// 事件播到最后一格。
EventPlayState lastFrameOf(EventCoordinator coord, String id) {
  var s = coord.open(eventId: id, eventVisitId: 0);
  for (;;) {
    final next = coord.advance(s);
    if (next == null) return s;
    s = next;
  }
}

/// 给结局链用的完整变量表（含注册表默认值）。
Map<String, Object?> varsFor(
  PackageContent content, {
  required int affection,
  required int trust,
  required int depravity,
  required int obedience,
  int day = 14,
}) => {
  ...content.variableRegistry.defaults,
  'day': day,
  '戒戒好感': affection,
  '戒戒信任': trust,
  '戒戒服从': obedience,
  '戒戒堕落': depravity,
};

/// 沿**当前内容**的真实链路把第 14 天的结局走完：
///
/// `day14_3` → `end_decision`（打针选择题，按 [optionText] 点）
/// → 点「不注射」时进 `end_no_inject`，在那里按堕落/服从分流 → 终局事件。
///
/// 出口判定用的是运行时那一个 [TargetRouter]，不是测试自己重写一遍条件。
Future<String?> walkEnding(
  PackageContent content, {
  required Map<String, Object?> variables,
  required String optionText,
}) async {
  final coord = EventCoordinator(events: content.eventDefs);
  final router = TargetRouter();
  final world = WorldSnapshot(
    variables: variables,
    characters: const {},
    eventHistory: const {},
    story: const {},
    presentation: const {},
    rngState: 1,
  );

  ExitTarget? pick(String eventId, String text) {
    final draft = coord.finish(lastFrameOf(coord, eventId));
    for (final o in draft.choice?.options ?? const <EventChoiceOption>[]) {
      if (o.text == text) return o.target;
    }
    return null;
  }

  final chosen = pick('end_decision', optionText);
  if (chosen == null) return null;
  if (chosen.kind != 'event') return chosen.to;
  if (chosen.to != 'end_no_inject') return chosen.to;
  final draft = coord.finish(lastFrameOf(coord, 'end_no_inject'));
  return router.route(draft.target, world, rngState: 1)?.to;
}

void main() {
  group('day7_3 好感生死线：59 → badend7，60 → day8_1', () {
    test('好感 59（差一点）→ end_badend7', () async {
      final loaded = load();
      final to = await leaveFrom(
        loaded.content,
        loaded.graph,
        'day7_3',
        affection: 59,
        trust: 60,
        day: 7,
      );
      expect(to, 'end_badend7');
    });

    test('好感 60（刚好过闸）→ day8_1', () async {
      final loaded = load();
      final to = await leaveFrom(
        loaded.content,
        loaded.graph,
        'day7_3',
        affection: 60,
        trust: 60,
        day: 7,
      );
      expect(to, 'day8_1');
    });

    test('好感 0 → end_badend7（远低于闸）', () async {
      final loaded = load();
      final to = await leaveFrom(
        loaded.content,
        loaded.graph,
        'day7_3',
        affection: 0,
        trust: 0,
        day: 7,
      );
      expect(to, 'end_badend7');
    });

    test('好感 100 → day8_1（远高于闸）', () async {
      final loaded = load();
      final to = await leaveFrom(
        loaded.content,
        loaded.graph,
        'day7_3',
        affection: 100,
        trust: 100,
        day: 7,
      );
      expect(to, 'day8_1');
    });
  });

  group('day14_3 好感+信任闸：119 → badend14，120 → 打针选择题', () {
    test('好感 50 + 信任 69 = 119 → end_badend14', () async {
      final loaded = load();
      final to = await leaveFrom(
        loaded.content,
        loaded.graph,
        'day14_3',
        affection: 50,
        trust: 69,
        depravity: 0,
        obedience: 50,
        day: 14,
      );
      expect(to, 'end_badend14');
    });

    test('好感 50 + 信任 70 = 120 → 跳过 badend14，进打针选择题', () async {
      final loaded = load();
      final to = await leaveFrom(
        loaded.content,
        loaded.graph,
        'day14_3',
        affection: 50,
        trust: 70,
        depravity: 0,
        obedience: 50,
        day: 14,
      );
      expect(to, 'end_decision', reason: '好感+信任=120 不触发 badend14，改走选择题事件');
    });

    test('好感 0 + 信任 0 = 0 → end_badend14', () async {
      final loaded = load();
      final to = await leaveFrom(
        loaded.content,
        loaded.graph,
        'day14_3',
        affection: 0,
        trust: 0,
        day: 14,
      );
      expect(to, 'end_badend14');
    });
  });

  group('end_decision 的打针选择：两个选项就是两条线', () {
    test('选项字面与目的地固定：注射→end_csrj / 不注射→end_no_inject', () {
      final loaded = load();
      final choice = loaded.content.eventDefs['end_decision']!.choice;
      expect(choice, isNotNull, reason: 'day14_3 现在是靠这个选择题分流的');
      final byText = {
        for (final o in choice!.options)
          o.text: '${o.target.kind}:${o.target.to}',
      };
      expect(byText, {
        '注射毛至试剂': 'event:end_csrj',
        '不注射，继续共生': 'event:end_no_inject',
      });
    });

    test('点「注射」→ end_csrj（终点事件，堕落/服从再高也不改道）', () async {
      final loaded = load();
      final to = await walkEnding(
        loaded.content,
        variables: varsFor(
          loaded.content,
          affection: 70,
          trust: 70,
          depravity: 100,
          obedience: 100,
        ),
        optionText: '注射毛至试剂',
      );
      expect(to, 'end_csrj');
    });
  });

  group('end_no_inject 分流：堕落/服从的临界（<=65 / >65，>40 且 >75）', () {
    // 前提：好感+信任 >= 120 跳过 badend14，并在打针选择上点「不注射，继续共生」。
    const noInject = '不注射，继续共生';

    Future<String?> fall(int depravity, int obedience) async {
      final loaded = load();
      return walkEnding(
        loaded.content,
        variables: varsFor(
          loaded.content,
          affection: 70,
          trust: 70,
          depravity: depravity,
          obedience: obedience,
        ),
        optionText: noInject,
      );
    }

    test('堕落 65 + 服从 50 → end_xtgs（堕落没超过 65）', () async {
      expect(await fall(65, 50), 'end_xtgs');
    });

    test('堕落 66 + 服从 50 → end_kwdl（堕落刚好超过 65）', () async {
      expect(await fall(66, 50), 'end_kwdl');
    });

    test('堕落 41 + 服从 76 → end_kwdl（堕落>40 且 服从>75）', () async {
      expect(await fall(41, 76), 'end_kwdl');
    });

    test('堕落 41 + 服从 75 → end_xtgs（服从差一点没过 75）', () async {
      expect(await fall(41, 75), 'end_xtgs');
    });

    test('堕落 40 + 服从 100 → end_xtgs（堕落差一点没过 40）', () async {
      expect(await fall(40, 100), 'end_xtgs');
    });

    test('堕落 100 + 服从 100 → end_kwdl', () async {
      expect(await fall(100, 100), 'end_kwdl');
    });
  });

  group('day14_3 组合边界：好感+信任闸与堕落闸的交互', () {
    test('好感+信任=119 且堕落=0 → badend14（第一块优先）', () async {
      final loaded = load();
      final to = await leaveFrom(
        loaded.content,
        loaded.graph,
        'day14_3',
        affection: 59,
        trust: 60,
        depravity: 0,
        obedience: 50,
        day: 14,
      );
      expect(to, 'end_badend14');
    });

    test('好感+信任=120 且堕落=0 → end_decision（跳过 badend14，进打针选择）', () async {
      final loaded = load();
      final to = await leaveFrom(
        loaded.content,
        loaded.graph,
        'day14_3',
        affection: 50,
        trust: 70,
        depravity: 0,
        obedience: 50,
        day: 14,
      );
      expect(to, 'end_decision');
    });

    test('好感+信任=200 且堕落=100 → 不注射后落 kwdl（全过闸后的最终落点）', () async {
      final loaded = load();
      final vars = varsFor(
        loaded.content,
        affection: 100,
        trust: 100,
        depravity: 100,
        obedience: 100,
      );
      // 第 14 天这一步只到选择题
      final to = await leaveFrom(
        loaded.content,
        loaded.graph,
        'day14_3',
        affection: 100,
        trust: 100,
        depravity: 100,
        obedience: 100,
        day: 14,
      );
      expect(to, 'end_decision');
      // 选择「不注射」之后才是数值分流的结果
      expect(
        await walkEnding(
          loaded.content,
          variables: vars,
          optionText: '不注射，继续共生',
        ),
        'end_kwdl',
      );
    });

    test('day != 14 时不触发任何结局块 → appShell 保底', () async {
      // 理论上不会走到这里（主线 day 只会是 14），但保底块要能兜住。
      final loaded = load();
      final reg = loaded.content.variableRegistry;
      final c = TransitionCoordinator(graph: loaded.graph, registry: reg);
      final world = WorldSnapshot(
        variables: {
          ...reg.defaults,
          'day': 13,
          '戒戒好感': 70,
          '戒戒信任': 70,
          '戒戒服从': 50,
          '戒戒堕落': 0,
        },
        characters: const {},
        eventHistory: const {},
        story: const {'storyId': 'day14_3', 'day': 13},
        presentation: const {},
        rngState: 1,
      );
      final r = await c.leaveCurrent(
        sessionId: 's',
        world: world,
        messages: const [],
        baseRevision: 0,
        provider: const MockSettlementProvider(),
        cursor: const RuntimeCursor(storyId: 'day14_3', visitId: 0),
      );
      expect(r.accepted, isTrue, reason: r.error);
      expect(r.targetKind, 'appShell');
    });
  });

  group('七个结局/选择事件都存在且可路由', () {
    // 第 14 天现在多了一层：day14_3 → end_decision（选择题）→ end_no_inject（数值分流）。
    const eventIds = [
      'end_badend7',
      'end_badend14',
      'end_decision',
      'end_no_inject',
      'end_csrj',
      'end_xtgs',
      'end_kwdl',
    ];

    test('七个事件在包里都存在', () {
      final loaded = load();
      for (final id in eventIds) {
        expect(
          loaded.content.eventDefs.containsKey(id),
          isTrue,
          reason: '事件 $id 必须存在',
        );
      }
    });

    test('每个结局事件都有至少一块 slides', () {
      final loaded = load();
      for (final id in eventIds) {
        final e = loaded.content.eventDefs[id]!;
        expect(e.slides, isNotEmpty, reason: '$id 至少要有一块');
        expect(e.frames.length, e.slides.length);
      }
    });
  });

  group('初始值全程回放：从新档到各结局', () {
    /// 从 start 出发走完整主线，用固定结算策略推进数值。
    Future<({String? ending, WorldSnapshot world, int steps})> walkMain(
      PackageContent content,
      SceneGraph graph, {
      required SettlementProvider provider,
      int maxSteps = 80,
    }) async {
      final reg = content.variableRegistry;
      final c = TransitionCoordinator(graph: graph, registry: reg);
      // 必须是**新档的真实初始世界**：day 默认 0 + start 的入场 +1 = 第 1 天。
      // （直接用注册表默认值会停在 day 0，整条链子都少一天。）
      var world = initialWorldFor(content);
      var cursor = const RuntimeCursor(storyId: 'start', visitId: 0);
      final applied = <String>[];
      for (var i = 0; i < maxSteps; i++) {
        final r = await c.leaveCurrent(
          sessionId: 's',
          world: world,
          messages: const [],
          baseRevision: i,
          provider: provider,
          appliedSettlementIds: applied,
          cursor: cursor,
        );
        expect(r.accepted, isTrue, reason: 'step $i: ${r.error}');
        applied.addAll(r.appliedSettlementIds);
        world = r.world!;
        cursor = r.cursor!;
        if (r.targetKind == 'event') {
          return (ending: r.nextEventId, world: world, steps: i + 1);
        }
      }
      return (ending: null, world: world, steps: maxSteps);
    }

    test('低好感策略：第 7 天落 badend7', () async {
      final loaded = load();
      final r = await walkMain(
        loaded.content,
        loaded.graph,
        provider: const MockSettlementProvider(deltas: {'戒戒好感': -1}),
      );
      expect(r.ending, 'end_badend7');
      expect(r.steps, lessThanOrEqualTo(21));
    });

    test('高好感低堕落策略：第 14 天进打针选择，点注射落箱庭共生 csrj', () async {
      final loaded = load();
      final r = await walkMain(
        loaded.content,
        loaded.graph,
        provider: const MockSettlementProvider(
          deltas: {'戒戒好感': 1, '戒戒信任': 1},
        ),
      );
      expect(r.ending, 'end_decision', reason: '第 14 天先到选择题');
      expect(r.world.variables['戒戒堕落'], 0);
      expect(
        await walkEnding(
          loaded.content,
          variables: r.world.variables,
          optionText: '注射毛至试剂',
        ),
        'end_csrj',
      );
    });

    test('高好感中堕落策略：第 14 天进打针选择，堕落停在 36~65 之间', () async {
      final loaded = load();
      final r = await walkMain(
        loaded.content,
        loaded.graph,
        provider: const MockSettlementProvider(
          deltas: {'戒戒好感': 1, '戒戒堕落': 1},
        ),
      );
      expect(r.ending, 'end_decision');
      final dep = (r.world.variables['戒戒堕落'] as num).toInt();
      expect(dep, greaterThan(35));
      expect(dep, lessThanOrEqualTo(65));
    });

    test('高好感高堕落策略：不注射后落开始堕落 kwdl', () async {
      final loaded = load();
      final r = await walkMain(
        loaded.content,
        loaded.graph,
        provider: const MockSettlementProvider(
          deltas: {'戒戒好感': 1, '戒戒堕落': 3},
        ),
      );
      expect(r.ending, 'end_decision');
      expect(r.world.variables['戒戒堕落'], 100);
      expect(
        await walkEnding(
          loaded.content,
          variables: r.world.variables,
          optionText: '不注射，继续共生',
        ),
        'end_kwdl',
      );
    });

    test('低好感+信任策略：先过第 7 天闸，再在第 14 天落 badend14', () async {
      final loaded = load();
      final r = await walkMain(
        loaded.content,
        loaded.graph,
        provider: _PhaseStrategyProvider(),
      );
      expect(r.ending, 'end_badend14');
    });
  });
}

/// 分阶段结算策略：前 21 幕抬好感过第 7 天闸，之后压好感+信任。
class _PhaseStrategyProvider implements SettlementProvider {
  int _step = 0;

  @override
  Future<SettlementProposal?> propose({
    required String sessionId,
    required SceneDef scene,
    required WorldSnapshot world,
    required SettlementEvidence evidence,
  }) async {
    _step++;
    if (_step <= 21) {
      return const SettlementProposal(deltas: {'戒戒好感': 2});
    }
    return const SettlementProposal(deltas: {'戒戒好感': -1, '戒戒信任': -1});
  }
}
