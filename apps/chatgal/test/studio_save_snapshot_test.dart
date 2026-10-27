import 'dart:io';

import 'package:chatgal/app/app_services.dart';
import 'package:chatgal/design_system/tokens.dart';
import 'package:chatgal/features/studio/manifest_editor.dart';
import 'package:chatgal/features/studio/studio_editor_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gal_storage/gal_storage.dart';

/// 创作台：**写盘期间继续输入**不能被误标成「已保存」（复审 P1）。
///
/// 以前的顺序是「构造成待写内容 → await 写盘 → 用**当时的表单**算签名」：
/// 用户在等待期间继续输入，表单已变成 B，磁盘上却是 A，界面却认为 B 已保存。
/// 现在签名在写盘前就固定成「这一份内容」的签名，写完再拿当前表单比对。
class _SlowStudioStore extends StudioStore {
  _SlowStudioStore({
    required super.rootDir,
    required super.installer,
    required super.packages,
  });

  /// 人为拉长写盘：把「保存进行中」这一段变成可操作窗口。
  Duration delay = Duration.zero;
  int writes = 0;

  @override
  Future<void> writeJson(
    String slug,
    String rel,
    Map<String, Object?> data,
  ) async {
    writes++;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return super.writeJson(slug, rel, data);
  }
}

class _Services implements AppServices {
  _Services(this.root, this.studio);
  @override
  final Directory root;
  @override
  final _SlowStudioStore studio;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('保存期间继续输入：磁盘存 A，界面必须仍然算「有未保存修改」', (tester) async {
    // 编辑器是一个长 ListView，保存按钮在最后；把测试窗口调高，
    // 让整页都真的被构建出来（否则 find 不到按钮，也就点不了）。
    tester.view.physicalSize = const Size(1000, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final root = Directory.systemTemp.createTempSync('chatgal_studio_');
    addTearDown(() => root.deleteSync(recursive: true));
    final base = StudioStore(
      rootDir: root.path,
      installer: PackageInstaller(rootDir: root.path),
      packages: PackageStore(root.path),
    );
    final store = _SlowStudioStore(
      rootDir: root.path,
      installer: PackageInstaller(rootDir: root.path),
      packages: PackageStore(root.path),
    );
    // 真实文件 I/O 必须放在 runAsync 里：widget 测试的假时钟不会推进它。
    final project = await tester.runAsync(
      () => base.createBlank(
        name: '我的内容包',
        packageId: 'local.pack.test',
        version: '1',
      ),
    );
    // 用同一个目录：把 base 建好的工程交给会「慢写」的 store 使用。
    expect(store.exists(project!.slug), isTrue);

    final services = _Services(root, store);
    bool? dirty;
    var savedCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ManifestEditor(
            theme: ChatGalTheme.violet,
            services: services,
            slug: project.slug,
            onSaved: () => savedCount++,
            onDirtyChanged: (d) => dirty = d,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(dirty, isFalse, reason: '刚打开时没有未保存修改');

    // 改包名 → 变脏。
    // 用「controller 身份」定位这个字段：按文本找的话，改完一次就再也找不到它了。
    final initialName = find.byWidgetPredicate(
      (w) => w is TextField && w.controller?.text == '我的内容包',
    );
    expect(initialName, findsOneWidget);
    final nameController =
        (initialName.evaluate().single.widget as TextField).controller!;
    final nameField = find.byWidgetPredicate(
      (w) => w is TextField && w.controller == nameController,
    );
    await tester.enterText(nameField, '第一次改的名字');
    await tester.pump();
    expect(dirty, isTrue);

    // 写盘进入「慢速」，然后点保存。
    store.delay = const Duration(milliseconds: 400);
    await tester.tap(find.text('保存基础信息'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(store.writes, greaterThan(0), reason: '保存已经开始了');

    // 写盘还没结束（那 400ms 是假时钟，靠 pump 推进），用户继续输入 → 表单变成 B。
    // 一边推时钟一边给真实事件循环让路：文件 I/O 只在真实时区里完成。
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      if (i == 1) {
        await tester.enterText(nameField, '保存期间又改的名字');
      }
      if (savedCount > 0) break;
    }
    expect(savedCount, greaterThan(0), reason: '保存流程走完了');

    // 磁盘上是 A（点保存那一刻的内容）。
    final onDisk = store.readJson(project.slug, 'manifest.json')!;
    expect('${onDisk['name']}', '第一次改的名字');

    // 表格里是 B —— 所以必须仍然是「有未保存修改」，否则这次改动会静默丢掉。
    expect(
      dirty,
      isTrue,
      reason: '写盘期间又改了内容：磁盘上是 A、表单是 B，不能认为已保存',
    );
  });

  testWidgets('整页创作台：保存期间继续输入 → 退出工程仍弹草稿保护', (tester) async {
    // 复审 P1：编辑器上报了「还有草稿」，但父页面 _onSaved 又把脏状态清成
    // 干净 —— 退出保护与页签重建保护一起失效。这条测试跑**真实父页面回调**。
    tester.view.physicalSize = const Size(1000, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final root = Directory.systemTemp.createTempSync('chatgal_studio_page_');
    addTearDown(() => root.deleteSync(recursive: true));
    final base = StudioStore(
      rootDir: root.path,
      installer: PackageInstaller(rootDir: root.path),
      packages: PackageStore(root.path),
    );
    final store = _SlowStudioStore(
      rootDir: root.path,
      installer: PackageInstaller(rootDir: root.path),
      packages: PackageStore(root.path),
    );
    final project = await tester.runAsync(
      () => base.createBlank(
        name: '我的内容包',
        packageId: 'local.pack.page',
        version: '1',
      ),
    );
    final services = _Services(root, store);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => StudioEditorPage(
                    theme: ChatGalTheme.violet,
                    services: services,
                    slug: project!.slug,
                  ),
                ),
              ),
              child: const Text('打开编辑器'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开编辑器'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final initialName = find.byWidgetPredicate(
      (w) => w is TextField && w.controller?.text == '我的内容包',
    );
    expect(initialName, findsOneWidget);
    final nameController =
        (initialName.evaluate().single.widget as TextField).controller!;
    final nameField = find.byWidgetPredicate(
      (w) => w is TextField && w.controller == nameController,
    );

    // 编辑 A → 保存（慢速）→ 写盘期间改成 B。
    await tester.enterText(nameField, '第一次改的名字');
    await tester.pump();
    store.delay = const Duration(milliseconds: 400);
    await tester.tap(find.text('保存基础信息'));
    await tester.pump(const Duration(milliseconds: 50));
    var done = false;
    for (var i = 0; i < 40 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      if (i == 1) await tester.enterText(nameField, '保存期间又改的名字');
      done = store.writes > 0 &&
          find.textContaining('已保存').evaluate().isNotEmpty;
    }
    expect(find.textContaining('已保存'), findsOneWidget, reason: '保存走完了');

    // 退出工程：因为表单里还有 B 没落盘，必须弹草稿保护。
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.text('有未保存的修改'),
      findsOneWidget,
      reason: '父页面不能把编辑器上报的脏状态清掉',
    );
    expect(find.textContaining('基础信息'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
