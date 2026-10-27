import 'dart:io';

import 'package:chatgal/app/app_services.dart';
import 'package:chatgal/design_system/tokens.dart';
import 'package:chatgal/features/home/home_page.dart';
import 'package:chatgal/features/session/chat_page.dart';
import 'package:chatgal/features/settings/api_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';

/// 主页的「存档」格必须跟着**实际在玩的那一份档**走。
///
/// 从「新的开始」进游戏时，存档是进去之后才建出来的，主页这时记住的还是
/// 「新的开始」；退出后如果不接游戏页交回来的 id，玩家会看到自己**刚玩的档
/// 已经不在选中状态**，还得手动再挑一次（用户报的这个问题）。
const _ref = PackageRef(
  packageId: 'test.home.jump',
  version: '1',
  contentHash: 'test',
);

class _Packages extends PackageStore {
  _Packages(super.rootDir);
  @override
  PackageRef? findExact(String id, String version, String hash) => _ref;
}

class _Services implements AppServices {
  _Services(this.root);
  @override
  final Directory root;
  @override
  late final api = ApiSettingsStore(root.path);
  @override
  late final packages = _Packages(root.path);
  @override
  late final saves = SaveRepository(rootDir: root.path, packages: packages);

  @override
  List<PackageRef> listPackagesForHome() => const [_ref];

  @override
  String packageDisplayName(PackageRef ref) => '测试包';

  @override
  PlaySessionData loadPlaySession(PackageRef ref) {
    final scene = SceneDef.fromJson({
      'displayName': '主页跳档测试',
      'background': '',
      'narration': '测试场景',
      'characters': [],
      'target': [
        {
          'kind': [
            {'kind': 'appShell', 'to': 'home'},
          ],
        },
      ],
    }, id: 'start');
    final graph = SceneGraph(scenes: {'start': scene}, entrypoint: 'start');
    return PlaySessionData(
      characterName: '测试',
      packageTitle: '测试包',
      packageIntro: '',
      characterPrompt: '',
      installDir: root.path,
      sceneGraph: graph,
      content: PackageContent(
        manifest: const PackageManifest(
          packageId: 'test.home.jump',
          version: '1',
          name: '测试包',
          author: 'test',
          description: '',
        ),
        characters: [],
        variables: [],
        scenes: graph.scenes,
        sceneGraph: graph,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 假时钟下等真实 IO：每轮推一帧假时间 + 让出真实时间给写盘。
Future<void> settleIo(
  WidgetTester tester, {
  bool Function()? until,
  int rounds = 60,
}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 60));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    if (until != null && until()) return;
  }
}

void main() {
  testWidgets('新的开始 → 进游戏 → 退出：主页跳到刚建的那个档', (tester) async {
    final root = Directory.systemTemp.createTempSync('chatgal_home_jump_');
    addTearDown(() => root.deleteSync(recursive: true));
    final services = _Services(root);

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(theme: ChatGalTheme.violet, services: services),
      ),
    );
    await tester.pumpAndSettle();
    // 一开始没有存档 → 这一格显示「新的开始」
    expect(find.text('新的开始'), findsWidgets);

    // 点「开始」→ 弹出命名新存档
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '我的新档');
    await tester.tap(find.text('开始').last);
    // ⚠ 进游戏之后**不能** pumpAndSettle：输入框一锁住，里面是无限循环的
    // 动效省略号，pumpAndSettle 永远等不到静止（会挂到它自己的 10 分钟超时）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ChatPage), findsOneWidget);

    // 新档是进去之后才落盘的：等它真的写到磁盘（_saveId 有了，退出才能带回来）
    await settleIo(
      tester,
      until: () => services.saves.listSaves().isNotEmpty,
      rounds: 120,
    );
    expect(services.saves.listSaves(), isNotEmpty, reason: '新档应该已经落盘');

    // 退出：点左上返回 → 确认对话框
    await tester.tap(find.byIcon(Icons.arrow_back));
    // 同上：这时候页面还在锁着（开场白/打字机），只用 pump 推帧
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    if (find.text('确定返回').evaluate().isNotEmpty) {
      await tester.tap(find.text('确定返回'));
    } else {
      // 正在回复中的分支：同样能离开，只是文案不同
      await tester.tap(find.text('返回'));
    }
    await settleIo(
      tester,
      until: () => find.byType(ChatPage).evaluate().isEmpty,
      rounds: 120,
    );
    await tester.pump();
    expect(find.byType(ChatPage), findsNothing);

    // 主页这一格应该已经是刚建的那个档，而不是还停在「新的开始」
    expect(find.text('我的新档'), findsOneWidget);
    expect(find.text('新的开始'), findsNothing);
    // 而且它被记进了设置：下次启动继续用它
    final prefs = services.api.load();
    expect(prefs.lastSaveId, services.saves.listSaves().single.saveId);

    // 收尾：先卸掉整棵树再推时间，让聊天页里那些计时器（跑马灯的 500ms）
    // 随 State.dispose 一起取消，否则测试框架会报「还有 Timer 在跑」。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
