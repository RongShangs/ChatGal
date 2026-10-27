import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 内容包版本号是**同一个数字的多份副本**，历史上因为不同步踩过坑：
/// 「安装新版 → 清理旧版」按 `packageId + version` 判断，版本号写错就是把刚装上的包
/// 当成旧版删掉，或者已装用户永远收不到新内容。
///
/// 现在唯一的守门是 `tools/pack_default_v2.py` 跑的那一瞬，而那要人记得跑。
/// 这条测试跟着测试一起走：漏改任何一处，跑测试就红。
void main() {
  final root = Directory('${Directory.current.path}/../..');

  String read(String relative) =>
      File('${root.path}/$relative').readAsStringSync();

  String jsonVersion(String relative) {
    final match = RegExp(
      r'"version"\s*:\s*"([^"]+)"',
    ).firstMatch(read(relative));
    expect(match, isNotNull, reason: '$relative 里没有 version');
    return match!.group(1)!;
  }

  String dartConst(String name) {
    final match = RegExp("$name\\s*=\\s*'([^']+)'")
        .firstMatch(read('apps/chatgal/lib/app/app_services.dart'));
    expect(match, isNotNull, reason: 'app_services.dart 里没有 $name');
    return match!.group(1)!;
  }

  test('默认包版本号：manifest / app_services / 重建脚本三者一致', () {
    final manifest = jsonVersion('content/default_v2/manifest.json');
    expect(
      int.tryParse(manifest),
      isNotNull,
      reason: '默认包版本号只能是数字（现在是 $manifest）',
    );
    expect(
      dartConst('defaultPackageVersion'),
      manifest,
      reason: 'app_services.defaultPackageVersion 与 manifest 必须同改',
    );
    // 重建脚本会**无条件**把自己那份版本写进 manifest：漏改它，跑一次重建
    // 就把版本号改回旧值（打包脚本下一轮才报 mismatch，还看不出是谁改的）。
    final rebuild = RegExp(
      r'^VERSION\s*=\s*"([^"]+)"',
      multiLine: true,
    ).firstMatch(read('tools/rebuild_default_v2_demo.py'));
    expect(rebuild, isNotNull, reason: '重建脚本里没有 VERSION');
    expect(
      rebuild!.group(1),
      manifest,
      reason: 'rebuild_default_v2_demo.py 的 VERSION 与 manifest 必须同改',
    );
  });

  test('教学包版本号：manifest / app_services 一致', () {
    final manifest = jsonVersion('content/daily_v2/manifest.json');
    expect(int.tryParse(manifest), isNotNull, reason: '教学包版本号只能是数字');
    expect(
      dartConst('dailyPackageVersion'),
      manifest,
      reason: 'app_services.dailyPackageVersion 与 manifest 必须同改',
    );
  });

  test('两个内置包的打包产物都在位（漏打包时至少能看见）', () {
    for (final rel in [
      'apps/chatgal/assets/hellojj_default.chatgal',
      'apps/chatgal/assets/hellojj_daily.chatgal',
    ]) {
      final f = File('${root.path}/$rel');
      expect(f.existsSync(), isTrue, reason: '$rel 是打包脚本的产物');
      expect(
        f.lengthSync(),
        greaterThan(1024 * 1024),
        reason: '$rel 体积不对，可能是空壳',
      );
    }
  });
}
