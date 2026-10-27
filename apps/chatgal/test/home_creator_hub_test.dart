import 'dart:io';

import 'package:chatgal/app/app_services.dart';
import 'package:chatgal/design_system/tokens.dart';
import 'package:chatgal/features/home/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 主页「创作」区：内容包创作台 + 创意工坊共用一张卡片。
///
/// 钉两件事：两个入口真的在同一张卡里（左对齐、上下相邻），以及点「创意工坊」
/// 在拿不到原生 WebView 时会给提示 —— 而不是静默什么都不发生。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('创作区把两个入口收在一张卡里，创意工坊点了会给提示', (tester) async {
    final root = Directory.systemTemp.createTempSync('chatgal_hub_');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ChatGalTheme.violet.toThemeData(),
        home: HomePage(
          theme: ChatGalTheme.violet,
          services: AppServices.forTestRoot(root),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));

    // 底部 sheet 初始只露出一点，两个入口要拖上来才会被 ListView 构建。
    await tester.drag(find.text('新的开始'), const Offset(0, -700));
    await tester.pumpAndSettle();

    final studio = find.text('内容包创作台');
    final workshop = find.text('创意工坊');
    expect(studio, findsOneWidget);
    expect(workshop, findsOneWidget);

    // 同一张卡：左边线一致，创意工坊在内容包创作台下面。
    final studioRect = tester.getRect(studio);
    final workshopRect = tester.getRect(workshop);
    expect(studioRect.left, closeTo(workshopRect.left, 0.5));
    expect(workshopRect.top, greaterThan(studioRect.top));

    // 系统浏览器通道：测试里让它失败，验证点击后给出复制提示。
    const sysChannel = MethodChannel('chatgal/system');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      sysChannel,
      (call) async {
        throw PlatformException(code: 'unavailable', message: '测试：打不开浏览器');
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(sysChannel, null),
    );

    // 先把它滚进可视区再点：ListView 会预构建屏幕外的项，只是「在树上」并不代表
    // 能点中（点屏幕外的坐标不会命中任何东西）。
    await tester.ensureVisible(workshop);
    await tester.pumpAndSettle();
    await tester.tap(workshop);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    // 创意工坊改为系统浏览器：通道不可用时给复制提示，不再走 WebView。
    expect(find.byType(SnackBar), findsOneWidget,
        reason: '点创意工坊在无法打开浏览器时要提示');
    expect(find.textContaining('复制'), findsWidgets);

    // 收尾：SnackBar 自带 4 秒计时器，先把树卸掉再推时间。
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
