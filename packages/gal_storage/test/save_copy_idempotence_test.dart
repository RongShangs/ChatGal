import 'dart:convert';
import 'dart:io';

import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';
import 'package:test/test.dart';

/// 复制 / 导入存档必须保持**事务历史的身份**（复审 P1）。
///
/// 结算与换幕的幂等 id 形如 `sid_<sessionId>_<情景>_v<访问号>`。
/// 复制/导入时如果换掉 `sessionId`、却把 `appliedSettlementIds` 原样抄过来，
/// 同一个访问号再走一次就会算出**对不上台账的新 id** → 同一幕重复加数值。
void main() {
  late Directory root;
  late SaveRepository saves;

  const ref = PackageRef(
    packageId: 'test.copy',
    version: '1',
    contentHash: 'h',
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('chatgal_copy_');
    saves = SaveRepository(rootDir: root.path, packages: PackageStore(root.path));
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<SaveSlot> seed() => saves.create(
        label: '原档',
        packageRef: ref,
        storyId: 'start',
        world: const WorldSnapshot(
          variables: {'day': 3},
          characters: {},
          story: {'storyId': 'start', 'nodeId': 'start', 'day': 3},
          presentation: {},
          eventHistory: {},
          rngState: 7,
        ),
      );

  test('复制档保留历史 sessionId → 同一访问号的幂等 id 仍然认得出来', () async {
    final src = await seed();
    // 这一幕（start 的第 3 次访问）已经结算过，记在台账里。
    final settledId = 'sid_${src.sessionId}_start_v3';
    final committedId = 'tr_${src.sessionId}_1_start_v3';
    await saves.update(
      src,
      appliedSettlementIds: [settledId],
      committedTransitions: [committedId],
      revision: 1,
    );

    final copy = await saves.copy(src.saveId, '副本');
    expect(copy, isNotNull);
    // 文件身份（saveId）换新，事务历史身份（sessionId）保持
    expect(copy!.saveId, isNot(src.saveId));
    expect(copy.sessionId, src.sessionId);
    expect(copy.appliedSettlementIds, contains(settledId));
    expect(copy.committedTransitions, contains(committedId));
    // 用副本自己的身份重新算一遍，仍然命中台账 → 不会重复结算
    expect(
      copy.appliedSettlementIds,
      contains('sid_${copy.sessionId}_start_v3'),
    );
  });

  test('导入档保留历史 sessionId → 幂等同样成立', () async {
    final src = await seed();
    final settledId = 'sid_${src.sessionId}_start_v5';
    await saves.update(
      src,
      appliedSettlementIds: [settledId],
      revision: 1,
    );
    final loaded = saves.load(src.saveId).slot!;
    final raw = jsonEncode({
      'exportType': 'chatgalsave',
      'slot': loaded.toJson(),
    });

    final imported = await saves.importFromJson(raw, labelOverride: '导入');
    expect(imported, isNotNull);
    expect(imported!.saveId, isNot(src.saveId));
    expect(imported.sessionId, src.sessionId);
    expect(
      imported.appliedSettlementIds,
      contains('sid_${imported.sessionId}_start_v5'),
    );
  });

  test('复制档带着 pending 一起走（恢复行为不能被落下）', () async {
    final src = await seed();
    await saves.update(
      src,
      pending: const PendingOp(
        kind: PendingOp.kindStoryTransition,
        id: 'tr_pending_1',
        baseRevision: 0,
      ),
      revision: 0,
    );
    final copy = await saves.copy(src.saveId, '副本');
    expect(copy!.pending, isNotNull);
    expect(copy.pending!.id, 'tr_pending_1');
    // 重新读盘也要还在（不是只在内存对象上）
    expect(saves.load(copy.saveId).slot!.pending?.id, 'tr_pending_1');
  });
}
