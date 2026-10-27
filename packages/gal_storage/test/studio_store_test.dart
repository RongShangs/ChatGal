import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 把空工程补成一个**能过体检（因而能装）**的最小包：
/// 一个角色 + 它唯一的立绘 + 一幕有出场角色的情景。
/// （空工程本身是合法的工程，但「没有角色」现在是 error —— 装不进去。）
Future<void> makeInstallable(StudioStore studio, String slug) async {
  await studio.writeJson(slug, 'characters/戒戒/character.json', {
    'id': '戒戒',
    'prompt': '你是戒戒。',
    'defaultState': '便服',
    'defaultEmotion': '平常',
    'states': ['便服'],
    'emotions': ['平常'],
  });
  await studio.writeBytes(
    slug,
    'characters/戒戒/便服_平常.png',
    const [1, 2, 3],
  );
  await studio.writeJson(slug, 'stories/start.json', {
    'displayName': '第 1 天 · 家里',
    'characters': [
      {
        'charId': '戒戒',
        'state': '便服',
        'emotion': '平常',
        'scenePrompt': '本幕：出租屋，第一天晚上。',
      },
    ],
    'target': <Object?>[],
  });
}

/// 内容包创作台的工程存储：新建 / 导入(复制) / 改名 / 删除 / 读写 / 体检 / 版本比对。
void main() {
  late Directory root;
  late StudioStore studio;
  late PackageInstaller installer;

  setUp(() {
    root = Directory.systemTemp.createTempSync('chatgal_studio_');
    installer = PackageInstaller(rootDir: root.path);
    studio = StudioStore(
      rootDir: root.path,
      installer: installer,
      packages: PackageStore(root.path),
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('工程改名等待已排队的保存，不重建旧目录或丢失写入', () async {
    final project = await studio.createBlank(
        name: '旧名', packageId: 'demo.rename', version: '1');
    final writing = studio.writeText(project.slug, 'notes.txt', '待写入的内容');
    final renamed = await studio.renameProject(project.slug, '新名');
    await writing;
    expect(
        File(p.join(studio.dirOf(renamed.slug), 'notes.txt'))
            .readAsStringSync(),
        '待写入的内容');
    expect(Directory(studio.dirOf(project.slug)).existsSync(), isFalse);
  });

  test('新建工程：目录树就是一棵合法包目录，体检只有「没有出口」的提示', () async {
    final proj = await studio.createBlank(
      name: '我的包',
      packageId: 'demo.mine',
      version: '1',
      description: '说明',
    );
    expect(proj.slug, '我的包');
    expect(proj.packageId, 'demo.mine');
    expect(proj.scenes, 1);
    expect(proj.characters, 0);

    // 写出来的是纯 JSON（不带注释）
    final raw = File(
      p.join(studio.dirOf(proj.slug), 'stories', 'start.json'),
    ).readAsStringSync();
    expect(raw.contains('//'), isFalse);
    expect(jsonDecode(raw), isA<Map<String, Object?>>());

    final check = studio.check(proj.slug);
    expect(check.loaded, isTrue);
    // 空工程还没角色：这是**必须修**的错误（没有角色就没人可对话）
    expect(
      check.errors.any((e) => e.message.contains('至少要有一个角色')),
      isTrue,
      reason: check.errors.map((e) => e.message).join(' / '),
    );
    expect(
      check.warnings.any((w) => w.message.contains('没有可用出口')),
      isTrue,
      reason: '没写出口是合法状态，只给 warning',
    );
  });

  test('新建工程时变量表保留 day（剧情分支靠它）', () async {
    final proj = await studio.createBlank(
      name: 'p',
      packageId: 'demo.p',
      version: '1',
    );
    final manifest = studio.readJson(proj.slug, 'manifest.json')!;
    final vars = manifest['variables']! as List;
    expect(
      vars.map((v) => (v as Map)['id']),
      contains('day'),
    );
  });

  test('readJson 容忍注释（导入进来的包可能带 //）', () async {
    final proj = await studio.createBlank(
      name: 'p',
      packageId: 'demo.p',
      version: '1',
    );
    await studio.writeText(
      proj.slug,
      'stories/start.json',
      '{\n  //展示名\n  "displayName": "白天·学校",\n  "target": []\n}\n',
    );
    final json = studio.readJson(proj.slug, 'stories/start.json')!;
    expect(json['displayName'], '白天·学校');
  });

  test('工程列表能数出角色 / 情景 / 事件（不是永远 0）', () async {
    final proj = await studio.createBlank(
      name: 'p',
      packageId: 'demo.count',
      version: '1',
    );
    expect(
      studio.listProjects().single.characters,
      0,
      reason: '空工程还没角色',
    );

    await makeInstallable(studio, proj.slug);
    final desc = studio.listProjects().single;
    // characters/<id>/character.json 是**文件**：早先这里误用目录判断，
    // 于是包内明明有角色、列表却永远显示 0。
    expect(desc.characters, 1);
    expect(desc.scenes, 1);
    expect(desc.events, 0);
  });

  test('复制工程：允许同一个 packageId 多份并存，改一份不影响另一份', () async {
    final a = await studio.createBlank(
      name: 'a',
      packageId: 'demo.same',
      version: '1',
    );
    final b = await studio.duplicate(a.slug);
    expect(b.slug, 'a 副本');
    expect(b.packageId, 'demo.same');

    // 改副本不动原件
    // （新建工程的 start 展示名留空 = 还没填，体检会一直提示到作者写下第一幕）
    final copied = studio.readJson(b.slug, 'stories/start.json')!;
    copied['displayName'] = '改过的';
    await studio.writeJson(b.slug, 'stories/start.json', copied);
    expect(
      studio.readJson(a.slug, 'stories/start.json')!['displayName'],
      '',
    );
    expect(
      studio.readJson(b.slug, 'stories/start.json')!['displayName'],
      '改过的',
    );

    // 再复制一次会自动加序号
    final c = await studio.duplicate(a.slug);
    expect(c.slug, 'a 副本 2');
    expect(studio.listProjects().length, 3);
  });

  test('重命名工程：改目录名不改包名', () async {
    final proj = await studio.createBlank(
      name: '旧名',
      packageId: 'demo.p',
      version: '1',
    );
    final renamed = await studio.renameProject(proj.slug, '新名');
    expect(renamed.slug, '新名');
    expect(renamed.packageId, 'demo.p');
    expect(studio.exists('旧名'), isFalse);
    expect(studio.exists('新名'), isTrue);
  });

  test('删除工程', () async {
    final proj = await studio.createBlank(
      name: 'p',
      packageId: 'demo.p',
      version: '1',
    );
    expect(await studio.delete(proj.slug), isTrue);
    expect(studio.listProjects(), isEmpty);
  });

  test('立绘改名：renamePath 把 旧状态_情绪.png 变成 新状态_情绪.png', () async {
    final proj = await studio.createBlank(
      name: 'p',
      packageId: 'demo.p',
      version: '1',
    );
    await studio.writeBytes(
      proj.slug,
      'characters/戒戒/便服_平常.png',
      const [1, 2, 3],
    );
    final ok = await studio.renamePath(
      proj.slug,
      'characters/戒戒/便服_平常.png',
      'characters/戒戒/校服_平常.png',
    );
    expect(ok, isTrue);
    expect(studio.listFiles(proj.slug, 'characters/戒戒'), ['校服_平常.png']);
  });

  test('立绘改名：源目标相同是无操作，不能把原图删掉', () async {
    final proj = await studio.createBlank(
      name: 'p',
      packageId: 'demo.same',
      version: '1',
    );
    await studio.writeBytes(
      proj.slug,
      'characters/戒戒/便服_平常.png',
      const [9, 9, 9],
    );
    // 同名改名：以前会先删目标再 rename → 原图丢失
    final ok = await studio.renamePath(
      proj.slug,
      'characters/戒戒/便服_平常.png',
      'characters/戒戒/便服_平常.png',
    );
    expect(ok, isTrue);
    expect(studio.listFiles(proj.slug, 'characters/戒戒'), ['便服_平常.png']);
    // 内容还在
    expect(
      studio.readPackFiles(proj.slug)['characters/戒戒/便服_平常.png'],
      isNotNull,
    );
  });

  test('版本比对：新包 → 内容一致 → 同版本换内容要报 conflict', () async {
    final proj = await studio.createBlank(
      name: 'p',
      packageId: 'demo.v',
      version: '100',
    );

    final fresh = await studio.installPlan(proj.slug);
    expect(fresh.verdict, StudioInstallVerdict.freshPackage);
    expect(fresh.canInstall, isTrue);

    // 装上去（先补成能过体检的最小包：没有角色会被校验器拦下）
    await makeInstallable(studio, proj.slug);
    final installed = await studio.installToPackages(proj.slug);
    expect(installed.ok, isTrue, reason: installed.error?.message);

    // 内容没动 → identical
    final same = await studio.installPlan(proj.slug);
    expect(same.verdict, StudioInstallVerdict.identical);

    // 改了内容但版本号没升 → conflict（安装器不允许同版本换内容）
    await studio.writeJson(proj.slug, 'stories/start.json', {
      'displayName': '改过的一幕',
      'target': <Object?>[],
    });
    final conflict = await studio.installPlan(proj.slug);
    expect(conflict.verdict, StudioInstallVerdict.contentConflict);
    expect(conflict.canInstall, isFalse);
    expect(
      conflict.message,
      contains(StudioStore.nextVersion('100')),
      reason: '要告诉用户把版本号升到 101 才能装',
    );

    // 升版本后就变成「别的版本 → 并存」
    await studio.writeJson(proj.slug, 'manifest.json', {
      ...studio.readJson(proj.slug, 'manifest.json')!,
      'version': '101',
    });
    final other = await studio.installPlan(proj.slug);
    expect(other.verdict, StudioInstallVerdict.otherVersion);
    expect(other.canInstall, isTrue);
    expect(other.installed.single.version, '100');
  });

  test('nextVersion：纯数字 +1，非数字给 1', () {
    expect(StudioStore.nextVersion('250'), '251');
    expect(StudioStore.nextVersion('9'), '10');
    expect(StudioStore.nextVersion('abc'), '1');
  });

  test('导出工程为 .chatgal，能再被导入成新工程', () async {
    final proj = await studio.createBlank(
      name: '导出测试',
      packageId: 'demo.export',
      version: '7',
    );
    final exported = await studio.exportZip(proj.slug);
    expect(exported.ok, isTrue, reason: exported.error?.message);
    expect(File(exported.file!).existsSync(), isTrue);

    final imported = await studio.importFromZip(exported.file!);
    expect(imported.packageId, 'demo.export');
    expect(imported.version, '7');
    expect(imported.scenes, 1);
  });

  test('从已安装的包导入成工程（原包不动）', () async {
    final proj = await studio.createBlank(
      name: '源工程',
      packageId: 'demo.frominstalled',
      version: '3',
    );
    await makeInstallable(studio, proj.slug);
    final r = await studio.installToPackages(proj.slug);
    expect(r.ok, isTrue, reason: r.error?.message);

    final refs = PackageStore(root.path)
        .listInstalled()
        .where((x) => x.packageId == 'demo.frominstalled')
        .toList();
    final imported = await studio.importFromInstalled(refs.single);
    expect(imported.packageId, 'demo.frominstalled');
    expect(imported.slug, contains('源工程'));
  });

  test('listProjects 按最近修改倒序，读不出来的工程仍然列出来', () async {
    final a = await studio.createBlank(
      name: 'aaa',
      packageId: 'demo.a',
      version: '1',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final b = await studio.createBlank(
      name: 'bbb',
      packageId: 'demo.b',
      version: '1',
    );
    // 还没动过任何文件时：后建的 b 排前面
    expect(studio.listProjects().first.slug, b.slug);
    // 把 a 的 manifest 写坏：列表要能显示（好让用户删掉），但不 readable。
    // 注意：保存走「写 tmp + 改名替换」，改名会更新工程目录的 mtime，所以刚改过的
    // a 变成「最近修改」排前面 —— 这比旧行为更合理（旧行为依赖「原地覆盖不动父目录
    // mtime」这个巧合）。
    await studio.writeText(a.slug, 'manifest.json', '{ 这不是 JSON');
    final list = studio.listProjects();
    expect(list.first.slug, a.slug, reason: '刚改过的工程应排在前面');
    final broken = list.firstWhere((x) => x.slug == a.slug);
    expect(broken.readable, isFalse);
    expect(broken.name, a.slug, reason: '读不出来时退回目录名做标题');
  });

  group('工程文件原子写（复审 P1）', () {
    test('写失败时旧文件原样保留，磁盘上不留半份 JSON', () async {
      final proj = await studio.createBlank(
        name: '原子写',
        packageId: 'demo.atomic',
        version: '1',
      );
      final manifest = File(p.join(studio.dirOf(proj.slug), 'manifest.json'));
      final before = manifest.readAsStringSync();
      // 故障注入：把**临时文件的位置**先占成一个目录 → 写 tmp 必然失败。
      // 临时名带点前缀（`.manifest.json.tmp`），点前缀是「不算包内容」的判据之一。
      Directory(p.join(p.dirname(manifest.path), '.manifest.json.tmp'))
          .createSync(recursive: true);

      await expectLater(
        studio.writeJson(proj.slug, 'manifest.json', {'packageId': 'x'}),
        throwsA(anything),
      );
      // 旧内容一个字节都没变，而且仍然能读出来（不是被截成空文件）。
      expect(manifest.readAsStringSync(), before);
      expect(studio.readJson(proj.slug, 'manifest.json'), isNotNull);
      expect(studio.readJson(proj.slug, 'manifest.json')!['packageId'],
          'demo.atomic');
    });

    test('同一文件并发写不互相截断，最后落盘的是完整 JSON', () async {
      final proj = await studio.createBlank(
        name: '并发写',
        packageId: 'demo.race',
        version: '1',
      );
      final futures = <Future<void>>[
        for (var i = 0; i < 8; i++)
          studio.writeJson(proj.slug, 'stories/start.json', {
            'displayName': '第 $i 次',
            'background': '',
            'narration': '',
            'characters': <Object?>[],
            'target': <Object?>[],
          }),
      ];
      await Future.wait(futures);
      await studio.flushWrites(proj.slug);
      final text = File(p.join(studio.dirOf(proj.slug), 'stories/start.json'))
          .readAsStringSync();
      // 完整 JSON（没被两次写交叉截断），且内容是最后那一次
      final decoded = decodeJsonc(text) as Map;
      expect(decoded['displayName'], '第 7 次');
      // 不留临时文件
      expect(
        Directory(p.join(studio.dirOf(proj.slug), 'stories'))
            .listSync()
            .where((e) => e.path.endsWith('.tmp')),
        isEmpty,
      );
      // 队列不残留：写完就从表里移除（以前只增不减）
      expect(studio.pendingWriteCount, 0);
    });
  });

  group('工程完成标记与包内容判据（复审 P1）', () {
    /// 模拟「旧版本落盘的工程」：有 manifest，但没有完成标记。
    File legacyProject(String slug) {
      final dir = Directory(studio.dirOf(slug))..createSync(recursive: true);
      Directory(p.join(dir.path, 'stories')).createSync(recursive: true);
      final manifest = File(p.join(dir.path, 'manifest.json'));
      manifest.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
        'packageId': 'legacy.$slug',
        'version': '9',
        'name': slug,
        'author': 'a',
        'description': 'd',
      }));
      File(p.join(dir.path, 'stories', 'start.json')).writeAsStringSync(
        '{"displayName": "旧的一幕", "target": []}',
      );
      return manifest;
    }

    test('新建工程带完成标记；没有标记又没有 manifest 的目录不算工程', () async {
      final proj = await studio.createBlank(
        name: '标记',
        packageId: 'demo.mark',
        version: '1',
      );
      expect(
        File(p.join(studio.dirOf(proj.slug), StudioStore.markerFileName))
            .existsSync(),
        isTrue,
      );
      // 半成品：manifest 写坏了的目录（复制/导入到一半被杀就是这个样子）
      final half = Directory(studio.dirOf('半成品'))..createSync(recursive: true);
      File(p.join(half.path, 'manifest.json')).writeAsStringSync('{"packageId":');
      // 只写了一部分文件的目录（连 manifest 都还没有）
      final partial = Directory(studio.dirOf('写了一半'))
        ..createSync(recursive: true);
      Directory(p.join(partial.path, 'stories')).createSync(recursive: true);
      File(p.join(partial.path, 'stories', 'start.json'))
          .writeAsStringSync('{"displayName": "x", "target": []}');
      // 落盘中途的临时目录（点前缀）
      Directory(p.join(studio.studioDir, '.new_123_0'))
          .createSync(recursive: true);

      expect(
        studio.listProjects().map((e) => e.slug).toList(),
        [proj.slug],
      );
    });

    test('存量工程（无标记但有 manifest）会被补标记，不会从列表里消失', () async {
      final manifest = legacyProject('老工程');
      final marker = File(
        p.join(manifest.parent.path, StudioStore.markerFileName),
      );
      expect(marker.existsSync(), isFalse, reason: '旧版本没有标记');

      final list = studio.listProjects();
      expect(list.single.slug, '老工程');
      expect(list.single.packageId, 'legacy.老工程');
      expect(list.single.readable, isTrue);
      // 迁移：列出来时就补写了标记，下次不再走兼容分支
      expect(marker.existsSync(), isTrue);
      expect(studio.listProjects().single.slug, '老工程');
    });

    test('导入 / 复制出来的工程同样带完成标记（半成品不冒充工程）', () async {
      final from = await studio.createBlank(
        name: '源',
        packageId: 'demo.allpaths',
        version: '1',
      );
      await makeInstallable(studio, from.slug);

      // 复制
      final copied = await studio.duplicate(from.slug);
      // 从已安装的包导入
      final installed = await studio.installToPackages(from.slug);
      expect(installed.ok, isTrue, reason: installed.error?.message);
      final refs = PackageStore(root.path)
          .listInstalled()
          .where((r) => r.packageId == 'demo.allpaths')
          .toList();
      final imported = await studio.importFromInstalled(refs.single);
      // 从 .chatgal 导入
      final exported = await studio.exportZip(from.slug);
      expect(exported.ok, isTrue, reason: exported.error?.message);
      final fromZip = await studio.importFromZip(exported.file!);

      for (final p2 in [copied, imported, fromZip, from]) {
        expect(
          File(p.join(studio.dirOf(p2.slug), StudioStore.markerFileName))
              .existsSync(),
          isTrue,
          reason: '${p2.slug} 应该有完成标记',
        );
      }
      // 全部都在列表里（没有因为缺标记而消失）
      expect(
        studio.listProjects().map((e) => e.slug).toSet(),
        {from.slug, copied.slug, imported.slug, fromZip.slug},
      );
    });

    test('建工程不留临时目录（先写临时目录 → 写标记 → 整目录就位）', () async {
      final proj = await studio.createBlank(
        name: '原子建',
        packageId: 'demo.atomiccreate',
        version: '1',
      );
      expect(
        Directory(studio.studioDir)
            .listSync()
            .where((e) => p.basename(e.path).startsWith('.new_')),
        isEmpty,
      );
      expect(studio.listProjects().map((e) => e.slug), [proj.slug]);
    });

    test('*.tmp 残骸不算包内容：导出包与安装目录都不含它', () async {
      final proj = await studio.createBlank(
        name: '临时残骸',
        packageId: 'demo.tmpresidue',
        version: '5',
      );
      await makeInstallable(studio, proj.slug);
      // 模拟旧版本留下的、**没有点前缀**的原子写临时文件
      File(p.join(studio.dirOf(proj.slug), 'manifest.json.tmp'))
          .writeAsStringSync('{"packageId": "半截"');
      File(p.join(studio.dirOf(proj.slug), 'stories', 'start.json.tmp'))
          .writeAsStringSync('半截');

      // 工程量文件表（体检/安装读的就是它）里没有它
      expect(
        studio.readPackFiles(proj.slug).keys.any((k) => k.endsWith('.tmp')),
        isFalse,
      );

      final installed = await studio.installToPackages(proj.slug);
      expect(installed.ok, isTrue, reason: installed.error?.message);
      expect(
        Directory(installed.installDir!)
            .listSync(recursive: true)
            .where((e) => e.path.endsWith('.tmp')),
        isEmpty,
        reason: '临时文件不能被拷进安装目录',
      );

      final exported = await studio.exportZip(proj.slug);
      expect(exported.ok, isTrue, reason: exported.error?.message);
      final archive = ZipDecoder()
          .decodeBytes(File(exported.file!).readAsBytesSync());
      expect(
        archive.files.map((f) => f.name).where((n) => n.endsWith('.tmp')),
        isEmpty,
        reason: '临时文件不能被打进导出包',
      );
      expect(
        archive.files
            .map((f) => f.name)
            .where((n) => n.split('/').any((s) => s.startsWith('.'))),
        isEmpty,
        reason: '完成标记这类点前缀文件也不进包',
      );
    });
  });
}
