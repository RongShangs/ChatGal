import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

DialogueTurn _turn(
  int i, {
  String storyId = 'day1',
  int visitId = 0,
  List<String> audience = const ['jj'],
}) {
  return DialogueTurn(
    turnId: 't$i',
    playerText: '玩家说$i',
    replyText: '她答$i',
    audience: audience,
    storyId: storyId,
    visitId: visitId,
    at: DateTime.utc(2026, 9, 13),
  );
}

/// Scripted provider: lets each test decide whether a step succeeds.
class _Scripted implements MemoryProvider {
  _Scripted({
    this.failSummary = false,
    this.failAggregate = false,
    this.l5Action = 'add',
  });

  final bool failSummary;
  final bool failAggregate;
  final String l5Action;

  @override
  String? get lastFailure => failSummary ? '测试用：摘要失败' : null;

  int summaryCalls = 0;
  int aggregateCalls = 0;
  int l5Calls = 0;
  int keywordCalls = 0;

  @override
  Future<FragmentResult?> summarizeFragment({
    required String owner,
    required List<DialogueTurn> turns,
    required String sceneId,
    required Map<String, Object?> facts,
  }) async {
    summaryCalls++;
    if (failSummary) return null;
    // 关键词**不在这里**给：L1→L2 只出片段摘要（见 extractKeywords）。
    return FragmentResult(summary: '片段：${turns.length} 轮 @$sceneId');
  }

  @override
  Future<List<KeywordMemory>> extractKeywords({
    required String owner,
    required List<MemoryEntry> batch,
  }) async {
    keywordCalls++;
    return const [
      KeywordMemory(keywords: ['项链'], content: '一条银色的项链'),
    ];
  }

  @override
  Future<String?> aggregate({
    required String owner,
    required int fromLayer,
    required List<MemoryEntry> batch,
  }) async {
    aggregateCalls++;
    if (failAggregate) return null;
    return '聚合 L${fromLayer + 1}（${batch.length} 条）';
  }

  @override
  Future<({String action, String text, List<String> supersede})?> reviewL5({
    required String owner,
    required List<MemoryEntry> batch,
    required List<MemoryEntry> currentL5,
  }) async {
    l5Calls++;
    return (
      action: l5Action,
      text: l5Action == 'keep' ? '' : '核心记忆 L5',
      supersede: const <String>[],
    );
  }

  int compressCalls = 0;

  @override
  Future<String?> compressL5({
    required String owner,
    required List<MemoryEntry> batch,
    required int maxChars,
  }) async {
    compressCalls++;
    return '压缩后（${batch.length} 条）';
  }
}

MemoryEntry _l(int layer, String id) => MemoryEntry(
      memId: id,
      layer: layer,
      owner: 'jj',
      text: '$id 的内容',
      audience: const ['jj'],
      createdAt: DateTime.utc(2026, 9, 13),
    );

