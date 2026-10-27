import 'dart:io';

import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 默认内容包（`content/default_v2`）的端到端复盘。
///
/// 这一份是「真包 + 引擎」的唯一联调用例，所以它同时守着几件容易静默失效的
/// 事：JSONC（带注释的 manifest/情景能装载）、扁平 `target` 的出口判定、
/// 离场结算 + L1→L2 提炼、以及幂等台账。
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

WorldSnapshot worldAt(
  VariableRegistry reg,
  String sceneId, {
  required int day,
  int affection = 70,
  int trust = 60,
  int obedience = 50,
  int depravity = 0,
  int rng = 1,
}) {
  return WorldSnapshot(
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
    rngState: rng,
  );
}

/// 每一幕「入场之后」的天数统计：用来验证日程计数与 day 的推进时机。
Map<int, int> countByDay(List<int> days) {
  final out = <int, int>{};
  for (final d in days) {
    out[d] = (out[d] ?? 0) + 1;
  }
  return out;
}

void main() {
  test('默认包能装载：JSONC 注释 + 扁平 stories/events，54 幕', () {
    final loaded = load();
    expect(loaded.content.scenes.containsKey('start'), isTrue);
    expect(loaded.content.scenes.containsKey('day1_2'), isTrue);
    expect(loaded.content.scenes.containsKey('day14_3'), isTrue);
    expect(loaded.content.scenes.containsKey('endless_human_day'), isTrue);
    // 主线 42 幕（start = 旧 day1_1）+ 三套无尽各 4 幕
    expect(loaded.content.scenes.length, 54);
    final mainLine = loaded.content.scenes.keys
        .where((k) => k == 'start' || k.startsWith('day'))
        .toList();
    expect(mainLine.length, 42);
    // 情景 id 就是文件名 stem（文件里不再写 id）；展示名 = 时段·地点
    expect(loaded.content.scene('start')!.displayName, '白天·学校');
    expect(loaded.content.scene('day1_2')!.displayName, '傍晚·校外');
    expect(loaded.content.scene('day7_3')!.displayName, '晚上·家里');
    expect(loaded.content.scene('day14_3')!.displayName, '晚上·地下实验室');
    // 每一幕的正文与人格都来自内容包：narration 非空，且有一份**逐幕写的**人格提示。
    // （这里以前还断言提示里有「本幕：」前缀 —— 那个标记只有无尽幕会写，
    //   主线 42 幕在提示词重写后不写它，而且它不参与任何运行时逻辑，
    //   所以改成断言提示确实非空。）
    for (final scene in loaded.content.scenes.values) {
      expect(scene.narration.trim(), isNotEmpty, reason: scene.id);
      expect(scene.characters, hasLength(1), reason: scene.id);
      expect(
        scene.characters.single.scenePrompt.trim(),
        isNotEmpty,
        reason: scene.id,
      );
    }
    // 事件 id 就是文件夹名
    expect(
      loaded.content.eventDefs.keys.toSet(),
      {
        'end_badend7',
        'end_badend14',
        'end_decision',
        'end_no_inject',
        'end_csrj',
        'end_kwdl',
        'end_xtgs',
      },
    );
    // 角色目录 = 角色表；变量扁平注册并按角色 id 前缀归属
    final reg = loaded.content.variableRegistry;
    expect(loaded.content.characters.single.id, '戒戒');
    expect(reg.ownerOf('戒戒信任'), '戒戒');
    expect(reg.ownerOf('day'), isNull);
  });

  test('真实包里的每一条 require 都能解析，且只引用注册过的变量', () {
    final loaded = load();
    final reg = loaded.content.variableRegistry;
    final registered = <String>{for (final v in loaded.content.variables) v.id};
    final all = <TargetBlock>[
      for (final s in loaded.content.scenes.values) ...s.target,
      for (final e in loaded.content.eventDefs.values) ...e.target,
    ];
    expect(all, isNotEmpty);
    for (final block in all) {
      final req = block.require;
      if (req == null) continue;
      expect(RequireExpr.check(req), isNull, reason: req);
      for (final name in RequireExpr.variablesIn(req)) {
        expect(registered, contains(name), reason: '$req 引用了 $name');
        expect(reg.contains(name), isTrue);
      }
    }
  });

  test('每一幕都有出口块（默认包不存在「到此为止」的情景）', () {
    final loaded = load();
    for (final scene in loaded.content.scenes.values) {
      expect(scene.target, isNotEmpty, reason: scene.id);
    }
  });

  test('flat pack loads start and walks start→day1_2', () async {
    final loaded = load();
    final reg = loaded.content.variableRegistry;
    final vars = <String, Object?>{...reg.defaults, 'day': 1};

    final c = TransitionCoordinator(
      graph: loaded.graph,
      registry: reg,
      memory: MemoryRuntime(provider: const DeterministicMemoryProvider()),
    );
    // One complete round already happened in this scene: that L1 round is the
    // settlement's evidence (not the raw message list).
    final bank = MemoryBank()
      ..recordTurn(
        DialogueTurn(
          turnId: 't1',
          playerText: 'hi',
          replyText: 'hello',
          audience: const ['戒戒'],
          storyId: 'start',
          visitId: 0,
          at: DateTime.utc(2026, 9, 13),
        ),
      );
    final r = await c.leaveCurrent(
      sessionId: 's',
      world: WorldSnapshot(
        variables: vars,
        characters: const {},
        eventHistory: const {},
        story: const {'storyId': 'start', 'day': 1},
        presentation: const {},
        rngState: 1,
      ),
      bank: bank,
      messages: const [
        {'role': 'user', 'content': 'hi'},
        {'role': 'assistant', 'content': 'hello'},
      ],
      baseRevision: 0,
      provider: const ChatMockSettlement(),
      cursor: const RuntimeCursor(storyId: 'start', visitId: 0),
    );
    expect(r.accepted, isTrue, reason: r.error);
    expect(r.nextSceneId, 'day1_2');
    // starts at the declared default 50, mock settlement adds +1
    expect(r.world!.variables['戒戒好感'], 51);
    // day1_2 不是「新的一天第一个时段」，day 保持 1
    expect(r.world!.variables['day'], 1);
    // one settlement id is recorded so a retry cannot add it again
    expect(r.appliedSettlementIds, [
      TransitionCoordinator.settlementIdFor(
        sessionId: 's',
        fromStoryId: 'start',
        fromVisitId: 0,
      ),
    ]);
    // the leave path summarized this scene's L1 rounds into one L2 fragment
    final after = r.memories!;
    expect(after.treeOf('戒戒').layerList(2).length, 1);
    expect(after.windowOf('戒戒').length, 0, reason: 'L1 已提炼并移出活跃窗口');
  });

  test('replaying a leave does not settle twice', () async {
    final loaded = load();
    final reg = loaded.content.variableRegistry;
    final vars = <String, Object?>{...reg.defaults, 'day': 1};
    WorldSnapshot world() => WorldSnapshot(
          variables: vars,
          characters: const {},
          eventHistory: const {},
          story: const {'storyId': 'start', 'day': 1},
          presentation: const {},
          rngState: 1,
        );

    // 本幕有可用的短期记忆证据，所以结算真的会发生（+1）
    MemoryBank bank() => MemoryBank()
      ..recordTurn(
        DialogueTurn(
          turnId: 't1',
          playerText: 'hi',
          replyText: 'hello',
          audience: const ['戒戒'],
          storyId: 'start',
          visitId: 0,
          at: DateTime.utc(2026, 9, 13),
        ),
      );

    final c = TransitionCoordinator(
      graph: loaded.graph,
      registry: reg,
      memory: MemoryRuntime(provider: const DeterministicMemoryProvider()),
    );
    final first = await c.leaveCurrent(
      sessionId: 's',
      world: world(),
      bank: bank(),
      messages: const [],
      baseRevision: 0,
      provider: const ChatMockSettlement(),
      cursor: const RuntimeCursor(storyId: 'start', visitId: 0),
    );
    expect(first.accepted, isTrue, reason: first.error);
    expect(first.appliedSettlementIds, isNotEmpty);
    expect(first.world!.variables['戒戒好感'], 51);

    // 从**已结算的世界**重放同一笔离场（崩溃后重放就是这个形状），
    // 交回已经落地的结算 id → 不再加第二遍。
    final replay = await c.leaveCurrent(
      sessionId: 's',
      world: first.world!.copyWith(story: const {'storyId': 'start', 'day': 1}),
      bank: bank(),
      messages: const [],
      baseRevision: 0,
      provider: const ChatMockSettlement(),
      appliedSettlementIds: first.appliedSettlementIds,
      cursor: const RuntimeCursor(storyId: 'start', visitId: 0),
    );
    expect(replay.accepted, isTrue, reason: replay.error);
    expect(replay.appliedDeltas, isEmpty);
    expect(replay.appliedSettlementIds, isEmpty);
    expect(replay.world!.variables['戒戒好感'], 51, reason: '不能再加一遍');
  });

  group('demo main line', () {
    /// Walk the whole main line, returning the visited scenes, the day each
    /// scene was entered on, and the ending event the walk stopped at.
    ///
    /// `provider` is the settlement provider: the default one proposes nothing,
    /// so the variables stay where [affection] put them.
    Future<
        ({
          List<String> visited,
          List<int> days,
          String? ending,
          WorldSnapshot world,
        })> walk(
      PackageContent content,
      SceneGraph graph, {
      required int affection,
      SettlementProvider provider = const MockSettlementProvider(),
      int trust = 60,
    }) async {
      final reg = content.variableRegistry;
      final c = TransitionCoordinator(graph: graph, registry: reg);
      var world = worldAt(
        reg,
        'start',
        day: 1,
        affection: affection,
        trust: trust,
      );
      var cursor = const RuntimeCursor(storyId: 'start', visitId: 0);
      // 入场就站在 start 里，所以 start 自己也算走位的第一幕、第 1 天的一幕。
      final visited = <String>['start'];
      final days = <int>[world.variables['day']! as int];
      final applied = <String>[];
      for (var i = 0; i < 80; i++) {
        final r = await c.leaveCurrent(
          sessionId: 's',
          world: world,
          messages: const [],
          baseRevision: i,
          provider: provider,
          appliedSettlementIds: applied,
          cursor: cursor,
        );
        expect(r.accepted, isTrue, reason: r.error);
        applied.addAll(r.appliedSettlementIds);
        world = r.world!;
        cursor = r.cursor!;
        if (r.targetKind == 'event') {
          return (
            visited: visited,
            days: days,
            ending: r.nextEventId,
            world: world,
          );
        }
        visited.add(r.nextSceneId!);
        days.add(world.variables['day']! as int);
      }
      return (visited: visited, days: days, ending: null, world: world);
    }

    /// 主线 42 幕的走位顺序：start 就是第 1 天白天（旧 day1_1）。
    List<String> mainLineOrder() {
      final ids = <String>['start', 'day1_2', 'day1_3'];
      for (var d = 2; d <= 14; d++) {
        ids.addAll(['day${d}_1', 'day${d}_2', 'day${d}_3']);
      }
      return ids;
    }

    test('低好感在第 7 天晚上被生死判定拦下：day7_3 → end_badend7', () async {
      final loaded = load();
      final r = await walk(loaded.content, loaded.graph, affection: 50);

      // 好感 50 < 60 成立 → 直接进 badend7，不进第 8 天
      expect(r.ending, 'end_badend7');
      expect(r.visited, mainLineOrder().sublist(0, 21));
      expect(r.visited.contains('day8_1'), isFalse);
      // 走事件出口时不再执行 fixedEffects：day 就停在第 7 天
      expect(r.world.variables['day'], 7);
      // 第 1~7 天每天 3 幕
      expect(countByDay(r.days), {for (var d = 1; d <= 7; d++) d: 3});
    });

    test('好感抬到 60 以上就一路走到第 14 天的终局判定', () async {
      final loaded = load();
      // 固定结算 provider：每一幕离场都给「戒戒好感」+1（59 → 60 起就过闸）
      final r = await walk(
        loaded.content,
        loaded.graph,
        affection: 59,
        provider: const MockSettlementProvider(deltas: {'戒戒好感': 1}),
      );

      // day7_3 → day8_1 → … → day14_3：42 幕一幕不少、顺序完整
      expect(r.visited, mainLineOrder());
      // 日程计数：第 1 天 3 幕（start/day1_2/day1_3）、第 2~14 天各 3 幕
      expect(countByDay(r.days), {for (var d = 1; d <= 14; d++) d: 3});
      // day 只在 dayN_1 入场时 +1：走到 day14_3 时是 14，不是 15
      for (var i = 0; i < r.visited.length; i++) {
        final id = r.visited[i];
        final day = id == 'start' ? 1 : int.parse(id.split('_').first.substring(3));
        expect(r.days[i], day, reason: id);
      }
      expect(r.world.variables['day'], 14);
      // 好感 59+42、信任 60、堕落 0、服从 50 → 第 14 天晚上进打针选择题
      // （走到哪个终局取决于之后在选择题上点注射还是不注射，这里只看主线这一步）
      expect(r.ending, 'end_decision');
    });

    test('endless afternoons branch to the special scene about half the time',
        () async {
      final loaded = load();
      final reg = loaded.content.variableRegistry;
      final c = TransitionCoordinator(graph: loaded.graph, registry: reg);
      final counts = <String, int>{};
      for (var rng = 1; rng <= 48; rng++) {
        final r = await c.leaveCurrent(
          sessionId: 's',
          world: worldAt(
            reg,
            'endless_human_afternoon',
            day: 40,
            rng: rng,
          ),
          messages: const [],
          baseRevision: 0,
          provider: const MockSettlementProvider(),
          cursor: const RuntimeCursor(
            storyId: 'endless_human_afternoon',
            visitId: 0,
          ),
        );
        expect(r.accepted, isTrue, reason: r.error);
        counts[r.nextSceneId!] = (counts[r.nextSceneId!] ?? 0) + 1;
      }
      // 块内等概率：两条都要出现（旧实现里随机永不生效，只会走第一条）
      expect(counts.keys, containsAll([
        'endless_human_night',
        'endless_human_afternoon_special',
      ]));
    });

    test('endless nights loop back to their own day and keep counting days',
        () async {
      final loaded = load();
      final reg = loaded.content.variableRegistry;
      final c = TransitionCoordinator(graph: loaded.graph, registry: reg);
      final r = await c.leaveCurrent(
        sessionId: 's',
        world: worldAt(reg, 'endless_cat_night', day: 40),
        messages: const [],
        baseRevision: 0,
        provider: const MockSettlementProvider(),
        cursor: const RuntimeCursor(storyId: 'endless_cat_night', visitId: 0),
      );
      expect(r.nextSceneId, 'endless_cat_day');
      expect(r.world!.variables['day'], 41);
      // 无尽里每一幕的出口都指向自己那一天的下一时段
      expect(
        loaded.content.scene('endless_cat_day')!.target.last.kinds.single.to,
        'endless_cat_afternoon',
      );
    });
  });

  test('settlement evidence is the summary, not the raw transcript', () async {
    final loaded = load();
    final reg = loaded.content.variableRegistry;
    final recorder = _EvidenceRecorder();
    final c = TransitionCoordinator(
      graph: loaded.graph,
      registry: reg,
      memory: MemoryRuntime(provider: const DeterministicMemoryProvider()),
    );

    final bank = MemoryBank()
      ..recordTurn(
        DialogueTurn(
          turnId: 't1',
          playerText: 'RAW_PLAYER_LINE',
          replyText: 'RAW_REPLY_LINE',
          audience: const ['戒戒'],
          storyId: 'start',
          visitId: 0,
          at: DateTime.utc(2026, 9, 13),
        ),
      );

    final r = await c.leaveCurrent(
      sessionId: 's',
      world: WorldSnapshot(
        variables: {...reg.defaults, 'day': 1},
        characters: const {},
        eventHistory: const {},
        story: const {'storyId': 'start', 'day': 1},
        presentation: const {},
        rngState: 1,
      ),
      bank: bank,
      messages: const [],
      baseRevision: 0,
      provider: recorder,
      cursor: const RuntimeCursor(storyId: 'start', visitId: 0),
    );
    expect(r.accepted, isTrue, reason: r.error);

    final seen = recorder.evidence!;
    final joined = seen.shortTerm.join('\n');
    // 证据取的是**提炼之前**的快照：本幕的 L1 原文仍在，但只以短周期记忆的
    // 形态给出（不是整段场景转录）
    expect(joined, contains('RAW_PLAYER_LINE'));
    expect(seen.shortTerm.length, 1, reason: '只有这一条本幕轮次');
    expect(seen.render(), contains('第 1 天'));
    expect(seen.audience, ['戒戒']);
    expect(seen.state, contains('戒戒好感'));
  });

  test('模型提炼失败时用确定性拼接兜底：照样放行，原文以 L2 形式留下', () async {
    final loaded = load();
    final reg = loaded.content.variableRegistry;
    final c = TransitionCoordinator(
      graph: loaded.graph,
      registry: reg,
      // 摘要永远失败：模拟 API 报错/输出解析不出来
      memory: MemoryRuntime(provider: const _AlwaysFailMemory()),
    );
    final bank = MemoryBank()
      ..recordTurn(
        DialogueTurn(
          turnId: 't1',
          playerText: '上一幕的话',
          replyText: '上一幕的回答',
          audience: const ['戒戒'],
          storyId: 'start',
          visitId: 0,
          at: DateTime.utc(2026, 9, 13),
        ),
      );
    expect(bank.windowOf('戒戒').length, 1);

    final r = await c.leaveCurrent(
      sessionId: 's',
      world: WorldSnapshot(
        variables: {...reg.defaults, 'day': 1},
        characters: const {},
        eventHistory: const {},
        story: const {'storyId': 'start', 'day': 1},
        presentation: const {},
        rngState: 1,
      ),
      bank: bank,
      messages: const [],
      baseRevision: 0,
      provider: const MockSettlementProvider(),
      cursor: const RuntimeCursor(storyId: 'start', visitId: 0),
    );
    expect(r.accepted, isTrue, reason: '兜底成立就应该放行，不能因为一次请求失败卡住换场');
    expect(r.memories, isNotNull);
    final after = r.memories!;
    expect(
      after.windowOf('戒戒').length,
      0,
      reason: '本幕的 L1 整理完就该清空，不再带进下一幕',
    );
    final l2 = after.treeOf('戒戒').layerList(2).single;
    expect(
      l2.text,
      contains('上一幕的话'),
      reason: '兜底文本来自原文拼接：细节不能丢',
    );
    expect(l2.source?['kind'], 'l1_to_l2_fallback');
  });
}

