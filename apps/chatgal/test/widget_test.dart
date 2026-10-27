import 'dart:io';

import 'package:chatgal/app/app_services.dart';
import 'package:chatgal/design_system/tokens.dart';
import 'package:chatgal/features/home/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('home shows package/save/start in bottom sheet', (tester) async {
    final root = Directory.systemTemp.createTempSync('chatgal_ui_');
    addTearDown(() => root.deleteSync(recursive: true));
    final services = AppServices.forTestRoot(root);

    await tester.pumpWidget(
      MaterialApp(
        theme: ChatGalTheme.violet.toThemeData(),
        home: HomePage(
          theme: ChatGalTheme.violet,
          services: services,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('内容包'), findsOneWidget);
    expect(find.text('存档'), findsOneWidget);
    expect(find.text('开始'), findsOneWidget);
    expect(find.text('新的开始'), findsOneWidget);
  });

  test('theme matrix has four themes', () {
    expect(ChatGalTheme.all, hasLength(4));
  });
}
