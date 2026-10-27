import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 上下文组装与条件求值的边界：这两处最容易「静默失效」——
/// 超预算整层被丢、畸形条件抛异常，都属于玩家看不见但机制已坏的类型。
void main() {
  group('记忆层注入：超预算只裁剪，不整层丢弃', () {
    MemoryEntry l5(String id, String text) => MemoryEntry(
          memId: id,
          layer: 5,
          owner: 'jj',
          text: text,
          audience: const ['jj'],
          createdAt: DateTime.now(),
        );

    test('聊天上下文不再追加「输出格式」与立绘词表（职责已交给立绘 agent）', () {
      final tree = CharacterMemoryTree(owner: 'jj');
      const asm = MemoryContextAssembler(maxTokens: 6000);
      final msgs = asm.assemble(
        protocolShell: '',
        basePrompt: 'BASE',
        authorityFacts: 'day=1',
        tree: tree,
      );
      for (final m in msgs) {
        final c = '${m['content']}';
        expect(c, isNot(contains('【输出格式')));
        expect(c, isNot(contains('protocolVersion')));
        // §32：聊天只写台词；词表只在 buildLookPlanPrompt 里出现
        expect(c, isNot(contains('【可用立绘】')));
        expect(c, isNot(contains('【可用情绪】')));
        expect(c, isNot(contains('portraitId 的唯一来源')));
      }
    });

    test('L5 超出该层 token 预算时仍然会注入（保留最新的几条）', () {
      final tree = CharacterMemoryTree(owner: 'jj');
      for (var i = 0; i < 8; i++) {
        tree.add(l5('l5_$i', '核心记忆第 $i 条：' + '内容' * 60));
      }
      const asm = MemoryContextAssembler(maxTokens: 6000, l1Budget: 100);
      final msgs = asm.assemble(
        protocolShell: '',
        basePrompt: 'BASE',
        authorityFacts: 'day=1',
        tree: tree,
      );
      final l5Block = msgs.firstWhere(
        (m) => (m['content'] ?? '').contains('【记忆 L5】'),
        orElse: () => const {'content': ''},
      );
      expect(
        l5Block['content'],
        isNotEmpty,
        reason: '整层被丢 = 核心记忆一条都进不了上下文（旧行为）',
      );
      // 保留的是**最新**的：最后一条一定在
      expect(l5Block['content'], contains('第 7 条'));
    });

    test('L5 同时受设置里的字数上限约束', () {
      final tree = CharacterMemoryTree(
        owner: 'jj',
        thresholds: const MemoryThresholds(l5MaxChars: 120),
      );
      for (var i = 0; i < 4; i++) {
        tree.add(l5('l5_$i', '核心记忆第 $i 条：' + '内容' * 30));
      }
      const asm = MemoryContextAssembler(maxTokens: 6000);
      final msgs = asm.assemble(
        protocolShell: '',
        basePrompt: 'BASE',
        authorityFacts: '',
        tree: tree,
      );
      final block = msgs.firstWhere(
        (m) => (m['content'] ?? '').contains('【记忆 L5】'),
      )['content']!;
      // 只保留能装进 120 字的那条（+ 表头）
      expect(block.length, lessThan(120 + 120));
      expect(block, contains('第 3 条'));
    });
  });

  group('出口条件坏掉时不炸离场事务', () {
    // ObjectConditionEvaluator（对象式 when）已随内容包格式一起删除：
    // 现在唯一的条件语法是 require 的中缀文本，由 RequireExpr 解析。
    const world = WorldSnapshot(
      variables: {'好感': 50},
      characters: {},
      eventHistory: {},
      story: {},
      presentation: {},
      rngState: 1,
    );

    test('取不到的变量当 0 / 空串：判假而不抛', () {
      expect(RequireExpr.parse('"好感" > 50').evaluate(world), isFalse);
      expect(RequireExpr.parse('"从未见过的变量" > 0').evaluate(world), isFalse);
      expect(RequireExpr.parse('"从未见过的变量" == 0').evaluate(world), isTrue);
    });

    test('正常条件照旧', () {
      expect(RequireExpr.parse('"好感" == 50').evaluate(world), isTrue);
      expect(RequireExpr.parse('"好感" < 50').evaluate(world), isFalse);
      expect(RequireExpr.parse('"好感" + "好感" < 120').evaluate(world), isTrue);
      expect(
        RequireExpr.parse('"好感" + "好感" < 60').evaluate(world),
        isFalse,
      );
      expect(RequireExpr.parse('"好感" == 50 & "好感" > 0').evaluate(world),
          isTrue);
      expect(RequireExpr.parse('"好感" == 1 | "好感" == 50').evaluate(world),
          isTrue);
    });

    test('语法错在装载期就被 RequireExpr.check 拦下（不会留到运行时）', () {
      expect(RequireExpr.check('"好感" === 50'), isNotNull);
      expect(RequireExpr.check('好感 > 50'), isNotNull, reason: '变量名必须带双引号');
      expect(RequireExpr.check('"好感" > 50'), isNull);
      // 校验器用同一个解析器：能装载 = 能判定
      expect(
        () => RequireExpr.parse('"好感" = 50'),
        throwsA(isA<RequireSyntaxException>()),
      );
    });
  });

  group('L5 自压缩', () {
    test('单条超限也能压（不再"压无可压"）', () async {
      final bank = MemoryBank(
        thresholds: const MemoryThresholds(l5MaxChars: 50, l5CompressBatch: 2),
      );
      bank.applyThresholds(bank.thresholds);
      final tree = bank.treeOf('jj');
      tree.add(MemoryEntry(
        memId: 'l5_only',
        layer: 5,
        owner: 'jj',
        text: '唯一一条但很长的核心记忆：' + '内容' * 40,
        audience: const ['jj'],
        createdAt: DateTime.now(),
      ));
      expect(tree.l5Chars, greaterThan(50));
      final rt = MemoryRuntime(provider: const DeterministicMemoryProvider());
      await rt.consolidate(bank, 'jj');
      expect(tree.l5Chars, lessThanOrEqualTo(50));
      expect(tree.layerList(5).where((e) => e.status == 'superseded').length, 1);
    });

    test('阈值被设成非正数时 consolidate 不崩、不死循环', () async {
      final bank = MemoryBank(
        thresholds: const MemoryThresholds(l2LiftCount: 0, l3LiftCount: 0),
      );
      bank.applyThresholds(bank.thresholds);
      final rt = MemoryRuntime(provider: const DeterministicMemoryProvider());
      await expectLater(rt.consolidate(bank, 'jj'), completes);
    });
  });
}
