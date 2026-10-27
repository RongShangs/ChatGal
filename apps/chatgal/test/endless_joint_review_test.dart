import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';

class _Packages extends PackageStore {
  _Packages(super.rootDir);
  @override
  PackageRef? findExact(String id, String version, String hash) =>
      PackageRef(packageId: id, version: version, contentHash: hash);
}

void main() {
  test('真实默认包 200 次无尽换幕：提炼升层、保存重载、幂等台账联合基线', () async {
    final contentRoot = Directory('../../content/default_v2').absolute;
    final prefix = contentRoot.path.replaceAll('\\', '/');
    final files = <String, String>{};
    for (final f in contentRoot.listSync(recursive: true).whereType<File>()) {
      final rel = f.path.replaceAll('\\', '/').substring(prefix.length + 1);
      files[rel] = rel.endsWith('.png') ? '' : f.readAsStringSync();
    }
    final content = PackageLoader.fromFiles(files);
    final root = Directory.systemTemp.createTempSync('chatgal_joint_');
    addTearDown(() => root.deleteSync(recursive: true));
    final repo = SaveRepository(
      rootDir: root.path,
      packages: _Packages(root.path),
    );
    final memory = MemoryRuntime(provider: const DeterministicMemoryProvider());
    var bank = MemoryBank();
    var slot = await repo.create(
      label: '联合基线',
      packageRef: const PackageRef(
        packageId: 'joint',
        version: '254',
        contentHash: 'test',
      ),
      storyId: 'endless_human_day',
      world: initialWorldFor(content).copyWith(
        variables: {...content.variableRegistry.defaults, 'day': 15},
        story: {
          'storyId': 'endless_human_day',
          'nodeId': 'endless_human_day',
          'day': 15,
        },
      ),
    );
    final watch = Stopwatch()..start();
    for (var i = 0; i < 200; i++) {
      final owner = content.characters.single.id;
      bank.recordTurn(
        DialogueTurn(
          turnId: 'round_$i',
          playerText: '一起散步 $i',
          replyText: '好呀 $i',
          audience: [owner],
          storyId: slot.runtimeCursor.storyId!,
          visitId: slot.runtimeCursor.visitId,
          at: DateTime.utc(2026, 9, 15),
        ),
      );
      final coord = TransitionCoordinator(
        graph: content.sceneGraph!,
        registry: content.variableRegistry,
        memory: memory,
      );
      final result = await coord.leaveCurrent(
        sessionId: slot.sessionId,
        world: slot.world,
        messages: [
          ...slot.messageCheckpoint,
          {'role': 'user', 'content': '一起散步 $i'},
          {'role': 'assistant', 'content': '好呀 $i'},
        ],
        baseRevision: slot.revision,
        cursor: slot.runtimeCursor,
        bank: bank,
        committedTransitions: slot.committedTransitions,
        appliedSettlementIds: slot.appliedSettlementIds,
        provider: const MockSettlementProvider(),
      );
      expect(result.accepted, isTrue, reason: 'turn $i: ${result.error}');
      expect(result.targetKind, 'story');
      bank = result.memories!;
      await memory.consolidate(bank, owner);
      slot = await repo.update(
        slot,
        world: result.world,
        messages: result.messages,
        revision: result.revision,
        runtimeCursor: result.cursor,
        committedTransitions: [
          ...slot.committedTransitions,
          result.transitionId!,
        ],
        appliedSettlementIds: [
          ...slot.appliedSettlementIds,
          ...result.appliedSettlementIds,
        ],
        memoryCheckpoint: bank.toJson(),
      );
      slot = repo.load(slot.saveId).slot!;
      bank = MemoryBank.fromJson(slot.memoryCheckpoint);
      expect(slot.runtimeCursor.visitId, i + 1);
      expect(slot.committedTransitions.toSet(), hasLength(i + 1));
    }
    watch.stop();
    expect(slot.world.variables['day'] as num, greaterThan(50));
    expect(bank.treeOf(content.characters.single.id).layerList(3), isNotEmpty);
    expect(bank.treeOf(content.characters.single.id).layerList(4), isNotEmpty);
    expect(
      slot.messageCheckpoint.where((m) => m['role'] == 'user'),
      hasLength(200),
    );
    // 这条量的是**数据模型**的紧凑大小（不是真实落盘文件：存档在磁盘上是缩进写出的，
    // 大约 +50%）。当模型增长的护栏用，不当文件大小承诺。
    final bytes = utf8.encode(jsonEncode(slot.toJson())).length;
    // 主机侧观测值，不把主机耗时当作 Android 性能承诺。
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(0));
    expect(bytes, lessThan(16 * 1024 * 1024));
  });
}
