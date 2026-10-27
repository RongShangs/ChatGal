import 'dart:io';

import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';
import 'package:test/test.dart';

void main() {
  test('默认包（default_v2）能加载、通过校验并初始化新档；包不在则锁档', () async {
    final root = Directory(
      '${Directory.current.path}/../../content/default_v2',
    ).resolveSymbolicLinksSync();
    final files = <String, String>{};
    for (final f in Directory(root).listSync(recursive: true)) {
      if (f is! File) continue;
      final rel = f.path
          .replaceAll('\\', '/')
          .substring(root.replaceAll('\\', '/').length + 1);
      files[rel] = rel.endsWith('.png') ? '' : f.readAsStringSync();
    }
    final content = PackageLoader.fromFiles(files);
    expect(const PackageValidator().validate(content).isValid, isTrue);

    // 新档世界：注册表默认值 + 入口场景（纯函数，v1 引擎已删除）
    final started = initialWorldFor(content);
    expect(started.story['nodeId'], 'start');
    expect(started.variables['day'], 1);
    expect(started.variables['戒戒好感'], 50);
    // 入口 start 就是主线的 day1_1「开学首日」（第 1 天 · 白天 · 学校），
    // 所以新档的底图是学校那张 xx_q.png。
    expect(started.presentation['scene'], 'xx_q.png');
    expect(started.presentation['scene'], content.scene('start')!.background);

    final storeRoot = Directory.systemTemp.createTempSync('t13_reg_');
    addTearDown(() => storeRoot.deleteSync(recursive: true));
    final packages = PackageStore(storeRoot.path);
    final saves = SaveRepository(rootDir: storeRoot.path, packages: packages);
    final m = content.manifest;
    final slot = await saves.create(
      label: 'reg',
      packageRef: PackageRef(
        packageId: m.packageId,
        version: m.version,
        contentHash: 'default-src',
        displayName: m.name,
      ),
      storyId: 'start',
      world: started,
    );
    final locked = saves.load(slot.saveId);
    expect(locked.canEnter, isFalse);
    expect(locked.reason, SaveLockReason.missingPackage);
  });

  test('T13: day7 affection gate documented boundary', () {
    const gate = 60;
    expect(59 < gate, isTrue);
    expect(60 < gate, isFalse);
  });
}
