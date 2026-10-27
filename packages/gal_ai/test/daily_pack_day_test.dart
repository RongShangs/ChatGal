import 'dart:io';

import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 教学包「与戒戒的每一天」的天数位置（用户报的「day+1 应该在白天」）。
///
/// 三幕循环：白天（start）→ 下午 → 晚上 → 回到白天。
/// `day+1` 写在**白天**那一幕的入场改值里（入场才执行），所以：
/// * 开新游戏：`day` 默认 0 + 进场 +1 = **第 1 天**；
/// * 下午/晚上：天数不动（以前写在晚上，晚上那一屏就提前变成第二天了）；
/// * 晚上回到白天：+1 → 第 2 天。
PackageContent loadDaily() {
  final root = Directory('${Directory.current.path}/../../content/daily_v2');
  expect(root.existsSync(), isTrue, reason: root.path);
  final rootPath = root.absolute.path.replaceAll(r'\', '/');
  final files = <String, String>{};
  for (final f in root.listSync(recursive: true).whereType<File>()) {
    final rel = f.path.replaceAll(r'\', '/').substring(rootPath.length + 1);
    files[rel] = rel.endsWith('.png') ? '' : f.readAsStringSync();
  }
  return PackageLoader.fromFiles(files);
}

/// 从某一幕离场一次，返回（下一幕 id，离场后的世界）。
Future<(String, WorldSnapshot)> leaveOnce(
  PackageContent content,
  String from, {
  required int day,
}) async {
  final c = TransitionCoordinator(
    graph: content.sceneGraph!,
    registry: content.variableRegistry,
  );
  final r = await c.leaveCurrent(
    sessionId: 's',
    world: WorldSnapshot(
      variables: {...content.variableRegistry.defaults, 'day': day},
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
  test('教学包结构：day+1 在「白天」，下午/晚上都不改天数', () {
    final content = loadDaily();
    expect(const PackageValidator().validate(content).isValid, isTrue);

    // day 默认 0：进场 +1 才是第 1 天
    expect(content.variableRegistry['day']!.defaultValue, 0);

    final day = content.scene('start')!.fixedEffects;
    expect(day.map((f) => f.id), ['day']);
    expect(day.single.value, 1);
    expect(content.scene('day_afternoon')!.fixedEffects, isEmpty);
    expect(content.scene('day_night')!.fixedEffects, isEmpty);

    // 三幕循环的出口链
    expect(content.scene('start')!.target.single.kinds.single.to, 'day_afternoon');
    expect(
      content.scene('day_afternoon')!.target.single.kinds.single.to,
      'day_night',
    );
    expect(content.scene('day_night')!.target.single.kinds.single.to, 'start');
  });

  test('开新游戏是第 1 天（默认 0 + 入场 +1）', () {
    final content = loadDaily();
    expect(initialWorldFor(content).variables['day'], 1);
  });

  test('下午 → 晚上：天数不动；晚上 → 白天：+1', () async {
    final content = loadDaily();

    final (toNight, atNight) = await leaveOnce(content, 'day_afternoon', day: 2);
    expect(toNight, 'day_night');
    expect(
      atNight.variables['day'],
      2,
      reason: '晚上不该改天数（以前写在晚上，那一屏就提前成了第二天）',
    );

    final (toDay, atDay) = await leaveOnce(content, 'day_night', day: 2);
    expect(toDay, 'start');
    expect(
      atDay.variables['day'],
      3,
      reason: '新的一天从白天开始：回到 start 时 +1',
    );
  });
}
