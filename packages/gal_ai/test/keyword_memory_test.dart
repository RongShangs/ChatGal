import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 关键词记忆是「被提到才唤起细节」的并行通道，不该无限堆积。
/// 规则：入库即合并同类；到 L3 阶段合并同主题 + 超限丢最旧。
void main() {
  MemoryEntry l2(String id, String text) => MemoryEntry(
        memId: id,
        layer: 2,
        owner: 'jj',
        text: text,
        audience: const ['jj'],
        createdAt: DateTime.utc(2026, 9, 13),
      );

  group('入库合并', () {
    test('同一内容不重复入库，只并关键词', () {
      final bank = MemoryBank();
      bank.addKeyword(
        owner: 'jj',
        keywords: ['项链'],
        content: '她把项链摘下来交给他保管。',
        source: 's',
        audience: const ['jj'],
      );
      bank.addKeyword(
        owner: 'jj',
        keywords: ['银色', '项链'],
        content: '她把项链摘下来交给他保管。',
        source: 's',
        audience: const ['jj'],
      );
      final list = bank.treeOf('jj').keywordEvents;
      expect(list, hasLength(1));
      expect(
        (list.single['keywords'] as List).map((e) => '$e').toSet(),
        {'项链', '银色'},
      );
    });

    test('关键词集合相同也合并', () {
      final bank = MemoryBank();
      bank.addKeyword(
        owner: 'jj',
        keywords: ['雪糕'],
        content: '第一天她在冰柜前看了很久。',
        source: 's',
        audience: const ['jj'],
      );
      bank.addKeyword(
        owner: 'jj',
        keywords: ['雪糕'],
        content: '放学路上她又停下来看冰柜。',
        source: 's',
        audience: const ['jj'],
      );
      final list = bank.treeOf('jj').keywordEvents;
      expect(list, hasLength(1));
      expect('${list.single['content']}', contains('第一天'));
      expect('${list.single['content']}', contains('放学路上'));
    });
  });

  group('L3 阶段整理', () {
    test('超过上限 → 丢最旧，保留最新的 N 条', () {
      final tree = CharacterMemoryTree(owner: 'jj');
      for (var i = 0; i < 20; i++) {
        tree.keywordEvents.add({
          'owner': 'jj',
          'keywords': ['k$i'],
          'content': '细节$i',
          'source': 's',
          'audience': const ['jj'],
          'createdAt': '2026-09-13T00:00:00Z',
        });
      }
      final changed = tree.consolidateKeywords(5);
      expect(changed, isTrue);
      expect(tree.keywordEvents, hasLength(5));
      expect('${tree.keywordEvents.last['content']}', '细节19');
      expect(tree.recallKeywordCount('jj'), 5);
    });

    test('没有变化时不标脏（避免每轮都触发落盘）', () {
      final tree = CharacterMemoryTree(owner: 'jj');
      tree.keywordEvents.add({
        'owner': 'jj',
        'keywords': ['a'],
        'content': 'x',
        'source': 's',
        'audience': const ['jj'],
        'createdAt': '2026-09-13T00:00:00Z',
      });
      expect(tree.consolidateKeywords(12), isFalse);
    });

    test('consolidate 在 L2→L3 成功升层后整理关键词', () async {
      final bank = MemoryBank(
        thresholds: const MemoryThresholds(
          l2LiftCount: 3,
          l2LiftBatch: 3,
          l3KeywordMax: 4,
        ),
      );
      bank.applyThresholds(bank.thresholds);
      final tree = bank.treeOf('jj');
      // 攒够能升 L3 的 L2
      for (var i = 0; i < 3; i++) {
        tree.add(l2('l2_$i', '片段$i'));
      }
      // 关键词堆到超出上限
      for (var i = 0; i < 10; i++) {
        tree.keywordEvents.add({
          'owner': 'jj',
          'keywords': ['k$i'],
          'content': '细节$i',
          'source': 's',
          'audience': const ['jj'],
          'createdAt': '2026-09-13T00:00:00Z',
        });
      }
      final rt = MemoryRuntime(provider: const DeterministicMemoryProvider());
      await rt.consolidate(bank, 'jj');
      expect(tree.layerList(3), isNotEmpty, reason: '先确认确实升到 L3 了');
      expect(tree.keywordEvents.length, lessThanOrEqualTo(4));
    });
  });
}

extension on CharacterMemoryTree {
  int recallKeywordCount(String owner) => keywordEvents.length;
}
