import 'dart:io';
import 'dart:convert';

import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

PackageRef demoRef() => const PackageRef(
      packageId: 'demo.install',
      version: '250',
      contentHash: 'abc',
      displayName: '安装测试',
    );

WorldSnapshot world() => const WorldSnapshot(
      variables: {'power_restored': true},
      characters: {},
      eventHistory: {},
      story: {'storyId': 'main', 'nodeId': 'n1', 'day': 1},
      presentation: {'scene': 'bg.lab'},
      rngState: 9,
    );

void main() {
  test('旧 schema 锁档，不以默认字段静默升级', () async {
    final root = Directory.systemTemp.createTempSync('chatgal_schema_');
    addTearDown(() => root.deleteSync(recursive: true));
    final repo =
        SaveRepository(rootDir: root.path, packages: PackageStore(root.path));
    final slot = await repo.create(
        label: '旧档', packageRef: demoRef(), storyId: 'main', world: world());
    final file = File(p.join(root.path, 'saves', '${slot.saveId}.json'));
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    json['saveSchemaVersion'] = SaveSlot.currentSchemaVersion - 1;
    file.writeAsStringSync(jsonEncode(json));
    final bytes = file.readAsBytesSync();
    expect(repo.load(slot.saveId).reason, SaveLockReason.schemaUnsupported);
    expect(file.readAsBytesSync(), bytes);
  });
  test('create/list/update/delete save slot', () async {
    final root = Directory.systemTemp.createTempSync('chatgal_t04_');
    addTearDown(() => root.deleteSync(recursive: true));
    final packages = PackageStore(root.path);
    // fake install dir so findExact works when needed
    final repo = SaveRepository(rootDir: root.path, packages: packages);

    final slot = await repo.create(
      label: '第一章',
      packageRef: demoRef(),
      storyId: 'main',
      world: world(),
      messages: [
        {'role': 'user', 'content': 'hi'}
      ],
    );
    expect(slot.saveId, isNotEmpty);

    final list = repo.listSaves();
    expect(list, hasLength(1));
    expect(list.single.label, '第一章');

    final loaded = repo.load(slot.saveId);
    expect(loaded.canEnter, isFalse);
    expect(loaded.reason, SaveLockReason.missingPackage);

    final updated = await repo.update(
      slot,
      world: world().copyWith(
        story: {'storyId': 'main', 'nodeId': 'n2', 'day': 2},
      ),
    );
    expect(updated.world.story['nodeId'], 'n2');

    final ok = await repo.delete(slot.saveId);
    expect(ok, isTrue);
    expect(repo.listSaves(), isEmpty);
  });

  test('exact package match unlocks save', () async {
    final root = Directory.systemTemp.createTempSync('chatgal_t04b_');
    addTearDown(() => root.deleteSync(recursive: true));
    final packages = PackageStore(root.path);
    final installDir = Directory(
      p.join(root.path, 'packages', 'demo.install', '250'),
    )..createSync(recursive: true);
    File(p.join(installDir.path, 'manifest.json')).writeAsStringSync('''
{"packageId":"demo.install","version":"250","name":"安装测试","author":"t","description":"d"}
''');
    File(p.join(installDir.path, '.content_hash')).writeAsStringSync('abc');

    final repo = SaveRepository(rootDir: root.path, packages: packages);
    final slot = await repo.create(
      label: 'ok',
      packageRef: demoRef(),
      storyId: 'main',
      world: world(),
    );
    final loaded = repo.load(slot.saveId);
    expect(loaded.canEnter, isTrue);
    expect(loaded.slot?.storyId, 'main');
  });

  test('同一个包换了版本/内容时按当前已安装的那份继续，不锁死存档', () async {
    final root = Directory.systemTemp.createTempSync('chatgal_t04c_');
    addTearDown(() => root.deleteSync(recursive: true));
    final packages = PackageStore(root.path);
    final installDir = Directory(
      p.join(root.path, 'packages', 'demo.install', '250'),
    )..createSync(recursive: true);
    File(p.join(installDir.path, 'manifest.json')).writeAsStringSync('''
{"packageId":"demo.install","version":"250","name":"安装测试","author":"t","description":"d"}
''');
    // 存档记录的 contentHash 与磁盘上这份不一致（相当于默认包随 APP 升级后
    // 旧版被卸载：存档绑的 (version, hash) 已解析不到精确命中）
    File(p.join(installDir.path, '.content_hash')).writeAsStringSync('OTHER');

    final repo = SaveRepository(rootDir: root.path, packages: packages);
    final slot = await repo.create(
      label: 'mismatch',
      packageRef: demoRef(),
      storyId: 'main',
      world: world(),
    );
    final loaded = repo.load(slot.saveId);
    // 同 id 的包还在 → 允许进入，并在 detail 里说明包已更新
    expect(loaded.canEnter, isTrue);
    expect(loaded.detail, contains('包已更新'));
  });

  test('包完全不在时才锁档', () async {
    final root = Directory.systemTemp.createTempSync('chatgal_t04d_');
    addTearDown(() => root.deleteSync(recursive: true));
    final packages = PackageStore(root.path);
    final repo = SaveRepository(rootDir: root.path, packages: packages);
    final slot = await repo.create(
      label: 'missing',
      packageRef: demoRef(),
      storyId: 'main',
      world: world(),
    );
    final loaded = repo.load(slot.saveId);
    expect(loaded.canEnter, isFalse);
    expect(loaded.reason, SaveLockReason.missingPackage);
  });

  group('打不开的存档：锁档要能看见、也不能被改写（复审 P2）', () {
    /// 旧形状（schema 2，扁平）的档：换过版本之后就是这个样子。
    const oldShape = '''
{
  "saveSchemaVersion": 2,
  "saveId": "save_old_1",
  "sessionId": "s_old",
  "label": "升级前的档",
  "packageRef": {"packageId": "demo.install", "version": "250", "contentHash": "abc"},
  "storyId": "main",
  "world": {"variables": {}, "characters": {}, "eventHistory": {},
            "story": {"storyId": "main"}, "presentation": {}, "rngState": 1},
  "createdAt": "2026-09-01T00:00:00.000Z",
  "updatedAt": "2026-09-02T00:00:00.000Z",
  "messageCheckpoint": [], "memoryCheckpoint": {},
  "presentationCheckpoint": {}, "revision": 3
}
''';

    late Directory root;
    late SaveRepository repo;

    setUp(() {
      root = Directory.systemTemp.createTempSync('chatgal_unreadable_');
      repo = SaveRepository(
        rootDir: root.path,
        packages: PackageStore(root.path),
      );
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    File oldFile() {
      final f = File(p.join(root.path, 'saves', 'save_old_1.json'));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(oldShape);
      return f;
    }

    test('旧形状 → schemaUnsupported（不是 corruptSave），文件一个字节不变', () {
      final f = oldFile();
      final bytes = f.readAsBytesSync();
      final loaded = repo.load('save_old_1');
      expect(loaded.canEnter, isFalse);
      expect(loaded.reason, SaveLockReason.schemaUnsupported);
      expect(loaded.detail, contains('saveSchemaVersion=2'));
      expect(f.readAsBytesSync(), bytes);
    });

    test('旧形状仍然**列得出来**（带原来的名字与包），不会从界面消失', () {
      oldFile();
      final list = repo.listSaves();
      expect(list, hasLength(1));
      final stub = list.single;
      expect(stub.saveId, 'save_old_1');
      expect(stub.label, '升级前的档');
      expect(stub.isUnreadable, isTrue);
      expect(stub.saveSchemaVersion, 2);
      expect(stub.packageRef.packageId, 'demo.install');
      expect(stub.updatedAt, DateTime.utc(2026, 9, 2));
    });

    test('改名 / 复制会拒绝，且不碰原文件（不能把未知分区重写掉）', () async {
      final f = oldFile();
      final bytes = f.readAsBytesSync();
      expect(await repo.rename('save_old_1', '新名字'), isNull);
      expect(await repo.copy('save_old_1', '副本'), isNull);
      expect(f.readAsBytesSync(), bytes);
      // 只有一条（没多出副本文件）
      expect(repo.listSaves(), hasLength(1));
    });

    test('完全读不出来的文件：corruptSave，列表里也仍在', () async {
      final f = File(p.join(root.path, 'saves', 'save_broken.json'));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('{ 这不是 JSON');
      final loaded = repo.load('save_broken');
      expect(loaded.reason, SaveLockReason.corruptSave);
      final list = repo.listSaves();
      expect(list, hasLength(1));
      expect(list.single.isUnreadable, isTrue);
      expect(list.single.label, contains('打不开'));
    });

    test('删掉数据分区（messages）→ corruptSave，不静默当空档', () async {
      final slot = await repo.create(
        label: '缺分区',
        packageRef: demoRef(),
        storyId: 'main',
        world: world(),
        messages: [
          {'role': 'user', 'content': '一句'},
        ],
      );
      final f = File(p.join(root.path, 'saves', '${slot.saveId}.json'));
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      json.remove('messages');
      f.writeAsStringSync(jsonEncode(json));
      final loaded = repo.load(slot.saveId);
      expect(loaded.canEnter, isFalse);
      expect(loaded.reason, SaveLockReason.corruptSave);
      expect(loaded.detail, contains('messages'));
    });

    test('缺运行位游标（progress.cursor）→ corruptSave（不能默认成访问号 0）', () async {
      final slot = await repo.create(
        label: '缺游标',
        packageRef: demoRef(),
        storyId: 'main',
        world: world(),
      );
      final f = File(p.join(root.path, 'saves', '${slot.saveId}.json'));
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      (json['progress'] as Map).remove('cursor');
      f.writeAsStringSync(jsonEncode(json));
      expect(repo.load(slot.saveId).reason, SaveLockReason.corruptSave);
    });
  });

  test('裸存档文件（分区形状、没有导出包装）也能导入', () async {
    final root = Directory.systemTemp.createTempSync('chatgal_rawimport_');
    addTearDown(() => root.deleteSync(recursive: true));
    final repo = SaveRepository(
      rootDir: root.path,
      packages: PackageStore(root.path),
    );
    final slot = await repo.create(
      label: '原档',
      packageRef: demoRef(),
      storyId: 'main',
      world: world(),
      messages: [
        {'role': 'user', 'content': '一句'},
      ],
    );
    final raw = jsonEncode(slot.toJson());
    final imported = await repo.importFromJson(raw, labelOverride: '导入档');
    expect(imported, isNotNull);
    expect(imported!.label, '导入档');
    expect(imported.saveId, isNot(slot.saveId));
    // 事务历史身份不换，幂等台账才认得出来
    expect(imported.sessionId, slot.sessionId);
    expect(imported.messageCheckpoint.single['content'], '一句');
  });

  group('存档写盘：并发互斥 / 临时文件 / 导入版本闸（复审 P1）', () {
    late Directory root;
    late SaveRepository repo;

    setUp(() {
      root = Directory.systemTemp.createTempSync('chatgal_write_');
      repo = SaveRepository(
        rootDir: root.path,
        packages: PackageStore(root.path),
      );
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    Directory savesDir() => Directory(p.join(root.path, 'saves'));

    /// 写盘残留：点前缀 + `.tmp`（新命名）和旧的 `<文件名>.tmp`。
    Iterable<FileSystemEntity> tmpResidue() => savesDir()
        .listSync()
        .where((e) => e is File && e.path.endsWith('.tmp'));

    test('同一 saveId 的并发写不会互相改名半成品，也不留残留', () async {
      final slot = await repo.create(
        label: '初版',
        packageRef: demoRef(),
        storyId: 'main',
        world: world(),
      );
      // 两个写入方：会话页那条 _persistQueue 与存档库的改名。
      final writers = <Future<void>>[
        for (var i = 0; i < 6; i++)
          repo.update(slot, label: '第 $i 次', world: world()),
        repo.rename(slot.saveId, '并发的改名').then((_) {}),
      ];
      await Future.wait(writers);

      final file = File(p.join(savesDir().path, '${slot.saveId}.json'));
      // 完整 JSON（不是两次写交叉出来的半截文件）
      jsonDecode(file.readAsStringSync());
      // 按当前 schema 能解析（包没装 → 只是锁包，不是 corruptSave）
      final loaded = repo.load(slot.saveId);
      expect(loaded.reason, SaveLockReason.missingPackage);
      expect(
        loaded.slot!.label,
        anyOf(['并发的改名', '初版', '第 0 次', '第 1 次', '第 2 次', '第 3 次',
            '第 4 次', '第 5 次']),
      );
      expect(tmpResidue(), isEmpty);
      expect(repo.pendingWriteCount, 0, reason: '队列条目用完要移除，不能只增不减');
    });

    test('delete 只清自己这个存档的临时残留，不碰另一个正在写的', () async {
      final a = await repo.create(
        label: 'a',
        packageRef: demoRef(),
        storyId: 'main',
        world: world(),
      );
      final b = await repo.create(
        label: 'b',
        packageRef: demoRef(),
        storyId: 'main',
        world: world(),
      );
      final mineNew = File(p.join(savesDir().path,
          '.${a.saveId}.json.123_0.tmp'))
        ..writeAsStringSync('半截');
      final mineLegacy = File(p.join(savesDir().path, '${a.saveId}.json.tmp'))
        ..writeAsStringSync('半截（旧命名）');
      final other = File(p.join(savesDir().path, '.${b.saveId}.json.456_1.tmp'))
        ..writeAsStringSync('别的存档正在写');

      expect(await repo.delete(a.saveId), isTrue);
      expect(mineNew.existsSync(), isFalse);
      expect(mineLegacy.existsSync(), isFalse);
      expect(other.existsSync(), isTrue, reason: '不能删别人正在写的临时文件');
    });

    test('importFromJson：高版本存档明确拒绝，不会被重写成当前形状', () async {
      final slot = await repo.create(
        label: '来自未来',
        packageRef: demoRef(),
        storyId: 'main',
        world: world(),
      );
      final json = slot.toJson();
      json['saveSchemaVersion'] = SaveSlot.currentSchemaVersion + 1;
      final raw = jsonEncode({'exportType': 'chatgalsave', 'slot': json});

      String? reason;
      final imported =
          await repo.importFromJson(raw, onRejected: (r) => reason = r);
      expect(imported, isNull);
      expect(reason, contains('${SaveSlot.currentSchemaVersion + 1}'));
      // 一个文件都没多出来：导入没有把未知分区按当前形状落盘
      expect(savesDir().listSync().whereType<File>(), hasLength(1));
    });

    test('importFromJson：低版本（旧形状）同样拒绝并给原因', () async {
      final slot = await repo.create(
        label: '旧版',
        packageRef: demoRef(),
        storyId: 'main',
        world: world(),
      );
      final json = slot.toJson();
      json['saveSchemaVersion'] = SaveSlot.currentSchemaVersion - 1;
      String? reason;
      final imported = await repo.importFromJson(
        jsonEncode({'exportType': 'chatgalsave', 'slot': json}),
        onRejected: (r) => reason = r,
      );
      expect(imported, isNull);
      expect(reason, contains('${SaveSlot.currentSchemaVersion - 1}'));
    });

    test('importFromJson：不是存档的文件也说清原因', () async {
      String? reason;
      final imported = await repo.importFromJson(
        jsonEncode({'hello': 'world'}),
        onRejected: (r) => reason = r,
      );
      expect(imported, isNull);
      expect(reason, isNotNull);
      // 乱码也一样，不抛异常
      expect(
        await repo.importFromJson('{ 这不是 JSON',
            onRejected: (r) => reason = r),
        isNull,
      );
    });
  });
}
