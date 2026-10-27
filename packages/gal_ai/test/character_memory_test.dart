import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

void main() {
  CharacterMemoryTree seed() {
    final t = CharacterMemoryTree(owner: 'jj');
    for (var i = 0; i < 6; i++) {
      t.add(MemoryEntry(
        memId: 'l2_$i',
        layer: 2,
        owner: 'jj',
        text: 'seg$i',
        audience: const ['jj'],
        createdAt: DateTime.now(),
        source: {
          'kind': 'sceneLeave',
          'storyId': 's1',
          'visitId': 1,
          'sourceKnown': true,
        },
        sourceScenes: const [
          {'storyId': 's1', 'visitId': 1},
        ],
      ));
    }
    return t;
  }

  test('L2 cascade 6→3 marks aggregatedInto', () {
    final t = seed();
    t.cascadeDeterministic();
    expect(t.layerList(3).length, 1);
    expect(t.layerList(2).where((e) => e.aggregatedInto != null).length, 3);
    expect(t.layerList(2).where((e) => e.isPendingLift).length, 3);
  });

  test('L4 keep marks l5ReviewedBy and is not re-fed', () {
    final t = CharacterMemoryTree(owner: 'jj');
    for (var i = 0; i < 4; i++) {
      t.add(MemoryEntry(
        memId: 'l4_$i',
        layer: 4,
        owner: 'jj',
        text: 'trend$i',
        audience: const ['jj'],
        createdAt: DateTime.now(),
        source: const {'kind': 'cascade', 'sourceKnown': true},
      ));
    }
    t.cascadeDeterministic(updateIdPrefix: 'upd');
    expect(t.layerList(4)[0].l5ReviewedBy, startsWith('upd_'));
    expect(t.layerList(4)[1].l5ReviewedBy, startsWith('upd_'));
    expect(t.layerList(4)[0].isPendingLift, isFalse);
    // second cascade no change on those two
    t.cascadeDeterministic(updateIdPrefix: 'upd2');
    expect(t.layerList(4)[0].l5ReviewedBy, startsWith('upd_'));
  });

  test('evidence prefers L4 and blocks lower L2', () {
    final t = seed();
    // add L3 covering first 3 L2
    t.add(MemoryEntry(
      memId: 'l3_a',
      layer: 3,
      owner: 'jj',
      text: 'experience',
      audience: const ['jj'],
      createdAt: DateTime.now(),
      source: const {'kind': 'cascade', 'sourceKnown': true},
      sourceMemIds: const ['l2_0', 'l2_1', 'l2_2'],
      sourceScenes: const [
        {'storyId': 's1', 'visitId': 1},
      ],
    ));
    for (final id in ['l2_0', 'l2_1', 'l2_2']) {
      final i = t.layerList(2).indexWhere((e) => e.memId == id);
      t.layers[2]![i] = t.layerList(2)[i].copyWith(aggregatedInto: 'l3_a');
    }
    final processed = [
      ProcessedRange(
        charId: 'jj',
        storyId: 's1',
        visitId: 1,
        fromMsgId: 'm1',
        toMsgId: 'm6',
        turnIds: ['t1', 't2'],
        producedMemIds: const ['l2_0', 'l2_1', 'l2_2', 'l3_a'],
      ),
    ];
    final ev = t.collectEvidence(
      sceneMemIds: {'l2_0', 'l2_1', 'l2_2', 'l3_a'},
      sceneProcessed: processed,
    );
    final ids = ev.map((e) => e.memId).toSet();
    expect(ids.contains('l3_a'), isTrue);
    expect(ids.contains('l2_0'), isFalse);
    expect(ids.contains('l2_3'), isTrue); // unrelated L2 not covered by L3
  });

  test('assembler reserves prompts and rejects overflow', () {
    final t = CharacterMemoryTree(owner: 'jj');
    t.add(MemoryEntry(
      memId: 'l5',
      layer: 5,
      owner: 'jj',
      text: 'core',
      audience: const ['jj'],
      createdAt: DateTime.now(),
      source: const {'kind': 'l5Update', 'sourceKnown': true},
    ));
    final a = MemoryContextAssembler(maxTokens: 2000, replyReserve: 50);
    final msgs = a.assemble(
      protocolShell: 'shell',
      basePrompt: '你是角色',
      authorityFacts: 'day=1',
      tree: t,
      messages: const [
        {'turnId': 't1', 'role': 'user', 'content': 'hi', 'audience': ['jj']},
        {
          'turnId': 't1',
          'role': 'assistant',
          'content': 'hello',
          'audience': ['jj'],
        },
      ],
      currentUserInput: 'next',
    );
    expect(msgs.first['content'], 'shell');
    expect(msgs.any((m) => (m['content'] ?? '').contains('core')), isTrue);

    // Budget pressure must **degrade**, not throw: the fixed prefix (protocol
    // shell + prompts + facts) is always sent, optional memory is dropped.
    final tiny = MemoryContextAssembler(maxTokens: 50, replyReserve: 10);
    final squeezed = tiny.assemble(
      protocolShell: 'long' * 40,
      basePrompt: 'p' * 40,
      authorityFacts: '',
      tree: t,
      messages: const [],
      currentUserInput: '',
    );
    expect(squeezed.first['content'], 'long' * 40);
    expect(
      squeezed.any((m) => (m['content'] ?? '').contains('core')),
      isFalse,
      reason: '记忆被降级裁掉，但前缀仍在',
    );
  });

  test('processed turn excluded from history', () {
    final t = CharacterMemoryTree(owner: 'jj');
    t.processed.add(const ProcessedRange(
      charId: 'jj',
      storyId: 's1',
      visitId: 1,
      fromMsgId: 'm1',
      toMsgId: 'm2',
      turnIds: ['old'],
    ));
    final a = const MemoryContextAssembler(maxTokens: 2000, replyReserve: 20);
    final msgs = a.assemble(
      protocolShell: 's',
      basePrompt: 'b',
      authorityFacts: '',
      tree: t,
      messages: const [
        {'turnId': 'old', 'role': 'user', 'content': 'OLD'},
        {'turnId': 'old', 'role': 'assistant', 'content': 'OLD2'},
        {'turnId': 'new', 'role': 'user', 'content': 'NEW'},
        {'turnId': 'new', 'role': 'assistant', 'content': 'NEW2'},
      ],
      currentUserInput: 'x',
    );
    final all = msgs.map((m) => m['content']).join('\n');
    expect(all.contains('OLD'), isFalse);
    expect(all.contains('NEW'), isTrue);
  });
}
