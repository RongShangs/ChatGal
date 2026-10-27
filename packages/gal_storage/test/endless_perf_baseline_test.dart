import 'dart:io';

import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 无尽模式长期性能基准：模拟大量回合后的存档文件增长与保存耗时。
///
/// 目的不是证明「不卡」，而是给出可复现的基线数据：
/// - 每回合消息与记忆的增量
/// - 存档文件大小随回合数的增长曲线
/// - 单次保存的耗时量级
///
/// 结论标注为基准测试，不是真机实测。
void main() {
  late Directory root;
  late SaveRepository saves;
  late PackageRef ref;

  setUp(() {
    root = Directory.systemTemp.createTempSync('chatgal_perf_');
    final packages = PackageStore(root.path);
    // 造一个最小可安装包（只为拿 PackageRef）。
    final installer = PackageInstaller(rootDir: root.path);
    // 直接写一个假的已装包目录（绕过安装器，测试只需 PackageRef）。
    final pkgDir = Directory(p.join(root.path, 'packages', 'perf.test', '1'));
    pkgDir.createSync(recursive: true);
    File(p.join(pkgDir.path, 'manifest.json')).writeAsStringSync('''
{"packageId":"perf.test","version":"1","name":"性能测试","author":"t","description":"d"}
''');
    File(p.join(pkgDir.path, '.content_hash')).writeAsStringSync('deadbeef');
    saves = SaveRepository(rootDir: root.path, packages: packages);
    ref = packages.listInstalled().first;
    // silence unused
    expect(installer, isNotNull);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 造一份「无尽跑了 N 轮」的存档内容。
  ({List<Map<String, Object?>> messages, Map<String, Object?> memory})
      buildEndlessState(int rounds) {
    final messages = <Map<String, Object?>>[];
    final turns = <Map<String, Object?>>[];
    for (var i = 0; i < rounds; i++) {
      final turnId = 'turn_$i';
      messages.add({
        'role': 'user',
        'content': '玩家第 $i 轮的话，带一些正常长度的文本内容。',
        'turnId': turnId,
      });
      messages.add({
        'role': 'assistant',
        'content': '角色第 $i 轮的回复，也带一些正常长度的文本内容。',
        'turnId': turnId,
      });
      turns.add({
        'turnId': turnId,
        'playerText': '玩家第 $i 轮的话，带一些正常长度的文本内容。',
        'replyText': '角色第 $i 轮的回复，也带一些正常长度的文本内容。',
        'audience': ['戒戒'],
        'storyId': 'endless_human_day',
        'visitId': i,
        'at': DateTime.now().toUtc().toIso8601String(),
      });
    }
    // 简化记忆：L1 窗口 + 少量 L2
    final memory = <String, Object?>{
      'trees': {
        '戒戒': {
          'owner': '戒戒',
          'layers': {
            '2': [
              for (var i = 0; i < (rounds / 10).ceil(); i++)
                {
                  'memId': 'l2_$i',
                  'layer': 2,
                  'owner': '戒戒',
                  'text': '第 ${i * 10}~${i * 10 + 9} 轮的摘要内容。',
                  'audience': ['戒戒'],
                  'createdAt': DateTime.now().toUtc().toIso8601String(),
                  'source': {'kind': 'cascade', 'fromLayer': 1},
                  'sourceScenes': [],
                },
            ],
          },
        },
      },
      'windows': {
        '戒戒': turns,
      },
    };
    return (messages: messages, memory: memory);
  }

  test('无尽 200 轮：存档大小与保存耗时基线', () async {
    final state = buildEndlessState(200);
    final world = WorldSnapshot(
      variables: {'day': 200, '戒戒好感': 70, '戒戒信任': 60},
      characters: const {},
      eventHistory: const {},
      story: {'storyId': 'endless_human_day', 'day': 200},
      presentation: const {},
      rngState: 200,
    );

    final sw = Stopwatch()..start();
    final slot = await saves.create(
      label: '无尽200轮',
      packageRef: ref,
      storyId: 'endless_human_day',
      world: world,
      sessionId: 'perf_200',
      messages: state.messages,
      memory: state.memory,
    );
    sw.stop();
    final createMs = sw.elapsedMilliseconds;

    final saveFile = File(p.join(root.path, 'saves', '${slot.saveId}.json'));
    // 注意：这是**真实落盘**的大小（存档现在缩进 2 格写出，比紧凑 JSON 大约 +50%）。
    final sizeBytes = saveFile.lengthSync();
    final jsonLen = saveFile.readAsStringSync().length;

    // 再做 10 次 update 测量平均耗时
    sw.reset();
    sw.start();
    const updates = 10;
    for (var i = 0; i < updates; i++) {
      await saves.update(
        slot,
        world: world.copyWith(rngState: 200 + i + 1),
        messages: state.messages,
        revision: i + 1,
      );
    }
    sw.stop();
    final avgUpdateMs = sw.elapsedMilliseconds / updates;

    // 输出基线数据（测试日志）
    // ignore: avoid_print
    print('[perf-baseline] rounds=200 '
        'createMs=$createMs '
        'sizeBytes=$sizeBytes '
        'jsonChars=$jsonLen '
        'avgUpdateMs=${avgUpdateMs.toStringAsFixed(1)}');

    // 基本合理性断言（不是性能 SLA）
    expect(createMs, lessThan(5000), reason: '创建存档不应超过 5 秒');
    expect(avgUpdateMs, lessThan(2000), reason: '单次更新不应超过 2 秒');
    expect(sizeBytes, greaterThan(1000), reason: '200 轮应有实质内容');
  });

  test('消息与记忆随轮数近似线性增长', () async {
    final sizes = <int, int>{};
    for (final rounds in const [50, 100, 200]) {
      final state = buildEndlessState(rounds);
      final world = WorldSnapshot(
        variables: {'day': rounds},
        characters: const {},
        eventHistory: const {},
        story: const {},
        presentation: const {},
        rngState: 1,
      );
      final slot = await saves.create(
        label: 'r$rounds',
        packageRef: ref,
        storyId: 's',
        world: world,
        messages: state.messages,
        memory: state.memory,
      );
      final f = File(p.join(root.path, 'saves', '${slot.saveId}.json'));
      sizes[rounds] = f.lengthSync();
    }
    // ignore: avoid_print
    print('[perf-baseline] sizes: $sizes');
    // 200 轮应明显大于 50 轮（近似线性，允许一定偏差）
    expect(sizes[200]!, greaterThan(sizes[50]! * 2),
        reason: '200 轮大小应至少是 50 轮的 2 倍以上');
  });
}
