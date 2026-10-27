import 'dart:convert';
import 'dart:io';

import 'package:gal_storage/gal_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 安装日志改成 append-only（一行一条 JSON）之后的行为：
/// 只追加不重写、尾行坏了不丢整份、旧格式还能读、超量按条数轮转。
void main() {
  late Directory root;
  late String path;

  setUp(() {
    root = Directory.systemTemp.createTempSync('chatgal_installlog_');
    path = p.join(root.path, 'install_log.json');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('append-only：一条一行，历史不会被重写', () async {
    final log = InstallLog(path);
    await log.write({'phase': 'staging', 'n': 1});
    await log.write({'phase': 'registered', 'n': 2});

    final lines = File(path)
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .toList();
    expect(lines, hasLength(2));
    // 每一行都是独立完整的 JSON（不是整份数组的一部分）
    for (final line in lines) {
      expect(jsonDecode(line), isA<Map>());
    }

    final all = await log.readAll();
    expect(all.map((e) => e['n']), [1, 2]);
    expect(all.every((e) => e['at'] is String), isTrue);
  });

  test('容忍尾行损坏：append 到一半被杀不丢整份日志', () async {
    final log = InstallLog(path);
    await log.write({'n': 1});
    await log.write({'n': 2});
    // 半截尾行（写到一半被杀）
    File(path).writeAsStringSync('{"n": 3, "pha', mode: FileMode.append);
    expect((await log.readAll()).map((e) => e['n']), [1, 2]);
  });

  test('旧格式（整份一个 JSON 数组）仍然读得出来', () async {
    File(path).writeAsStringSync(jsonEncode([
      {'n': 1},
      {'n': 2},
    ]));
    expect((await InstallLog(path).readAll()).map((e) => e['n']), [1, 2]);
  });

  test('轮转：只保留最近 N 条', () async {
    final log = InstallLog(path, maxEntries: 3);
    final pad = List<String>.filled(600, 'x').join();
    for (var i = 0; i < 60; i++) {
      await log.write({'n': i, 'pad': pad});
    }
    final all = await log.readAll();
    expect(all, hasLength(3));
    expect(all.map((e) => e['n']), [57, 58, 59], reason: '留最新的，丢最旧的');
    // 轮转后仍然是可追加的 JSONL，而不是被截断的半份文件
    expect(File(path).readAsLinesSync().where((l) => l.trim().isNotEmpty),
        hasLength(3));
  });

  test('clear 把日志整份删掉', () async {
    final log = InstallLog(path);
    await log.write({'n': 1});
    expect(File(path).existsSync(), isTrue);
    await log.clear();
    expect(File(path).existsSync(), isFalse);
    expect(await log.readAll(), isEmpty);
  });

  test('目录不存在时会建出来（安装器第一次写日志）', () async {
    final nested = p.join(root.path, 'deep', 'log.json');
    final log = InstallLog(nested);
    await log.write({'n': 1});
    expect(File(nested).existsSync(), isTrue);
    expect((await log.readAll()).single['n'], 1);
  });
}
