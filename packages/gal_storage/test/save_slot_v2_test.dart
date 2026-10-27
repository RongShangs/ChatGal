import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';
import 'package:test/test.dart';

void main() {
  test('存档：分区形状 roundtrip（身份 / 包 / 运行位 / 对白）', () {
    final world = WorldSnapshot(
      variables: const {'day': 0},
      characters: const {
        'demo': {'affection': 50},
      },
      eventHistory: const {},
      story: const {'storyId': 'start'},
      presentation: const {},
      rngState: 1,
    );
    final slot = SaveSlot(
      saveId: 'a',
      sessionId: 's',
      label: 'L',
      packageRef: PackageRef(
        packageId: 'p',
        version: '1',
        contentHash: 'h',
      ),
      storyId: 'start',
      world: world,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      saveSchemaVersion: SaveSlot.currentSchemaVersion,
      revision: 3,
      runtimeCursor: const RuntimeCursor(storyId: 's1', visitId: 2),
      committedTransitions: const ['tr_a'],
      pending: const PendingOp(
        kind: PendingOp.kindCollapse,
        id: 'col_1',
        baseRevision: 3,
        cache: {'turnIds': ['t1']},
      ),
    );
    final json = slot.toJson();
    final back = SaveSlot.fromJson(json);
    expect(back.revision, 3);
    expect(back.runtimeCursor.storyId, 's1');
    expect(back.pending!.id, 'col_1');
    expect(back.pending!.kind, PendingOp.kindCollapse);
    expect(json.containsKey('endingId'), isFalse);
    // **分区形状**：身份在 identity、运行位在 progress、世界在 world
    expect(json['world'], isA<Map>());
    expect((json['identity']! as Map)['saveId'], 'a');
    expect((json['identity']! as Map)['revision'], 3);
    expect((json['progress']! as Map)['storyId'], 'start');
    expect((json['package']! as Map)['packageId'], 'p');
    expect(json['messages'], isEmpty);
    expect(json['eventLedger'], isEmpty);
  });
}
