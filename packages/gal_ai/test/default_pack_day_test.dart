import 'dart:io';

import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 默认包「你好戒戒」的天数账（用户点名要核的一条）。
///
/// 约定：`day` 默认 **0**，每一天的第一个情景（`start` / `dayN_1` / `endless_X_day`）
/// 在**入场改值**里 +1 —— 所以：
/// * 新游戏进 `start` 就是第 1 天；
/// * 走到 `dayN_3` 时 `day == N`（`dayN_1` 那一步已经 +1）；
/// * `day14_3` 的四块优先级链里 `"day" == 14` 读到的就是 14，不会变成 15。
///
/// 换句话说：**「第 7 天」的判定读到的确实是 7**（`day7_3` 这个幕名里的 7 不是
/// 「七杠什么」的编号，而是真的第 7 天）。
PackageContent loadDefault() {
  final root = Directory('${Directory.current.path}/../../content/default_v2');
  expect(root.existsSync(), isTrue, reason: root.path);
  final rootPath = root.absolute.path.replaceAll(r'\', '/');
  final files = <String, String>{};
  for (final f in root.listSync(recursive: true).whereType<File>()) {
    final rel = f.path.replaceAll(r'\', '/').substring(rootPath.length + 1);
    files[rel] = rel.endsWith('.png') ? '' : f.readAsStringSync();
  }
  return PackageLoader.fromFiles(files);
}

/// 从某一幕离场一次（数值给定，避免 mock 结算把分支带偏）。
Future<(String, WorldSnapshot)> leaveOnce(
  PackageContent content,
  String from, {
  required int day,
  int affection = 80,
  int trust = 80,
  int obedience = 50,
  int depravity = 0,
}) async {
  final reg = content.variableRegistry;
  final c = TransitionCoordinator(graph: content.sceneGraph!, registry: reg);
  final r = await c.leaveCurrent(
    sessionId: 's',
    world: WorldSnapshot(
      variables: {
        ...reg.defaults,
        'day': day,
        '戒戒好感': affection,
        '戒戒信任': trust,
        '戒戒服从': obedience,
        '戒戒堕落': depravity,
      },
      characters: const {},
      eventHistory: const {},
      story: {'storyId': from, 'day': day},
      presentation: const {},
      rngState: 1,
    ),
    messages: const [],
    baseRevision: 0,
    provider: const MockSettlementProvider(),
    cursor: RuntimeCursor(storyId: from, visitId: 0),
  );
  expect(r.accepted, isTrue, reason: r.error);
  return (r.nextSceneId ?? r.nextEventId ?? '', r.world!);
}

void main() {
  test('默认包：day 默认 0，新游戏进 start 就是第 1 天', () {
    final content = loadDefault();
    expect(content.variableRegistry['day']!.defaultValue, 0);
    expect(initialWorldFor(content).variables['day'], 1);
    // 开场那一幕就是第 1 天的白天
    final start = content.scene('start')!;
    expect(start.displayName, contains('白天'));
    expect(start.fixedEffects.map((f) => '${f.id}${f.value >= 0 ? '+' : ''}${f.value}'),
        ['day+1']);
  });

  test('一路走下来：dayN_3 离场时 day 就是 N（第 7 / 第 14 天的判定读到的值）', () async {
    final content = loadDefault();

    // 第 1 天：start（入场 +1，day=1）→ day1_2 → day1_3
    final (day1Next, day1World) = await leaveOnce(content, 'day1_3', day: 1);
    expect(day1Next, 'day2_1');
    expect(day1World.variables['day'], 2, reason: 'day2_1 的入场 +1');

    // 第 2~6 天：各自 +1，逐个对账
    for (var day = 2; day <= 6; day++) {
      final (next, world) = await leaveOnce(content, 'day${day}_3', day: day);
      expect(next, 'day${day + 1}_1', reason: '第 $day 天晚上接第 ${day + 1} 天白天');
      expect(world.variables['day'], day + 1, reason: 'day${day + 1}_1 的入场 +1');
    }

    // 第 7 天晚上：生死判定读的是 day == 7（好感够 → 进第 8 天）
    final (day7Next, day7World) = await leaveOnce(content, 'day7_3', day: 7);
    expect(day7Next, 'day8_1');
    expect(day7World.variables['day'], 8);

    // 第 8~13 天
    for (var day = 8; day <= 13; day++) {
      final (next, world) = await leaveOnce(content, 'day${day}_3', day: day);
      expect(next, 'day${day + 1}_1', reason: '第 $day 天晚上接第 ${day + 1} 天白天');
      expect(world.variables['day'], day + 1);
    }

    // 第 14 天晚上：判定块写的是 `"day" == 14`，读到的必须就是 14
    final day14 = content.scene('day14_3')!;
    expect(
      day14.target.first.require,
      contains('"day" == 14'),
      reason: '终局块靠 day == 14 生效',
    );
    final (day14Next, day14World) = await leaveOnce(content, 'day14_3', day: 14);
    expect(
      day14Next,
      startsWith('end_'),
      reason: '第 14 天晚上离场进结局事件',
    );
    expect(
      day14World.variables['day'],
      14,
      reason: '事件出口不再执行 fixedEffects：day 停在第 14 天，不会变成 15',
    );
  });

  test('低好感：第 7 天晚上走生死判定那条事件（day 仍是 7）', () async {
    final content = loadDefault();
    final (next, world) = await leaveOnce(
      content,
      'day7_3',
      day: 7,
      affection: 59,
    );
    expect(next, 'end_badend7');
    expect(world.variables['day'], 7);
  });

  test('无尽：每一天的第一幕同样 +1', () async {
    final content = loadDefault();
    for (final form in const ['human', 'cat', 'doll']) {
      final (next, world) = await leaveOnce(
        content,
        'endless_${form}_night',
        day: 30,
      );
      expect(next, 'endless_${form}_day');
      expect(world.variables['day'], 31, reason: '$form 无尽的一天 +1');
    }
  });
}
