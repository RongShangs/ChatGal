import 'dart:convert';
import 'dart:io';

import 'package:chatgal/app/app_services.dart';
import 'package:chatgal/features/settings/api_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('chatgal_store_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File settingsFile() => File(p.join(root.path, 'app_settings.json'));

  group('设置存储：串行与原子写入（复审 P1）', () {
    test('并发保存不会写出半截文件，最后一个值生效', () async {
      final store = ApiSettingsStore(root.path);
      await store.save(store.load().copyWith(themeId: 'violet'));

      // 同时发起 10 次整份保存（滑条 + 其它页面同时改设置就是这个形状）。
      final tasks = [
        for (var i = 0; i < 10; i++)
          store.save(store.load().copyWith(themeId: i.isEven ? 'night' : 'abyss')),
      ];
      await Future.wait(tasks);
      await store.flush();

      // 文件始终是完整 JSON，不残留临时文件。
      final text = settingsFile().readAsStringSync();
      expect(() => jsonDecode(text), returnsNormally);
      expect(File('${settingsFile().path}.tmp').existsSync(), isFalse);
      expect(store.load().themeId, 'abyss');
    });

    test('写入走临时文件替换：中途失败不会毁掉旧设置', () async {
      final store = ApiSettingsStore(root.path);
      await store.save(store.load().copyWith(replyLength: 'long'));
      final before = settingsFile().readAsStringSync();

      // 造一个「上一次写到一半留下的 .tmp」，再正常保存一次。
      File('${settingsFile().path}.tmp').writeAsStringSync('{"themeId": "broken');
      await store.save(store.load().copyWith(themeId: 'sakura'));

      expect(store.load().themeId, 'sakura');
      expect(store.load().replyLength, 'long');
      expect(before, contains('"replyLength":"long"'));
      expect(File('${settingsFile().path}.tmp').existsSync(), isFalse);
    });

    test('读失败不静默吞掉：保留 .corrupt 备份并给出 loadError', () async {
      settingsFile().writeAsStringSync('{"themeId": "violet", "providers": [');
      final store = ApiSettingsStore(root.path);

      final loaded = store.load();
      expect(loaded.themeId, 'violet'); // 退回默认值
      expect(store.loadError, isNotNull);
      expect(store.hasCorruptBackup, isTrue);
      expect(File('${settingsFile().path}.corrupt').readAsStringSync(),
          contains('"themeId"'));

      // 再读一次不要把备份覆盖掉（最能说明问题的是第一份）。
      File('${settingsFile().path}.corrupt').writeAsStringSync('第一份');
      store.load();
      expect(File('${settingsFile().path}.corrupt').readAsStringSync(), '第一份');
    });

    test('空文件不是损坏（clear 之后就是空的）', () {
      settingsFile().writeAsStringSync('');
      final store = ApiSettingsStore(root.path);
      expect(store.load().themeId, 'violet');
      expect(store.loadError, isNull);
      expect(store.hasCorruptBackup, isFalse);
    });

    test('update() 在最新值上打补丁，不会用旧快照覆盖别处刚改的字段', () async {
      final store = ApiSettingsStore(root.path);
      await store.save(store.load().copyWith(logMaxEntries: 500));

      // 旧快照（这个页面打开时读到的，还不知道日志上限被改过）。
      final stale = store.load().copyWith(logMaxEntries: 1000);

      // 走 update：读最新 → 只改主题。
      final updated = await store.update((s) => s.copyWith(themeId: 'night'));
      expect(updated.themeId, 'night');
      expect(updated.logMaxEntries, 500, reason: '别人刚改的上限要留住');

      // 对照：拿旧快照整份写回，就会把它盖掉（这正是要避免的用法）。
      await store.save(stale);
      expect(store.load().logMaxEntries, 1000);
    });

    test('设置文件路径可查（日志页/提示要用）', () {
      final store = ApiSettingsStore(root.path);
      expect(store.settingsPath, endsWith('app_settings.json'));
      expect(store.settingsPath, contains(root.path));
    });
  });

  group('启动流程：内容包不可用要有明确结论（复审 P2）', () {
    /// 造一个「已安装」的包目录（PackageStore 只认 manifest + .content_hash）。
    void fakeInstalled(String packageId, String version) {
      final dir = Directory(p.join(root.path, 'packages', packageId, version));
      dir.createSync(recursive: true);
      File(p.join(dir.path, 'manifest.json')).writeAsStringSync('''
{"packageId":"$packageId","version":"$version","name":"旧包","author":"t","description":""}
''');
      File(p.join(dir.path, '.content_hash')).writeAsStringSync('v2:deadbeef');
    }

    test('首次启动、默认包装不上 → 抛出启动异常（不要假装成功）', () async {
      final services = AppServices.forTestRoot(root);
      await expectLater(
        services.ensureBootablePackage(zipBytes: [1, 2, 3, 4]),
        throwsA(isA<PackageBootException>()),
      );
      expect(services.bootWarning, isNull);
    });

    test('已有可用包、只是这次更新失败 → 允许进入但留下警告', () async {
      fakeInstalled('local.pack.mine', '3');
      final services = AppServices.forTestRoot(root);
      expect(services.packages.listInstalled(), hasLength(1));

      await services.ensureBootablePackage(zipBytes: [1, 2, 3, 4]);
      expect(services.bootWarning, isNotNull);
      expect(services.bootWarning, contains('继续使用已安装'));
      expect(services.bootWarning, contains('v1'.substring(0, 1)));

      // 包还在，游戏可用。
      expect(services.packages.listInstalled(), hasLength(1));
    });
  });
}
