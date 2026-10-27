import 'dart:io';

import 'package:gal_storage/gal_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Directory tempRoot() {
  final dir = Directory.systemTemp.createTempSync('chatgal_t03_');
  return dir;
}

/// 最小的**扁平 v2** 包（loader 只认这一种结构；v1 的
/// `stories/<id>/nodes.json` + `assets/index.json` 已被拒绝）。
///
/// 夹具按新契约写：manifest 只有 packageId/version/name/author/description/variables
/// （`version` 只能是数字），角色人格**内联**在 `prompt` 里，立绘只靠
/// `characters/<id>/<状态>_<情绪>.png` 命名约定，情景是**扁平**的
/// （文件名 stem 就是 id），出口写在 `target` 块数组里。
Map<String, String> minimalFiles() {
  return {
    'manifest.json': '''
{
  "packageId": "demo.install",
  "version": "250",
  "name": "安装测试",
  "author": "t",
  "description": "d",
  "variables": [
    { "id": "day", "type": "int", "default": 1, "min": 1, "max": 9999 }
  ]
}
''',
    'home.png': '',
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
    'characters/guide/便服_平常.png': '',
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
}

Future<void> writeDir(Directory dir, Map<String, String> files) async {
  for (final e in files.entries) {
    final f = File(p.join(dir.path, e.key));
    await f.parent.create(recursive: true);
    await f.writeAsString(e.value);
  }
}

void main() {
  test('temporary publication with a hash marker remains invisible', () async {
    final root = tempRoot();
    addTearDown(() => root.deleteSync(recursive: true));
    final temporary = Directory(
        p.join(root.path, 'packages', 'demo.install', '250.tmp_install_test'));
    await writeDir(temporary, minimalFiles());
    await File(p.join(temporary.path, '.content_hash')).writeAsString('ready');
    final store = PackageStore(root.path);
    expect(store.listInstalled(), isEmpty);
    await temporary
        .rename(p.join(root.path, 'packages', 'demo.install', '250'));
    expect(store.listInstalled(), hasLength(1));
  });

  test('install from directory, list, export reimport hash stable', () async {
    final root = tempRoot();
    addTearDown(() => root.deleteSync(recursive: true));

    final src = Directory(p.join(root.path, 'src'));
    await writeDir(src, minimalFiles());

    final installer = PackageInstaller(rootDir: root.path);
    final r1 = await installer.installFromPath(src.path);
    expect(r1.ok, isTrue, reason: r1.error?.toString());
    expect(r1.packageRef!.packageId, 'demo.install');
    expect(r1.packageRef!.version, '250');
    expect(r1.contentHash, isNotEmpty);

    final store = PackageStore(root.path);
    final list = store.listInstalled();
    expect(list, hasLength(1));
    expect(list.single.version, '250');

    final export = await installer.exportInstalled(r1.installDir!);
    expect(export.ok, isTrue, reason: export.error?.toString());

    // Reinstall export into fresh root should produce same contentHash
    final root2 = tempRoot();
    addTearDown(() => root2.deleteSync(recursive: true));
    final installer2 = PackageInstaller(rootDir: root2.path);
    final r2 = await installer2.installFromPath(export.file!);
    expect(r2.ok, isTrue, reason: r2.error?.toString());
    expect(r2.contentHash, r1.contentHash);
  });

  test('v1 布局（stories/main/nodes.json）被拒绝', () async {
    final root = tempRoot();
    addTearDown(() => root.deleteSync(recursive: true));
    final src = Directory(p.join(root.path, 'v1'));
    final files = minimalFiles()
      ..remove('stories/start.json')
      ..['stories/main/nodes.json'] =
          '[{"id": "n1", "title": "a", "text": "t"}]'
      ..['assets/index.json'] = '{"assets": []}';
    await writeDir(src, files);

    final installer = PackageInstaller(rootDir: root.path);
    final r = await installer.installFromPath(src.path);
    expect(r.ok, isFalse);
  });

  test('path traversal zip is rejected', () async {
    final root = tempRoot();
    addTearDown(() => root.deleteSync(recursive: true));
    final bad = Directory(p.join(root.path, 'bad'));
    await writeDir(bad, {
      '../evil.json': '{}',
    });
    final installer = PackageInstaller(rootDir: root.path);
    final result = await installer.installFromPath(bad.path);
    // 至少不能让包外的文件被写进安装目录
    expect(result.ok, isFalse);
  });

  test('版本号必须是数字：带字母的 manifest 装不上', () async {
    final root = tempRoot();
    addTearDown(() => root.deleteSync(recursive: true));
    final src = Directory(p.join(root.path, 'badver'));
    final files = minimalFiles();
    files['manifest.json'] = files['manifest.json']!
        .replaceFirst('"version": "250"', '"version": "1.0.0"');
    await writeDir(src, files);

    final installer = PackageInstaller(rootDir: root.path);
    final r = await installer.installFromPath(src.path);
    expect(r.ok, isFalse);
    expect(r.error?.code, 'invalid_version');
    expect(r.error?.message, contains('version'));
  });

  test('缺立绘（命名约定找不到图）装不上', () async {
    final root = tempRoot();
    addTearDown(() => root.deleteSync(recursive: true));
    final src = Directory(p.join(root.path, 'noportrait'));
    final files = minimalFiles()..remove('characters/guide/便服_平常.png');
    await writeDir(src, files);

    final installer = PackageInstaller(rootDir: root.path);
    final r = await installer.installFromPath(src.path);
    expect(r.ok, isFalse);
  });

  test('same version different content conflicts', () async {
    final root = tempRoot();
    addTearDown(() => root.deleteSync(recursive: true));
    final installer = PackageInstaller(rootDir: root.path);

    final srcA = Directory(p.join(root.path, 'a'));
    await writeDir(srcA, minimalFiles());
    final r1 = await installer.installFromPath(srcA.path);
    expect(r1.ok, isTrue, reason: r1.error?.toString());

    // 同版本号但内容不同 → 必须被 contentHash 拦下
    final filesB = minimalFiles();
    filesB['stories/start.json'] =
        filesB['stories/start.json']!.replaceFirst('入场词', '换过的入场词');
    final srcB = Directory(p.join(root.path, 'b'));
    await writeDir(srcB, filesB);
    final r2 = await installer.installFromPath(srcB.path);
    expect(r2.ok, isFalse);
    expect(r2.error?.message, contains('contentHash'));
  });

  group('v1→v2 哈希迁移', () {
    test('旧 v1 哈希 + 相同内容 → 升级成功', () async {
      final root = tempRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      final installer = PackageInstaller(rootDir: root.path);

      final src = Directory(p.join(root.path, 'src'));
      await writeDir(src, minimalFiles());
      final r1 = await installer.installFromPath(src.path);
      expect(r1.ok, isTrue, reason: r1.error?.toString());

      // 把已安装的 .content_hash 改成 v1 格式（无版本前缀）
      final installDir = r1.installDir!;
      final hashFile = File(p.join(installDir, '.content_hash'));
      final v2Hash = hashFile.readAsStringSync();
      expect(v2Hash.startsWith('v2:'), isTrue);
      // 模拟旧安装：去掉 v2: 前缀
      hashFile.writeAsStringSync(v2Hash.substring(3));

      // 相同内容再次安装：应升级哈希标记并成功
      final r2 = await installer.installFromPath(src.path);
      expect(r2.ok, isTrue, reason: r2.error?.toString());
      expect(
        hashFile.readAsStringSync().startsWith('v2:'),
        isTrue,
        reason: '升级后 .content_hash 应带 v2 前缀',
      );
    });

    test('旧 v1 哈希 + 不同内容 → 拒绝覆盖', () async {
      final root = tempRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      final installer = PackageInstaller(rootDir: root.path);

      final srcA = Directory(p.join(root.path, 'a'));
      await writeDir(srcA, minimalFiles());
      final r1 = await installer.installFromPath(srcA.path);
      expect(r1.ok, isTrue, reason: r1.error?.toString());

      // 改成 v1 格式
      final hashFile =
          File(p.join(r1.installDir!, '.content_hash'));
      hashFile.writeAsStringSync(
        hashFile.readAsStringSync().substring(3),
      );

      // 不同内容：即使旧哈希过期，内容真不同也应拒绝
      final filesB = minimalFiles();
      filesB['stories/start.json'] =
          filesB['stories/start.json']!.replaceFirst('入场词', '完全不同的内容');
      final srcB = Directory(p.join(root.path, 'b'));
      await writeDir(srcB, filesB);
      final r2 = await installer.installFromPath(srcB.path);
      expect(r2.ok, isFalse);
      expect(r2.error?.message, contains('different content'));
    });
  });

  group('目录来源安装也要过限额（复审 P1）', () {
    test('条目数超限：直接拒绝并清掉 staging', () async {
      final root = tempRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      final src = Directory(p.join(root.path, 'many'));
      await writeDir(src, {
        'a.txt': 'a',
        'b.txt': 'b',
        'c.txt': 'c',
        'd.txt': 'd',
      });
      final installer = PackageInstaller(
        rootDir: root.path,
        limits: const InstallLimits(maxEntries: 3),
      );
      final r = await installer.installFromPath(src.path);
      expect(r.ok, isFalse);
      expect(r.error?.message, 'Too many entries');
      expect(Directory(p.join(root.path, 'staging')).listSync(), isEmpty);
    });

    test('总字节超限：直接拒绝并清掉 staging', () async {
      final root = tempRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      final src = Directory(p.join(root.path, 'big'));
      for (var i = 0; i < 3; i++) {
        final f = File(p.join(src.path, 'part$i.bin'));
        await f.parent.create(recursive: true);
        await f.writeAsBytes(List<int>.filled(100, i));
      }
      final installer = PackageInstaller(
        rootDir: root.path,
        limits: const InstallLimits(maxExtractedBytes: 64),
      );
      final r = await installer.installFromPath(src.path);
      expect(r.ok, isFalse);
      expect(r.error?.message, 'Extracted size exceeds limit');
      expect(Directory(p.join(root.path, 'staging')).listSync(), isEmpty);
    });
  });

  group('包内容判据：临时文件不算内容（复审 P1）', () {
    test('*.tmp 残骸不进安装目录，也不改内容哈希', () async {
      final root = tempRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      final src = Directory(p.join(root.path, 'src'));
      await writeDir(src, minimalFiles());
      // 模拟旧版本原子写留下的、**没有点前缀**的临时文件残骸
      File(p.join(src.path, 'manifest.json.tmp'))
          .writeAsStringSync('{"packageId": "半截"');
      File(p.join(src.path, 'stories', 'start.json.tmp')).writeAsStringSync('半截');

      final installer = PackageInstaller(rootDir: root.path);
      final r1 = await installer.installFromPath(src.path);
      expect(r1.ok, isTrue, reason: r1.error?.message);
      expect(
        Directory(r1.installDir!)
            .listSync(recursive: true)
            .where((e) => e.path.endsWith('.tmp')),
        isEmpty,
      );

      // 删掉残骸再装一遍同一版本：内容一致 —— 不能被判成「同版本换了内容」。
      // （临时文件若进了哈希，这两次的 contentHash 就会不同。）
      File(p.join(src.path, 'manifest.json.tmp')).deleteSync();
      File(p.join(src.path, 'stories', 'start.json.tmp')).deleteSync();
      final r2 = await installer.installFromPath(src.path);
      expect(r2.ok, isTrue, reason: r2.error?.message);
      expect(r2.contentHash, r1.contentHash);
    });
  });
}
