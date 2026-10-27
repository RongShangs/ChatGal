import 'dart:io';

import 'package:chatgal/app/app_services.dart';
import 'package:chatgal/design_system/tokens.dart';
import 'package:chatgal/features/home/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 主页背景的铺法：
/// * 上沿贴屏幕顶、**下沿停在抽屉收起时的顶边**（抽屉顶部的两个圆角是切掉的，
///   图伸到它们下面就会从圆弧外侧露出边角）；
/// * 区域内 `cover` —— 上下钉满、左右按比例裁切，但**不改图本身的比例**。
///
/// 这里断的是坐标：背景层的下边界必须等于抽屉的上边界。两者共用
/// `_sheetCollapsed`，所以任何一处被改歪都会红。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('背景层下沿与抽屉顶边对齐（不伸到抽屉下面）', (tester) async {
    final root = Directory.systemTemp.createTempSync('chatgal_bg_');
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

    final bg = tester.getRect(find.byKey(const ValueKey('home-bg')));
    final screenH =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;

    // 上沿贴屏幕顶。
    expect(bg.top, closeTo(0, 0.5));
    // 下沿越过抽屉顶边**一个圆角高度**（0.76 + 32/屏高）：圆角弧线外侧仍属
    // 可见的背景区，不越过去那两个角就会露出底色。
    expect(bg.height, closeTo(screenH * 0.76 + 32, 2.0));
    // 确实没铺满整屏 —— 伸到抽屉下面就会从圆角外侧露出边角。
    expect(bg.bottom, lessThan(screenH));

    await tester.pumpWidget(const SizedBox());
  });
}