/// 永远提炼失败的 provider（模拟 API 报错 / 输出不可解析）。
class _AlwaysFailMemory implements MemoryProvider {
  const _AlwaysFailMemory();

  @override
  String? get lastFailure => '测试用：提炼始终失败';

  @override
  Future<FragmentResult?> summarizeFragment({
    required String owner,
    required List<DialogueTurn> turns,
    required String sceneId,
    required Map<String, Object?> facts,
  }) async =>
      null;

  @override
  Future<List<KeywordMemory>> extractKeywords({
    required String owner,
    required List<MemoryEntry> batch,
  }) async =>
      const [];

  @override
  Future<String?> aggregate({
    required String owner,
    required int fromLayer,
    required List<MemoryEntry> batch,
  }) async =>
      null;

  @override
  Future<({String action, String text, List<String> supersede})?> reviewL5({
    required String owner,
    required List<MemoryEntry> batch,
    required List<MemoryEntry> currentL5,
  }) async =>
      null;

  @override
  Future<String?> compressL5({
    required String owner,
    required List<MemoryEntry> batch,
    required int maxChars,
  }) async =>
      null;
}

/// Captures the evidence the coordinator hands to the settlement provider.
class _EvidenceRecorder implements SettlementProvider {
  SettlementEvidence? evidence;

  @override
  Future<SettlementProposal?> propose({
    required String sessionId,
    required SceneDef scene,
    required WorldSnapshot world,
    required SettlementEvidence evidence,
  }) async {
    this.evidence = evidence;
    return const SettlementProposal(deltas: {});
  }
}
