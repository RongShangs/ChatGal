import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

DialogueTurn _turn(
  int i, {
  List<String> audience = const ['jj'],
  String playerText = '你好',
  String replyText = '嗯',
}) {
  return DialogueTurn(
    turnId: 't$i',
    playerText: playerText,
    replyText: replyText,
    audience: audience,
    storyId: 'day1_2',
    visitId: 0,
    at: DateTime.utc(2026, 9, 13),
  );
}

CharacterMemoryTree _tree() => CharacterMemoryTree(owner: 'jj');

MemoryEntry _l4(String id) => MemoryEntry(
      memId: id,
      layer: 4,
      owner: 'jj',
      text: '趋势 $id',
      audience: const ['jj'],
      createdAt: DateTime.utc(2026, 9, 13),
    );

void main() {
  group('L1 active window', () {
    test('holds rounds until the collapse threshold is reached', () {
      final w = ActiveWindow(owner: 'jj');
      for (var i = 0; i < 49; i++) {
        w.turns.add(_turn(i));
      }
      expect(w.pendingBatch(), isEmpty);

      w.turns.add(_turn(49)); // 50th round completes
      final batch = w.pendingBatch();
      expect(batch.length, 20, reason: '最早 20 轮压成一条 L2');
      expect(w.length, 50);

      // After a successful summary only the kept tail remains…
      w.commitBatch(batch.length);
      expect(w.length, 30, reason: 'L1 保留最近 30 轮');
      expect(w.turns.first.turnId, 't20');
      expect(w.pendingBatch(), isEmpty);
    });

    test('re-collapses after another 20 rounds', () {
      final w = ActiveWindow(owner: 'jj');
      for (var i = 0; i < 50; i++) {
        w.turns.add(_turn(i));
      }
      w.commitBatch(w.pendingBatch().length);
      for (var i = 50; i < 70; i++) {
        w.turns.add(_turn(i));
      }
      expect(w.pendingBatch().length, 20);
    });

    test('a failed summary keeps the text (nothing removed)', () {
      final w = ActiveWindow(owner: 'jj');
      for (var i = 0; i < 50; i++) {
        w.turns.add(_turn(i));
      }
      final before = w.length;
      // no commitBatch → the window is untouched, so it can be retried
      expect(w.length, before);
      expect(w.pendingBatch().length, 20);
    });

    test('thresholds are configurable and not baked into the class', () {
      const t = MemoryThresholds(l1KeepRounds: 10, l1CollapseAt: 12);
      final w = ActiveWindow(owner: 'jj', thresholds: t);
      for (var i = 0; i < 12; i++) {
        w.turns.add(_turn(i));
      }
      // 12 轮、保留 10 轮、默认批大小 20 → 只多出 2 轮，压 2 轮
      expect(w.pendingBatch().length, 2);
    });

    test('批大小 = 触发轮数 − 保留轮数（不是独立设置项）', () {
      const t = MemoryThresholds(l1KeepRounds: 30, l1CollapseAt: 50);
      expect(t.l1CollapseBatch, 20);
      final w = ActiveWindow(owner: 'jj', thresholds: t);
      for (var i = 0; i < 50; i++) {
        w.turns.add(_turn(i));
      }
      expect(w.pendingBatch().length, 20, reason: '50 − 30');

      // 保留线贴得越近，一次压得越少 —— 保留轮数是硬约束，绝不吃掉尾巴
      const tight = MemoryThresholds(l1KeepRounds: 48, l1CollapseAt: 50);
      expect(tight.l1CollapseBatch, 2);
      final w2 = ActiveWindow(owner: 'jj', thresholds: tight);
      for (var i = 0; i < 50; i++) {
        w2.turns.add(_turn(i));
      }
      expect(w2.pendingBatch().length, 2, reason: '不能吃掉要保留的最近 48 轮');
    });

    test('normalized() 保证「触发 > 保留」，倒挂的配置会被掰正', () {
      const bad = MemoryThresholds(l1KeepRounds: 40, l1CollapseAt: 10);
      final ok = bad.normalized();
      expect(ok.l1CollapseAt, greaterThan(ok.l1KeepRounds));
      expect(ok.l1CollapseBatch, greaterThanOrEqualTo(1));
    });
  });

  group('multi-character audience', () {
    test('a round lands only in the windows of characters present', () {
      final bank = MemoryBank();
      bank.recordTurn(_turn(1, audience: const ['jj']));
      bank.recordTurn(_turn(2, audience: const ['jj', 'xy']));

      expect(bank.windowOf('jj').length, 2);
      expect(bank.windowOf('xy').length, 1);
      expect(bank.windowOf('xy').turns.single.turnId, 't2');
      // a character that was never present has no window at all
      expect(bank.windowIfExists('zz'), isNull);
      expect(bank.owners, containsAll(['jj', 'xy']));
    });

    test('a character cannot recall a round it was absent from', () {
      final bank = MemoryBank();
      bank.recordTurn(_turn(1, audience: const ['jj']));
      final turn = bank.windowOf('jj').turns.single;
      expect(turn.visibleTo('jj'), isTrue);
      expect(turn.visibleTo('xy'), isFalse);
    });
  });

  group('keyword memory', () {
    test('recalls on a hit and stays invisible to others', () {
      final bank = MemoryBank();
      bank.addKeyword(
        owner: 'jj',
        keywords: ['项链'],
        content: '一条细细的银色项链，是母亲留下的。',
        source: 'L2→L3 时提取',
        audience: ['jj'],
      );
      final hit = bank.recallKeywords('jj', probe: '你还戴着那条项链吗');
      expect(hit.length, 1);
      expect(bank.recallKeywords('jj', probe: '今天天气不错'), isEmpty);
      expect(bank.recallKeywords('xy', probe: '项链'), isEmpty);
    });

    test('deduplicates identical content and respects the limit', () {
      final bank = MemoryBank();
      for (var i = 0; i < 20; i++) {
        bank.addKeyword(
          owner: 'jj',
          keywords: ['承诺'],
          content: '同一件事',
          source: 'x',
          audience: const ['jj'],
        );
      }
      expect(bank.recallKeywords('jj', probe: '承诺', limit: 5).length, 1);
    });
  });

  group('L5 review', () {
    test('layer 4 reaching the threshold offers the oldest batch', () {
      final t = _tree();
      for (var i = 0; i < 3; i++) {
        t.add(_l4('m$i'));
      }
      expect(t.pendingL5Review(), isEmpty, reason: '需要 ≥4 条');
      t.add(_l4('m3'));
      expect(t.pendingL5Review().map((e) => e.memId), ['m0', 'm1']);
    });

    test('add appends a core memory and stamps the batch', () {
      final t = _tree();
      for (var i = 0; i < 4; i++) {
        t.add(_l4('m$i'));
      }
      final batch = t.pendingL5Review();
      final created = t.applyL5Review(action: 'add', batch: batch, text: '她开始依赖哥哥。');
      expect(created, isNotNull);
      expect(t.layerList(5).length, 1);
      expect(t.pendingL5Review(), isEmpty, reason: '批次已处理，不再重复送审');
      // the raw L4 evidence is preserved, not deleted
      expect(t.layerList(4).length, 4);
    });

    test('keep creates nothing but still marks the batch reviewed', () {
      final t = _tree();
      for (var i = 0; i < 4; i++) {
        t.add(_l4('m$i'));
      }
      final batch = t.pendingL5Review();
      final created = t.applyL5Review(action: 'keep', batch: batch);
      expect(created, isNull);
      expect(t.layerList(5), isEmpty);
      expect(t.pendingL5Review(), isEmpty);
      expect(t.cascadeDeterministic(), isNull);
    });

    test('merge supersedes the merged core memories', () {
      final t = _tree();
      final existing = t.applyL5Review(
        action: 'add',
        batch: [_l4('seed')],
        text: '旧认知',
        updateId: 'l5_old',
      )!;
      for (var i = 0; i < 4; i++) {
        t.add(_l4('n$i'));
      }
      final merged = t.applyL5Review(
        action: 'merge',
        batch: t.pendingL5Review(),
        text: '合并后的新认知',
        supersedeL5Ids: [existing.memId],
      );
      expect(merged!.text, '合并后的新认知');
      final old = t.layerList(5).firstWhere((e) => e.memId == 'l5_old');
      expect(old.status, 'superseded');
      expect(old.aggregatedInto, merged.memId);
      // only the replacement is injected
      expect(t.injectable(5).map((e) => e.memId), [merged.memId]);
    });
  });

  group('persistence', () {
    test('bank round-trips through JSON', () {
      final bank = MemoryBank();
      bank.recordTurn(_turn(1, audience: const ['jj', 'xy']));
      bank.treeOf('jj').add(_l4('m0'));
      bank.addKeyword(
        owner: 'jj',
        keywords: ['肩章'],
        content: '父亲留下的旧肩章。',
        source: 'L2→L3 时提取',
        audience: const ['jj'],
      );
      final raw = bank.toJson();
      final restored = MemoryBank.fromJson(raw);

      expect(restored.windowOf('jj').length, 1);
      expect(restored.windowOf('xy').length, 1);
      expect(restored.treeOf('jj').layerList(4).single.memId, 'm0');
      expect(restored.recallKeywords('jj', probe: '肩章').length, 1);
      // 存档里没有阈值：它属于游戏外设置，读出来是默认值。
      expect(restored.thresholds.l1KeepRounds, 30);
      expect(restored.thresholds.l1CollapseAt, 50);
      expect(restored.thresholds.l5MaxChars, 1200);
    });

    test('阈值不进存档', () {
      final bank = MemoryBank(
        thresholds: const MemoryThresholds(
          l1KeepRounds: 5,
          l1CollapseAt: 8,
          l5MaxChars: 400,
        ),
      );
      final raw = bank.toJson();
      expect(raw.containsKey('thresholds'), isFalse, reason: '阈值不落盘');

      // 读出来是默认值，再由调用方灌入当前设置。
      final restored = MemoryBank.fromJson(raw);
      expect(restored.thresholds.l1KeepRounds, 30);

      restored.applyThresholds(
        const MemoryThresholds(l1KeepRounds: 5, l1CollapseAt: 8),
      );
      expect(restored.thresholds.l1KeepRounds, 5);
      expect(restored.thresholds.l1CollapseAt, 8);
      // 窗口与记忆树都要跟着换（否则「一部分层用新阈值」）
      expect(restored.windowOf('jj').thresholds.l1KeepRounds, 5);
      expect(restored.treeOf('jj').thresholds.l1KeepRounds, 5);
    });

    test('非法的阈值组合被夹到自洽区间', () {
      const bad = MemoryThresholds(
        l1KeepRounds: 0,
        l1CollapseAt: 0,
        l2LiftCount: 0,
        l2LiftBatch: 99,
        l5MaxChars: 0,
        l5CompressBatch: 0,
        l3KeywordMax: 0,
      );
      final ok = bad.normalized();
      expect(ok.l1KeepRounds, greaterThanOrEqualTo(1));
      expect(ok.l1CollapseAt, greaterThan(ok.l1KeepRounds));
      expect(ok.l1CollapseBatch, greaterThanOrEqualTo(1));
      expect(ok.l1CollapseBatch, ok.l1CollapseAt - ok.l1KeepRounds);
      expect(ok.l2LiftCount, greaterThanOrEqualTo(2));
      expect(ok.l2LiftBatch, lessThanOrEqualTo(ok.l2LiftCount));
      expect(ok.l5MaxChars, greaterThanOrEqualTo(100));
      expect(ok.l5CompressBatch, greaterThanOrEqualTo(2));
      expect(ok.l3KeywordMax, greaterThanOrEqualTo(4));
    });

    test('fromJson 显式传入 thresholds 时保留（换幕克隆不能重置）', () {
      const custom = MemoryThresholds(
        l1KeepRounds: 5,
        l1CollapseAt: 10,
        l5MaxChars: 300,
      );
      final bank = MemoryBank(thresholds: custom);
      bank.recordTurn(_turn(1, audience: const ['jj']));
      final raw = bank.toJson();
      // 克隆时必须显式传 thresholds，否则 fromJson 默认回落到 defaults
      final clone = MemoryBank.fromJson(raw, thresholds: bank.thresholds);
      expect(clone.thresholds.l1KeepRounds, 5);
      expect(clone.thresholds.l1CollapseAt, 10);
      expect(clone.thresholds.l5MaxChars, 300);
      // 不传 thresholds 会回落默认（这是契约的一部分）
      final defaulted = MemoryBank.fromJson(raw);
      expect(defaulted.thresholds.l1CollapseAt, 50);
    });
  });
}
