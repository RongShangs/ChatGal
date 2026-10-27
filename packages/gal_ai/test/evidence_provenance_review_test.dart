import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

void main() {
  final scene = SceneDef.fromJson({'displayName': 's'}, id: 's');
  final rt = MemoryRuntime(provider: const DeterministicMemoryProvider());
  MemoryEntry entry({bool? interaction, String? aggregatedInto}) =>
      MemoryEntry.fromJson({
        'memId': 'm',
        'layer': 2,
        'owner': 'a',
        'text': '保留的摘要',
        'audience': ['a'],
        'createdAt': '2026-09-15T00:00:00Z',
        'sourceScenes': [
          {'storyId': 's', 'visitId': 2}
        ],
        if (interaction != null) 'hasPlayerInteraction': interaction,
        if (aggregatedInto != null) 'aggregatedInto': aggregatedInto,
      });
  test('unknown provenance keeps text but does not invent interaction', () {
    final bank = MemoryBank();
    bank.treeOf('a').add(entry());
    expect(bank.treeOf('a').injectable(2).single.text, '保留的摘要');
    expect(
        rt.buildEvidence(
            bank: bank,
            owner: 'a',
            scene: scene,
            visitId: 2,
            day: 1,
            audience: ['a'],
            state: {}).hasContent,
        isFalse);
  });
  test('lifting L2 does not remove current-visit settlement evidence', () {
    final bank = MemoryBank();
    bank.treeOf('a').add(entry(interaction: true, aggregatedInto: 'l3'));
    expect(bank.treeOf('a').injectable(2), isEmpty);
    expect(
        rt.buildEvidence(
            bank: bank,
            owner: 'a',
            scene: scene,
            visitId: 2,
            day: 1,
            audience: ['a'],
            state: {}).shortTerm,
        contains('保留的摘要'));
    expect(
        rt.buildEvidence(
            bank: bank,
            owner: 'a',
            scene: scene,
            visitId: 3,
            day: 1,
            audience: ['a'],
            state: {}).hasContent,
        isFalse);
  });
}
