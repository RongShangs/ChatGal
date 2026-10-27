import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gal_storage/gal_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// **内容哈希值一个字节都不许变**。
///
/// 它写在安装目录的 `.content_hash` 里，存档的 `packageRef.contentHash` 绑着它，
/// app 启动时还用 `startsWith('v2:')` 判断默认包要不要重装。所以「把二进制从
/// base64 常驻内存改成流式」这类优化只能改内存占用，不能改摘要结果 ——
/// 这里用旧算法的复刻版当守门人。
void main() {
  test('内容哈希与旧算法逐位一致（二进制走 base64 文本摘要）', () async {
    final root = Directory.systemTemp.createTempSync('chatgal_hash_');
    addTearDown(() => root.deleteSync(recursive: true));
    final src = Directory(p.join(root.path, 'src'));
    _writePackage(src);
    // 立绘写成真字节（不是空串）：必须走到二进制分支
    File(p.join(src.path, 'characters/guide/便服_平常.png'))
        .writeAsBytesSync(List<int>.generate(4096, (i) => i % 251));

    final installer = PackageInstaller(rootDir: root.path);
    final r = await installer.installFromPath(src.path);
    expect(r.ok, isTrue, reason: r.error?.message);

    final expected = _legacyContentHash(src);
    expect(expected.startsWith('v2:'), isTrue);
    expect(r.contentHash, expected, reason: '哈希值不能因为改成流式就变了');
    expect(
      File(p.join(r.installDir!, '.content_hash')).readAsStringSync().trim(),
      expected,
    );
    // 同一个目录直接算哈希也一致
    expect(await installer.hashOfDirectory(src.path), expected);

    // 换一个字节 → 哈希必须变（「换图但文本不变」不能撞哈希）
    File(p.join(src.path, 'characters/guide/便服_平常.png'))
        .writeAsBytesSync(List<int>.generate(4096, (i) => (i + 1) % 251));
    expect(await installer.hashOfDirectory(src.path), isNot(expected));
  });

  test('分块 base64 摘要：跨块进位与三种余数（0/1/2）都与旧算法一致', () async {
    final root = Directory.systemTemp.createTempSync('chatgal_hash_chunk_');
    addTearDown(() => root.deleteSync(recursive: true));
    final dir = Directory(p.join(root.path, 'bin'));
    await dir.create(recursive: true);
    // 0~8 字节覆盖 base64 的三种余数；200000 字节（> 64KB 读块）覆盖跨块进位。
    for (var n = 0; n <= 8; n++) {
      await File(p.join(dir.path, 'b$n.bin'))
          .writeAsBytes(List<int>.generate(n, (i) => i + 1));
    }
    await File(p.join(dir.path, 'big.bin'))
        .writeAsBytes(List<int>.generate(200000, (i) => i % 256));
    final installer = PackageInstaller(rootDir: root.path);
    expect(await installer.hashOfDirectory(dir.path), _legacyContentHash(dir));
  });
}

/// 旧算法的复刻（升级前的 `_readTree` + `_contentHash`）：
/// 文本读 `readAsString()`、二进制读字节再 base64；
/// 每份内容各算一次 sha256，再按排序后的 `相对路径:摘要` 行合成总摘要。
String _legacyContentHash(Directory dir) {
  final rootPath = dir.absolute.path.replaceAll('\\', '/');
  final values = <String, String>{};
  for (final f in dir.listSync(recursive: true, followLinks: false)) {
    if (f is! File) continue;
    final rel = f.path.replaceAll('\\', '/').substring(rootPath.length + 1);
    if (rel.startsWith('.')) continue;
    final lower = rel.toLowerCase();
    final isText = lower.endsWith('.json') ||
        lower.endsWith('.md') ||
        lower.endsWith('.txt') ||
        lower.endsWith('.csv');
    values[rel] = isText
        ? f.readAsStringSync()
        : base64Encode(f.readAsBytesSync());
  }
  final keys = values.keys.toList()..sort();
  final buf = StringBuffer();
  for (final k in keys) {
    buf.writeln('$k:${sha256.convert(utf8.encode(values[k]!))}');
  }
  return 'v2:${sha256.convert(utf8.encode(buf.toString()))}';
}

/// 最小可安装包（扁平 v2 布局）。
void _writePackage(Directory src) {
  final files = {
    'manifest.json': '''
{
  "packageId": "demo.hash",
  "version": "250",
  "name": "哈希守门",
  "author": "t",
  "description": "d",
  "variables": [
    { "id": "day", "type": "int", "default": 1, "min": 1, "max": 9999 }
  ]
}
''',
    'characters/guide/character.json': '''
{
  "id": "guide",
  "prompt": "你是向导。",
  "defaultState": "便服",
  "defaultEmotion": "平常",
  "states": ["便服"],
  "emotions": ["平常"]
}
''',
    'stories/start.json': '''
{
  "displayName": "开始",
  "background": "bg.png",
  "narration": "入场词",
  "characters": [
    { "charId": "guide", "state": "便服", "emotion": "平常", "scenePrompt": "本幕：第一天。" }
  ],
  "fixedEffects": [],
  "target": [
    { "kind": [ { "kind": "story", "to": "start" } ] }
  ]
}
''',
    'stories/bg.png': '',
  };
  for (final e in files.entries) {
    final f = File(p.join(src.path, e.key));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(e.value);
  }
}
