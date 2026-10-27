import 'dart:io';

import 'package:chatgal/design_system/tokens.dart';
import 'package:chatgal/features/logs/log_page.dart';
import 'package:chatgal/features/settings/api_settings.dart';
import 'package:chatgal/features/settings/font_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 钉住两处**层级顺序**（用户提过、容易被后续改动弄反）：
/// * 运行日志：「保留条数」（设置）在级别筛选（筛选器）**上方**；
/// * 字体与字号：先「字号」，再「预设字体」。
///
/// 这类顺序只能靠坐标断言，文本本身看不出前后。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('chatgal_order_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets('日志页：保留条数在级别筛选上方', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LogPage(theme: ChatGalTheme.violet, api: ApiSettingsStore(root.path)),
      ),
    );
    await tester.pump();

    final limit = find.text('保留条数');
    final allChip = find.text('全部');
    expect(limit, findsOneWidget);
    expect(allChip, findsOneWidget);

    final limitY = tester.getTopLeft(limit).dy;
    final chipY = tester.getTopLeft(allChip).dy;
    expect(
      limitY,
      lessThan(chipY),
      reason: '「保留条数」是设置项，要排在「全部/调试/信息…」这排筛选胶囊之上',
    );
  });

  testWidgets('字体页：字号在预设字体上方', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FontSettingsPage(
          theme: ChatGalTheme.violet,
          api: ApiSettingsStore(root.path),
        ),
      ),
    );
    await tester.pump();

    final size = find.text('字号');
    final presets = find.text('预设字体');
    expect(size, findsOneWidget);
    expect(presets, findsOneWidget);

    expect(
      tester.getTopLeft(size).dy,
      lessThan(tester.getTopLeft(presets).dy),
      reason: '先「多大」再「哪一种」，字号要排在预设字体之上',
    );
  });
}
