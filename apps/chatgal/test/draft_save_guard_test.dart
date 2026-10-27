import 'package:chatgal/design_system/tokens.dart';
import 'package:chatgal/features/studio/scene_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final saved in [false, true]) {
    testWidgets('草稿保存${saved ? '成功允许切换' : '失败保留表单'}', (tester) async {
      bool? maySwitch;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  maySwitch = await confirmDiscardDraft(
                    context,
                    ChatGalTheme.violet,
                    what: '测试情景',
                    onSave: () async => saved,
                  );
                },
                child: const Text('切换'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('切换'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(maySwitch, saved);
    });
  }
}