void main() {
  group('auto-collapse (threshold)', () {
    test('after 50 rounds the oldest 20 become one L2 and L1 keeps 30',
        () async {
      final bank = MemoryBank();
      final rt = MemoryRuntime(provider: _Scripted());
      for (var i = 0; i < 50; i++) {
        bank.recordTurn(_turn(i));
      }
      final plan = await rt
          .planThresholdCollapse(bank: bank, owner: 'jj', facts: const {});
      expect(plan, isNotNull);
      expect(plan!.rounds.length, 20);
      expect(plan.isEmpty, isFalse);

      expect(rt.commitCollapse(bank, plan), isTrue);
      expect(bank.windowOf('jj').length, 30);
      final l2 = bank.treeOf('jj').layerList(2);
      expect(l2.length, 1);
      expect(l2.single.text, contains('20 轮'));
      // L1→L2 只出片段摘要，**不**带关键词记忆（提取已挪到 L2→L3）
      expect(bank.recallKeywords('jj', probe: '那条项链'), isEmpty);
    });

    test('关键词记忆在 L2→L3 升层时才提取', () async {
      final bank = MemoryBank(
        thresholds: const MemoryThresholds(l2LiftCount: 2, l2LiftBatch: 2),
      );
      bank.applyThresholds(bank.thresholds);
      final scripted = _Scripted();
      final rt = MemoryRuntime(provider: scripted);
      final tree = bank.treeOf('jj');
      for (var i = 0; i < 2; i++) {
        tree.add(_l(2, 'l2_$i'));
      }
      expect(
        bank.recallKeywords('jj', probe: '那条项链'),
        isEmpty,
        reason: '还没升到 L3，一个字都不该有',
      );

      await rt.consolidate(bank, 'jj');

      expect(tree.layerList(3), isNotEmpty, reason: '先确认确实升到 L3 了');
      expect(scripted.keywordCalls, 1, reason: '升层那一刻提取一次');
      expect(bank.recallKeywords('jj', probe: '那条项链').length, 1);
    });

    test('模型提炼失败时用确定性拼接兜底：照样成一条 L2，原文不丢', () async {
      final bank = MemoryBank();
      final rt = MemoryRuntime(provider: _Scripted(failSummary: true));
      for (var i = 0; i < 50; i++) {
        bank.recordTurn(_turn(i));
      }
      final plan = await rt
          .planThresholdCollapse(bank: bank, owner: 'jj', facts: const {});
      expect(plan, isNotNull);
      expect(plan!.isEmpty, isFalse, reason: '兜底也要产出一条 L2');
      expect(plan.failure, isNull);
      // 界面要知道「这条 L2 是原文兜底」以及为什么（超时/报错/输出没法解析）。
      expect(plan.usedFallback, isTrue);
      expect(plan.fallbackReason, '测试用：摘要失败');

      expect(rt.commitCollapse(bank, plan), isTrue);
      expect(bank.windowOf('jj').length, 30);
      final l2 = bank.treeOf('jj').layerList(2).single;
      // 兜底文本来自原文拼接（DeterministicMemoryProvider），不是模型摘要
      expect(l2.text, contains('玩家：'));
      expect(l2.source?['kind'], 'l1_to_l2_fallback');
      // 兜底不带关键词记忆（不编造）
      expect(bank.recallKeywords('jj', probe: '那条项链'), isEmpty);
    });

    test('L5 超过上下文上限时自压缩成一条（只保留仍成立的）', () async {
      final bank = MemoryBank(
        thresholds: const MemoryThresholds(l5MaxChars: 100, l5CompressBatch: 3),
      );
      bank.applyThresholds(bank.thresholds);
      final tree = bank.treeOf('jj');
      for (var i = 0; i < 4; i++) {
        tree.add(
          MemoryEntry(
            memId: 'l5_$i',
            layer: 5,
            owner: 'jj',
            text: '核心记忆第 $i 条，' + '内容' * 20,
            audience: const ['jj'],
            createdAt: DateTime.now(),
          ),
        );
      }
      expect(tree.l5Chars, greaterThan(100));

      final rt = MemoryRuntime(provider: _Scripted());
      final changed = await rt.consolidate(bank, 'jj');
      expect(changed, isTrue);
      final live = tree.injectable(5);
      // 最旧的 3 条合并成 1 条新条目，剩下最新那条不动
      expect(live.length, 2);
      expect(live.map((e) => e.memId), contains(startsWith('l5c_')));
      expect(
        tree.layerList(5).where((e) => e.status == 'superseded').length,
        3,
      );
      expect(tree.l5Chars, lessThanOrEqualTo(100));
    });

    test('L2 的 audience 记的是该幕在场角色（不在场的人查不到）', () async {
      final bank = MemoryBank();
      final rt = MemoryRuntime(provider: _Scripted());
      bank.recordTurn(_turn(0, audience: const ['jj', 'xy']));
      final plan = await rt.planSceneSummary(
        bank: bank,
        owner: 'jj',
        storyId: 't0',
        visitId: 0,
        facts: const {},
      );
      expect(plan!.entry!.audience, containsAll(<String>['jj', 'xy']));
      rt.commitCollapse(bank, plan);
      expect(bank.treeOf('jj').injectable(2), isNotEmpty);

      // 把这条硬塞进一个**当时不在场**的角色树里：audience 不含它就不该被注入
      // ——「不在场就不知道」这条规则对高层记忆同样成立。
      final zz = bank.treeOf('zz');
      zz.add(plan.entry!);
      expect(zz.injectable(2), isEmpty);
    });
  });

  group('leave path', () {
    test('summarizes only this scene visit and is idempotent on retry',
        () async {
      final bank = MemoryBank();
      final rt = MemoryRuntime(provider: _Scripted());
      bank.recordTurn(_turn(0, storyId: 'day1', visitId: 0));
      bank.recordTurn(_turn(1, storyId: 'day1', visitId: 0));
      bank.recordTurn(_turn(2, storyId: 'day2', visitId: 0));

      final plan = await rt.planSceneSummary(
        bank: bank,
        owner: 'jj',
        storyId: 'day1',
        visitId: 0,
        facts: const {'day': 1},
      );
      expect(plan!.rounds.length, 3, reason: '离场把 L1 整个整理，不限本幕');
      expect(rt.commitCollapse(bank, plan), isTrue);
      expect(
        bank.windowOf('jj').length,
        0,
        reason: '离场后 L1 必须为空：新场景不该被上一幕的原始对话影响',
      );
      expect(bank.treeOf('jj').layerList(2).length, 1);

      // retry: same visit is already recorded in processed
      final again = await rt.planSceneSummary(
        bank: bank,
        owner: 'jj',
        storyId: 'day1',
        visitId: 0,
        facts: const {'day': 1},
      );
      expect(again, isNull);
      expect(bank.treeOf('jj').layerList(2).length, 1);
    });

    test('本幕还没有轮次 → 什么都不做', () async {
      final bank = MemoryBank();
      final rt = MemoryRuntime(provider: _Scripted());
      expect(
        await rt.planSceneSummary(
          bank: bank,
          owner: 'jj',
          storyId: 'ghost',
          visitId: 0,
          facts: const {},
        ),
        isNull,
      );
    });
  });

  group('decoupled consolidation', () {
    test('concurrent lifts commit the same batch only once', () async {
      final bank = MemoryBank();
      final rt = MemoryRuntime(provider: _Scripted());
      final tree = bank.treeOf('jj');
      for (var i = 0; i < 6; i++) {
        tree.add(_l(2, 'parallel$i'));
      }
      await Future.wait(
          [rt.consolidate(bank, 'jj'), rt.consolidate(bank, 'jj')]);
      expect(tree.layerList(3), hasLength(1));
      expect(tree.layerList(2).where((e) => e.isPendingLift), hasLength(3));
    });

    test('leave invalidates an in-flight aggregate without changing its source',
        () async {
      final bank = MemoryBank();
      final rt = MemoryRuntime(provider: _Scripted());
      final tree = bank.treeOf('jj');
      for (var i = 0; i < 6; i++) {
        tree.add(_l(2, 'old$i'));
      }
      var active = true;
      final pending = rt.consolidate(bank, 'jj', isCurrent: () => active);
      active = false;
      expect(await pending, isFalse);
      expect(tree.layerList(3), isEmpty);
      expect(tree.layerList(2).where((e) => e.isPendingLift), hasLength(6));
      await rt.consolidate(bank, 'jj');
      expect(tree.layerList(3), hasLength(1));
    });

    test('replacing the bank rejects a late result on the detached tree',
        () async {
      final bank = MemoryBank();
      final rt = MemoryRuntime(provider: _Scripted());
      final oldTree = bank.treeOf('jj');
      for (var i = 0; i < 6; i++) {
        oldTree.add(_l(2, 'snapshot$i'));
      }
      final pending = rt.consolidate(bank, 'jj');
      bank.replaceWith(
          MemoryBank.fromJson(bank.toJson(), thresholds: bank.thresholds));
      expect(await pending, isFalse);
      expect(oldTree.layerList(3), isEmpty);
      expect(bank.treeOf('jj').layerList(3), isEmpty);
    });

    test('lifts L2→L3→L4 and then maintains L5', () async {
      final bank = MemoryBank();
      final rt = MemoryRuntime(provider: _Scripted());
      final tree = bank.treeOf('jj');
      for (var i = 0; i < 6; i++) {
        tree.add(_l(2, 'm$i'));
      }
      await rt.consolidate(bank, 'jj');
      expect(tree.layerList(3).length, 1, reason: '6 条取最早 3 条压成 1 条');
      expect(tree.layerList(2).where((e) => e.isPendingLift).length, 3);

      // 补到 6 条待整理的 L3
      for (var i = 0; i < 5; i++) {
        tree.add(_l(3, 'n$i'));
      }
      await rt.consolidate(bank, 'jj');
      expect(tree.layerList(4).isNotEmpty, isTrue);

      for (var i = 0; i < 4; i++) {
        tree.add(_l(4, 'p$i'));
      }
      await rt.consolidate(bank, 'jj');
      expect(tree.layerList(5).isNotEmpty, isTrue);
      expect(tree.layerList(5).first.l5ReviewedBy, 'add');
    });

    test('keep produces no L5 entry (no evidence → 保持)', () async {
      final bank = MemoryBank();
      final rt = MemoryRuntime(provider: _Scripted(l5Action: 'keep'));
      final tree = bank.treeOf('jj');
      for (var i = 0; i < 4; i++) {
        tree.add(_l(4, 'k$i'));
      }
      await rt.consolidate(bank, 'jj');
      expect(tree.layerList(5), isEmpty);
      expect(tree.pendingL5Review(), isEmpty, reason: '批次已盖章，不再重复送审');
    });

    test('running twice does not duplicate entries', () async {
      final bank = MemoryBank();
      final rt = MemoryRuntime(provider: _Scripted());
      final tree = bank.treeOf('jj');
      for (var i = 0; i < 6; i++) {
        tree.add(_l(2, 'd$i'));
      }
      await rt.consolidate(bank, 'jj');
      final first = tree.layerList(3).length;
      await rt.consolidate(bank, 'jj');
      expect(tree.layerList(3).length, first);
    });

    test('failed aggregation keeps the batch for a later retry', () async {
      final bank = MemoryBank();
      final rt = MemoryRuntime(provider: _Scripted(failAggregate: true));
      final tree = bank.treeOf('jj');
      for (var i = 0; i < 6; i++) {
        tree.add(_l(2, 'f$i'));
      }
      await rt.consolidate(bank, 'jj');
      expect(tree.layerList(3), isEmpty);
      expect(tree.layerList(2).where((e) => e.isPendingLift).length, 6);
    });
  });

  group('settlement evidence', () {
    final scene = SceneDef.fromJson(
      {
        'displayName': '白天·学校',
        'background': 'x.png',
        'narration': 'n',
        'characters': [
          {'charId': 'jj', 'state': 'school', 'emotion': 'pingchang'},
        ],
        'judgePrompt': '给增量',
        'vars': ['戒戒好感'],
        'target': [
          {
            'kind': [
              {'kind': 'story', 'to': 'day2'},
            ],
          },
        ],
      },
      id: 'day1',
    );

    test('short-term only: this visit\'s L1 + L2, never higher layers',
        () async {
      final bank = MemoryBank();
      bank.recordTurn(_turn(0, storyId: 'day1', visitId: 0));
      bank.recordTurn(_turn(1, storyId: 'day9', visitId: 0));
      final tree = bank.treeOf('jj');
      tree.add(
        MemoryEntry(
          memId: 'l2_here',
          layer: 2,
          owner: 'jj',
          text: '本幕的片段',
          hasPlayerInteraction: true,
          audience: const ['jj'],
          createdAt: DateTime.utc(2026, 9, 13),
          sourceScenes: const [
            {'storyId': 'day1', 'visitId': 0},
          ],
        ),
      );
      tree.add(_l(3, 'l3_far'));
      tree.add(_l(5, 'l5_far'));
      final rt = MemoryRuntime(provider: _Scripted());

      final ev = rt.buildEvidence(
        bank: bank,
        owner: 'jj',
        scene: scene,
        visitId: 0,
        day: 1,
        audience: const ['jj'],
        state: const {'戒戒好感': 50},
      );
      final joined = ev.shortTerm.join('\n');
      expect(joined, contains('玩家说0'));
      expect(joined, contains('本幕的片段'));
      expect(joined, isNot(contains('玩家说1')), reason: '其它场景的轮次不进证据');
      expect(joined, isNot(contains('l3_far')));
      expect(joined, isNot(contains('l5_far')));
      expect(ev.render(), contains('第 1 天'));
    });

    test('a character absent from the scene contributes no evidence', () async {
      final bank = MemoryBank();
      bank.recordTurn(_turn(0, storyId: 'day1', visitId: 0, audience: ['jj']));
      final rt = MemoryRuntime(provider: _Scripted());
      final ev = rt.buildEvidence(
        bank: bank,
        owner: 'xy',
        scene: scene,
        visitId: 0,
        day: 1,
        audience: const ['jj'],
        state: const {},
      );
      expect(ev.shortTerm, isEmpty);
      expect(ev.hasContent, isFalse);
    });
  });

  group('provider parsing', () {
    test('extracts JSON from fenced or noisy replies', () {
      expect(
        parseModelJsonObject('```json\n{"summary":"ok"}\n```')!['summary'],
        'ok',
      );
      expect(
        parseModelJsonObject('好的：{"summary":"ok"} 以上')!['summary'],
        'ok',
      );
      expect(parseModelJsonObject('完全不是 JSON'), isNull);
      expect(parseModelJsonObject(null), isNull);
    });

    test('被截断的 JSON 也能救回 summary（max_tokens 用尽时常发生）', () {
      // 典型：模型先写了一段话，JSON 到一半就被截断
      const truncated =
          '思考：他们在雨里聊了很久……\n{"summary":"他们在雨里聊了很久，她第一次主动说出了害怕。","keywords":[{"keywords":["雨"]';
      expect(
        parseModelJsonObject(truncated)!['summary'],
        '他们在雨里聊了很久，她第一次主动说出了害怕。',
      );
    });

    test('完全没给 JSON 但写了摘要文本时不硬认', () {
      // 只有明确带 summary 字段才会被救回；纯散文不猜
      expect(parseModelJsonObject('他们聊了很久，她很害怕。'), isNull);
    });

    test('截断落在摘要字符串中间也能取回', () {
      const cutInside = '{"summary":"他们从放学聊到深夜，她第一次主动说出了害怕的事，还提到那条项链';
      final got = parseModelJsonObject(cutInside)!['summary'] as String;
      expect(got, startsWith('他们从放学聊到深夜'));
      expect(got, contains('项链'));
    });
  });
}
